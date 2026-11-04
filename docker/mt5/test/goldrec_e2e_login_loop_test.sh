#!/bin/bash
# Simulates goldrec-e2e.sh's ensure_live login loop against a fake terminal
# whose broker server list is the one seen on a user's machine (2026-11-04):
#   FTMO-Server4, FTMO-Server5, FTMO-Server, FTMO-Server3, FTMO-Server2, FTMO-Demo
# Each wizard try "logs in" to list[INDEX] (Down at the end stays on the last
# entry); the target server connects, others log "authorization … failed".
# Run: bash docker/mt5/test/goldrec_e2e_login_loop_test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../../../scripts/goldrec-e2e.sh"
fns=$(grep -E '^(failed_auth_count|last_failed_server)\(\)' "$script")
loop=$(sed -n '/^ensure_live() {/,/^}/p' "$script")
[ -n "$fns" ] && [ -n "$loop" ] || { echo "FAIL: functions not found"; exit 1; }
fail=0

run() { # target-server password-ok -> prints the loop's messages and "exit=N"
  bash -c '
    set -euo pipefail
    eval "$1"; eval "$2"
    LIST=(FTMO-Server4 FTMO-Server5 FTMO-Server FTMO-Server3 FTMO-Server2 FTMO-Demo)
    TARGET=$3 PW_OK=$4
    J=$(mktemp); STATE=$(mktemp); echo 0 >"$STATE"; trap "rm -f $J $STATE" EXIT
    MT5_LOGIN=12345678 MT5_PASSWORD=x MT5_SERVER=$TARGET FIND_BROKER=FTMO NAME=c OUT=/tmp
    CONNECT_TIMEOUT=0 LOGIN_TRIES=12 LOGIN_WAIT=2 LOGIN_START=0 SYM=XAUUSD
    say() { echo "$*"; }
    sleep() { :; }
    show_network() { :; }
    journal() { cat "$J"; }
    trade_connected() { [ "$(cat "$STATE")" = 1 ]; }
    wait_for() { echo "wait_for $1"; }
    scripts/mt5ctl.sh() { # -c NAME -o OUT login-broker COMPANY INDEX
      local idx=$7 srv
      [ "$idx" -ge ${#LIST[@]} ] && idx=$((${#LIST[@]} - 1))
      srv=${LIST[$idx]}
      if [ "$srv" = "$TARGET" ] && [ "$PW_OK" = 1 ]; then echo 1 >"$STATE"
      else printf "XX\t2\t00:00:00.000\tNetwork\t%s\n" "'"'"'12345678'"'"': authorization on $srv failed (Invalid account)" >>"$J"; fi
    }
    ensure_live 1
    echo "LOGIN_START=$LOGIN_START"
  ' _ "$fns" "$loop" "$1" "$2" 2>&1
  echo "exit=$?"
}
expect() { # name, output, substring
  if [[ "$2" == *"$3"* ]]; then echo "ok   $1"; else echo "FAIL $1: no '$3' in: $(echo "$2" | tr '\n' '|')"; fail=1; fi
}

out=$(run FTMO-Demo 1)
expect "reaches FTMO-Demo at entry 5" "$out" "LOGIN_START=5"
expect "says which server each wrong entry was" "$out" "entry 0 is FTMO-Server4"
expect "then waits for live ticks" "$out" "wait_for 1 live XAUUSD ticks"

out=$(run FTMO-Demo 0)
expect "wrong password: stops at FTMO-Demo with a clear reason" "$out" "FTMO-Demo itself rejected account"
expect "wrong password: non-zero exit" "$out" "exit=1"

out=$(run FTMO-Missing 1)
expect "server not in the list: stops at the end" "$out" "end of FTMO's server list reached"
expect "server not in the list: non-zero exit" "$out" "exit=1"
exit $fail
