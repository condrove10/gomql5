#!/bin/bash
# Tests that scripts/e2e.sh passes docker build exactly one context argument
# and no empty arguments, with and without the optional proxy/CA/mirror
# settings. A fake `docker` on PATH records argv; nothing is built.
# Regression: with none of HTTPS_PROXY/E2E_CA_CERT/BASE_IMAGE/GO_IMAGE set,
# an empty "" argument made docker fail with "'docker buildx build' requires
# 1 argument" (seen on a user's machine, 2026-11-04).
# Run: bash docker/mt5/test/e2e_build_args_test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/docker" <<'FAKE'
#!/bin/bash
if [ "$1" = build ]; then
  printf '%s\0' "$@" >"$FAKE_ARGV"
  exit 0
fi
[ "$1 $2" = "image inspect" ] && { echo "sha256:fake 2026-01-01"; exit 0; }
exit 0
FAKE
chmod +x "$tmp/bin/docker"
fail=0
check() { # name, env assignments...
  local name=$1; shift
  rm -f "$tmp/argv"
  (cd "$root" && env -i PATH="$tmp/bin:$PATH" HOME="$HOME" FAKE_ARGV="$tmp/argv" "$@" \
    bash scripts/e2e.sh --build --image-only --out "$tmp/out" >/dev/null 2>&1)
  if [ ! -f "$tmp/argv" ]; then echo "FAIL $name: docker build not called"; fail=1; return; fi
  mapfile -d '' argv <"$tmp/argv"
  local empty=0 a
  for a in "${argv[@]}"; do [ -z "$a" ] && empty=$((empty + 1)); done
  if [ $empty -gt 0 ]; then echo "FAIL $name: $empty empty argument(s): $(printf '[%s] ' "${argv[@]}")"; fail=1; return; fi
  if [ "${argv[-1]}" != . ]; then echo "FAIL $name: last argument is not the context: ${argv[-1]}"; fail=1; return; fi
  echo "ok   $name (${#argv[@]} args)"
}
check "no optional settings"
check "all settings" HTTPS_PROXY=http://p:3128 E2E_CA_CERT=/etc/ca.crt BASE_IMAGE=mirror/debian GO_IMAGE=mirror/golang
check "mirror only" BASE_IMAGE=mirror/debian
exit $fail
