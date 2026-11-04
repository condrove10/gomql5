#!/bin/bash
# Tests entrypoint.sh's bridge_connected() against fake /proc/net tables.
# Run: bash docker/mt5/test/bridge_connected_test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
fn=$(sed -n '/^bridge_connected() {/,/^}/p' "$here/../entrypoint.sh")
[ -n "$fn" ] || { echo "FAIL: bridge_connected not found in entrypoint.sh"; exit 1; }
GOBRIDGE_PORT=7788
est='  0: 0100007F:9A3C 0100007F:1E6C 01 0'     # established, remote port 7788
lis='  0: 00000000:1E6C 00000000:0000 0A 0'     # listening on 7788 (not a client)
loc='  0: 0100007F:1E6C 0100007F:9A3C 01 0'     # server side of a connection
fail=0
check() { # name, tcp line, has_tcp6, want
  local d got
  d=$(mktemp -d)
  printf 'sl local rem st\n%s\n' "$2" >"$d/tcp"
  [ "$3" = 1 ] && printf 'sl local rem st\n' >"$d/tcp6"
  eval "${fn//\/proc\/net/$d}"
  if bridge_connected; then got=yes; else got=no; fi
  rm -rf "$d"
  if [ "$got" = "$4" ]; then echo "ok   $1"; else echo "FAIL $1: got $got want $4"; fail=1; fi
}
check "established, no tcp6"  "$est" 0 yes
check "established, tcp6"     "$est" 1 yes
check "listening only"        "$lis" 0 no
check "server-side socket"    "$loc" 0 no
exit $fail
