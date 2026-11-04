#!/bin/bash
# Tests the wait predicates of scripts/goldrec-e2e.sh against real-shaped
# recorder files. Regression: `grep -c … || echo 0` printed "0\n0" when a file
# existed without matches, so `[ … -ge 1 ]` errored ("integer expected") and
# the EA-connection wait could never succeed (seen on a user's run, 2026-11-04).
# Run: bash docker/mt5/test/goldrec_e2e_predicates_test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../../../scripts/goldrec-e2e.sh"
defs=$(grep -E '^(count|lines|have_ticks|connects|have_live_ticks|trade_connected)\(\)' "$script")
[ -n "$defs" ] || { echo "FAIL: predicates not found"; exit 1; }
DATA=$(mktemp -d)
trap 'rm -rf "$DATA"' EXIT
eval "$defs"
fail=0
check() { # name, expected (true|false), command...
  local name=$1 want=$2; shift 2
  local err got
  err=$("$@" 2>&1 >/dev/null) && got=true || got=false
  if [ "$got" = "$want" ] && [ -z "$err" ]; then echo "ok   $name"; else echo "FAIL $name: got $got, stderr: ${err:-none}"; fail=1; fi
}
check "no events file: not connected" false connects 1
echo '{"kind":"run_start","seq":1}' >"$DATA/events.jsonl"
check "events without a connection: not connected, no error" false connects 1
echo '{"kind":"terminal_connected","seq":2}' >>"$DATA/events.jsonl"
check "one connection" true connects 1
check "not yet two connections" false connects 2
echo '{"kind":"terminal_info","trade_server_connected":false}' >>"$DATA/events.jsonl"
check "trade server not connected" false trade_connected
echo '{"kind":"terminal_info","trade_server_connected":true}' >>"$DATA/events.jsonl"
check "trade server connected" true trade_connected
echo '{"bid":1,"trade_server_connected":false}' >"$DATA/prices.jsonl"
check "cached ticks are not live ticks" false have_live_ticks 1
echo '{"bid":2,"trade_server_connected":true}' >>"$DATA/prices.jsonl"
check "one live tick" true have_live_ticks 1
check "two ticks in total" true have_ticks 2
exit $fail
