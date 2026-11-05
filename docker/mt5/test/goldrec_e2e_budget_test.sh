#!/bin/bash
# Tests goldrec-e2e.sh's --require-live classifier (ensure_live): S1 EA, S2 identity
# (-check-live for L1 and L2, the window title for L3), S3 symbol, S4 ticks, in that
# order, within LIVE_BUDGET of the container start and again after a restart; every
# reason of the exit table has a case here, and a FAIL names the phase reached. The
# phase timings are printed and written to OUT/timings.txt. Runs the script's own
# functions with docker/goldrec stubbed out and a fake clock (now/sleep), so no time
# passes and no container runs; then the same functions against the real
# goldrec -check-live on real-shaped JSONL (still no terminal). Also runs the whole
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

# run EA_AT TRADE_AT TICK_AT [JOURNAL] [MODE]: ensure_live against a fake terminal
# whose EA connects, trade server connects and first fresh record arrives AT seconds
# after the container start (-1 = never); later fresh records come every RATE seconds
# (default 5); each poll takes SLOW seconds (default 0). MODE restart: run once, let
# 500 s pass, start a fresh container (connection 2) and run again, needing 3 fresh
# records. Prints the output, exit=N, timings.txt, result.txt and check-args (what
# -check-live was asked). Env: PASS (MT5_PASSWORD), SERVER (MT5_SERVER), NEED (fresh
# records, default 1), EVENTS (a file to use as events.jsonl), TITLE and TITLE_AT (the
# window title, stale until then); ACCOUNT, FB_AT, SWITCH_AT, STALE, NO_SERVER_TIME
# and CHECK_LINE steer the -check-live stub, which answers in goldrec's own format
# and order (identity, connected, stale, ticks, server time).
run() {
  local o="$T/out.$RANDOM"; mkdir -p "$o/data"
  [ -z "${EVENTS:-}" ] || cp "$EVENTS" "$o/data/events.jsonl"
  bash -c '
    set -euo pipefail
    CLOCK=1000
    now() { echo "$CLOCK"; }
    eval "$1"
    EA_AT=$2 TR_AT=$3 TK_AT=$4 J=$5 MODE=$6 OUT=$7 DATA=$7/data CONN=1
    LIVE_BUDGET=${BUDGET:-120} TIMEOUT=${TIMEOUT:-300} POLL=3 NAME=c SYM=XAUUSD RATE=${RATE:-5} NEED=${NEED:-1}
    MT5_LOGIN=12345678 MT5_PASSWORD=${PASS-x} MT5_SERVER=${SERVER:-FTMO-Demo} EXPECT_SERVER=${SERVER:-FTMO-Demo} STAGE=start
    GOOD_TITLE="12345678 - $EXPECT_SERVER: Demo Account - Read Only - Hedge - FTMO Global Markets Ltd"
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
    terminal_fatal() { return 1; }
    scripts/mt5ctl.sh() { # -c NAME logs terminal N | -c NAME exec CMD
      case $3 in
        exec)
          printf '%s\n' "$4" >>"$OUT/title-cmd"
          if [ -n "${TITLE_AT:-}" ] && ! at "$TITLE_AT"; then echo "12345678 - $EXPECT_SERVER - Netting"
          else echo "${TITLE-$GOOD_TITLE}"; fi ;;
        *) cat "$J" ;;
      esac
    }
    latest_conn() { if at "$EA_AT"; then echo "$CONN"; else echo $((CONN - 1)); fi; }
    conn_connected() { at "$TR_AT"; }
    goldrec_check() { # -expect-login L -expect-server S -min-fresh M -conn K
      local min=$6 k=$8 n=0 head account=${ACCOUNT:-ok}
      echo "$*" >>"$OUT/check-args"
      if [ -n "${CHECK_LINE:-}" ]; then echo "$CHECK_LINE"; return "${CHECK_RC:-1}"; fi
      if [ "$TK_AT" -ge 0 ] && at "$TK_AT"; then n=$(( ($(el) - TK_AT) / RATE + 1 )); fi
      head="conn=$k records=$((n + 1)) fresh=$n/$min"
      if [ -n "${SWITCH_AT:-}" ] && at "$SWITCH_AT"; then account=ok; fi
      case $account in
        none) echo "reason=pending $head waiting=account"; return 64 ;;
        wrong) echo "reason=wrong_account $head server=\"FTMO-Demo\""; return 25 ;;
        fallback)
          if at "${FB_AT:-15}"; then echo "reason=fallback_server $head server=\"MetaQuotes-Demo\""; return 22; fi
          echo "reason=pending $head waiting=account"; return 64 ;;
      esac
      if ! at "$TR_AT"; then echo "reason=pending $head waiting=connected"; return 64; fi
      if [ -n "${STALE:-}" ] && [ "$n" -gt 0 ]; then echo "reason=stale_ticks $head last_tick_age_ms=999999"; return 29; fi
      if [ "$n" -lt "$min" ]; then echo "reason=pending $head waiting=ticks"; return 64; fi
      if [ -n "${NO_SERVER_TIME:-}" ]; then echo "reason=pending $head waiting=server_time"; return 64; fi
      echo "reason=ok $head last_tick_age_ms=900 server=\"FTMO-Demo\" company=\"FTMO\""
    }
    mark_started
    ensure_live 1 "$NEED"
    echo "ensured at $(el)s, fresh=$LC_FRESH"
    if [ "$MODE" = restart ]; then
      sleep 500
      RUN_LABEL=restart STAGE=restart CONN=2
      mark_started
      ensure_live 2 3
      echo "ensured again at $(el)s, fresh=$LC_FRESH"
    fi
  ' _ "$defs" "$1" "$2" "$3" "${4:-$T/empty.txt}" "${5:-}" "$o" 2>&1
  echo "exit=$?"
  sed 's/^/timings.txt: /' "$o/timings.txt" 2>/dev/null
  sed 's/^/result.txt: /' "$o/result.txt" 2>/dev/null
  sed 's/^/check-args: /' "$o/check-args" 2>/dev/null
  sed 's/^/title-cmd: /' "$o/title-cmd" 2>/dev/null
}
has() { # name, output, substring
  if [[ "$2" == *"$3"* ]]; then echo "ok   $1"; else echo "FAIL $1: no '$3' in: $(echo "$2" | tr '\n' '|')"; fail=1; fi
}
hasnt() { # (what -check-live was asked is the test's own line: the login is there on purpose)
  set -- "$1" "$(echo "$2" | grep -v '^check-args: ')" "$3"
  if [[ "$2" != *"$3"* ]]; then echo "ok   $1"; else echo "FAIL $1: unexpected '$3' in: $(echo "$2" | tr '\n' '|')"; fail=1; fi
}
# failed NAME OUTPUT REASON RC: the exit status and result.txt agree on the reason.
failed() {
  has "$1: exit status" "$2" "exit=$4"
  has "$1: result" "$2" "result.txt: reason=$3"$'\n'"result.txt: rc=$4"
}

# Polls every 3 s from 0: EA seen at 42 s, trade server at 60 s, tick at 63 s.
out=$(run 41 58 63)
has "within budget: passes" "$out" "exit=0"
has "within budget: phases in order" "$out" "EA connected (42s)"
has "within budget: timings printed" "$out" "timings (start): ea_connected=42s trade_server=60s first_live_tick=63s (budget 120s)"
has "within budget: timings.txt" "$out" "timings.txt: start: ea_connected=42s trade_server=60s first_live_tick=63s (budget 120s)"
has "within budget: the verdict is asked about the expected account and connection 1" "$out" "check-args: -expect-login 12345678 -expect-server FTMO-Demo -min-fresh 1 -conn 1"
has "within budget: says what the title showed" "$out" "read_only=yes"
has "title is read with ui_main_window, through exec" "$out" 'title-cmd: w=$(ui_main_window) && xdotool getwindowname "$w"'
hasnt "title is read without the UI lock" "$out" "ui_lock"

# S1
out=$(run -1 -1 -1)
failed "EA never connects" "$out" ea_timeout 21
has "EA never connects: reason printed" "$out" "FAIL reason=ea_timeout: no live XAUUSD tick"
has "EA never connects: result stage" "$out" "result.txt: stage=start"
has "EA never connects: result elapsed" "$out" "result.txt: elapsed=120"
has "EA never connects: names the budget" "$out" "no live XAUUSD tick within the 120s live budget"
has "EA never connects: elapsed seconds" "$out" "120s since the container started"
has "EA never connects: phase" "$out" "phase: container started"
has "EA never connects: timings on FAIL" "$out" "timings.txt: start: ea_connected=never trade_server=never first_live_tick=never (budget 120s)"
hasnt "EA never connects: goldrec not asked before the EA" "$out" "check-args:"
hasnt "EA never connects: no login in the output" "$out" "12345678"

# S2: the account (L1), from -check-live.
out=$(ACCOUNT=wrong run 10 20 30)
failed "another login, however good the ticks" "$out" wrong_account 25
has "another login: at once" "$out" "result.txt: elapsed=12"
hasnt "another login: no login in the output" "$out" "12345678"

out=$(ACCOUNT=fallback FB_AT=30 run 10 20 30)
failed "login on another server, however good the ticks" "$out" fallback_server 22
has "fallback: as soon as -check-live says so, which holds it for 3 polls" "$out" "result.txt: elapsed=30"
has "fallback: says how to give a route" "$out" "provide a servers.dat that lists it"
hasnt "fallback: no login in the output" "$out" "12345678"
out=$(ACCOUNT=fallback FB_AT=30 SWITCH_AT=20 run 10 20 40)
has "a server switch inside the hold passes" "$out" "exit=0"

out=$(ACCOUNT=none run 10 20 30)
failed "no account yet at the budget" "$out" no_broker_connection 24
has "no account yet: only at the budget" "$out" "result.txt: elapsed=120"
has "no account yet: phase" "$out" "phase: trade server connected"
out=$(ACCOUNT=none SWITCH_AT=50 run 10 20 60)
has "an account that comes late (hello login=0) passes" "$out" "exit=0"

printf '%s\n' '{"at":"2026-11-05T12:00:00Z","company":"MetaQuotes","conn":1,"kind":"account","login":12345678,"server":"MetaQuotes-Demo","trade_allowed":false}' >"$T/ev-holding.jsonl"
out=$(ACCOUNT=fallback FB_AT=999 EVENTS="$T/ev-holding.jsonl" run 10 20 30)
failed "still on another server at the budget, hold not over" "$out" fallback_server 22
has "still on another server: names it" "$out" "MetaQuotes-Demo"
printf '%s\n' '{"at":"2026-11-05T12:00:00Z","company":"","conn":1,"kind":"account","login":0,"server":"MetaQuotes-Demo","trade_allowed":false}' >"$T/ev-login0.jsonl"
out=$(ACCOUNT=none EVENTS="$T/ev-login0.jsonl" run 10 20 30)
failed "login 0 is no fallback, whatever server it names" "$out" no_broker_connection 24

# S2: the connection (L2).
out=$(run 10 -1 -1)
has "EA connected, no trade server: phase" "$out" "phase: EA connected"
failed "EA connected, no trade server" "$out" no_broker_connection 24

# S2: the journal. A rejection fails at once; a fallback only ever counts at the budget,
# because the account is what shows it held.
out=$(run -1 -1 -1 "$wizard")
failed "fallback journal, nothing else" "$out" fallback_server 22
has "fallback journal: says so" "$out" "FAIL reason=fallback_server: the terminal does not know MT5_SERVER=FTMO-Demo and fell back to MetaQuotes-Demo"
has "fallback journal: not before the budget" "$out" "(120s since the container started; phase: container started)"
out=$(run 10 -1 -1 "$wizard")
has "fallback journal, but the account is the expected one: no trade server is the reason" "$out" "exit=24"
out=$(run 10 20 30 "$wizard")
has "fallback journal, then the expected account and ticks: passes" "$out" "exit=0"
out=$(ACCOUNT=none SWITCH_AT=50 run 10 20 60 "$wizard")
has "fallback journal, then a late switch: passes" "$out" "exit=0"

grep -v MetaQuotes-Demo "$wizard" >"$T/rejected.txt"
out=$(SERVER=FTMO-Server4 run -1 -1 -1 "$T/rejected.txt")
failed "server rejects the login" "$out" auth_rejected 23
has "server rejects the login: says so" "$out" "FAIL reason=auth_rejected: FTMO-Server4 rejected the login"
has "server rejects the login: at once" "$out" "(0s since the container started; phase: container started)"
out=$(SERVER=FTMO-Server4 run 10 -1 -1 "$T/rejected.txt")
has "rejected with the account named but no trade server: not 24" "$out" "exit=23"

out=$(PASS= run -1 -1 -1)
failed "no password" "$out" env_missing 10
has "no password: reason names the variable" "$out" "FAIL reason=env_missing: --require-live needs MT5_LOGIN/MT5_PASSWORD/MT5_SERVER"
hasnt "no password: no login in the output" "$out" "12345678"

out=$(run 0 0 0 "$wizard")
has "a trade-server connection wins over an old journal failure" "$out" "exit=0"

# S2: the title (L3).
out=$(TITLE="12345678 - MetaQuotes-Demo: Demo Account - Hedge" run 10 20 30)
failed "the account and the title disagree on the server" "$out" identity_conflict 26
has "title disagrees: only at the budget" "$out" "result.txt: elapsed=120"
has "title disagrees: quotes it" "$out" "<login> - MetaQuotes-Demo: Demo Account - Hedge"
hasnt "title disagrees: no login in the output" "$out" "12345678"
out=$(TITLE="12345678 - FTMO-Demo - Netting" run 10 20 30)
failed "the title has the server but no account" "$out" identity_conflict 26
out=$(TITLE="" run 10 20 30)
failed "no title to read" "$out" identity_conflict 26
out=$(TITLE_AT=50 run 10 20 30)
has "a title that catches up passes" "$out" "exit=0"
has "a title that catches up: the first tick counts from then" "$out" "first_live_tick=51s"
# The read-only guard (rc 31): a title without Read Only fails at the identity step.
out=$(TITLE="12345678 - FTMO-Demo: Demo Account - Hedge" run 10 20 30)
failed "title without Read Only" "$out" not_read_only 31
has "title without Read Only: quotes the title" "$out" "the window title lacks 'Read Only': <login> - FTMO-Demo: Demo Account - Hedge"
hasnt "title without Read Only: identity not said to hold" "$out" "identity holds"

# S3: the symbol, never before identity.
printf '%s\n' '{"at":"2026-11-05T12:00:00Z","broker_symbol":"XAUUSD","candidates":["XAUUSD.r","XAUEUR"],"conn":1,"error":"mt5 error -4: unknown symbol","kind":"quality","what":"broker_symbol_unavailable"}' >"$T/ev-symbol.jsonl"
out=$(EVENTS="$T/ev-symbol.jsonl" run 10 20 -1)
failed "symbol missing, identity holds" "$out" symbol_missing 27
has "symbol missing: names the candidates" "$out" "candidates: XAUUSD.r,XAUEUR"
has "symbol missing: at the budget, not at the first refusal" "$out" "result.txt: elapsed=120"
out=$(EVENTS="$T/ev-symbol.jsonl" ACCOUNT=none run 10 20 -1)
failed "symbol missing with no account yet: identity first" "$out" no_broker_connection 24
out=$(EVENTS="$T/ev-symbol.jsonl" run 10 -1 -1)
failed "symbol missing with no trade server: identity first" "$out" no_broker_connection 24
out=$(EVENTS="$T/ev-symbol.jsonl" ACCOUNT=wrong run 10 20 -1)
failed "symbol missing on another login: identity first" "$out" wrong_account 25
out=$(EVENTS="$T/ev-symbol.jsonl" ACCOUNT=fallback FB_AT=30 run 10 20 -1)
failed "symbol missing on another server: identity first" "$out" fallback_server 22
out=$(EVENTS="$T/ev-symbol.jsonl" TITLE="12345678 - MetaQuotes-Demo - Netting" run 10 20 -1)
failed "symbol missing while the title disagrees: identity first" "$out" identity_conflict 26
out=$(EVENTS="$T/ev-symbol.jsonl" run -1 -1 -1)
failed "symbol missing with no EA (an old line): the EA first" "$out" ea_timeout 21
out=$(EVENTS="$T/ev-symbol.jsonl" run 10 20 30)
has "symbol selected late, ticks flow: passes" "$out" "exit=0"
{ cat "$T/ev-symbol.jsonl"; printf '%s\n' '{"at":"2026-11-05T12:00:30Z","broker_symbol":"XAUUSD","conn":1,"kind":"instrument"}'; } >"$T/ev-symbol-back.jsonl"
out=$(EVENTS="$T/ev-symbol-back.jsonl" run 10 20 -1)
failed "symbol came back, still no tick: not the symbol's fault" "$out" no_fresh_ticks 28
sed 's/"conn":1/"conn":2/' "$T/ev-symbol.jsonl" >"$T/ev-symbol-other.jsonl"
out=$(EVENTS="$T/ev-symbol-other.jsonl" run 10 20 -1)
failed "symbol missing on another connection does not count" "$out" no_fresh_ticks 28

# S4: the ticks. The market rule compares server_time*1000 with quote_time_msc.
# resync FILE QUOTE_MSC SERVER_SEC: a symbol_resync line; the clock is an old one on purpose.
resync() { printf '{"at":"2026-11-05T12:00:30Z","broker_symbol":"XAUUSD","conn":1,"kind":"symbol_resync","quote_time_msc":%s,"reason":"quiet","server_time":%s}\n' "$2" "$3" >"$1"; }
resync "$T/ev-closed.jsonl" 1700000000000 1700000301
out=$(EVENTS="$T/ev-closed.jsonl" run 10 20 -1)
failed "quote older than 300 s by the broker's clock" "$out" market_closed 75
has "market closed: quote age" "$out" "quote age 301s"
has "market closed: record count" "$out" "records=1 fresh=0"
resync "$T/ev-300.jsonl" 1700000000000 1700000300
out=$(EVENTS="$T/ev-300.jsonl" run 10 20 -1)
failed "quote exactly 300 s old" "$out" no_fresh_ticks 28
has "quote exactly 300 s old: quote age" "$out" "quote age 300s"
resync "$T/ev-fresh.jsonl" 1700000299000 1700000300
out=$(EVENTS="$T/ev-fresh.jsonl" run 10 20 -1)
failed "fresh quote, no ticks" "$out" no_fresh_ticks 28
has "fresh quote: quote age" "$out" "quote age 1s"
{ cat "$T/ev-closed.jsonl"; cat "$T/ev-fresh.jsonl"; } >"$T/ev-both.jsonl"
out=$(EVENTS="$T/ev-both.jsonl" run 10 20 -1)
failed "the latest symbol_resync decides" "$out" no_fresh_ticks 28
sed 's/"conn":1/"conn":9/' "$T/ev-closed.jsonl" >"$T/ev-closed-other.jsonl"
out=$(EVENTS="$T/ev-closed-other.jsonl" run 10 20 -1)
failed "a symbol_resync of another connection does not count" "$out" no_fresh_ticks 28
resync "$T/ev-noping.jsonl" 1700000000000 0
out=$(EVENTS="$T/ev-noping.jsonl" run 10 20 -1)
failed "no server time: no market verdict" "$out" no_fresh_ticks 28
has "no server time: says so" "$out" "no quote age"
out=$(EVENTS="$T/ev-closed.jsonl" ACCOUNT=none run 10 20 -1)
failed "an old quote before identity: not market closed" "$out" no_broker_connection 24

out=$(run 10 20 -1)
failed "connected, no fresh tick" "$out" no_fresh_ticks 28
has "connected, no fresh tick: phase" "$out" "phase: trade server connected"
has "connected, no fresh tick: timings" "$out" "ea_connected=12s trade_server=21s first_live_tick=never"
has "connected, no fresh tick: says there is no quote age" "$out" "no quote age"

out=$(STALE=1 run 10 20 30)
failed "rising but old ticks" "$out" stale_ticks 29
has "stale: at once" "$out" "result.txt: elapsed=30"
has "stale: age and count" "$out" "last_tick_age_ms=999999"
out=$(STALE=1 TITLE="12345678 - MetaQuotes-Demo - Netting" run 10 20 30)
failed "stale ticks while the title disagrees: identity first" "$out" identity_conflict 26

out=$(NO_SERVER_TIME=1 RATE=5 run 10 20 30)
failed "fresh records but never a server time" "$out" stale_ticks 29
has "no server time: only at --timeout" "$out" "result.txt: elapsed=300"

out=$(CHECK_LINE="reason=unclassified conn=1 records=0 fresh=0/1 error=\"x\"" run 10 20 30)
failed "goldrec cannot judge the data" "$out" unclassified 1
has "goldrec cannot judge the data: says why" "$out" 'error="x"'
out=$(CHECK_LINE=" " run 10 20 30)
failed "goldrec gives no verdict" "$out" unclassified 1

# Deadlines.
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
out=$(run 30 30 0)
has "ticks before this container's EA connected don't count" "$out" "first_live_tick=30s"

out=$(NEED=5 RATE=10 run 10 20 30)
has "min ticks: more fresh records may take past the budget" "$out" "ensured at 72s, fresh=5"
out=$(NEED=5 RATE=100 run 10 20 30)
failed "min ticks: capped by --timeout from the container start" "$out" no_fresh_ticks 28
has "min ticks: the cap" "$out" "timed out waiting for 5 fresh XAUUSD ticks (300s after the container start)"
has "min ticks: first tick was on time" "$out" "first_live_tick=30s"
out=$(NEED=5 RATE=100 EVENTS="$T/ev-closed.jsonl" run 10 20 30)
failed "min ticks: the market closes under the run" "$out" market_closed 75

# S5: the restart, a new connection, 3 fresh records, its own stage in the result.
out=$(run 41 58 63 "" restart)
has "restart: passes" "$out" "ensured again at 75s, fresh=3"
has "restart: timing starts over" "$out" "timings.txt: restart: ea_connected=42s trade_server=60s first_live_tick=63s (budget 120s)"
has "restart: asks about the new connection, for 3 fresh records" "$out" "check-args: -expect-login 12345678 -expect-server FTMO-Demo -min-fresh 3 -conn 2"
hasnt "restart: never asks 1 fresh record of it" "$out" "-min-fresh 1 -conn 2"

# ---- the real goldrec -check-live, on real-shaped JSONL; no stubs for its output ----
# real CONNS NEED [ENV...] fixture files in $R: ensure_live with the real binary and the
# real event readers; only the title, the journal and the clock stay fake. STAGE from env.
if command -v go >/dev/null 2>&1; then
  (cd "$here/../../.." && go build -o "$T/real-goldrec" ./apps/goldrec) || { echo "FAIL go build ./apps/goldrec"; exit 1; }
  R=$T/real
  real_ev() { # kind conn sec extra-json
    printf '{"at":"2020-01-01T00:00:%02dZ","conn":%s,"id":"e","kind":"%s","run_id":"%s","schema":"goldrec/1"%s}\n' "$3" "$2" "$1" "${RUN:-r1}" "${4:-}" >>"$R/events.jsonl"
  }
  real_start() { rm -rf "$R"; mkdir -p "$R"; : >"$R/prices.jsonl"; printf '{"at":"2020-01-01T00:00:00Z","id":"e","kind":"run_start","run_id":"%s"}\n' "${RUN:-r1}" >>"$R/events.jsonl"; }
  real_acct() { real_ev account "$1" "$2" ",\"company\":\"FTMO S.R.O.\",\"login\":${3:-12345678},\"server\":\"${4:-FTMO-Demo}\",\"trade_allowed\":false"; real_ev terminal_info "$1" "$2" ',"build":6300,"trade_server_connected":true'; }
  real_px() { # conn sec...; broker clock in step with received_at, from 2020-01-01T00:00:00Z
    local c=$1 s; shift
    for s in "$@"; do
      printf '{"run_id":"%s","conn":%s,"seq":1,"broker_company":"FTMO S.R.O.","broker_server":"FTMO-Demo","login":12345678,"broker_symbol":"XAUUSD","trade_server_connected":true,"provider_time_msc":%s,"received_at":"2020-01-01T00:00:%02dZ","server_time":%s}\n' \
        "${RUN:-r1}" "$c" "$((1577836800000 + s * 1000))" "$s" "$((1577836800 + s))" >>"$R/prices.jsonl"
    done
  }
  real() {
    local o="$T/real-out.$RANDOM"; mkdir -p "$o"; cp -r "$R" "$o/data"; cp "$T/real-goldrec" "$o/goldrec"
    bash -c '
      set -euo pipefail
      CLOCK=1000
      now() { echo "$CLOCK"; }
      eval "$1"
      OUT=$2 DATA=$2/data
      LIVE_BUDGET=${BUDGET:-9} TIMEOUT=${TIMEOUT:-300} POLL=3 NAME=c SYM=XAUUSD
      MT5_LOGIN=12345678 MT5_PASSWORD=x MT5_SERVER=FTMO-Demo EXPECT_SERVER=FTMO-Demo STAGE=${REAL_STAGE:-start}
      RUN_LABEL=$STAGE
      sleep() { CLOCK=$((CLOCK + $1)); }
      say() { echo "$*"; }
      show_network() { :; }
      terminal_fatal() { return 1; }
      scripts/mt5ctl.sh() { case $3 in exec) echo "1 - FTMO-Demo: Demo Account - Read Only - Hedge" ;; *) : ;; esac; }
      mark_started
      ensure_live "$3" "$4"
      echo "ensured, fresh=$LC_FRESH"
    ' _ "$defs" "$o" "$1" "$2" 2>&1
    echo "exit=$?"
    sed 's/^/result.txt: /' "$o/result.txt" 2>/dev/null
  }

  real_start; real_ev terminal_connected 1 0 ',"login":0,"server":"MetaQuotes-Demo"'; real_acct 1 0; real_px 1 1 2 3 4
  out=$(real 1 3)
  has "real check: live data passes" "$out" "ensured, fresh=3"
  out=$(TIMEOUT=12 real 1 4)
  failed "real check: one record short, because the first is dropped" "$out" no_fresh_ticks 28
  has "real check: one record short: counts" "$out" "records=4 fresh=3"

  real_start; real_ev terminal_connected 1 0; real_acct 1 0; real_px 1 1
  out=$(real 1 3)
  failed "real check: the cached quote alone" "$out" no_fresh_ticks 28
  real_ev symbol_resync 1 5 ',"quote_time_msc":1577836800000,"server_time":1577837101'
  out=$(real 1 3)
  failed "real check: the cached quote, 301 s old" "$out" market_closed 75
  real_ev symbol_resync 1 6 ',"quote_time_msc":1577836800000,"server_time":1577836801'
  out=$(real 1 3)
  failed "real check: the cached quote, 1 s old" "$out" no_fresh_ticks 28

  real_start; real_ev terminal_connected 1 0; real_acct 1 0 12345678 MetaQuotes-Demo; real_px 1 1 2 3 4
  out=$(real 1 3)
  failed "real check: fallback, rising ticks and all" "$out" fallback_server 22
  real_start; real_ev terminal_connected 1 0; real_acct 1 0 99999999; real_px 1 1 2 3 4
  out=$(real 1 3)
  failed "real check: another login" "$out" wrong_account 25
  hasnt "real check: another login: neither login in the output" "$out" "99999999"
  real_start; real_ev terminal_connected 1 0; real_ev account 1 0 ',"company":"","login":0,"server":"MetaQuotes-Demo","trade_allowed":false'
  out=$(real 1 3)
  failed "real check: login 0" "$out" no_broker_connection 24

  # The restart: conn 2 alone is judged, and its first accepted value must beat conn 1's last.
  real_start; real_ev terminal_connected 1 0; real_acct 1 0; real_px 1 1 2 3 4 40
  real_ev terminal_disconnected 1 21; real_ev terminal_connected 2 22; real_acct 2 22; real_px 2 23 24 25 26
  out=$(REAL_STAGE=restart real 2 3)
  failed "real check: after a restart, the first accepted not above the last before" "$out" stale_ticks 29
  has "real check: restart result stage" "$out" "result.txt: stage=restart"
  real_start; real_ev terminal_connected 1 0; real_acct 1 0; real_px 1 1 2 3 4
  real_ev terminal_disconnected 1 21; real_ev terminal_connected 2 22; real_acct 2 22; real_px 2 22 23 24 25
  out=$(REAL_STAGE=restart real 2 3)
  has "real check: restart with new ticks" "$out" "ensured, fresh=3"
  real_start; real_ev terminal_connected 1 0; real_acct 1 0; real_px 1 1 2 3 4
  real_ev terminal_disconnected 1 21; real_ev terminal_connected 2 22; real_acct 2 22; real_px 2 23
  out=$(REAL_STAGE=restart real 2 3)
  failed "real check: conn 1's ticks do not carry conn 2" "$out" no_fresh_ticks 28
  has "real check: conn 1's ticks: counts" "$out" "records=1 fresh=0"
  real_start; real_ev terminal_connected 1 0; real_acct 1 0; real_px 1 1 2 3 4
  out=$(REAL_STAGE=restart real 2 3)
  failed "real check: no reconnect yet" "$out" ea_timeout 21

  # A reused --out: the older run's lines count for nothing.
  real_start; real_ev terminal_connected 1 0; real_ev terminal_connected 2 0; real_acct 2 0; real_px 2 1 2 3 4
  RUN=r2; printf '{"at":"2020-01-01T00:00:30Z","id":"e","kind":"run_start","run_id":"r2"}\n' >>"$R/events.jsonl"
  out=$(real 1 3)
  failed "real check: a reused --out, this run has no EA yet" "$out" ea_timeout 21
  real_ev terminal_connected 1 31; real_acct 1 31; real_px 1 32 33 34 35
  out=$(real 1 3)
  has "real check: a reused --out: this run's connection 1" "$out" "ensured, fresh=3"
else
  echo "skip real goldrec -check-live: go not on PATH"
fi

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
    # In the recorder's log before the script goes on, unlike STUB_RECORDER_LOG.
    [ -z "${STUB_RUN_LOG:-}" ] || echo "$STUB_RUN_LOG" >>"$STUB_OUT/goldrec.log"
    touch "$STUB_OUT/running"
    feed=${STUB_FEED:-full}
    if [ "$feed" = once ]; then
      if [ "$(wc -l <"$STUB_OUT/docker-runs")" -gt 1 ]; then feed=none; fi
    fi
    [ "$feed" != none ] || exit 0
    conn=$(($(wc -l <"$STUB_OUT/docker-runs")))
    {
      echo "{\"kind\":\"terminal_connected\",\"build\":6300,\"company\":\"Hello Co\",\"conn\":$conn,\"login\":0,\"server\":\"MetaQuotes-Demo\"}"
      echo "{\"kind\":\"account\",\"company\":\"FTMO S.R.O.\",\"conn\":$conn,\"login\":12345678,\"server\":\"FTMO-Demo\",\"trade_allowed\":true}"
      echo "{\"kind\":\"terminal_info\",\"build\":6300,\"conn\":$conn,\"trade_server_connected\":true}"
    } >>"$d/events.jsonl"
    if [ "$feed" = symbol-refused ]; then
      echo "{\"broker_symbol\":\"XAUUSD\",\"candidates\":[\"XAUUSD.r\"],\"conn\":$conn,\"error\":\"mt5 error -4: unknown symbol\",\"kind\":\"quality\",\"what\":\"broker_symbol_unavailable\"}" >>"$d/events.jsonl"
    fi
    [ "$feed" = no-ticks ] || [ "$feed" = symbol-refused ] || echo '{"bid":1,"trade_server_connected":true}' >>"$d/prices.jsonl"
    if [ "$feed" != no-obs ] && [ "$feed" != no-ticks ]; then
      echo '{"source":"replay"}' >>"$d/sentiment.jsonl"
      echo '{"source":"replay"}' >>"$d/sentiment.jsonl"
    fi
    ;;
  logs) [ -z "${STUB_LOGS:-}" ] || echo "$STUB_LOGS" ;;
  inspect) [ -f "$STUB_OUT/running" ] || exit 1; echo true ;; # mt5ctl's gate; also `gone`
  exec) # mt5ctl exec: the window title; every other look inside finds nothing
    case $* in
      *ui_main_window*getwindowname*) echo "${STUB_TITLE-12345678 - FTMO-Demo: Demo Account - Read Only - Hedge}" ;;
      *) exit 1 ;;
    esac
    ;;
  stop) rm -f "$STUB_OUT/running"; echo '{"kind":"terminal_disconnected"}' >>"$d/events.jsonl" ;;
  *) exit 1 ;; # ps, cp: no such container
esac
EOF
cat >"$T/bin/go" <<'EOF'
#!/bin/bash
[ "${STUB_GO_RC:-0}" = 0 ] || exit "$STUB_GO_RC"
cp "$STUB_RECORDER_BIN" "$3" # go build -o BIN ./apps/goldrec
EOF
cat >"$T/recorder" <<'EOF'
#!/bin/bash
if [ "${1:-}" = -check-live ]; then # -check-live -out D -expect-login L -expect-server S -min-fresh M -conn K
  m=$9 k=${11}
  echo "-min-fresh $m -conn $k" >>"$STUB_OUT/check-args"
  case ${STUB_CHECK:-ok} in
    pending-account) echo "reason=pending conn=$k records=0 fresh=0/$m waiting=account"; exit 64 ;;
    pending-ticks) echo "reason=pending conn=$k records=1 fresh=0/$m waiting=ticks"; exit 64 ;;
    wrong) echo "reason=wrong_account conn=$k records=$((m + 1)) fresh=$m/$m server=\"FTMO-Demo\""; exit 25 ;;
    fallback) echo "reason=fallback_server conn=$k records=$((m + 1)) fresh=$m/$m server=\"MetaQuotes-Demo\""; exit 22 ;;
    stale-restart)
      if [ "$k" -gt 1 ]; then echo "reason=stale_ticks conn=$k records=$((m + 1)) fresh=$m/$m first_fresh_msc=1 last_before_restart_msc=2"; exit 29; fi ;;
  esac
  echo "reason=ok conn=$k records=$((m + 1)) fresh=$m/$m last_tick_age_ms=900 server=\"FTMO-Demo\" company=\"FTMO S.R.O.\""
  exit 0
fi
[ -z "${STUB_RECORDER_LOG:-}" ] || echo "$STUB_RECORDER_LOG"
[ "${STUB_RECORDER:-}" != die ] || exit 1
# Background jobs of a script start with SIGINT ignored: restore it, or the
# script's `kill -INT` + `wait` would block until this sleep ends.
exec env --default-signal=INT "$REAL_SLEEP" 120
EOF
cat >"$T/bin/sleep" <<'EOF'
#!/bin/bash
# POLL and the flush nap, no real waiting. STUB_LATE_OBS: the positioning data comes
# in the first nap, so a wait has to survive one fatal check to see it.
if [ -n "${STUB_LATE_OBS:-}" ]; then
  echo '{"source":"replay"}' >>"$STUB_OUT/data/sentiment.jsonl"
  echo '{"source":"replay"}' >>"$STUB_OUT/data/sentiment.jsonl"
fi
exec "$REAL_SLEEP" 0.02
EOF
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
# live [ARGS]: whole, with an account and the route preflight_live asks for.
live() { STUB_LOGIN=12345678 STUB_PASSWORD=x STUB_SERVER=FTMO-Demo whole --require-live --servers-dat "$T/servers.dat" "$@"; }

out=$(live)
reason "live pass" "$out" ok 0 start
if [[ "$out" =~ \[goldrec-e2e\]\ LIVE\ PASS:\ server=FTMO-Demo\ symbol=XAUUSD\ fresh=3\ first_live=[0-9]+s\ image=abcdef012345\ build=6300\ company=FTMO\ S\.R\.O\. ]]; then
  echo "ok   live pass: LIVE PASS line, identity from the account event"
else echo "FAIL live pass: LIVE PASS line in: $(echo "$out" | tr '\n' '|')"; fail=1; fi
hasnt "live pass: no login in the LIVE PASS line" "$(echo "$out" | grep 'LIVE PASS')" "12345678"

out=$(live --restart)
reason "live pass with a restart" "$out" ok 0 restart
if [[ "$out" =~ LIVE\ PASS:\ server=FTMO-Demo\ symbol=XAUUSD\ fresh=3/3\ first_live=[0-9]+s/[0-9]+s\ image=abcdef012345\ build=6300\ company=FTMO ]]; then
  echo "ok   live pass with a restart: per-container counts"
else echo "FAIL live pass with a restart: LIVE PASS line in: $(echo "$out" | tr '\n' '|')"; fail=1; fi

# Identity before the symbol, with the recorder's own log line in place: the script's
# real functions, a real clock, a 1 s budget.
out=$(STUB_CHECK=pending-account STUB_RECORDER_LOG='broker symbol unavailable; set -broker-symbol' live --live-budget 1)
reason "symbol line in the log, no account yet" "$out" no_broker_connection 24 start
hasnt "symbol line in the log, no account yet: never the symbol" "$out" "symbol_missing"
out=$(STUB_CHECK=fallback STUB_RECORDER_LOG='broker symbol unavailable; set -broker-symbol' live --live-budget 1)
reason "symbol line in the log, on another server" "$out" fallback_server 22 start
hasnt "no LIVE PASS on a fallback" "$out" "LIVE PASS"
out=$(STUB_CHECK=wrong live --live-budget 1)
reason "another login" "$out" wrong_account 25 start
hasnt "no LIVE PASS on another login" "$out" "LIVE PASS"
out=$(STUB_TITLE="12345678 - MetaQuotes-Demo - Netting" live --live-budget 1)
reason "the title disagrees" "$out" identity_conflict 26 start
hasnt "no LIVE PASS when the title disagrees" "$out" "LIVE PASS"
out=$(STUB_CHECK=pending-ticks live --live-budget 1)
reason "no fresh tick" "$out" no_fresh_ticks 28 start
out=$(STUB_CHECK=stale-restart live --restart --live-budget 1)
reason "a stale restart" "$out" stale_ticks 29 restart
hasnt "no LIVE PASS on a stale restart" "$out" "LIVE PASS"

# The recorder's refused-symbol line, with the real fatal: in a live run it ends nothing,
# neither the waits after ensure_live nor ensure_live itself; only the budget, after
# identity, makes it symbol_missing. Without --require-live it still fails fast.
refused='broker symbol unavailable; set -broker-symbol'
out=$(STUB_FEED=no-obs STUB_RUN_LOG="$refused" STUB_LATE_OBS=1 live)
reason "symbol refused, then selected: the wait after identity goes on" "$out" ok 0 start
has "symbol refused, then selected: LIVE PASS" "$out" "LIVE PASS: server=FTMO-Demo"
hasnt "symbol refused, then selected: never the symbol" "$out" "symbol_missing"
out=$(STUB_FEED=symbol-refused STUB_RUN_LOG="$refused" STUB_CHECK=pending-ticks live --live-budget 1)
reason "symbol refused to the end: at the budget" "$out" symbol_missing 27 start
has "symbol refused to the end: the budget's message" "$out" "FAIL reason=symbol_missing: no live XAUUSD tick within the 1s live budget"
has "symbol refused to the end: names the candidates" "$out" "candidates: XAUUSD.r"
out=$(STUB_FEED=no-obs STUB_RUN_LOG="$refused" STUB_LATE_OBS=1 whole)
reason "symbol refused, without --require-live: still fails fast" "$out" symbol_missing 27 start
has "symbol refused, without --require-live: quotes the line" "$out" "FAIL reason=symbol_missing: broker symbol XAUUSD unavailable: $refused"

# session.sh reports 77 as SKIP, so no failure may use it.
if grep -nE 'live_fail(_why)? .*\b77\b' "$script"; then echo "FAIL rc 77 used in $script"; fail=1; else echo "ok   rc 77 is not used"; fi
exit $fail
