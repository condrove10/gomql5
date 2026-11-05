#!/bin/bash
# Tests goldrec-e2e.sh's preflight_live: with --require-live, a run that cannot
# reach the expected broker with the current image is refused before any
# terminal starts, with its own reason and rc, naming variables and never their
# values. Runs the real script, copied into a stubbed tree (mql5/, lib.sh,
# entrypoint.sh), with docker and go stubbed on PATH. The stub docker keeps the
# "image" in a directory, so the content hash really is computed on both sides.
# The go stub fails with 7: reason=unclassified rc=7 at stage preflight with no
# container means preflight let the run through.
# Run: bash docker/mt5/test/goldrec_e2e_preflight_test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
root="$here/../../.."
script="$root/scripts/goldrec-e2e.sh"
fail=0
T=$(mktemp -d)
LISTENER=""
trap '[ -z "$LISTENER" ] || kill "$LISTENER" 2>/dev/null; rm -rf "$T"' EXIT
tree=$T/tree image=$T/image
LOGIN=LOGIN-VALUE-77 PW=PASSWORD-VALUE-77 SRV=SERVERNAME-VALUE-77

mkdir -p "$T/bin" "$T/bin-timeout" "$tree/scripts" "$tree/docker/mt5" "$tree/mql5/Experts/GoBridge"
cp "$script" "$tree/scripts/goldrec-e2e.sh"
echo 'ea source' >"$tree/mql5/Experts/GoBridge/GoBridge.mq5"
echo 'lib' >"$tree/docker/mt5/lib.sh"
echo 'entrypoint' >"$tree/docker/mt5/entrypoint.sh"
# build_image: what `docker build` does with the tree, per docker/mt5/Dockerfile.
build_image() {
  rm -rf "$image"
  mkdir -p "$image/opt/gobridge" "$image/usr/local/lib/gomql5" "$image/usr/local/bin"
  cp -r "$tree/mql5" "$image/opt/gobridge/mql5"
  cp "$tree/docker/mt5/lib.sh" "$image/usr/local/lib/gomql5/lib.sh"
  cp "$tree/docker/mt5/entrypoint.sh" "$image/usr/local/bin/entrypoint.sh"
}
build_image

cat >"$T/bin/docker" <<'EOF'
#!/bin/bash
case $1 in
  image)
    [ "${STUB_IMAGE_RC:-0}" = 0 ] || exit "$STUB_IMAGE_RC"
    [ "$3" != -f ] || echo sha256:abcdef0123456789abcdef
    ;;
  run)
    if [ "$2 $3 $4" = "--rm --entrypoint sh" ]; then # run --rm --entrypoint sh IMAGE -c S sh A B C
      echo hash >>"$STUB_OUT/docker-hash"
      [ "${STUB_HASH_RC:-0}" = 0 ] || exit "$STUB_HASH_RC"
      exec sh -c "$7" sh "$STUB_IMG$9" "$STUB_IMG${10}" "$STUB_IMG${11}"
    fi
    echo run >>"$STUB_OUT/docker-runs"
    ;;
  *) exit 1 ;;
esac
EOF
printf '#!/bin/bash\nexit 7\n' >"$T/bin/go"
# Only on PATH when a case asks: the connect that never answers.
printf '#!/bin/bash\necho "$*" >>"$STUB_OUT/timeout-args"\nexit 124\n' >"$T/bin-timeout/timeout"
chmod +x "$T/bin/docker" "$T/bin/go" "$T/bin-timeout/timeout"

# run_script ARGS: the script against the stubs, with a good account unless L, P, S
# or X override MT5_LOGIN, MT5_PASSWORD, MT5_SERVER or MT5_EXPECT_SERVER. Prints
# the output, exit=N, docker_runs=N, hash_runs=N and result.txt.
run_script() {
  local o; o=$(mktemp -d "$T/out.XXXXXX")
  PATH="${EXTRA_PATH:-}$T/bin:$PATH" STUB_OUT="$o" STUB_IMG="$image" E2E_IMAGE=stub/image \
    MT5_LOGIN="${L-$LOGIN}" MT5_PASSWORD="${P-$PW}" MT5_SERVER="${S-$SRV}" MT5_EXPECT_SERVER="${X-}" \
    bash "$tree/scripts/goldrec-e2e.sh" --out "$o" "$@" 2>&1
  echo "exit=$?"
  echo "docker_runs=$(cat "$o/docker-runs" 2>/dev/null | wc -l)"
  echo "hash_runs=$(cat "$o/docker-hash" 2>/dev/null | wc -l)"
  sed 's/^/result.txt: /' "$o/result.txt" 2>/dev/null
}
pf() { run_script --require-live "$@"; }
has() { # name, output, substring
  if [[ "$2" == *"$3"* ]]; then echo "ok   $1"; else echo "FAIL $1: no '$3' in: $(echo "$2" | tr '\n' '|')"; fail=1; fi
}
hasnt() {
  if [[ "$2" != *"$3"* ]]; then echo "ok   $1"; else echo "FAIL $1: '$3' in: $(echo "$2" | tr '\n' '|')"; fail=1; fi
}
# refused NAME OUTPUT REASON RC: that reason and rc, at preflight, no terminal, no value.
refused() {
  has "$1: reason" "$2" "FAIL reason=$3:"
  has "$1: exit status" "$2" "exit=$4"$'\n'
  has "$1: result.txt" "$2" "result.txt: reason=$3"$'\n'"result.txt: rc=$4"$'\n'"result.txt: stage=preflight"$'\n'
  has "$1: no container" "$2" "docker_runs=0"
  hasnt "$1: no login value" "$2" "$LOGIN"
  hasnt "$1: no password value" "$2" "$PW"
  hasnt "$1: no server value" "$2" "$SRV"
}
# passed NAME OUTPUT: preflight let the run through (the go stub then ended it).
passed() {
  has "$1: preflight passed" "$2" "preflight ok"
  has "$1: stopped only by the go stub" "$2" "result.txt: reason=unclassified"$'\n'"result.txt: rc=7"
  has "$1: no container yet" "$2" "docker_runs=0"
  hasnt "$1: no login value" "$2" "$LOGIN"
  hasnt "$1: no password value" "$2" "$PW"
  hasnt "$1: no server value" "$2" "$SRV"
}
sha() { sha256sum <"$1" | cut -d' ' -f1; }
# state [SERVER [HASH]]: a --state dir with a servers.dat and, with SERVER, a marker.
state() {
  local d; d=$(mktemp -d "$T/state.XXXXXX")
  echo "servers bytes" >"$d/servers.dat"
  if [ $# -gt 0 ]; then printf 'server=%s\nsha256=%s\n' "$1" "${2:-$(sha "$d/servers.dat")}" >"$d/servers.dat.verified"; fi
  echo "$d"
}
good=$(state "$SRV")
echo "file bytes" >"$T/explicit.dat"

# Row 10: env_missing names the variable.
for v in MT5_LOGIN MT5_PASSWORD MT5_SERVER; do
  case $v in
    MT5_LOGIN) out=$(L='' pf --state "$good") ;;
    MT5_PASSWORD) out=$(P='' pf --state "$good") ;;
    MT5_SERVER) out=$(S='' pf --state "$good") ;;
  esac
  refused "no $v" "$out" env_missing 10
  has "no $v: named" "$out" "$v"
done

# Row 12: expect_server_missing.
out=$(S=203.0.113.9:443 pf)
refused "address, no MT5_EXPECT_SERVER" "$out" expect_server_missing 12
has "address, no MT5_EXPECT_SERVER: named" "$out" MT5_EXPECT_SERVER
out=$(S=MetaQuotes-Demo pf --servers-dat "$T/explicit.dat")
refused "MT5_SERVER is the fallback server" "$out" expect_server_missing 12
out=$(X=MetaQuotes-Beta pf --servers-dat "$T/explicit.dat")
refused "MT5_EXPECT_SERVER is a MetaQuotes server" "$out" expect_server_missing 12

# Row 13: no_route, with the hint.
out=$(pf)
refused "name, no file, no state" "$out" no_route 13
has "name, no file: hint" "$out" "MT5_SERVERS_DAT=/path/to/servers.dat"
out=$(pf --state "$T/no-such-state")
refused "name, empty state" "$out" no_route 13
out=$(pf --servers-dat "$T/no-such.dat")
refused "--servers-dat file missing" "$out" no_route 13
has "--servers-dat file missing: hint" "$out" "MT5_SERVERS_DAT=/path/to/servers.dat"

# Row 14: route_unverified; the marker holds exactly the server and the file's hash.
out=$(pf --state "$(state)")
refused "state file, no marker" "$out" route_unverified 14
out=$(pf --state "$(state Other-Server)")
refused "marker for another server" "$out" route_unverified 14
out=$(pf --state "$(state "$SRV" 0000)")
refused "marker for another file" "$out" route_unverified 14
d=$(state "$SRV"); echo "changed" >>"$d/servers.dat"
out=$(pf --state "$d")
refused "file changed after the marker" "$out" route_unverified 14
d=$(state "$SRV"); echo "extra=1" >>"$d/servers.dat.verified"
out=$(pf --state "$d")
refused "marker with a third line" "$out" route_unverified 14
out=$(X=Other-Server pf --state "$good")
refused "marker for MT5_SERVER, another expected" "$out" route_unverified 14

# The routes that pass.
out=$(pf --state "$good")
passed "verified state" "$out"
has "verified state: image ID printed" "$out" "id=abcdef012345"
has "verified state: hash read from the image" "$out" "hash_runs=1"
out=$(X=Other-Server pf --state "$(state Other-Server)")
passed "marker for MT5_EXPECT_SERVER" "$out"
out=$(pf --servers-dat "$T/explicit.dat")
passed "explicit file, no marker" "$out"
out=$(pf --servers-dat "$T/explicit.dat" --state "$(state)")
passed "explicit file over an unverified state" "$out"

# Row 15: image_stale. Content counts; a touch does not.
out=$(STUB_IMAGE_RC=1 pf --state "$good")
refused "image missing" "$out" image_stale 15
has "image missing: no hash read" "$out" "hash_runs=0"
out=$(STUB_HASH_RC=125 pf --state "$good")
refused "image unreadable" "$out" image_stale 15
for f in mql5/Experts/GoBridge/GoBridge.mq5 docker/mt5/lib.sh docker/mt5/entrypoint.sh; do
  echo 'edit' >>"$tree/$f"
  out=$(pf --state "$good")
  refused "$f changed" "$out" image_stale 15
  build_image
  out=$(pf --state "$good")
  passed "$f changed, image rebuilt" "$out"
done
echo 'new' >"$tree/mql5/Experts/New.mqh"
out=$(pf --state "$good")
refused "file added to mql5/" "$out" image_stale 15
rm "$tree/mql5/Experts/New.mqh"
find "$tree/mql5" "$tree/docker" -type f -exec touch -d '2001-02-03 04:05:06' {} +
out=$(pf --state "$good")
passed "touch alone is not stale" "$out"

# Row 16: broker_unreachable, on the loopback only.
out=$(S=127.0.0.1:1 X=FTMO-Demo pf)
refused "address refuses" "$out" broker_unreachable 16
hasnt "address refuses: no address printed" "$out" "127.0.0.1"
out=$(EXTRA_PATH="$T/bin-timeout:" S=127.0.0.1:1 X=FTMO-Demo pf)
refused "address never answers" "$out" broker_unreachable 16
if command -v python3 >/dev/null; then
  python3 -c '
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(8)
print(s.getsockname()[1], flush=True)
while True: s.accept()[0].close()
' >"$T/port" &
  LISTENER=$!
  for _ in $(seq 100); do [ -s "$T/port" ] && break; sleep 0.05; done
  out=$(S="127.0.0.1:$(cat "$T/port")" X=FTMO-Demo pf)
  passed "address answers, no file needed" "$out"
else
  echo "skip address answers: no python3 for the listener"
fi
out=$(S=127.0.0.1:1 X=FTMO-Demo pf --state "$(state)")
refused "address: an unverified state does not matter, the probe does" "$out" broker_unreachable 16

# Order: the cheap checks come first, and each failure is the earliest row.
echo 'edit' >>"$tree/docker/mt5/lib.sh"
out=$(pf)
refused "no route and a stale image: the route" "$out" no_route 13
has "no route: image not read" "$out" "hash_runs=0"
out=$(L='' pf)
refused "no login and no route: the login" "$out" env_missing 10
build_image
echo 'edit' >>"$tree/docker/mt5/entrypoint.sh"

# Without --require-live nothing changes: no account, a stale image, no refusal.
out=$(L='' P='' S='' run_script)
has "no --require-live: stopped only by the go stub" "$out" "result.txt: reason=unclassified"$'\n'"result.txt: rc=7"
has "no --require-live: no hash read" "$out" "hash_runs=0"
hasnt "no --require-live: no preflight" "$out" "preflight ok"
build_image

# The paths in the script are where the Dockerfile puts the files.
for pair in 'COPY mql5/ /opt/gobridge/mql5/|/opt/gobridge/mql5' \
  'COPY docker/mt5/lib.sh /usr/local/lib/gomql5/lib.sh|/usr/local/lib/gomql5/lib.sh' \
  'COPY docker/mt5/entrypoint.sh docker/mt5/allow-host.sh /usr/local/bin/|/usr/local/bin/entrypoint.sh'; do
  has "Dockerfile: ${pair%%|*}" "$(cat "$root/docker/mt5/Dockerfile")" "${pair%%|*}"
  has "script reads: ${pair##*|}" "$(grep -F 'docker run --rm --entrypoint sh' "$script")" "${pair##*|}"
done
exit $fail
