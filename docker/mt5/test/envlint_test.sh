#!/bin/bash
# Tests C13: scripts/envlint.sh runs before anything sources .env. An unsafe
# line exits 11 and prints the key only. Covers the audit table directly, then
# scripts/session.sh and `make session-live` with an unsafe file: both refuse,
# and the `echo TAIL-RAN` in the value never runs. Runs in a scratch copy with
# a stub docker, so no session-out/ appears in the repo and no container starts.
# Run: bash docker/mt5/test/envlint_test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
root="$here/../../.."
fail=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
lint="$root/scripts/envlint.sh"

# expect FILE_LINE RC: lint one line and compare the exit code
expect() {
  local line=$1 want=$2 got
  printf '%s\n' "$line" >"$T/one.env"
  bash "$lint" "$T/one.env" >"$T/out" 2>&1; got=$?
  if [ "$got" = "$want" ]; then echo "ok   rc=$want: $line"
  else echo "FAIL want rc=$want got rc=$got: $line"; fail=1; fi
}
expect 'K=plain123' 0
expect 'K=' 0
expect "K='ab\$?cd'" 0
expect "K='a b'" 0
expect 'K="quoted"' 0
expect 'export K=plain' 0
expect 'K=ab$?cd' 11
expect 'K=ab;echo TAIL-RAN' 11
expect 'K=a b' 11
expect 'K=a|b' 11
expect 'K=a&b' 11
expect 'K=(x)' 11
expect 'K=a<b' 11
expect 'K=a>b' 11
expect 'K=`id`' 11
expect 'K="a$b"' 11
expect "K='a'b'" 11
expect "K=a'b" 11
expect 'K=a\b' 11
expect 'ab;echo TAIL-RAN' 11
expect 'not an assignment' 11
printf 'A=1\nB=x;y\n' >"$T/two.env"
bash "$lint" "$T/two.env" >"$T/out" 2>&1; rc=$?
if [ "$rc" = 11 ] && grep -q 'B' "$T/out" && ! grep -q 'x;y' "$T/out"; then echo "ok   key printed, value not"
else echo "FAIL key/value output: rc=$rc"; cat "$T/out"; fail=1; fi
bash "$lint" "$T/missing.env" >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ]; then echo "ok   missing file passes"; else echo "FAIL missing file: rc=$rc"; fail=1; fi

# whole-stack refusal: session.sh and make session-live, scratch copy
mkdir -p "$T/stack/scripts" "$T/stack/bin"
cp "$root/Makefile" "$T/stack/"
cp "$root/scripts/session.sh" "$root/scripts/gotmpdir.sh" "$root/scripts/envlint.sh" "$T/stack/scripts/"
printf '#!/bin/sh\nexit 0\n' >"$T/stack/bin/docker" && chmod +x "$T/stack/bin/docker"
printf 'MT5_LOGIN=1\nMT5_PASSWORD=x\nMT5_SERVER=s\nBAD=ab;echo TAIL-RAN\n' >"$T/stack/unsafe.env"
run() { (cd "$T/stack" && env -u MT5_LOGIN -u MT5_PASSWORD -u MT5_SERVER PATH="$T/stack/bin:$PATH" E2E_ENV=unsafe.env "$@"); }

run scripts/session.sh e2e-live >"$T/session.out" 2>&1; rc=$?
if [ "$rc" = 11 ]; then echo "ok   session.sh rc=11"; else echo "FAIL session.sh rc=$rc (want 11)"; fail=1; fi
run make session-live >"$T/make.out" 2>&1; mrc=$?
if [ "$mrc" != 0 ]; then echo "ok   make session-live non-zero (rc=$mrc)"; else echo "FAIL make session-live exit 0"; fail=1; fi
for o in "$T/session.out" "$T/make.out"; do
  if grep -q 'TAIL-RAN' "$o"; then echo "FAIL $(basename "$o"): the unsafe line ran"; fail=1; fi
  if grep -q 'ab;echo' "$o"; then echo "FAIL $(basename "$o"): value printed"; fail=1; fi
done
grep -q 'BAD' "$T/session.out" && echo "ok   session.sh names the key" || { echo "FAIL session.sh does not name the key"; fail=1; }

exit $fail
