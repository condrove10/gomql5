#!/bin/bash
# Tests C12: e2e-live named on the command line never skips when MT5_* is
# missing. It refuses with rc 10 and writes reason=env_missing to
# $OUT/e2e-live/result.txt. Both entry points are checked: scripts/session.sh
# and `make e2e-live`. Runs in a scratch copy of the scripts, with a stub
# docker, so no session-out/ appears in the repo and no container is touched.
# Run: bash docker/mt5/test/session_live_refusal_test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
root="$here/../../.."
fail=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts" "$T/bin"
cp "$root/Makefile" "$T/"
cp "$root/scripts/session.sh" "$root/scripts/gotmpdir.sh" "$root/scripts/envlint.sh" "$T/scripts/"
printf '#!/bin/sh\nexit 0\n' >"$T/bin/docker" && chmod +x "$T/bin/docker"
typo="$T/typo.env" # does not exist: the step must refuse, not skip

# unset MT5_* so the developer's shell cannot change the result
run() { env -u MT5_LOGIN -u MT5_PASSWORD -u MT5_SERVER PATH="$T/bin:$PATH" E2E_ENV="$typo" "$@"; }

check() { # name rc
  local name=$1 rc=$2 res
  res=$(ls "$T"/session-out/*/e2e-live/result.txt 2>/dev/null | head -1)
  if [ "$rc" = 0 ]; then echo "FAIL $name: exit 0 (expected non-zero)"; fail=1; return; fi
  if [ -z "$res" ] || ! grep -qx 'reason=env_missing' "$res" || ! grep -qx 'rc=10' "$res"; then
    echo "FAIL $name: no reason=env_missing rc=10 in result.txt (${res:-missing})"; fail=1; return
  fi
  if (cd "$T" && run bash -c "grep -q 'SKIP: ' session-out/*/session.log"); then
    echo "FAIL $name: step was reported as SKIP"; fail=1; return
  fi
  echo "ok   $name: rc=$rc, reason=env_missing rc=10 written"
}

rm -rf "$T/session-out"
(cd "$T" && run scripts/session.sh e2e-live >"$T/session.out" 2>&1); rc=$?
check "session.sh e2e-live" "$rc"

rm -rf "$T/session-out"
(cd "$T" && run make e2e-live >"$T/make.out" 2>&1); rc=$?
check "make e2e-live" "$rc"

exit $fail
