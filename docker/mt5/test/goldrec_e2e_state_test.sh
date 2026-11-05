#!/bin/bash
# Tests goldrec-e2e.sh's --state: the terminal in a run writes to the run's own
# copy under OUT/state, which is seeded only from a servers.dat that
# servers.dat.verified verifies for the expected server and hash. Only a
# --require-live PASS copies that copy back to the --state dir and writes the
# marker (server= and sha256= of the promoted bytes); a failed run leaves the
# --state dir as it was. Runs the real script in a stubbed tree: docker, go and
# mt5ctl are stubs, go builds a fake recorder that writes the JSONL the script
# reads, and the stub docker "terminal" writes its servers.dat into the mount.
# Run: bash docker/mt5/test/goldrec_e2e_state_test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
root="$here/../../.."
script="$root/scripts/goldrec-e2e.sh"
fail=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
tree=$T/tree image=$T/image
LOGIN=LOGIN-VALUE-88 PW=PASSWORD-VALUE-88 SRV=SERVERNAME-VALUE-88

mkdir -p "$T/bin" "$tree/scripts" "$tree/docker/mt5" "$tree/mql5/Experts/GoBridge"
cp "$script" "$tree/scripts/goldrec-e2e.sh"
echo 'ea source' >"$tree/mql5/Experts/GoBridge/GoBridge.mq5"
echo 'lib' >"$tree/docker/mt5/lib.sh"
echo 'entrypoint' >"$tree/docker/mt5/entrypoint.sh"
printf '#!/bin/bash\nexit 1\n' >"$tree/scripts/mt5ctl.sh"
# build_image: what `docker build` does with the tree, per docker/mt5/Dockerfile.
build_image() {
  rm -rf "$image"
  mkdir -p "$image/opt/gobridge" "$image/usr/local/lib/gomql5" "$image/usr/local/bin"
  cp -r "$tree/mql5" "$image/opt/gobridge/mql5"
  cp "$tree/docker/mt5/lib.sh" "$image/usr/local/lib/gomql5/lib.sh"
  cp "$tree/docker/mt5/entrypoint.sh" "$image/usr/local/bin/entrypoint.sh"
}
build_image

# The stub docker: the image hash runs for real on the image directory; `run -d`
# is the terminal. Its mount of the state dir is recorded, the servers.dat that
# was there when it started is recorded as seen, and it then writes
# $FAKE_TERMINAL_DAT there, as the entrypoint's save does.
cat >"$T/bin/docker" <<'EOF'
#!/bin/bash
case $1 in
  image) [ "$3" != -f ] || echo sha256:abcdef0123456789abcdef ;;
  run)
    if [ "$2 $3 $4" = "--rm --entrypoint sh" ]; then # run --rm --entrypoint sh IMAGE -c S sh A B C
      exec sh -c "$7" sh "$STUB_IMG$9" "$STUB_IMG${10}" "$STUB_IMG${11}"
    fi
    for a in "$@"; do
      case $a in
        *:/gomql5-state)
          src=${a%:/gomql5-state}
          echo "$src" >"$STUB_OUT/state-mount"
          cat "$src/servers.dat" >"$STUB_OUT/state-seen" 2>/dev/null || : >"$STUB_OUT/state-seen"
          [ -z "${FAKE_TERMINAL_DAT:-}" ] || printf '%s\n' "$FAKE_TERMINAL_DAT" >"$src/servers.dat"
          ;;
      esac
    done
    echo run >>"$STUB_OUT/docker-runs"
    ;;
  *) exit 0 ;;
esac
EOF
# The stub go: `go build -o FILE ./apps/goldrec` installs the fake recorder at FILE.
cat >"$T/bin/go" <<EOF
#!/bin/bash
while [ \$# -gt 0 ]; do [ "\$1" = -o ] && cp "$T/fake-goldrec" "\$2"; shift; done
EOF
# The fake recorder: one connection, a trade server, ticks unless FAKE_NO_TICKS
# is set, and enough positioning observations; then it runs until interrupted.
# Perl, not bash: an async bash job ignores SIGINT, which the script sends.
cat >"$T/fake-goldrec" <<'PERL'
#!/usr/bin/perl
my $out;
for my $i (0 .. $#ARGV) { $out = $ARGV[$i + 1] if $ARGV[$i] eq '-out' }
mkdir $out;
sub append { open my $fh, '>>', "$out/$_[0]" or die; print $fh "$_[1]\n"; close $fh }
append('events.jsonl', '{"kind":"terminal_connected"}');
append('events.jsonl', '{"kind":"terminal_info","trade_server_connected":true}');
append('prices.jsonl', '{"trade_server_connected":true,"n":1}') unless $ENV{FAKE_NO_TICKS};
append('sentiment.jsonl', '{"n":1}');
append('sentiment.jsonl', '{"n":2}');
$SIG{INT} = $SIG{TERM} = sub { exit 0 };
sleep 1 while 1;
PERL
chmod +x "$T/bin/docker" "$T/bin/go" "$T/fake-goldrec" "$tree/scripts/mt5ctl.sh"

sha() { sha256sum <"$1" | cut -d' ' -f1; }
# state [SERVER [HASH] [BYTES]]: a --state dir with servers.dat (BYTES, default
# "servers bytes") and, with SERVER, a marker for SERVER and HASH (default: the file's).
state() {
  local d; d=$(mktemp -d "$T/state.XXXXXX")
  printf '%s\n' "${4:-servers bytes}" >"$d/servers.dat"
  if [ $# -gt 0 ]; then printf 'server=%s\nsha256=%s\n' "$1" "${2:-$(sha "$d/servers.dat")}" >"$d/servers.dat.verified"; fi
  echo "$d"
}
echo "file bytes" >"$T/explicit.dat"

# run_script O ARGS: the script with --out O/run, the stub docker and go, the
# account and image from the environment; its output goes to O/console.txt.
run_script() {
  O=$(mktemp -d "$T/out.XXXXXX")
  PATH="$T/bin:$PATH" STUB_OUT="$O" STUB_IMG="$image" E2E_IMAGE=stub/image \
    MT5_LOGIN="$LOGIN" MT5_PASSWORD="$PW" MT5_SERVER="$SRV" MT5_EXPECT_SERVER= \
    bash "$tree/scripts/goldrec-e2e.sh" --out "$O/run" --min-ticks 1 --timeout 30 "$@" >"$O/console.txt" 2>&1
  RC=$?
}
has() { # name, file, substring
  if grep -qF -- "$3" "$2"; then echo "ok   $1"; else echo "FAIL $1: no '$3' in: $(tr '\n' '|' <"$2")"; fail=1; fi
}
same() { # name, got, want
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; fail=1; fi
}

# Live PASS with a verified state: the run sees the verified bytes in its own
# copy, the terminal's bytes are promoted, and the marker holds exactly the
# server and the promoted file's hash.
st=$(state "$SRV")
FAKE_TERMINAL_DAT="terminal saved routes" run_script --require-live --live-budget 30 --state "$st"
same "verified PASS: exit" "$RC" 0
same "verified PASS: result" "$(cat "$O/run/result.txt" | head -1)" "reason=ok"
same "verified PASS: mount is the run's copy" "$(cat "$O/state-mount")" "$O/run/state"
same "verified PASS: seeded from the verified file" "$(cat "$O/state-seen")" "servers bytes"
same "verified PASS: promoted bytes" "$(cat "$st/servers.dat")" "terminal saved routes"
same "verified PASS: marker" "$(cat "$st/servers.dat.verified")" "$(printf 'server=%s\nsha256=%s' "$SRV" "$(sha "$st/servers.dat")")"
has "verified PASS: LIVE PASS line" "$O/console.txt" "LIVE PASS"

# Live PASS with no verified state (an explicit file): the marker is not
# trusted, so the run's copy starts empty; PASS still promotes the new bytes.
st=$(state "$SRV" 0000)
FAKE_TERMINAL_DAT="terminal saved routes" run_script --require-live --live-budget 30 --servers-dat "$T/explicit.dat" --state "$st"
same "explicit file: exit" "$RC" 0
same "explicit file: seeded nothing from a wrong hash" "$(wc -c <"$O/state-seen")" 0
st=$(state "$SRV")
st=$(state Other-Server)
FAKE_TERMINAL_DAT="terminal saved routes" run_script --require-live --live-budget 30 --servers-dat "$T/explicit.dat" --state "$st"
same "marker for another server: seeded nothing" "$(wc -c <"$O/state-seen")" 0

# A failed live run leaves --state alone: the terminal wrote into the run's copy.
st=$(state "$SRV")
before=$(cat "$st/servers.dat" "$st/servers.dat.verified")
FAKE_NO_TICKS=1 FAKE_TERMINAL_DAT="terminal saved routes" run_script --require-live --live-budget 2 --state "$st"
same "failed run: exit" "$RC" 28
same "failed run: result" "$(sed -n 1p "$O/run/result.txt")" "reason=no_fresh_ticks"
same "failed run: state unchanged" "$(cat "$st/servers.dat" "$st/servers.dat.verified")" "$before"
same "failed run: the run's own copy holds the terminal's bytes" "$(cat "$O/run/state/servers.dat")" "terminal saved routes"

# Without --require-live nothing is promoted, even on a PASS.
st=$(state "$SRV")
before=$(cat "$st/servers.dat" "$st/servers.dat.verified")
FAKE_TERMINAL_DAT="terminal saved routes" run_script --state "$st"
same "cached PASS: exit" "$RC" 0
same "cached PASS: state unchanged" "$(cat "$st/servers.dat" "$st/servers.dat.verified")" "$before"

exit $fail
