#!/bin/bash
# goldrec-e2e.sh - end-to-end check of apps/goldrec against the real MT5
# terminal (Wine, Docker) + GoBridge EA. Passes when goldrec has recorded
#   * >= MIN_TICKS broker gold ticks in prices.jsonl,
#   * >= 2 positioning observations in sentiment.jsonl (replay by default),
#   * and, with --restart, ticks again after the terminal container restarts
#     (EA reconnect -> re-subscribe).
#
# Usage: scripts/goldrec-e2e.sh [options]
#   --broker-symbol S   broker gold symbol (default XAUUSD)
#   --source S          replay (default; synthetic fixtures, labelled) | api (needs MYFXBOOK_* env)
#   --interval D        positioning interval (default 15s)
#   --min-ticks N       (default 3)
#   --restart           also restart the terminal and require ticks after reconnect
#   --timeout S         seconds per wait (default 300)
#   --port P            (default 7789)
#   --require-live      fail unless ticks arrive with trade_server_connected=true
#                       (needs MT5_LOGIN/MT5_PASSWORD/MT5_SERVER); fails at once when
#                       the journal shows the login cannot work (see login_failure)
#   --servers-dat FILE  install FILE as the terminal's config/servers.dat (a desktop MT5's
#                       copy that knows the broker): a config login to a named server
#                       (MT5_SERVER=FTMO-Demo) then works without any UI
#   --state DIR         keep the terminal's servers.dat in DIR (installed from it at start
#                       when present, saved back while running and at stop): after one
#                       successful login, later runs log in from the config alone
#   --keep              leave the terminal running
#   --out DIR           evidence directory (default e2e-out/goldrec-<timestamp>)
#
# Broker account: MT5_LOGIN/MT5_PASSWORD/MT5_SERVER are passed to the terminal
# when set (otherwise it runs without a trade server: cached quotes only). The
# login is config-only (no UI): MT5_SERVER must be "address:port" or a name
# listed in the terminal's config/servers.dat (--servers-dat / --state).
# --source api needs MYFXBOOK_EMAIL/MYFXBOOK_PASSWORD.
#
# Exit 0 = PASS. Requires gomql5/mt5:local (build with scripts/e2e.sh --build).
set -euo pipefail
cd "$(dirname "$0")/.."

SYM=XAUUSD SOURCE=replay INTERVAL=15s MIN_TICKS=3 RESTART=0 TIMEOUT=300 PORT=7789 KEEP=0 OUT=""
LIVE=0 SERVERS_DAT="" STATE_DIR=""
while [ $# -gt 0 ]; do
  case $1 in
    --broker-symbol) SYM=$2; shift ;;
    --source) SOURCE=$2; shift ;;
    --interval) INTERVAL=$2; shift ;;
    --min-ticks) MIN_TICKS=$2; shift ;;
    --restart) RESTART=1 ;;
    --timeout) TIMEOUT=$2; shift ;;
    --port) PORT=$2; shift ;;
    --keep) KEEP=1 ;;
    --require-live) LIVE=1 ;;
    --servers-dat) SERVERS_DAT=$2; shift ;;
    --state) STATE_DIR=$2; shift ;;
    --out) OUT=$2; shift ;;
    -h | --help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "goldrec-e2e: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
TS=$(date +%Y%m%d-%H%M%S)
OUT="${OUT:-e2e-out/goldrec-$TS}"
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
DATA=$OUT/data
IMAGE=gomql5/mt5:local NAME=gomql5-goldrec-$TS TOKEN=goldrec-e2e APP_PID=""
say() { echo "[goldrec-e2e] $*"; }
lines() { [ -f "$1" ] && wc -l <"$1" || echo 0; }

docker image inspect "$IMAGE" >/dev/null 2>&1 || { say "FAIL: $IMAGE missing (scripts/e2e.sh --build)"; exit 1; }
go build -o "$OUT/goldrec" ./apps/goldrec
GOBRIDGE_TOKEN=$TOKEN "$OUT/goldrec" -out "$DATA" -source "$SOURCE" -interval "$INTERVAL" \
  -listen "127.0.0.1:$PORT" -broker-symbol "$SYM" >"$OUT/goldrec.log" 2>&1 &
APP_PID=$!

start_terminal() {
  local acct=()
  for v in MT5_LOGIN MT5_PASSWORD MT5_SERVER; do [ -n "${!v:-}" ] && acct+=(-e "$v"); done
  if [ -n "$SERVERS_DAT" ]; then
    [ -s "$SERVERS_DAT" ] || { say "FAIL: --servers-dat $SERVERS_DAT missing or empty"; exit 1; }
    acct+=(-v "$(cd "$(dirname "$SERVERS_DAT")" && pwd)/$(basename "$SERVERS_DAT"):/gomql5/servers.dat:ro" -e MT5_SERVERS_DAT=/gomql5/servers.dat)
  fi
  if [ -n "$STATE_DIR" ]; then
    mkdir -p "$STATE_DIR"
    acct+=(-v "$(cd "$STATE_DIR" && pwd):/gomql5-state" -e GOMQL5_STATE_DIR=/gomql5-state)
  fi
  docker run -d --rm --name "$NAME" --network host --shm-size 512m "${acct[@]}" \
    -e GOBRIDGE_TOKEN=$TOKEN -e GOBRIDGE_HOST=127.0.0.1 -e GOBRIDGE_PORT="$PORT" "$IMAGE" >/dev/null
}
collect() {
  docker logs "$NAME" >"$OUT/container.log" 2>&1 || true
  if [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" = "true" ]; then
    scripts/mt5ctl.sh -c "$NAME" -o "$OUT" status >"$OUT/status.txt" 2>&1 || true
    # Visible terminal windows (main window title shows the account once logged in; dialogs show up here too).
    scripts/mt5ctl.sh -c "$NAME" exec 'for w in $(xdotool search --onlyvisible --class terminal64 2>/dev/null); do echo "$w $(xdotool getwindowname "$w")"; done' >"$OUT/windows.txt" 2>&1 || true
    scripts/mt5ctl.sh -c "$NAME" -o "$OUT" shot screen >/dev/null 2>&1 || true
    scripts/mt5ctl.sh -c "$NAME" -o "$OUT" goto experts-log >/dev/null 2>&1 || true
    scripts/mt5ctl.sh -c "$NAME" -o "$OUT" goto journal >/dev/null 2>&1 || true
    scripts/mt5ctl.sh -c "$NAME" -o "$OUT" logs terminal 400 >"$OUT/terminal.log" 2>&1 || true
    scripts/mt5ctl.sh -c "$NAME" -o "$OUT" logs compile >"$OUT/compile.log" 2>&1 || true
  fi
}
cleanup() {
  collect
  [ -n "$APP_PID" ] && kill -INT "$APP_PID" 2>/dev/null && wait "$APP_PID" 2>/dev/null || true
  if [ $KEEP = 1 ]; then say "--keep: terminal left running as $NAME"; else docker stop -t 30 "$NAME" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT

# wait_for COND_DESC TEST_CMD
wait_for() {
  local desc=$1; shift
  local deadline=$((SECONDS + TIMEOUT))
  while [ $SECONDS -lt $deadline ]; do
    if "$@"; then return 0; fi
    if ! kill -0 "$APP_PID" 2>/dev/null; then say "FAIL: goldrec exited"; tail -20 "$OUT/goldrec.log"; exit 1; fi
    if grep -q 'broker symbol unavailable' "$OUT/goldrec.log"; then
      say "FAIL: broker symbol $SYM unavailable: $(grep -m1 'broker symbol unavailable' "$OUT/goldrec.log")"; exit 1
    fi
    if docker logs "$NAME" 2>&1 | grep -qE 'compilation failed|cannot resolve'; then
      say "FAIL: container: $(docker logs "$NAME" 2>&1 | grep -E 'compilation failed|cannot resolve' | head -1)"; exit 1
    fi
    sleep 3
  done
  say "FAIL: timed out waiting for $desc"; exit 1
}
have_ticks() { [ "$(lines "$DATA/prices.jsonl")" -ge "$1" ]; }
have_obs() { [ "$(lines "$DATA/sentiment.jsonl")" -ge 2 ]; }
# count PATTERN FILE: matching lines, 0 when none or no file. (Not
# `grep -c … || echo 0`: with no match grep prints 0 AND fails, giving "0\n0".)
count() { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); echo "${n:-0}"; }
connects() { [ "$(count '"kind":"terminal_connected"' "$DATA/events.jsonl")" -ge "$1" ]; }
have_live_ticks() { [ "$(count '"trade_server_connected":true' "$DATA/prices.jsonl")" -ge "$1" ]; }
# The LATEST terminal_info event says connected (goldrec writes one per EA
# connection and on every change; an earlier "true" says nothing after a
# restart or an account switch).
trade_connected() { grep '"kind":"terminal_info"' "$DATA/events.jsonl" 2>/dev/null | tail -1 | grep -q '"trade_server_connected":true'; }
# Echo the terminal's Network journal lines (login progress) once each.
SEEN_NET=0
show_network() {
  local all n
  all=$(scripts/mt5ctl.sh -c "$NAME" logs terminal 400 2>/dev/null | grep -E $'\tNetwork\t' || true)
  n=$(printf '%s' "$all" | grep -c . || true)
  if [ "$n" -gt "$SEEN_NET" ]; then printf '%s\n' "$all" | tail -n $((n - SEEN_NET)) | sed 's/^/[goldrec-e2e] journal: /'; SEEN_NET=$n; fi
}

say "goldrec on 127.0.0.1:$PORT (source=$SOURCE, broker symbol $SYM); terminal $NAME"
start_terminal
# login_failure SERVER (stdin = terminal journal): print why a config login to
# SERVER cannot succeed and return 0, or return 1 when the journal shows no such
# sign (yet). Two shapes, both from real runs (testdata/journal-ftmo-wizard.txt):
#   * a server name the terminal doesn't know (not in config/servers.dat) falls
#     back to MetaQuotes-Demo: "authorization on MetaQuotes-Demo failed (Invalid account)";
#   * the server itself rejects the account: "authorization on SERVER failed (...)".
SERVERS_DAT_HINT="provide a servers.dat that lists it (MT5_SERVERS_DAT=/path/to/servers.dat, copied from a desktop MT5 that has logged in to the broker once: File > Open Data Folder > config/servers.dat) or set MT5_SERVER=address:port"
login_failure() {
  local srv=$1 net line
  net=$(grep -E $'\tNetwork\t' || true) # (`|| true`: no match is normal under set -euo pipefail)
  if [ "$srv" != MetaQuotes-Demo ] && line=$(printf '%s\n' "$net" | grep -E "(authorization on|authorized on) MetaQuotes-Demo( |$)" | tail -1) && [ -n "$line" ]; then
    echo "the terminal does not know MT5_SERVER=$srv and fell back to MetaQuotes-Demo (journal: ${line##*$'\t'}): $SERVERS_DAT_HINT"
    return 0
  fi
  if [ -n "$srv" ] && line=$(printf '%s\n' "$net" | grep -F "authorization on $srv failed" | tail -1) && [ -n "$line" ]; then
    echo "$srv rejected the login (journal: ${line##*$'\t'}): check MT5_LOGIN/MT5_PASSWORD; if they are right, the servers.dat entry for $srv may be stale: $SERVERS_DAT_HINT"
    return 0
  fi
  return 1
}
# ensure_live LIVE_TICKS_NEEDED: wait for the config login to reach the trade
# server, failing at once when the journal shows it cannot; then wait for live ticks.
ensure_live() {
  local need=$1
  [ -n "${MT5_LOGIN:-}" ] && [ -n "${MT5_PASSWORD:-}" ] || { say "FAIL: --require-live needs MT5_LOGIN/MT5_PASSWORD/MT5_SERVER"; exit 1; }
  live_or_fail() {
    local why
    show_network
    trade_connected && return 0
    if why=$(scripts/mt5ctl.sh -c "$NAME" logs terminal 5000 2>/dev/null | login_failure "${MT5_SERVER:-}"); then
      say "FAIL: $why"; exit 1
    fi
    return 1
  }
  wait_for "trade-server connection (account $MT5_LOGIN on ${MT5_SERVER:-?})" live_or_fail
  say "trade server connected"
  wait_for "$need live $SYM ticks" have_live_ticks "$need"
}
if [ $LIVE = 1 ]; then
  wait_for "EA connection" connects 1
  ensure_live "$MIN_TICKS"
fi
wait_for "$MIN_TICKS $SYM ticks" have_ticks "$MIN_TICKS"
wait_for "2 positioning observations" have_obs
if [ $RESTART = 1 ]; then
  before=$(lines "$DATA/prices.jsonl")
  before_live=$(count '"trade_server_connected":true' "$DATA/prices.jsonl")
  before_conn=$(count '"kind":"terminal_connected"' "$DATA/events.jsonl")
  say "restarting terminal (had $before ticks, $before_conn EA connections)"
  docker stop -t 30 "$NAME" >/dev/null
  wait_for "disconnect event" grep -q '"kind":"terminal_disconnected"' "$DATA/events.jsonl"
  gone() { ! docker inspect "$NAME" >/dev/null 2>&1; }
  wait_for "old container removed" gone
  start_terminal
  wait_for "reconnect" connects $((before_conn + 1))
  if [ $LIVE = 1 ]; then
    ensure_live $((before_live + 1)) # a fresh container starts logged out again
  fi
  wait_for "ticks after reconnect" have_ticks $((before + 1))
fi
sleep 2 # let one flush/status cycle pass
say "PASS: $(lines "$DATA/prices.jsonl") ticks, $(lines "$DATA/sentiment.jsonl") positioning observations, $(grep -c terminal_connected "$DATA/events.jsonl") connections"
if grep -q '"trade_server_connected":false' "$DATA/prices.jsonl"; then
  say "      NOTE: terminal had no trade-server connection: ticks are cached quotes, not live prices"
fi
say "      first tick: $(head -1 "$DATA/prices.jsonl")"
say "      last observation: $(tail -1 "$DATA/sentiment.jsonl" | cut -c1-400)"
say "      evidence: $OUT (goldrec.log, data/, terminal.log, screen.png, journal.png, experts-log.png)"
