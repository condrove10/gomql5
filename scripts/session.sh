#!/bin/bash
# session.sh - run a full verification session and write ONE log file plus an
# evidence bundle you can hand back for review.
#
# Usage: scripts/session.sh [STEP...]        (default: all steps, in order)
#
# Steps:
#   env          versions, git revision, disk, docker, which credentials are SET (never their values)
#   check        go vet + go test -race (unit, FakeEA mock, seed corpora of the fuzz targets)
#   shell        docker/mt5/test/*_test.sh
#   fuzz         every Go fuzz target for $FUZZTIME (default 20s) each
#   image        build gomql5/mt5:local (proxy/CA/mirror settings from the environment)
#   probe-net    host egress: Myfxbook API (unauthenticated), MetaQuotes site, the MT5 server name
#   probe-api    goldrec -source api -once        (needs MYFXBOOK_EMAIL/MYFXBOOK_PASSWORD; else skipped)
#   e2e          scripts/e2e.sh                   (bridge smoke test)
#   e2e-goldrec  scripts/goldrec-e2e.sh on EURUSD with a restart (pipeline; works without an account)
#   e2e-live     scripts/goldrec-e2e.sh --require-live on $BROKER_SYMBOL with a restart
#                (needs MT5_LOGIN/MT5_PASSWORD/MT5_SERVER; else skipped)
#
# Credentials come from the environment, or from the file $E2E_ENV (default
# .env, never committed). Use the account's READ-ONLY (investor) password: the
# recorder only needs quotes. Every secret value is replaced by [REDACTED] in
# the log, and the bundle is scanned for leftovers before it is written.
#
# Output: session-out/<timestamp>/session.log, plus every step's evidence
# directory, and session-out/<timestamp>.tar.gz. Steps keep going after a
# failure; the summary at the end lists PASS/FAIL/SKIP per step.
#
# Settings: FUZZTIME, BROKER_SYMBOL (XAUUSD), FIND_BROKER (broker directory
# search term, e.g. FTMO), POSITIONING_SOURCE (replay | api), E2E_TIMEOUT (600),
# plus e2e.sh's E2E_CA_CERT, HTTPS_PROXY, BASE_IMAGE, GO_IMAGE.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)

E2E_ENV="${E2E_ENV:-.env}"
if [ -f "$E2E_ENV" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$E2E_ENV"
  set +a
fi
FUZZTIME="${FUZZTIME:-20s}"
BROKER_SYMBOL="${BROKER_SYMBOL:-XAUUSD}"
FIND_BROKER="${FIND_BROKER:-}"
POSITIONING_SOURCE="${POSITIONING_SOURCE:-replay}"
E2E_TIMEOUT="${E2E_TIMEOUT:-600}"

# A noexec /tmp breaks `go test`; see scripts/gotmpdir.sh.
GOTMPDIR="$(bash scripts/gotmpdir.sh)"
if [ -n "$GOTMPDIR" ]; then export GOTMPDIR; else unset GOTMPDIR; fi

TS=$(date -u +%Y%m%dT%H%M%SZ)
OUT="$ROOT/session-out/$TS"
mkdir -p "$OUT"
LOG="$OUT/session.log"

# --- redaction: every line of output goes through this filter ----------------
SECRET_VARS=(MT5_PASSWORD MYFXBOOK_PASSWORD MYFXBOOK_EMAIL GOBRIDGE_TOKEN VNC_PASSWORD)
redact() {
  perl -pe 'BEGIN { $| = 1; @s = grep { length($_) >= 3 } map { $ENV{$_} // "" } split / /, $ENV{SECRET_VAR_LIST} }
            for my $s (@s) { s/\Q$s\E/[REDACTED]/g }'
}
export SECRET_VAR_LIST="${SECRET_VARS[*]}"
for v in "${SECRET_VARS[@]}"; do export "${v}=${!v:-}"; done
exec > >(redact | while IFS= read -r line; do printf '%s %s\n' "$(date -u +%H:%M:%S)" "$line"; done | tee -a "$LOG") 2>&1
LOGGER_PID=$!

declare -A RESULT
ORDER=()
step() { # NAME CMD...
  local name=$1; shift
  ORDER+=("$name")
  echo
  echo "=================== STEP $name ==================="
  echo "\$ $*"
  local t0=$SECONDS rc
  "$@"
  rc=$?
  case $rc in
    0) RESULT[$name]="PASS" ;;
    77) RESULT[$name]="SKIP" ;;
    *) RESULT[$name]="FAIL (exit $rc)" ;;
  esac
  echo "=================== END $name: ${RESULT[$name]} in $((SECONDS - t0))s ==================="
}
skip() { echo "SKIP: $*"; return 77; }
have() { [ -n "${!1:-}" ]; }

s_env() {
  echo "date (UTC): $(date -u)"
  echo "host: $(uname -a)"
  if git rev-parse --git-dir >/dev/null 2>&1; then
    echo "git: $(git rev-parse --abbrev-ref HEAD) $(git rev-parse --short HEAD) $(git status --porcelain | wc -l) uncommitted file(s)"
  else
    echo "git: not a git checkout (e.g. a zip download)"
  fi
  echo "go: $(go version 2>&1)"
  echo "docker: $(docker version --format '{{.Server.Version}}' 2>&1)"
  local img
  img=$(docker image inspect -f '{{.Id}} created {{.Created}}' gomql5/mt5:local 2>/dev/null) || img="gomql5/mt5:local not built yet"
  echo "image: $img"
  echo "temp dir: ${TMPDIR:-/tmp} ($(findmnt -no OPTIONS --target "${TMPDIR:-/tmp}" 2>/dev/null || echo 'mount options unknown'))"
  echo "go work dir (GOTMPDIR): ${GOTMPDIR:-Go default}"
  echo "disk: $(df -h . | tail -1)"
  echo "env file: $E2E_ENV $([ -f "$E2E_ENV" ] && echo present || echo absent)"
  for v in MT5_LOGIN MT5_SERVER BROKER_SYMBOL FIND_BROKER POSITIONING_SOURCE FUZZTIME HTTPS_PROXY BASE_IMAGE GO_IMAGE E2E_CA_CERT; do
    echo "  $v=${!v:-<unset>}"
  done
  for v in MT5_PASSWORD MYFXBOOK_EMAIL MYFXBOOK_PASSWORD; do
    echo "  $v: $(have "$v" && echo set || echo unset)"
  done
  return 0
}
s_check() { go vet ./... && go test -race -count=1 ./...; }
s_shell() { local rc=0 t; for t in docker/mt5/test/*_test.sh; do echo "-- $t"; bash "$t" || rc=1; done; return $rc; }
s_fuzz() {
  local rc=0 pkg fn
  while read -r pkg fn; do
    echo "-- $pkg $fn ($FUZZTIME)"
    go test -run '^$' -fuzz "^${fn}\$" -fuzztime "$FUZZTIME" "./$pkg" >"$OUT/fuzz.tmp" 2>&1 || rc=1
    # keep the last progress line (execs, coverage) and anything that is not progress
    grep -vE '^fuzz: elapsed: ' "$OUT/fuzz.tmp"; grep -E '^fuzz: elapsed: ' "$OUT/fuzz.tmp" | tail -1
    rm -f "$OUT/fuzz.tmp"
    # A failing input is saved under <pkg>/testdata/fuzz/<fn>/ : copy it into the bundle.
    [ -d "$pkg/testdata/fuzz/$fn" ] && cp -r "$pkg/testdata/fuzz/$fn" "$OUT/fuzz-crashers-$fn"
  done < <(grep -rl --include='*_test.go' '^func Fuzz' . | while read -r f; do
    grep -o '^func Fuzz[A-Za-z0-9_]*' "$f" | sed 's/^func //' | while read -r fn; do echo "$(dirname "${f#./}") $fn"; done
  done)
  return $rc
}
s_image() { scripts/e2e.sh --build --image-only --out "$OUT/image"; }
s_probe_net() {
  local u
  for u in "https://www.myfxbook.com/api/get-community-outlook.json?session=" "https://www.metatrader5.com/" "https://www.mql5.com/"; do
    echo "-- GET ${u%%\?*}"
    curl -sS -m 20 -o "$OUT/probe-body.txt" -w "   http=%{http_code} type=%{content_type} bytes=%{size_download} time=%{time_total}s\n" "$u" || echo "   transport error"
    head -c 200 "$OUT/probe-body.txt" | tr -d '\r' | sed 's/^/   body: /'; echo
  done
  if have MT5_SERVER; then
    echo "-- MT5 server '$MT5_SERVER': the terminal resolves it through MetaQuotes' broker directory, not DNS."
    echo "   Watch the e2e-live step's 'journal: ... Network' lines and find-broker screenshot for the outcome."
  fi
  rm -f "$OUT/probe-body.txt"
  return 0
}
s_probe_api() {
  have MYFXBOOK_EMAIL && have MYFXBOOK_PASSWORD || { skip "MYFXBOOK_EMAIL/MYFXBOOK_PASSWORD not set"; return; }
  go run ./apps/goldrec -source api -once -out "$OUT/probe-api"
  local rc=$?
  echo "-- attempts:"; cat "$OUT/probe-api/attempts.jsonl" 2>/dev/null
  echo "-- XAUUSD observation:"; cat "$OUT/probe-api/sentiment.jsonl" "$OUT/probe-api/quarantine.jsonl" 2>/dev/null
  return $rc
}
s_e2e() { scripts/e2e.sh --timeout "$E2E_TIMEOUT" --out "$OUT/e2e"; }
s_e2e_goldrec() {
  # Runs with no account on purpose (the pipeline check works on cached quotes).
  env -u MT5_LOGIN -u MT5_PASSWORD -u MT5_SERVER \
    scripts/goldrec-e2e.sh --broker-symbol EURUSD --min-ticks 1 --restart --timeout "$E2E_TIMEOUT" --out "$OUT/e2e-goldrec"
}
s_e2e_live() {
  have MT5_LOGIN && have MT5_PASSWORD && have MT5_SERVER || { skip "MT5_LOGIN/MT5_PASSWORD/MT5_SERVER not set"; return; }
  local args=(--require-live --broker-symbol "$BROKER_SYMBOL" --min-ticks 5 --restart --timeout "$E2E_TIMEOUT"
    --source "$POSITIONING_SOURCE" --out "$OUT/e2e-live")
  [ -n "$FIND_BROKER" ] && args+=(--find-broker "$FIND_BROKER")
  scripts/goldrec-e2e.sh "${args[@]}"
  local rc=$?
  echo "-- live price sample:"; grep '"trade_server_connected":true' "$OUT/e2e-live/data/prices.jsonl" 2>/dev/null | head -3
  echo "-- terminal journal (Network/account lines):"
  grep -E $'\t(Network|Terminal)\t' "$OUT/e2e-live/terminal.log" 2>/dev/null | tail -30
  return $rc
}

ALL=(env check shell fuzz image probe-net probe-api e2e e2e-goldrec e2e-live)
STEPS=("$@")
[ ${#STEPS[@]} -gt 0 ] || STEPS=("${ALL[@]}")
echo "gomql5 verification session $TS -> $OUT"
echo "steps: ${STEPS[*]}"
for s in "${STEPS[@]}"; do
  case $s in
    env) step env s_env ;;
    check) step check s_check ;;
    shell) step shell s_shell ;;
    fuzz) step fuzz s_fuzz ;;
    image) step image s_image ;;
    probe-net) step probe-net s_probe_net ;;
    probe-api) step probe-api s_probe_api ;;
    e2e) step e2e s_e2e ;;
    e2e-goldrec) step e2e-goldrec s_e2e_goldrec ;;
    e2e-live) step e2e-live s_e2e_live ;;
    *) echo "unknown step '$s' (have: ${ALL[*]})"; RESULT[$s]="FAIL (unknown step)"; ORDER+=("$s") ;;
  esac
done

# --- bundle --------------------------------------------------------------------
leak=0
for v in "${SECRET_VARS[@]}"; do
  val="${!v:-}"
  [ ${#val} -ge 3 ] || continue
  if grep -rlaF -- "$val" "$OUT" >/dev/null 2>&1; then
    echo "WARNING: value of $v found in: $(grep -rlaF -- "$val" "$OUT" | tr '\n' ' ') (redacting)"
    grep -rlaF -- "$val" "$OUT" | while read -r f; do V="$val" perl -pi -e 's/\Q$ENV{V}\E/[REDACTED]/g' "$f"; done
    leak=1
  fi
done
echo
echo "=================== SUMMARY $TS ==================="
fails=0
for s in "${ORDER[@]}"; do
  printf '  %-12s %s\n' "$s" "${RESULT[$s]}"
  case ${RESULT[$s]} in FAIL*) fails=$((fails + 1)) ;; esac
done
echo "  secrets in bundle: $([ $leak = 0 ] && echo none found || echo 'found and redacted (see warnings)')"
echo "  log:    $LOG"
echo "  bundle: $OUT.tar.gz"
rc=0; [ $fails = 0 ] || rc=1
# Close our end of the logging pipeline and wait for it to drain, so the
# archive holds the whole log.
exec 1>&- 2>&-
wait "$LOGGER_PID" 2>/dev/null || true # bash >= 5.1 waits for the process substitution
tar -C "$ROOT/session-out" --exclude="$TS/*/goldrec" --exclude="$TS/*/basic" -czf "$OUT.tar.gz" "$TS" 2>/dev/null
exit $rc
