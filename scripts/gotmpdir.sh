#!/bin/bash
# gotmpdir.sh - print the directory Go should use as its build work dir
# (GOTMPDIR), or nothing when the default is fine.
#
# Go builds test binaries in $GOTMPDIR (else $TMPDIR, else /tmp) and runs them
# from there. Hosts that mount /tmp noexec (a common hardening setting) make
# every `go test` fail with "fork/exec .../x.test: permission denied". There
# this prints <repo>/.gotmp (and creates it).
#
# Usage: export GOTMPDIR="$(scripts/gotmpdir.sh)"   (an empty value = Go's default)
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
if [ -n "${GOTMPDIR:-}" ]; then
  echo "$GOTMPDIR"
  exit 0
fi
dir="${TMPDIR:-/tmp}"
probe=$(mktemp "$dir/gomql5-exec-check.XXXXXX" 2>/dev/null) || probe=""
ok=1
if [ -n "$probe" ]; then
  printf '#!/bin/sh\nexit 0\n' >"$probe" && chmod +x "$probe" && "$probe" 2>/dev/null && ok=0
  unlink "$probe"
fi
if [ $ok != 0 ]; then
  mkdir -p "$root/.gotmp"
  echo "$root/.gotmp"
fi
