#!/bin/bash
# Tests goldrec-e2e.sh's --require-live budget (ensure_live): the first live
# tick must arrive within LIVE_BUDGET seconds of the container start, a FAIL
# names the phase reached, a login failure in the journal fails at once, and
# the phase timings are printed and written to OUT/timings.txt. Runs the
# script's own functions with docker/goldrec stubbed out and a fake clock
# (now/sleep), so no time passes and no container runs.
# Run: bash docker/mt5/test/goldrec_e2e_budget_test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../../../scripts/goldrec-e2e.sh"
wizard="$here/testdata/journal-ftmo-wizard.txt"
defs=$(sed -n '/^# wait_until DEADLINE/,/^wait_for()/p; /^# Live-login phase timings/,/^say "goldrec on/p' "$script" | grep -v '^say "goldrec on')
for f in wait_until mark_started phase record_timings login_failure ensure_live; do
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
# start a fresh container and run again. Prints the output, timings.txt and
# exit=N.
run() {
  local o="$T/out.$RANDOM"; mkdir -p "$o"
  bash -c '
    set -euo pipefail
    CLOCK=1000
    now() { echo "$CLOCK"; }
    eval "$1"
    EA_AT=$2 TR_AT=$3 TK_AT=$4 J=$5 MODE=$6 OUT=$7
    LIVE_BUDGET=${BUDGET:-120} TIMEOUT=${TIMEOUT:-300} POLL=3 NAME=c SYM=XAUUSD RATE=${RATE:-5} NEED=${NEED:-1}
    MT5_LOGIN=12345678 MT5_PASSWORD=x MT5_SERVER=FTMO-Demo
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
has "EA never connects: fails" "$out" "exit=1"
has "EA never connects: names the budget" "$out" "no live XAUUSD tick within the 120s live budget"
has "EA never connects: elapsed seconds" "$out" "120s since the container started"
has "EA never connects: phase" "$out" "phase: container started"
has "EA never connects: timings on FAIL" "$out" "timings.txt: start: ea_connected=never trade_server=never first_live_tick=never (budget 120s)"

out=$(run 10 -1 -1)
has "EA connected, no trade server: phase" "$out" "phase: EA connected"

out=$(run 10 20 -1)
has "connected, no live tick: fails" "$out" "exit=1"
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
has "fallback journal: fails" "$out" "FAIL: the terminal does not know MT5_SERVER=FTMO-Demo and fell back to MetaQuotes-Demo"
has "fallback journal: immediately" "$out" "(0s since the container started; phase: container started)"
hasnt "fallback journal: not a budget timeout" "$out" "live budget"
has "fallback journal: non-zero exit" "$out" "exit=1"

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
has "min ticks: cap fails" "$out" "exit=1"
exit $fail
