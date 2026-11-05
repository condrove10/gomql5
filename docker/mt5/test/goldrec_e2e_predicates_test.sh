#!/bin/bash
# Tests the wait predicates of scripts/goldrec-e2e.sh against real-shaped
# recorder files. Regression: `grep -c … || echo 0` printed "0\n0" when a file
# existed without matches, so `[ … -ge 1 ]` errored ("integer expected") and
# the EA-connection wait could never succeed (seen on a user's run, 2026-11-04).
# Then what decides a --require-live run: goldrec's -check-live verdict (the
# recorder binary is a stub here), never a record's trade_server_connected label,
# which a cached quote also carries; and what the script's main flow asks of it,
# 3 fresh records after a restart whatever --min-ticks says.
# Run: bash docker/mt5/test/goldrec_e2e_predicates_test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../../../scripts/goldrec-e2e.sh"
defs=$(grep -E '^lines\(\)' "$script"
  sed -n '/^# Live-login phase timings/,/^# collect:/p; /^have_ticks()/,/^# Echo the terminal/p; /^# login_failure SERVER/,/^say "goldrec on/p' "$script" | grep -v '^say "goldrec on')
for f in lines count have_ticks connects conn_connected goldrec_check live_check account_holds ensure_live; do
  [[ "$defs" == *"$f()"* ]] || { echo "FAIL: $f not found in $script"; exit 1; }
done
first=$(sed -n '/^start_terminal$/,/^wait_for unclassified 1 "2 positioning/p' "$script")
again=$(sed -n '/^if \[ \$RESTART = 1 \]; then$/,/^fi$/p' "$script")
fresh=$(grep -E '^LIVE_FRESH=' "$script")
[ -n "$first" ] && [ -n "$again" ] && [ -n "$fresh" ] || { echo "FAIL: main flow not found in $script"; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
OUT=$T DATA=$T/data
mkdir "$DATA"
now() { echo 1000; } # the definitions read the clock
eval "$defs"
fail=0
check() { # name, expected (true|false), command...
  local name=$1 want=$2; shift 2
  local err got
  err=$("$@" 2>&1 >/dev/null) && got=true || got=false
  if [ "$got" = "$want" ] && [ -z "$err" ]; then echo "ok   $name"; else echo "FAIL $name: got $got, stderr: ${err:-none}"; fail=1; fi
}
same() { # name, got, want
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; fail=1; fi
}
has() { # name, output, substring
  if [[ "$2" == *"$3"* ]]; then echo "ok   $1"; else echo "FAIL $1: no '$3' in: $(echo "$2" | tr '\n' '|')"; fail=1; fi
}
hasnt() { # name, output, substring
  if [[ "$2" != *"$3"* ]]; then echo "ok   $1"; else echo "FAIL $1: unexpected '$3' in: $(echo "$2" | tr '\n' '|')"; fail=1; fi
}

check "no events file: not connected" false connects 1
echo '{"kind":"run_start","seq":1}' >"$DATA/events.jsonl"
check "events without a connection: not connected, no error" false connects 1
echo '{"conn":1,"kind":"terminal_connected","seq":2}' >>"$DATA/events.jsonl"
check "one connection" true connects 1
check "not yet two connections" false connects 2
echo '{"conn":1,"kind":"terminal_info","trade_server_connected":false}' >>"$DATA/events.jsonl"
check "trade server not connected" false conn_connected 1
echo '{"conn":1,"kind":"terminal_info","trade_server_connected":true}' >>"$DATA/events.jsonl"
check "trade server connected" true conn_connected 1
echo '{"conn":2,"kind":"terminal_connected","seq":5}' >>"$DATA/events.jsonl"
echo '{"conn":2,"kind":"terminal_info","trade_server_connected":false}' >>"$DATA/events.jsonl"
check "after a restart the latest state counts (not connected)" false conn_connected 2
check "the earlier connection's state stays its own" true conn_connected 1
echo '{"bid":1,"trade_server_connected":false}' >"$DATA/prices.jsonl"
echo '{"bid":2,"trade_server_connected":true}' >>"$DATA/prices.jsonl"
check "two ticks in total" true have_ticks 2

# ---- the verdict, from a stub recorder ----
# verdict RC LINE: what the stub answers to -check-live. It also complains on stderr
# with the login, as the flag package would quote a bad value.
verdict() {
  printf '#!/bin/bash\necho "$*" >>"%s/check-args"\necho "invalid value 12345678" >&2\necho %q\nexit %s\n' "$OUT" "$2" "$1" >"$OUT/goldrec"
  chmod +x "$OUT/goldrec"
}
MT5_LOGIN=12345678 EXPECT_SERVER=FTMO-Demo
parsed() { live_check 1 3; echo "$LC_REASON/$LC_WAITING/$LC_RECORDS/$LC_FRESH"; }
verdict 64 'reason=pending conn=1 records=5 fresh=0/3 waiting=ticks'
same "pending: the line is read" "$(parsed)" "pending/ticks/5/0"
verdict 0 'reason=ok conn=1 records=4 fresh=3/3 last_tick_age_ms=900 server="FTMO-Demo" company="FTMO"'
same "ok: the line is read" "$(parsed)" "ok//4/3"
verdict 1 'panic: something else'
same "any other shape is no verdict" "$(parsed)" "//0/0"
: >"$T/check-args"
parsed >/dev/null
same "asked about the expected account and that connection" "$(cat "$T/check-args")" \
  "-check-live -out $DATA -expect-login 12345678 -expect-server FTMO-Demo -min-fresh 3 -conn 1"

holds() { LC_REASON=${1:-} LC_WAITING=${2:-}; account_holds; }
for v in ok stale_ticks 'pending ticks' 'pending server_time'; do check "the account holds: $v" true holds $v; done
for v in 'pending account' 'pending connected' wrong_account fallback_server ''; do check "the account does not hold: ${v:-no verdict}" false holds $v; done

# labelled N true|false: N price records, all with that label.
labelled() {
  local i
  : >"$DATA/prices.jsonl"
  for ((i = 1; i <= $1; i++)); do echo "{\"bid\":$i,\"provider_time_msc\":$i,\"trade_server_connected\":$2}" >>"$DATA/prices.jsonl"; done
}
printf '%s\n' '{"kind":"run_start"}' '{"conn":1,"kind":"terminal_connected"}' >"$DATA/events.jsonl"
# ensure NEED: the real ensure_live on these files, under the script's own shell
# options. A fake clock; only the title and the journal are made up.
ensure() {
  bash -c '
    set -euo pipefail
    CLOCK=1000
    now() { echo "$CLOCK"; }
    sleep() { CLOCK=$((CLOCK + $1)); }
    say() { echo "$*"; }
    eval "$1"
    OUT=$2 DATA=$2/data
    LIVE_BUDGET=9 TIMEOUT=30 POLL=3 NAME=c SYM=XAUUSD STAGE=start
    MT5_LOGIN=12345678 MT5_PASSWORD=x MT5_SERVER=FTMO-Demo EXPECT_SERVER=FTMO-Demo
    show_network() { :; }
    terminal_fatal() { return 1; }
    scripts/mt5ctl.sh() { case $3 in exec) echo "12345678 - FTMO-Demo: Demo Account - Read Only - Hedge" ;; esac; }
    mark_started
    ensure_live 1 "$3"
    echo "ensured, fresh=$LC_FRESH"
  ' _ "$defs" "$T" "$1" 2>&1
  echo "exit=$?"
}
labelled 5 true
verdict 64 'reason=pending conn=1 records=5 fresh=0/3 waiting=ticks'
out=$(ensure 3)
has "labelled live, the verdict says no fresh record: no PASS" "$out" "exit=28"
has "labelled live, no fresh record: reason" "$out" "FAIL reason=no_fresh_ticks"
has "labelled live, no fresh record: the verdict's counts" "$out" "records=5 fresh=0"
hasnt "labelled live, no fresh record: not ensured" "$out" "ensured"
hasnt "goldrec's stderr stays out: a flag error quotes the login" "$out" "12345678"
verdict 64 'reason=pending conn=1 records=5 fresh=2/3 waiting=ticks'
out=$(ensure 3)
has "labelled live, one fresh record short: no PASS" "$out" "exit=28"
verdict 29 'reason=stale_ticks conn=1 records=5 fresh=3/3 last_tick_age_ms=999999'
out=$(ensure 3)
has "labelled live, the verdict says stale: no PASS" "$out" "exit=29"
verdict 25 'reason=wrong_account conn=1 records=5 fresh=3/3 server="FTMO-Demo"'
out=$(ensure 3)
has "labelled live, the verdict says another login: no PASS" "$out" "exit=25"
labelled 5 false
verdict 0 'reason=ok conn=1 records=5 fresh=3/3 last_tick_age_ms=900 server="FTMO-Demo" company="FTMO"'
out=$(ensure 3)
has "the verdict decides, whatever the label says" "$out" "ensured, fresh=3"
has "the verdict decides: passes" "$out" "exit=0"

# ---- the main flow: what each container is asked for ----
# flow LIVE MIN_TICKS: the script's own lines from the first start through the restart,
# with the waits stubbed to say what they were asked.
flow() (
  LIVE=$1 MIN_TICKS=$2 RESTART=1 SYM=XAUUSD STAGE=x RUN_LABEL=x T_TICK=30 LC_FRESH=3
  ensure_live() { echo "ensure_live $*"; }
  wait_for() { echo "wait_for $*"; }
  start_terminal() { :; }
  docker() { :; }
  latest_conn() { echo 1; }
  say() { :; }
  eval "$fresh"
  eval "$first"
  eval "$again"
)
out=$(flow 1 1)
has "live, --min-ticks 1: the first container still needs 3" "$out" "ensure_live 1 3"
has "live, --min-ticks 1: the restart needs 3, on the next connection" "$out" "ensure_live 2 3"
hasnt "live: the verdict alone counts ticks" "$out" "have_ticks"
hasnt "live: the verdict alone says the EA connected" "$out" "connects"
out=$(flow 1 5)
has "live, --min-ticks 5: the first container needs 5" "$out" "ensure_live 1 5"
has "live, --min-ticks 5: the restart needs 3" "$out" "ensure_live 2 3"
out=$(flow 0 1)
hasnt "no account: no verdict to ask for" "$out" "ensure_live"
has "no account: waits for the EA" "$out" "connects 1"
has "no account: counts ticks" "$out" "have_ticks 1"
has "no account: waits for the reconnect" "$out" "connects 2"
has "no account: counts new ticks" "$out" "ticks after reconnect have_ticks"

exit $fail
