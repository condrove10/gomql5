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
#   --restart           also restart the terminal and require ticks after reconnect; with
#                       --require-live: 3 fresh records, the first above the last one before
#   --timeout S         seconds per wait (default 300); with --require-live also the cap,
#                       counted from the container start, on reaching MIN_TICKS live ticks
#   --port P            (default 7789)
#   --require-live      PASS only when goldrec -check-live says the expected login and server
#                       hold, the window title agrees, and at least 3 (and MIN_TICKS)
#                       fresh records followed (needs MT5_LOGIN/MT5_PASSWORD/MT5_SERVER);
#                       refuses to start the terminal when preflight_live fails, and fails
#                       at once when the journal shows the server rejected the login
#   --live-budget S     with --require-live: the EA, the identity, the symbol and the first
#                       fresh record must all be there within S seconds of the terminal
#                       container starting (default 120), else FAIL with the first of them
#                       missing (see ensure_live); applies again after --restart.
#                       Phase timings go to the output and to OUT/timings.txt
#   --servers-dat FILE  install FILE as the terminal's config/servers.dat (a desktop MT5's
#                       copy that knows the broker): a config login to a named server
#                       (MT5_SERVER=FTMO-Demo) then works without any UI
#   --state DIR         the terminal's servers.dat, kept in DIR. A run starts from DIR's copy
#                       only when servers.dat.verified names this server and that file's
#                       sha256. A --require-live PASS copies the run's copy back to DIR once
#                       the terminal has stopped and writes that marker, so later runs log in
#                       from the config alone. A failed run never writes to DIR
#   --keep              leave the terminal running
#   --out DIR           evidence directory (default e2e-out/goldrec-<timestamp>)
#
# Broker account: MT5_LOGIN/MT5_PASSWORD/MT5_SERVER are passed to the terminal
# when set (otherwise it runs without a trade server: cached quotes only). The
# login is config-only (no UI): MT5_SERVER must be "address:port" or a name
# listed in the terminal's config/servers.dat (--servers-dat / --state).
# MT5_EXPECT_SERVER is the server the account must end up on: it defaults to
# MT5_SERVER when that is a name, is required when that is address:port (take it
# from the broker's account email, never from terminal output), and may not be a
# MetaQuotes-* server (the terminal's own fallback).
# --source api needs MYFXBOOK_EMAIL/MYFXBOOK_PASSWORD.
#
# Exit 0 = PASS, else the failure's rc (never 77: scripts/session.sh reports that as SKIP).
# OUT/result.txt always holds reason=, rc=, stage= and elapsed= (whole-run seconds); a failure
# prints "FAIL reason=<r>: <why>". --require-live prints a LIVE PASS line too.
# Runs $E2E_IMAGE (default gomql5/mt5:local; build with scripts/e2e.sh --build).
set -euo pipefail
cd "$(dirname "$0")/.."

SYM=XAUUSD SOURCE=replay INTERVAL=15s MIN_TICKS=3 RESTART=0 TIMEOUT=300 PORT=7789 KEEP=0 OUT=""
LIVE=0 SERVERS_DAT="" STATE_DIR="" LIVE_BUDGET=120 POLL=3
LIVE_FRESH=3 # L4: fresh records a container must show, whatever --min-ticks says
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
    --live-budget) LIVE_BUDGET=$2; shift ;;
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
rm -f "$OUT/result.txt" # a reused --out must not report the previous run's result
DATA=$OUT/data
IMAGE=${E2E_IMAGE:-gomql5/mt5:local} NAME=gomql5-goldrec-$TS TOKEN=goldrec-e2e APP_PID=""
say() { echo "[goldrec-e2e] $*"; }
now() { echo "$SECONDS"; } # the clock every wait reads
lines() { [ -f "$1" ] && wc -l <"$1" || echo 0; }

# Live-login phase timings, in seconds since the terminal container started
# (mark_started, called by start_terminal); empty = phase not reached.
T0=$(now) T_EA="" T_TRADE="" T_TITLE="" T_TICK="" RUN_LABEL=start
# The latest goldrec -check-live verdict (live_check).
LC_LINE="" LC_REASON="" LC_WAITING="" LC_RECORDS=0 LC_FRESH=0
mark_started() {
  T0=$(now) T_EA="" T_TRADE="" T_TITLE="" T_TICK=""
  LC_LINE="" LC_REASON="" LC_WAITING="" LC_RECORDS=0 LC_FRESH=0
}
# phase: the last phase reached, in order.
phase() {
  if [ -n "$T_TICK" ]; then echo "first live tick"
  elif [ -n "$T_TRADE" ]; then echo "trade server connected"
  elif [ -n "$T_EA" ]; then echo "EA connected"
  else echo "container started"; fi
}
secs() { if [ -n "$1" ]; then echo "${1}s"; else echo never; fi; }
timings_line() {
  echo "ea_connected=$(secs "$T_EA") trade_server=$(secs "$T_TRADE") first_live_tick=$(secs "$T_TICK") (budget ${LIVE_BUDGET}s)"
}
# record_timings: print this run's timings and append them to OUT/timings.txt.
record_timings() {
  say "timings ($RUN_LABEL): $(timings_line)"
  echo "$RUN_LABEL: $(timings_line)" >>"$OUT/timings.txt"
}
# The clock result.txt reads, and the stage a result belongs to:
# preflight, start (from the first container), restart (from its stop).
START=$(now) STAGE=preflight
# write_result REASON RC: OUT/result.txt, this run's outcome.
write_result() {
  printf 'reason=%s\nrc=%s\nstage=%s\nelapsed=%s\n' "$1" "$2" "$STAGE" "$(($(now) - START))" >"$OUT/result.txt"
}
# live_fail REASON RC MSG: the one exit path of a failed run.
live_fail() {
  local reason=$1 rc=$2; shift 2
  write_result "$reason" "$rc"
  say "FAIL reason=$reason: $*"
  record_timings
  exit "$rc"
}
# live_fail_why "REASON RC MSG": live_fail with the three in one string (fatal's
# output, whose MSG can span lines).
live_fail_why() { local rest=${1#* }; live_fail "${1%% *}" "${rest%% *}" "${rest#* }"; }
# How to give the terminal a route to a named server (no_route, login_failure).
SERVERS_DAT_HINT="provide a servers.dat that lists it (MT5_SERVERS_DAT=/path/to/servers.dat, copied from a desktop MT5 that has logged in to the broker once: File > Open Data Folder > config/servers.dat) or set MT5_SERVER=address:port"

# collect: evidence from the terminal, when it still runs.
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
  rc=$? # first: set -e can end the script anywhere (go build, docker run)
  if [ ! -f "$OUT/result.txt" ]; then
    write_result unclassified "$rc"
    say "FAIL reason=unclassified: exit $rc outside live_fail (see the output above)"
  fi
  collect
  [ -n "$APP_PID" ] && kill -INT "$APP_PID" 2>/dev/null && wait "$APP_PID" 2>/dev/null || true
  if [ $KEEP = 1 ]; then say "--keep: terminal left running as $NAME (state not promoted: its save is not final)"; return 0; fi
  docker stop -t 30 "$NAME" >/dev/null 2>&1 || true
  if [ $LIVE = 1 ] && [ -n "$STATE_DIR" ] && [ "$(head -1 "$OUT/result.txt" 2>/dev/null)" = reason=ok ]; then
    promote_state
  fi
}
trap cleanup EXIT

# image_id: the image's ID, short; fails when there is no such image.
image_id() { docker image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null | sed 's/^sha256://' | cut -c1-12; }
# sh -c program, on the host and in the image: a hash of the mql5 tree $1 and the
# files $2 and $3. Contents and relative names only: mtimes mean nothing in a zip
# extraction.
CONTENT_HASH='{ (cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do sha256sum "$f"; done); sha256sum <"$2"; sha256sum <"$3"; } | sha256sum | cut -d" " -f1'
# state_verified SERVER: the --state servers.dat exists and is the one a PASS verified
# for SERVER: the marker holds exactly that server and that file's sha256.
state_verified() {
  local dat=$STATE_DIR/servers.dat
  [ -n "$STATE_DIR" ] && [ -s "$dat" ] || return 1
  [ "$(cat "$dat.verified" 2>/dev/null)" = "server=$1"$'\n'"sha256=$(sha256sum <"$dat" | cut -d' ' -f1)" ]
}
# check_state_route: a name with no explicit --servers-dat needs the --state copy,
# and that copy counts only when state_verified says so: a failed run never writes
# to --state, but an older file or a hand-made one must not pass as verified.
check_state_route() {
  [ -n "$STATE_DIR" ] && [ -s "$STATE_DIR/servers.dat" ] || live_fail no_route 13 "MT5_SERVER is a name and no servers.dat lists it: $SERVERS_DAT_HINT"
  state_verified "$EXPECT_SERVER" ||
    live_fail route_unverified 14 "the --state servers.dat has no servers.dat.verified marker for this server and this file: pass the file with --servers-dat (MT5_SERVERS_DAT), or get one PASS"
}
# seed_state: the run's own copy of the --state servers.dat (OUT/state, mounted as the
# terminal's GOMQL5_STATE_DIR) starts as the verified file or not at all.
seed_state() {
  local want=${EXPECT_SERVER:-${MT5_SERVER:-}} # EXPECT_SERVER is set by --require-live only
  mkdir -p "$OUT/state"
  if state_verified "$want"; then
    cp "$STATE_DIR/servers.dat" "$OUT/state/servers.dat"
    say "state: seeded from the verified $STATE_DIR/servers.dat"
  else
    say "state: no verified servers.dat in $STATE_DIR: the terminal starts without a saved route"
  fi
}
# promote_state: after a LIVE PASS and the terminal's stop (its final save is in
# OUT/state by then): the run's servers.dat becomes the --state copy, and the marker
# names EXPECT_SERVER and that file's hash. The marker goes first, so a crash leaves
# the state unverified rather than wrong.
promote_state() {
  if [ ! -s "$OUT/state/servers.dat" ]; then say "state: the terminal saved no servers.dat; $STATE_DIR not changed"; return 0; fi
  mkdir -p "$STATE_DIR"
  rm -f "$STATE_DIR/servers.dat.verified"
  cp "$OUT/state/servers.dat" "$STATE_DIR/servers.dat.gomql5-tmp" && mv -f "$STATE_DIR/servers.dat.gomql5-tmp" "$STATE_DIR/servers.dat"
  printf 'server=%s\nsha256=%s\n' "$EXPECT_SERVER" "$(sha256sum <"$STATE_DIR/servers.dat" | cut -d' ' -f1)" >"$STATE_DIR/servers.dat.verified"
  say "state: promoted to $STATE_DIR/servers.dat, verified for $EXPECT_SERVER (sha256 $(sha256sum <"$STATE_DIR/servers.dat" | cut -c1-12))"
}
# preflight_live: everything a --require-live run needs that can be checked before
# the terminal starts, cheapest first. Messages name variables, never values. Sets
# EXPECT_SERVER.
preflight_live() {
  local v missing="" id want got
  for v in MT5_LOGIN MT5_PASSWORD MT5_SERVER; do [ -n "${!v:-}" ] || missing+=" $v"; done
  [ -z "$missing" ] || live_fail env_missing 10 "--require-live needs$missing"
  EXPECT_SERVER=${MT5_EXPECT_SERVER:-}
  if [ -z "$EXPECT_SERVER" ]; then
    case $MT5_SERVER in
      *:*) live_fail expect_server_missing 12 "MT5_SERVER is address:port: set MT5_EXPECT_SERVER to the server on the broker's account email" ;;
      *) EXPECT_SERVER=$MT5_SERVER ;;
    esac
  fi
  case $EXPECT_SERVER in
    MetaQuotes-*) live_fail expect_server_missing 12 "the expected server (MT5_EXPECT_SERVER, default MT5_SERVER) is a MetaQuotes-* server, the terminal's own fallback: a PASS would prove nothing" ;;
  esac
  [ -z "$SERVERS_DAT" ] || [ -s "$SERVERS_DAT" ] || live_fail no_route 13 "the --servers-dat file is missing or empty: $SERVERS_DAT_HINT"
  case $MT5_SERVER in
    *:*) ;; # the address is the route
    *) [ -n "$SERVERS_DAT" ] || check_state_route ;;
  esac
  id=$(image_id) || live_fail image_stale 15 "$IMAGE missing (scripts/e2e.sh --build)"
  say "preflight: image $IMAGE id=${id:-?}"
  want=$(sh -c "$CONTENT_HASH" sh mql5 docker/mt5/lib.sh docker/mt5/entrypoint.sh)
  got=$(docker run --rm --entrypoint sh "$IMAGE" -c "$CONTENT_HASH" sh /opt/gobridge/mql5 /usr/local/lib/gomql5/lib.sh /usr/local/bin/entrypoint.sh 2>/dev/null) || got=""
  [ -n "$want" ] && [ "$want" = "$got" ] || live_fail image_stale 15 "$IMAGE does not hold the local mql5/, docker/mt5/lib.sh and docker/mt5/entrypoint.sh (scripts/e2e.sh --build)"
  case $MT5_SERVER in
    *:*) timeout 5 bash -c 'exec 3<>"/dev/tcp/$0/$1"' "${MT5_SERVER%:*}" "${MT5_SERVER##*:}" 2>/dev/null ||
      live_fail broker_unreachable 16 "no TCP connection within 5 s to the address in MT5_SERVER" ;;
  esac
  say "preflight: today is $(date -u +%A) (UTC); evidence decides whether the market is open, not this note"
  say "preflight ok"
}
if [ $LIVE = 1 ]; then
  preflight_live
else
  docker image inspect "$IMAGE" >/dev/null 2>&1 || live_fail image_stale 15 "$IMAGE missing (scripts/e2e.sh --build)"
fi
go build -o "$OUT/goldrec" ./apps/goldrec
GOBRIDGE_TOKEN=$TOKEN "$OUT/goldrec" -out "$DATA" -source "$SOURCE" -interval "$INTERVAL" \
  -listen "127.0.0.1:$PORT" -broker-symbol "$SYM" >"$OUT/goldrec.log" 2>&1 &
APP_PID=$!

start_terminal() {
  local acct=()
  for v in MT5_LOGIN MT5_PASSWORD MT5_SERVER; do [ -n "${!v:-}" ] && acct+=(-e "$v"); done
  if [ -n "$SERVERS_DAT" ]; then
    [ -s "$SERVERS_DAT" ] || live_fail no_route 13 "--servers-dat $SERVERS_DAT missing or empty: $SERVERS_DAT_HINT"
    acct+=(-v "$(cd "$(dirname "$SERVERS_DAT")" && pwd)/$(basename "$SERVERS_DAT"):/gomql5/servers.dat:ro" -e MT5_SERVERS_DAT=/gomql5/servers.dat)
  fi
  if [ -n "$STATE_DIR" ]; then # the run's own copy: a failed run never reaches STATE_DIR
    acct+=(-v "$OUT/state:/gomql5-state" -e GOMQL5_STATE_DIR=/gomql5-state)
  fi
  STAGE=$RUN_LABEL
  docker run -d --rm --name "$NAME" --network host --shm-size 512m "${acct[@]}" \
    -e GOBRIDGE_TOKEN=$TOKEN -e GOBRIDGE_HOST=127.0.0.1 -e GOBRIDGE_PORT="$PORT" "$IMAGE" >/dev/null
  mark_started
}
# fatal: print "REASON RC why" (see live_fail_why) when the run cannot pass any
# more and return 0, else return 1.
fatal() {
  if terminal_fatal; then return 0; fi
  if grep -q 'broker symbol unavailable' "$OUT/goldrec.log"; then
    echo "symbol_missing 27 broker symbol $SYM unavailable: $(grep -m1 'broker symbol unavailable' "$OUT/goldrec.log")"; return 0
  fi
  return 1
}
# terminal_fatal: fatal's part that no identity can change: the recorder or the
# terminal's start. ensure_live reads only this: a refused symbol says nothing until
# the identity holds, and is then judged at the budget.
terminal_fatal() {
  local line
  if ! kill -0 "$APP_PID" 2>/dev/null; then echo "recorder_died 30 goldrec exited:"; tail -20 "$OUT/goldrec.log"; return 0; fi
  if docker logs "$NAME" 2>&1 | grep -qE 'compilation failed|cannot resolve'; then
    line=$(docker logs "$NAME" 2>&1 | grep -E 'compilation failed|cannot resolve' | head -1)
    case $line in
      *'compilation failed'*) echo "compile_failed 20 container: $line" ;;
      *) echo "ea_timeout 21 container: $line" ;; # the EA can never reach GOBRIDGE_HOST
    esac
    return 0
  fi
  return 1
}
# wait_until DEADLINE REASON RC COND_DESC TEST_CMD...: poll until TEST_CMD passes
# (it is tried at least once); FAIL on a fatal condition, or with REASON and RC
# once now() reaches DEADLINE.
wait_until() {
  local deadline=$1 reason=$2 rc=$3 desc=$4 why; shift 4
  while :; do
    if "$@"; then return 0; fi
    [ "$(now)" -lt "$deadline" ] || break
    if why=$(fatal); then live_fail_why "$why"; fi
    sleep "$POLL"
  done
  live_fail "$reason" "$rc" "timed out waiting for $desc"
}
# wait_for REASON RC COND_DESC TEST_CMD...: wait_until, TIMEOUT seconds from now.
wait_for() { local reason=$1 rc=$2 desc=$3; shift 3; wait_until $(($(now) + TIMEOUT)) "$reason" "$rc" "$desc" "$@"; }
have_ticks() { [ "$(lines "$DATA/prices.jsonl")" -ge "$1" ]; }
have_obs() { [ "$(lines "$DATA/sentiment.jsonl")" -ge 2 ]; }
# count PATTERN FILE: matching lines, 0 when none or no file. (Not
# `grep -c … || echo 0`: with no match grep prints 0 AND fails, giving "0\n0".)
count() { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); echo "${n:-0}"; }
connects() { [ "$(count '"kind":"terminal_connected"' "$DATA/events.jsonl")" -ge "$1" ]; }
# Echo the terminal's Network journal lines (login progress) once each.
SEEN_NET=0
show_network() {
  local all n
  all=$(scripts/mt5ctl.sh -c "$NAME" logs terminal 400 2>/dev/null | grep -E $'\tNetwork\t' || true)
  n=$(printf '%s' "$all" | grep -c . || true)
  if [ "$n" -gt "$SEEN_NET" ]; then printf '%s\n' "$all" | tail -n $((n - SEEN_NET)) | sed 's/^/[goldrec-e2e] journal: /'; SEEN_NET=$n; fi
}

# login_failure SERVER (stdin = terminal journal): print why a config login to
# SERVER cannot succeed and return 0, or return 1 when the journal shows no such
# sign (yet). Two shapes, both from real runs (testdata/journal-ftmo-wizard.txt):
#   * a server name the terminal doesn't know (not in config/servers.dat) falls
#     back to MetaQuotes-Demo: "authorization on MetaQuotes-Demo failed (Invalid account)";
#   * the server itself rejects the account: "authorization on SERVER failed (...)".
login_failure() {
  local srv=$1 net line
  net=$(grep -E $'\tNetwork\t' || true) # (`|| true`: no match is normal under set -euo pipefail)
  # address:port (MT5_SERVER given as an address) is not a name in servers.dat, so servers.dat is no fix for it
  if [[ "$srv" =~ ^[^:]+:[0-9]+$ ]]; then
    if line=$(printf '%s\n' "$net" | grep -F "authorization on $srv failed" | tail -1) && [ -n "$line" ]; then
      echo "$srv rejected the login (journal: ${line##*$'\t'}): check MT5_LOGIN/MT5_PASSWORD and the address:port in MT5_SERVER"
      return 0
    fi
  fi
  if [ "$srv" != MetaQuotes-Demo ] && line=$(printf '%s\n' "$net" | grep -E "(authorization on|authorized on) MetaQuotes-Demo( |$)" | tail -1) && [ -n "$line" ]; then
    if [[ "$srv" =~ ^[^:]+:[0-9]+$ ]]; then
      echo "the terminal fell back to MetaQuotes-Demo for MT5_SERVER=$srv (journal: ${line##*$'\t'}): check the address:port in MT5_SERVER"
    else
      echo "the terminal does not know MT5_SERVER=$srv and fell back to MetaQuotes-Demo (journal: ${line##*$'\t'}): $SERVERS_DAT_HINT"
    fi
    return 0
  fi
  if [ -n "$srv" ] && line=$(printf '%s\n' "$net" | grep -F "authorization on $srv failed" | tail -1) && [ -n "$line" ]; then
    echo "$srv rejected the login (journal: ${line##*$'\t'}): check MT5_LOGIN/MT5_PASSWORD; if they are right, the servers.dat entry for $srv may be stale: $SERVERS_DAT_HINT"
    return 0
  fi
  return 1
}
# run_events: this run's lines of events.jsonl; the recorder appends, so a reused
# --out still holds older runs, whose connections count from 1 too.
run_events() {
  [ -f "$DATA/events.jsonl" ] || return 0
  awk '/"kind":"run_start"/ { n = 0 } { l[++n] = $0 } END { for (i = 1; i <= n; i++) print l[i] }' "$DATA/events.jsonl"
}
# conn_events CONN KINDS: this run's events of that connection, KINDS an ERE of kinds.
conn_events() { run_events | grep -E "\"conn\":$1[,}]" | grep -E "\"kind\":\"($2)\"" || true; }
# latest_conn: this run's latest EA connection, 0 before the first.
latest_conn() { run_events | sed -n '/"kind":"terminal_connected"/s/.*"conn":\([0-9]*\).*/\1/p' | tail -1 | grep . || echo 0; }
# conn_connected CONN: that connection's latest terminal_info says connected.
conn_connected() { conn_events "$1" terminal_info | tail -1 | grep -q '"trade_server_connected":true'; }
# json_num FIELD LINE, json_str FIELD LINE: a field of an event line, empty when absent.
json_num() { printf '%s\n' "$2" | sed -n 's/.*"'"$1"'":\([0-9][0-9]*\).*/\1/p'; }
json_str() { printf '%s\n' "$2" | sed -n 's/.*"'"$1"'":"\([^"]*\)".*/\1/p'; }

# goldrec_check ARGS: the verdict on the recorder's files. Stderr stays out: a flag
# error quotes its value, and the login is one.
goldrec_check() { "$OUT/goldrec" -check-live -out "$DATA" "$@" 2>/dev/null; }
# live_check CONN NEED: L1, L2, L4, L5 and L6 for that connection, into LC_*. Its exit
# code says nothing the line does not; a line of any other shape leaves LC_REASON empty.
live_check() {
  local shape='^reason=([a-z_]+) conn=[0-9]+ records=([0-9]+) fresh=([0-9]+)/[0-9]+( waiting=([a-z_]+))?'
  LC_REASON="" LC_WAITING="" LC_RECORDS=0 LC_FRESH=0
  LC_LINE=$(goldrec_check -expect-login "$MT5_LOGIN" -expect-server "$EXPECT_SERVER" -min-fresh "$2" -conn "$1") || true
  if [[ "$LC_LINE" =~ $shape ]]; then
    LC_REASON=${BASH_REMATCH[1]} LC_RECORDS=${BASH_REMATCH[2]} LC_FRESH=${BASH_REMATCH[3]} LC_WAITING=${BASH_REMATCH[5]}
  fi
}
# account_holds: the verdict is past L1 and L2. Only then does it speak about ticks.
account_holds() {
  case $LC_REASON/$LC_WAITING in
    ok/* | stale_ticks/* | pending/ticks | pending/server_time) return 0 ;;
    *) return 1 ;;
  esac
}
# title_holds: L3, from the terminal itself and not from the RPC: the main window's
# title names the expected server and says it is an account (shapes: docker/mt5/lib.sh).
# Read only: no click, no UI lock. MAIN_TITLE keeps it, without the login, for messages.
MAIN_TITLE=""
title_holds() {
  MAIN_TITLE=$(scripts/mt5ctl.sh -c "$NAME" exec 'w=$(ui_main_window) && xdotool getwindowname "$w"' 2>/dev/null) || MAIN_TITLE=""
  MAIN_TITLE=${MAIN_TITLE//"$MT5_LOGIN"/<login>}
  [[ "$MAIN_TITLE" == *"$EXPECT_SERVER"* && "$MAIN_TITLE" == *" Account - "* ]]
}
# The market rule's age limit, on the broker's clock (assumption; E8 tunes it).
QUOTE_MAX_AGE=300
# ticks_fail CONN WHAT: no fresh ticks in time, identity holding: the latest symbol_resync
# of this connection decides. Ping gave seconds and the quote has milliseconds, both on
# the broker's clock, whose UTC offset is unknown. No quote or no server time: no verdict
# on the market. Never green: market_closed means inconclusive.
ticks_fail() {
  local line quote server age reason=no_fresh_ticks rc=28 aged="no quote age: no symbol_resync gave a quote and a server time"
  line=$(conn_events "$1" symbol_resync | tail -1)
  quote=$(json_num quote_time_msc "$line") server=$(json_num server_time "$line")
  if [ "${quote:-0}" -gt 0 ] && [ "${server:-0}" -gt 0 ]; then
    age=$((server * 1000 - quote))
    aged="quote age $((age / 1000))s on the broker's clock"
    if [ "$age" -gt $((QUOTE_MAX_AGE * 1000)) ]; then reason=market_closed rc=75; fi
  fi
  live_fail "$reason" "$rc" "$2: $aged (limit ${QUOTE_MAX_AGE}s), records=$LC_RECORDS fresh=$LC_FRESH; $(($(now) - T0))s since the container started; phase: $(phase)"
}
# budget_fail CONN JOURNAL_FALLBACK: LIVE_BUDGET ran out before the first fresh record;
# say why: the first of S1 to S4, in order, that does not hold. The identity comes
# before the symbol and the ticks: only it can tell a broker problem from a market one.
budget_fail() {
  local conn=$1 journal=$2 line login server
  local head="no live $SYM tick within the ${LIVE_BUDGET}s live budget"
  local where="$(($(now) - T0))s since the container started; phase: $(phase)"
  if [ -n "$journal" ] && { [ -z "$T_EA" ] || [ "$LC_WAITING" = account ]; }; then
    live_fail fallback_server 22 "$journal ($where)"
  fi
  [ -n "$T_EA" ] || live_fail ea_timeout 21 "$head: the EA never connected; $where"
  if ! account_holds; then
    line=$(conn_events "$conn" account | tail -1)
    server=$(json_str server "$line")
    # -check-live answers fallback_server only after its hold; the budget ends the wait.
    login=$(json_num login "$line")
    if [ "${login:-0}" != 0 ] && [ -n "$server" ] && [ "$server" != "$EXPECT_SERVER" ]; then
      live_fail fallback_server 22 "$head: the login is right, but the server is $server, not $EXPECT_SERVER: $SERVERS_DAT_HINT; $where"
    fi
    live_fail no_broker_connection 24 "$head: account_info or the trade server is not there yet ($LC_LINE); $where"
  fi
  [ -n "$T_TITLE" ] || live_fail identity_conflict 26 "$head: account_info says $EXPECT_SERVER, the window title says: ${MAIN_TITLE:-nothing readable}; $where"
  line=$(conn_events "$conn" 'quality|instrument' | grep -E 'broker_symbol_unavailable|"kind":"instrument"' | tail -1 || true)
  if [[ "$line" == *broker_symbol_unavailable* ]]; then
    line=$(printf '%s\n' "$line" | sed -n 's/.*"candidates":\[\([^]]*\)\].*/\1/p' | tr -d '"')
    live_fail symbol_missing 27 "$head: $EXPECT_SERVER does not offer broker symbol $SYM; candidates: ${line:-none}; $where"
  fi
  ticks_fail "$conn" "$head"
}
# ensure_live CONNS NEED: the live classifier, for the container started last, whose
# EA connection is number CONNS or later. Polls, and asks in order: S1 the EA connected;
# S2 the identity: goldrec -check-live on the latest connection (L1, L2), then the window
# title (L3); S3 the symbol; S4 the first fresh record, all by LIVE_BUDGET seconds from the
# start, and NEED fresh records (L4, L5, L6) by TIMEOUT. Definite answers end the run
# at once: another login or server (-check-live holds a server for 3 polls, so a late
# switch passes), a rejection in the journal, stale ticks, a dead recorder or terminal.
# What is merely missing is judged at its deadline, in that same order (budget_fail).
# A journal fallback is only a hint until then: the account is what shows it held.
ensure_live() {
  local conns=$1 need=$2 conn el why ro journal="" deadline rem
  [ -n "${MT5_LOGIN:-}" ] && [ -n "${MT5_PASSWORD:-}" ] || live_fail env_missing 10 "--require-live needs MT5_LOGIN/MT5_PASSWORD/MT5_SERVER"
  while :; do
    show_network # (slow: it reads the journal; so is the login_failure check below)
    el=$(($(now) - T0))
    conn=$(latest_conn)
    if [ -z "$T_EA" ] && [ "$conn" -ge "$conns" ]; then T_EA=$el; say "EA connected (${el}s)"; fi
    if [ -n "$T_EA" ]; then
      # Only after this container's EA connected: anything earlier belongs to the
      # previous container, and -check-live reads this connection alone.
      live_check "$conn" "$need"
      case $LC_REASON in
        ok | pending | stale_ticks) ;;
        wrong_account) live_fail wrong_account 25 "account_info names another login than MT5_LOGIN, whatever the ticks say ($LC_LINE); ${el}s since the container started" ;;
        fallback_server) live_fail fallback_server 22 "the login is right, but the terminal stays on another server than $EXPECT_SERVER ($LC_LINE): $SERVERS_DAT_HINT; ${el}s since the container started" ;;
        *) live_fail unclassified 1 "goldrec -check-live gave no verdict (${LC_LINE:-no output}); ${el}s since the container started" ;;
      esac
      if [ -z "$T_TRADE" ] && { account_holds || conn_connected "$conn"; }; then T_TRADE=$el; say "trade server connected (${el}s)"; fi
      if account_holds; then
        if [ -z "$T_TITLE" ] && title_holds; then
          T_TITLE=$el
          case $MAIN_TITLE in *'Read Only'*) ro=yes ;; *) ro=no ;; esac
          say "identity holds: account_info and the window title say $EXPECT_SERVER (${el}s, read_only=$ro)"
        fi
        if [ -n "$T_TITLE" ]; then
          if [ "$LC_REASON" = stale_ticks ]; then live_fail stale_ticks 29 "$LC_LINE; ${el}s since the container started; phase: $(phase)"; fi
          # A record first seen after the budget (a slow poll) is too late.
          if [ -z "$T_TICK" ] && [ "$el" -le "$LIVE_BUDGET" ] && [ "$LC_FRESH" -ge 1 ]; then T_TICK=$el; say "first live $SYM tick (${el}s)"; fi
          if [ "$LC_REASON" = ok ] && [ -n "$T_TICK" ]; then break; fi
        fi
      fi
    fi
    if [ -z "$T_TRADE" ] && why=$(scripts/mt5ctl.sh -c "$NAME" logs terminal 5000 2>/dev/null | login_failure "${MT5_SERVER:-}"); then
      case $why in
        *'fell back to'*) journal=$why ;;
        *) live_fail auth_rejected 23 "$why (${el}s since the container started; phase: $(phase))" ;;
      esac
    fi
    if why=$(terminal_fatal); then live_fail_why "$why"; fi
    deadline=$LIVE_BUDGET
    if [ -n "$T_TICK" ]; then deadline=$TIMEOUT; fi
    el=$(($(now) - T0))
    if [ "$el" -ge "$deadline" ]; then
      if [ -z "$T_TICK" ]; then budget_fail "$conn" "$journal"; fi
      # L6 could not be judged: rising records, but no clock to read them against.
      if [ "$LC_WAITING" = server_time ]; then live_fail stale_ticks 29 "$need fresh records but no server time to judge their age ($LC_LINE); ${el}s since the container started; phase: $(phase)"; fi
      ticks_fail "$conn" "timed out waiting for $need fresh $SYM ticks (${TIMEOUT}s after the container start)"
    fi
    # Nap at most until the deadline, so the last poll lands on it (the polls
    # themselves take time: count from the clock, not from el).
    rem=$((deadline - el))
    if [ "$rem" -gt 0 ]; then sleep $((rem < POLL ? rem : POLL)); fi
  done
  record_timings
}

# account_field FIELD: FIELD of the latest account event, ? without one (never the
# hello's value: that can be a stale login or the fallback server).
account_field() {
  grep '"kind":"account"' "$DATA/events.jsonl" 2>/dev/null | tail -1 | sed -n 's/.*"'"$1"'":"\([^"]*\)".*/\1/p' | grep . || echo '?'
}
# live_pass: the verdict line of a --require-live PASS; with --restart, counts
# and timings are per container (first/restarted).
live_pass() {
  local fresh first image build
  fresh=$LC_FRESH first=$(secs "$T_TICK")
  if [ "$RESTART" = 1 ]; then
    fresh=$fresh_before/$LC_FRESH first=$(secs "$first_live_before")/$(secs "$T_TICK")
  fi
  image=$(image_id) || true
  build=$(grep -o '"build":[0-9]*' "$DATA/events.jsonl" 2>/dev/null | tail -1 | cut -d: -f2) || true
  say "LIVE PASS: server=$(account_field server) symbol=$SYM fresh=$fresh first_live=$first image=${image:-?} build=${build:-?} company=$(account_field company)"
}

say "goldrec on 127.0.0.1:$PORT (source=$SOURCE, broker symbol $SYM); terminal $NAME"
: >"$OUT/timings.txt"
if [ -n "$STATE_DIR" ]; then seed_state; fi
start_terminal
if [ $LIVE = 1 ]; then
  ensure_live 1 $((MIN_TICKS > LIVE_FRESH ? MIN_TICKS : LIVE_FRESH))
else
  wait_for ea_timeout 21 "EA connection" connects 1
  wait_for no_fresh_ticks 28 "$MIN_TICKS $SYM ticks" have_ticks "$MIN_TICKS"
fi
wait_for unclassified 1 "2 positioning observations" have_obs
if [ $RESTART = 1 ]; then
  STAGE=restart
  first_live_before=$T_TICK fresh_before=$LC_FRESH
  live_conn=$(latest_conn)
  before=$(lines "$DATA/prices.jsonl")
  before_conn=$(count '"kind":"terminal_connected"' "$DATA/events.jsonl")
  say "restarting terminal (had $before ticks, $before_conn EA connections)"
  docker stop -t 30 "$NAME" >/dev/null
  wait_for unclassified 1 "disconnect event" grep -q '"kind":"terminal_disconnected"' "$DATA/events.jsonl"
  gone() { ! docker inspect "$NAME" >/dev/null 2>&1; }
  wait_for unclassified 1 "old container removed" gone
  RUN_LABEL=restart
  start_terminal # a fresh container starts logged out again: the budget starts over
  if [ $LIVE = 1 ]; then
    ensure_live $((live_conn + 1)) "$LIVE_FRESH"
  else
    wait_for ea_timeout 21 "reconnect" connects $((before_conn + 1))
    wait_for no_fresh_ticks 28 "ticks after reconnect" have_ticks $((before + 1))
  fi
fi
sleep 2 # let one flush/status cycle pass
say "PASS: $(lines "$DATA/prices.jsonl") ticks, $(lines "$DATA/sentiment.jsonl") positioning observations, $(grep -c terminal_connected "$DATA/events.jsonl") connections"
if grep -q '"trade_server_connected":false' "$DATA/prices.jsonl"; then
  say "      NOTE: terminal had no trade-server connection: ticks are cached quotes, not live prices"
fi
[ -s "$OUT/timings.txt" ] && sed 's/^/[goldrec-e2e]       timings /' "$OUT/timings.txt"
say "      first tick: $(head -1 "$DATA/prices.jsonl")"
say "      last observation: $(tail -1 "$DATA/sentiment.jsonl" | cut -c1-400)"
say "      evidence: $OUT (goldrec.log, data/, terminal.log, screen.png, journal.png, experts-log.png)"
if [ $LIVE = 1 ]; then live_pass; fi
write_result ok 0 # last: an error above must not leave a green result
