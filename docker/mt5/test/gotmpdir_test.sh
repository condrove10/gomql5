#!/bin/bash
# Tests scripts/gotmpdir.sh, which picks Go's build work dir so `go test`
# works on hosts with a noexec /tmp (seen on a user's machine, 2026-11-04:
# "fork/exec /tmp/go-build…/x.test: permission denied").
# Run: bash docker/mt5/test/gotmpdir_test.sh   (the noexec case needs root)
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
helper="$root/scripts/gotmpdir.sh"
tmp=$(mktemp -d)
cleanup() { mountpoint -q "$tmp/nx" 2>/dev/null && umount "$tmp/nx"; rm -rf "$tmp"; }
trap cleanup EXIT
fail=0
check() { # name, expected, actual
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
check "exec-capable TMPDIR: Go default" "" "$(env -u GOTMPDIR TMPDIR="$tmp" bash "$helper")"
check "GOTMPDIR from the environment is kept" "/x/y" "$(GOTMPDIR=/x/y bash "$helper")"
check "unusable TMPDIR: repo-local dir" "$root/.gotmp" "$(env -u GOTMPDIR TMPDIR="$tmp/missing" bash "$helper")"
mkdir -p "$tmp/nx"
if [ "$(id -u)" = 0 ] && mount -t tmpfs -o noexec,size=4m tmpfs "$tmp/nx" 2>/dev/null; then
  check "noexec TMPDIR: repo-local dir" "$root/.gotmp" "$(env -u GOTMPDIR TMPDIR="$tmp/nx" bash "$helper")"
  check "no probe file left behind" "0" "$(find "$tmp/nx" -type f | wc -l)"
else
  echo "skip noexec TMPDIR (needs root and tmpfs mount)"
fi
exit $fail
