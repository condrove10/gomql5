#!/bin/bash
# Tests lib.sh's ui_lock: two actors must not interleave their UI sequences.
# Run: bash docker/mt5/test/ui_lock_test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
d=$(mktemp -d)
actor() { # name: take the lock, log a 3-step "sequence" with pauses
  (
    source "$here/../lib.sh"
    UI_LOCK="$d/lock"
    ui_lock 10 || { echo "$1 lock-timeout" >>"$d/log"; exit 1; }
    for step in 1 2 3; do echo "$1$step" >>"$d/log"; sleep 0.2; done
  )
}
actor A & actor B & wait
seq=$(tr '\n' ' ' <"$d/log")
rm -rf "$d"
case "$seq" in
  "A1 A2 A3 B1 B2 B3 " | "B1 B2 B3 A1 A2 A3 ") echo "ok   sequences serialized ($seq)"; exit 0 ;;
  *) echo "FAIL sequences interleaved: $seq"; exit 1 ;;
esac
