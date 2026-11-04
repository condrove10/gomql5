#!/bin/bash
# Tests the wait predicates of scripts/goldrec-e2e.sh against real-shaped
# recorder files. Regression: `grep -c … || echo 0` printed "0\n0" when a file
# existed without matches, so `[ … -ge 1 ]` errored ("integer expected") and
# the EA-connection wait could never succeed (seen on a user's run, 2026-11-04).
# Run: bash docker/mt5/test/goldrec_e2e_predicates_test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../../../scripts/goldrec-e2e.sh"
defs=$(grep -E '^(count|lines|have_ticks|connects|have_live_ticks|trade_connected|failed_auth_count|last_failed_server)\(\)' "$script")
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
echo '{"kind":"terminal_connected","seq":5}' >>"$DATA/events.jsonl"
echo '{"kind":"terminal_info","trade_server_connected":false}' >>"$DATA/events.jsonl"
check "after a restart the latest state counts (not connected)" false trade_connected
echo '{"bid":1,"trade_server_connected":false}' >"$DATA/prices.jsonl"
check "cached ticks are not live ticks" false have_live_ticks 1
echo '{"bid":2,"trade_server_connected":true}' >>"$DATA/prices.jsonl"
check "one live tick" true have_live_ticks 1
check "two ticks in total" true have_ticks 2

# Journal parsing, on the Network/Broker lines of a real wizard-login run
# (user's FTMO run 2026-11-04, login replaced): the config login fell back to
# MetaQuotes-Demo, then list entries 0..4 hit Server4, Server5, Server,
# Server3, Server2 ("Broker … no demo/preliminary groups" lines must not count).
journal="$here/testdata/journal-ftmo-wizard.txt"
same() { # name, expected, actual
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
same "failed logins counted (fallback + 5 wizard tries)" 6 "$(failed_auth_count <"$journal")"
same "last failed server" "FTMO-Server2" "$(last_failed_server <"$journal")"
same "server of the first wizard try" "FTMO-Server4" "$(grep -m2 'authorization on' "$journal" | tail -1 | last_failed_server)"
same "no failures in an empty journal" 0 "$(failed_auth_count </dev/null)"
same "no server from an empty journal" "" "$(last_failed_server </dev/null)"
# The script runs under `set -euo pipefail`: a no-match must not abort it
# (it did: srv=$(journal | last_failed_server) exited silently when the
# journal had no failed login yet).
same "parsers survive set -euo pipefail on no match" "reached" \
  "$(bash -c 'set -euo pipefail; eval "$1"; a=$(printf "x\n" | last_failed_server); b=$(printf "x\n" | failed_auth_count); echo reached' _ "$defs" 2>&1)"
exit $fail
