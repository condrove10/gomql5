#!/bin/bash
# Tests entrypoint.sh's GOBRIDGE_HOST -> IP resolution block under set -euo pipefail.
# Run: bash docker/mt5/test/resolve_host_test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
block=$(sed -n '/^EA_HOST="\$GOBRIDGE_HOST"/,/^fi$/p' "$here/../entrypoint.sh")
[ -n "$block" ] || { echo "FAIL: resolution block not found"; exit 1; }
fail=0
run() { # host -> prints "exit=<code> EA_HOST=<value>"
  bash -c '
    set -euo pipefail
    log() { :; }; seq() { command seq 1 2; }; sleep() { :; }
    GOBRIDGE_HOST="$1"
    eval "$2"
    echo "EA_HOST=$EA_HOST"' _ "$1" "$block"
  echo "exit=$?"
}
check() { # name, host, expected-substring
  local out; out=$(run "$2" 2>&1 | tr '\n' ' ')
  if [[ "$out" == *"$3"* ]]; then echo "ok   $1"; else echo "FAIL $1: $out"; fail=1; fi
}
check "IP passes through"           "10.1.2.3"             "EA_HOST=10.1.2.3 exit=0"
check "localhost passes through"    "localhost"            "EA_HOST=localhost exit=0"
check "name resolves to IPv4"       "$(hostname)"          "exit=0"
check "unresolvable exits 1 (not 2)" "no-such-host.invalid" "exit=1"
exit $fail
