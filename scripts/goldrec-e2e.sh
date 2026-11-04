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
#                       (needs MT5_LOGIN/MT5_PASSWORD/MT5_SERVER)
#   --find-broker NAME  if the account is not connected after --connect-timeout,
#                       log in through File > Open an Account: search NAME (e.g.
#                       FTMO), Next, "existing trade account", login/password,
#                       server-list entry 0, 1, … (up to --login-tries) until the
#                       bridge reports a trade-server connection. Screenshots of
#                       each server list and form go into the evidence.
#   --connect-timeout S seconds to wait for the configured login (default 90)
#   --login-tries N     server-list entries to try (default 5)
#   --login-wait S      seconds to wait for a connection after each try (default 60)
#   --keep              leave the terminal running
#   --out DIR           evidence directory (default e2e-out/goldrec-<timestamp>)
#
# Broker account: MT5_LOGIN/MT5_PASSWORD/MT5_SERVER are passed to the terminal
# when set (otherwise it runs without a trade server: cached quotes only).
# --source api needs MYFXBOOK_EMAIL/MYFXBOOK_PASSWORD.
#
# Exit 0 = PASS. Requires gomql5/mt5:local (build with scripts/e2e.sh --build).
set -euo pipefail
cd "$(dirname "$0")/.."

SYM=XAUUSD SOURCE=replay INTERVAL=15s MIN_TICKS=3 RESTART=0 TIMEOUT=300 PORT=7789 KEEP=0 OUT=""
LIVE=0 FIND_BROKER="" CONNECT_TIMEOUT=90 LOGIN_TRIES=5 LOGIN_WAIT=60
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
    --find-broker) FIND_BROKER=$2; shift ;;
    --connect-timeout) CONNECT_TIMEOUT=$2; shift ;;
    --login-tries) LOGIN_TRIES=$2; shift ;;
    --login-wait) LOGIN_WAIT=$2; shift ;;
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
# ensure_live LIVE_TICKS_NEEDED: wait for the configured login; if the terminal
# doesn't reach a trade server (a broker the stock terminal doesn't know falls
# back to MetaQuotes-Demo: "Invalid account"), log in through File > Open an
# Account for $FIND_BROKER, trying server-list entries 0..LOGIN_TRIES-1 until
# the bridge reports a trade-server connection. Then wait for live ticks.
ensure_live() {
  local need=$1 deadline idx
  [ -n "${MT5_LOGIN:-}" ] && [ -n "${MT5_PASSWORD:-}" ] || { say "FAIL: --require-live needs MT5_LOGIN/MT5_PASSWORD/MT5_SERVER"; exit 1; }
  deadline=$((SECONDS + CONNECT_TIMEOUT))
  while [ $SECONDS -lt $deadline ] && ! trade_connected; do show_network; sleep 5; done
  if ! trade_connected && [ -n "$FIND_BROKER" ]; then
    for ((idx = 0; idx < LOGIN_TRIES; idx++)); do
      say "not connected to a trade server: logging in via File > Open an Account ('$FIND_BROKER', server list entry $idx)"
      scripts/mt5ctl.sh -c "$NAME" -o "$OUT" login-broker "$FIND_BROKER" "$idx" || say "login-broker failed"
      say "      screenshots: $OUT/login-$idx-servers.png, $OUT/login-$idx-form.png"
      deadline=$((SECONDS + LOGIN_WAIT))
      while [ $SECONDS -lt $deadline ] && ! trade_connected; do show_network; sleep 5; done
      trade_connected && break
    done
  fi
  live_or_net() { show_network; trade_connected; }
  wait_for "trade-server connection (account $MT5_LOGIN on ${MT5_SERVER:-?})" live_or_net
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
