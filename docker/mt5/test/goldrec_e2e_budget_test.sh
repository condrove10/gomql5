#!/bin/bash
# Tests goldrec-e2e.sh's --require-live budget (ensure_live): the first live
# tick must arrive within LIVE_BUDGET seconds of the container start, a FAIL
# names the phase reached, a login failure in the journal fails at once, and
# the phase timings are printed and written to OUT/timings.txt. Runs the
# script's own functions with docker/goldrec stubbed out and a fake clock
# (now/sleep), so no time passes and no container runs. Also runs the whole
# script with docker, go and sleep stubbed on PATH: every failure exits with its
# reason's rc and leaves OUT/result.txt, even when set -e ends the script.
# Run: bash docker/mt5/test/goldrec_e2e_budget_test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../../../scripts/goldrec-e2e.sh"
wizard="$here/testdata/journal-ftmo-wizard.txt"
defs=$(sed -n '/^# Live-login phase timings/,/^# collect:/p; /^# wait_until DEADLINE/,/^wait_for()/p; /^# login_failure SERVER/,/^say "goldrec on/p' "$script" | grep -v '^say "goldrec on')
for f in wait_until mark_started phase record_timings live_fail login_failure ensure_live; do
  [[ "$defs" == *"$f()"* ]] || { echo "FAIL: $f not found in $script"; exit 1; }
done
fail=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
: >"$T/empty.txt"

# run EA_AT TRADE_AT TICK_AT [JOURNAL] [MODE]: ensure_live against a fake
# terminal whose EA connects, trade server connects and first live tick
# arrives AT seconds after the container start (-1 = never); later live ticks
# come every RATE seconds (default 5); each poll takes SLOW seconds (default 0). MODE restart: run once, let 500 s pass,
# start a fresh container and run again. Prints the output, exit=N, timings.txt
# and result.txt. Env: PASS (MT5_PASSWORD), SERVER (MT5_SERVER).
run() {
  local o="$T/out.$RANDOM"; mkdir -p "$o"
  bash -c '
    set -euo pipefail
    CLOCK=1000
    now() { echo "$CLOCK"; }
    eval "$1"
    EA_AT=$2 TR_AT=$3 TK_AT=$4 J=$5 MODE=$6 OUT=$7
    LIVE_BUDGET=${BUDGET:-120} TIMEOUT=${TIMEOUT:-300} POLL=3 NAME=c SYM=XAUUSD RATE=${RATE:-5} NEED=${NEED:-1}
    MT5_LOGIN=12345678 MT5_PASSWORD=${PASS-x} MT5_SERVER=${SERVER:-FTMO-Demo} STAGE=start
    sleep() { # fake clock; a loop that ignores the budget would never end
      CLOCK=$((CLOCK + $1))
      [ $CLOCK -lt 100000 ] || { echo "clock ran away: the loop never stops"; exit 3; }
    }
    el() { echo $((CLOCK - T0)); }
    at() { [ "$1" -ge 0 ] && [ "$(el)" -ge "$1" ]; }
    say() { echo "$*"; }
    POLLS=0
    show_network() { # once per poll; SLOW: seconds each poll takes
      CLOCK=$((CLOCK + ${SLOW:-0})) POLLS=$((POLLS + 1))
      [ $POLLS -lt 300 ] || { echo "the loop never stops (300 polls)"; exit 3; }
    }
    fatal() { return 1; }
    scripts/mt5ctl.sh() { cat "$J"; } # -c NAME logs terminal N
    connects() { at "$EA_AT"; }
    trade_connected() { at "$TR_AT"; }
    have_live_ticks() { at "$TK_AT" && [ $(( ($(el) - TK_AT) / RATE + 1 )) -ge "$1" ]; }
    mark_started
    ensure_live 1 0 "$NEED"
    echo "ensured at $(el)s"
    if [ "$MODE" = restart ]; then
      sleep 500
      RUN_LABEL=restart
      mark_started
      ensure_live 2 0 1
      echo "ensured again at $(el)s"
    fi
  ' _ "$defs" "$1" "$2" "$3" "${4:-$T/empty.txt}" "${5:-}" "$o" 2>&1
  echo "exit=$?"
  sed 's/^/timings.txt: /' "$o/timings.txt" 2>/dev/null
  sed 's/^/result.txt: /' "$o/result.txt" 2>/dev/null
}
has() { # name, output, substring
  if [[ "$2" == *"$3"* ]]; then echo "ok   $1"; else echo "FAIL $1: no '$3' in: $(echo "$2" | tr '\n' '|')"; fail=1; fi
}
hasnt() {
  if [[ "$2" != *"$3"* ]]; then echo "ok   $1"; else echo "FAIL $1: unexpected '$3' in: $(echo "$2" | tr '\n' '|')"; fail=1; fi
}

# Polls every 3 s from 0: EA seen at 42 s, trade server at 60 s, tick at 63 s.
out=$(run 41 58 63)
has "within budget: passes" "$out" "exit=0"
has "within budget: phases in order" "$out" "EA connected (42s)"
has "within budget: timings printed" "$out" "timings (start): ea_connected=42s trade_server=60s first_live_tick=63s (budget 120s)"
has "within budget: timings.txt" "$out" "timings.txt: start: ea_connected=42s trade_server=60s first_live_tick=63s (budget 120s)"

out=$(run -1 -1 -1)
has "EA never connects: fails" "$out" "exit=21"
has "EA never connects: reason printed" "$out" "FAIL reason=ea_timeout: no live XAUUSD tick"
has "EA never connects: result reason" "$out" "result.txt: reason=ea_timeout"
has "EA never connects: result rc" "$out" "result.txt: rc=21"
has "EA never connects: result stage" "$out" "result.txt: stage=start"
has "EA never connects: result elapsed" "$out" "result.txt: elapsed=120"
has "EA never connects: names the budget" "$out" "no live XAUUSD tick within the 120s live budget"
has "EA never connects: elapsed seconds" "$out" "120s since the container started"
has "EA never connects: phase" "$out" "phase: container started"
has "EA never connects: timings on FAIL" "$out" "timings.txt: start: ea_connected=never trade_server=never first_live_tick=never (budget 120s)"

out=$(run 10 -1 -1)
has "EA connected, no trade server: phase" "$out" "phase: EA connected"
has "EA connected, no trade server: rc" "$out" "exit=24"
has "EA connected, no trade server: reason" "$out" "result.txt: reason=no_broker_connection"

out=$(run 10 20 -1)
has "connected, no live tick: fails" "$out" "exit=28"
has "connected, no live tick: reason" "$out" "result.txt: reason=no_fresh_ticks"
has "connected, no live tick: phase" "$out" "phase: trade server connected"
has "connected, no live tick: timings" "$out" "ea_connected=12s trade_server=21s first_live_tick=never"

out=$(BUDGET=60 run 10 20 70)
has "--live-budget 60: a tick at 70 s is too late" "$out" "within the 60s live budget"

out=$(run 10 20 120)
has "tick exactly at the budget: passes" "$out" "first_live_tick=120s"
out=$(run 10 20 121)
has "tick 1 s after the budget: fails" "$out" "phase: trade server connected"

out=$(SLOW=4 run 10 20 60)
has "slow polls: timings read the clock after the poll" "$out" "first_live_tick=60s"
out=$(SLOW=4 run 10 20 121)
has "slow polls: a tick first seen after the budget fails" "$out" "123s since the container started; phase: trade server connected"

out=$(run -1 -1 -1 "$wizard")
has "fallback journal: fails" "$out" "FAIL reason=fallback_server: the terminal does not know MT5_SERVER=FTMO-Demo and fell back to MetaQuotes-Demo"
has "fallback journal: immediately" "$out" "(0s since the container started; phase: container started)"
hasnt "fallback journal: not a budget timeout" "$out" "live budget"
has "fallback journal: rc" "$out" "exit=22"
has "fallback journal: result" "$out" "result.txt: reason=fallback_server"

grep -v MetaQuotes-Demo "$wizard" >"$T/rejected.txt"
out=$(SERVER=FTMO-Server4 run -1 -1 -1 "$T/rejected.txt")
has "server rejects the login: reason" "$out" "FAIL reason=auth_rejected: FTMO-Server4 rejected the login"
has "server rejects the login: rc" "$out" "exit=23"
has "server rejects the login: result" "$out" "result.txt: reason=auth_rejected"

out=$(PASS= run -1 -1 -1)
has "no password: rc" "$out" "exit=10"
has "no password: reason names the variable" "$out" "FAIL reason=env_missing: --require-live needs MT5_LOGIN/MT5_PASSWORD/MT5_SERVER"
has "no password: result" "$out" "result.txt: reason=env_missing"
hasnt "no password: no login in the output" "$out" "12345678"

out=$(run 0 0 0 "$wizard")
has "a trade-server connection wins over an old journal failure" "$out" "exit=0"

out=$(run 30 30 0)
has "ticks before this container's EA connected don't count" "$out" "first_live_tick=30s"
out=$(run 30 -1 30)
has "a live tick implies the trade-server phase" "$out" "trade_server=30s first_live_tick=30s"

out=$(run 41 58 63 "" restart)
has "restart: passes" "$out" "ensured again at 63s"
has "restart: timing starts over" "$out" "timings.txt: restart: ea_connected=42s trade_server=60s first_live_tick=63s (budget 120s)"

out=$(NEED=5 RATE=10 run 10 20 30)
has "min ticks: more live ticks may take past the budget" "$out" "ensured at 72s"
out=$(NEED=5 RATE=100 run 10 20 30)
has "min ticks: capped by --timeout from the container start" "$out" "timed out waiting for 5 live XAUUSD ticks (300s after the container start)"
has "min ticks: cap fails" "$out" "exit=28"
has "min ticks: cap reason" "$out" "result.txt: reason=no_fresh_ticks"

# whole [ARGS]: the real script against the stubs below. No real container, no
# recorder, no account: MT5_* are always overwritten, from STUB_LOGIN and friends.
# Prints the output, exit=N, docker_runs=N and result.txt.
real_sleep=$(command -v sleep)
mkdir -p "$T/bin"
cat >"$T/bin/docker" <<'EOF'
#!/bin/bash
d=$STUB_OUT/data
case $1 in
  image)
    [ "${STUB_IMAGE_RC:-0}" = 0 ] || exit "$STUB_IMAGE_RC"
    [ "$3" != -f ] || echo sha256:abcdef0123456789abcdef
    ;;
  run)
    if [ "$2" = --rm ]; then # preflight's content hash: run --rm --entrypoint sh IMAGE -c S sh A B C
      exec sh -c "$7" sh "$STUB_TREE/mql5" "$STUB_TREE/docker/mt5/lib.sh" "$STUB_TREE/docker/mt5/entrypoint.sh"
    fi
    echo run >>"$STUB_OUT/docker-runs"
    [ "${STUB_RUN_RC:-0}" = 0 ] || exit "$STUB_RUN_RC"
    feed=${STUB_FEED:-full}
    if [ "$feed" = once ]; then
      if [ "$(wc -l <"$STUB_OUT/docker-runs")" -gt 1 ]; then feed=none; fi
    fi
    [ "$feed" != none ] || exit 0
    conn=$(($(wc -l <"$STUB_OUT/docker-runs")))
    {
      echo '{"kind":"terminal_connected","build":6300,"company":"Hello Co","login":0,"server":"MetaQuotes-Demo"}'
      echo "{\"kind\":\"account\",\"company\":\"FTMO S.R.O.\",\"conn\":$conn,\"login\":12345678,\"server\":\"FTMO-Demo\",\"trade_allowed\":true}"
      echo '{"kind":"terminal_info","build":6300,"trade_server_connected":true}'
    } >>"$d/events.jsonl"
    [ "$feed" = no-ticks ] || echo '{"bid":1,"trade_server_connected":true}' >>"$d/prices.jsonl"
    if [ "$feed" != no-obs ] && [ "$feed" != no-ticks ]; then
      echo '{"source":"replay"}' >>"$d/sentiment.jsonl"
      echo '{"source":"replay"}' >>"$d/sentiment.jsonl"
    fi
    ;;
  logs) [ -z "${STUB_LOGS:-}" ] || echo "$STUB_LOGS" ;;
  stop) echo '{"kind":"terminal_disconnected"}' >>"$d/events.jsonl" ;;
  *) exit 1 ;; # inspect, exec, ps: no such container
esac
EOF
cat >"$T/bin/go" <<'EOF'
#!/bin/bash
[ "${STUB_GO_RC:-0}" = 0 ] || exit "$STUB_GO_RC"
cp "$STUB_RECORDER_BIN" "$3" # go build -o BIN ./apps/goldrec
EOF
cat >"$T/recorder" <<'EOF'
#!/bin/bash
[ -z "${STUB_RECORDER_LOG:-}" ] || echo "$STUB_RECORDER_LOG"
[ "${STUB_RECORDER:-}" != die ] || exit 1
# Background jobs of a script start with SIGINT ignored: restore it, or the
# script's `kill -INT` + `wait` would block until this sleep ends.
exec env --default-signal=INT "$REAL_SLEEP" 120
EOF
printf '#!/bin/bash\nexec "$REAL_SLEEP" 0.02\n' >"$T/bin/sleep" # POLL and the flush nap, no real waiting
chmod +x "$T/bin/docker" "$T/bin/go" "$T/bin/sleep" "$T/recorder"
whole() {
  local o="$T/whole.$RANDOM"; mkdir -p "$o/data"
  [ -z "${STUB_OLD_RESULT:-}" ] || echo "$STUB_OLD_RESULT" >"$o/result.txt"
  PATH="$T/bin:$PATH" REAL_SLEEP="$real_sleep" STUB_OUT="$o" STUB_RECORDER_BIN="$T/recorder" E2E_IMAGE=stub/image \
    STUB_TREE="$here/../../.." MT5_LOGIN="${STUB_LOGIN:-}" MT5_PASSWORD="${STUB_PASSWORD:-}" MT5_SERVER="${STUB_SERVER:-}" MT5_EXPECT_SERVER="" \
    timeout 60 bash "$script" --out "$o" --min-ticks 1 "$@" 2>&1
  echo "exit=$?"
  echo "docker_runs=$(cat "$o/docker-runs" 2>/dev/null | wc -l)"
  sed 's/^/result.txt: /' "$o/result.txt" 2>/dev/null
}
# reason NAME OUTPUT REASON RC STAGE: the exit status and all of result.txt agree.
reason() {
  has "$1: exit status" "$2" "exit=$4"
  has "$1: result reason" "$2" "result.txt: reason=$3"$'\n'"result.txt: rc=$4"$'\n'"result.txt: stage=$5"$'\n'"result.txt: elapsed="
}

out=$(STUB_IMAGE_RC=1 whole)
reason "image missing" "$out" image_stale 15 preflight
has "image missing: reason printed" "$out" "FAIL reason=image_stale: stub/image missing"
has "image missing: no container" "$out" "docker_runs=0"

out=$(STUB_GO_RC=7 whole)
reason "go build fails (set -e)" "$out" unclassified 7 preflight
has "go build fails: no container" "$out" "docker_runs=0"

out=$(STUB_RUN_RC=125 whole)
reason "docker run fails (set -e)" "$out" unclassified 125 start

out=$(whole --servers-dat "$T/no-such-servers.dat")
reason "servers.dat missing" "$out" no_route 13 preflight
has "servers.dat missing: hint" "$out" "provide a servers.dat that lists it"
has "servers.dat missing: no container" "$out" "docker_runs=0"

out=$(STUB_OLD_RESULT=reason=ok STUB_GO_RC=7 whole)
reason "a reused --out: the old result does not count" "$out" unclassified 7 preflight

out=$(STUB_FEED=none STUB_RECORDER=die whole)
reason "recorder dies" "$out" recorder_died 30 start
has "recorder dies: reason printed" "$out" "FAIL reason=recorder_died: goldrec exited:"

out=$(STUB_FEED=none STUB_RECORDER_LOG='broker symbol unavailable: BTCXXX' whole)
reason "symbol unavailable" "$out" symbol_missing 27 start
has "symbol unavailable: reason printed" "$out" "FAIL reason=symbol_missing: broker symbol XAUUSD unavailable"

out=$(STUB_FEED=none STUB_LOGS='[gomql5-mt5] compilation failed (no GoBridge.ex5)' whole)
reason "compile fails" "$out" compile_failed 20 start
has "compile fails: the compile line" "$out" "compilation failed (no GoBridge.ex5)"

out=$(STUB_FEED=none STUB_LOGS='[gomql5-mt5] cannot resolve host.example' whole)
reason "bridge host unresolvable" "$out" ea_timeout 21 start

out=$(STUB_FEED=none whole --timeout 0)
reason "no EA, without --require-live" "$out" ea_timeout 21 start
has "no EA: what it waited for" "$out" "FAIL reason=ea_timeout: timed out waiting for EA connection"

out=$(STUB_FEED=no-ticks whole --timeout 0)
reason "no ticks, without --require-live" "$out" no_fresh_ticks 28 start

out=$(STUB_FEED=no-obs whole --timeout 0)
reason "no positioning data" "$out" unclassified 1 start
has "no positioning data: says so" "$out" "timed out waiting for 2 positioning observations"

out=$(STUB_FEED=once whole --restart --timeout 0)
reason "no reconnect" "$out" ea_timeout 21 restart
has "no reconnect: both containers ran" "$out" "docker_runs=2"

out=$(whole)
reason "pass, no account" "$out" ok 0 start
has "pass, no account: PASS line" "$out" "[goldrec-e2e] PASS: 1 ticks"
hasnt "pass, no account: not a live pass" "$out" "LIVE PASS"

echo 'servers bytes' >"$T/servers.dat" # the route preflight_live asks for
out=$(STUB_LOGIN=12345678 STUB_PASSWORD=x STUB_SERVER=FTMO-Demo whole --require-live --servers-dat "$T/servers.dat")
reason "live pass" "$out" ok 0 start
if [[ "$out" =~ \[goldrec-e2e\]\ LIVE\ PASS:\ server=FTMO-Demo\ symbol=XAUUSD\ fresh=1\ first_live=[0-9]+s\ image=abcdef012345\ build=6300\ company=FTMO\ S\.R\.O\. ]]; then
  echo "ok   live pass: LIVE PASS line, identity from the account event"
else echo "FAIL live pass: LIVE PASS line in: $(echo "$out" | tr '\n' '|')"; fail=1; fi

out=$(STUB_LOGIN=12345678 STUB_PASSWORD=x STUB_SERVER=FTMO-Demo whole --require-live --restart --servers-dat "$T/servers.dat")
reason "live pass with a restart" "$out" ok 0 restart
if [[ "$out" =~ LIVE\ PASS:\ server=FTMO-Demo\ symbol=XAUUSD\ fresh=1/1\ first_live=[0-9]+s/[0-9]+s\ image=abcdef012345\ build=6300\ company=FTMO ]]; then
  echo "ok   live pass with a restart: per-container counts"
else echo "FAIL live pass with a restart: LIVE PASS line in: $(echo "$out" | tr '\n' '|')"; fail=1; fi

# session.sh reports 77 as SKIP, so no failure may use it.
if grep -nE 'live_fail(_why)? .*\b77\b' "$script"; then echo "FAIL rc 77 used in $script"; fail=1; else echo "ok   rc 77 is not used"; fi
exit $fail
