#!/bin/bash
# Tests C14: scripts/session.sh says whether the saved mt5-state/servers.dat is
# verified. It is verified only when servers.dat.verified holds a sha256= that
# matches the file. Runs on temp dirs only, so mt5-state/ is never read.
# Run: bash docker/mt5/test/servers_state_test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
fn=$(sed -n '/^servers_state_status() {/,/^}/p' "$here/../../../scripts/session.sh")
[ -n "$fn" ] || { echo "FAIL: servers_state_status not found in scripts/session.sh"; exit 1; }
eval "$fn"
fail=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

same() { # name, want, got
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}

# no servers.dat at all, and an empty one
mkdir -p "$T/none"
same "no file: empty" "is empty" "$(servers_state_status "$T/none")"
mkdir -p "$T/zero"; : >"$T/zero/servers.dat"
same "zero-byte file: empty" "is empty" "$(servers_state_status "$T/zero")"

# a saved file with no marker is unverified
mkdir -p "$T/nomark"; printf 'learned list' >"$T/nomark/servers.dat"
same "file without marker: unverified" "has a saved servers.dat, unverified" "$(servers_state_status "$T/nomark")"

# a marker whose hash matches is verified
mkdir -p "$T/ok"; printf 'learned list' >"$T/ok/servers.dat"
h=$(sha256sum "$T/ok/servers.dat" | cut -d' ' -f1)
printf 'server=FTMO-Demo\nsha256=%s\n' "$h" >"$T/ok/servers.dat.verified"
same "matching hash: verified" "has a saved servers.dat, verified" "$(MT5_SERVER=FTMO-Demo servers_state_status "$T/ok")"

# the file changed after promotion: the hash no longer matches
printf 'overwritten by a failed run' >"$T/ok/servers.dat"
same "hash mismatch: unverified" "has a saved servers.dat, unverified" "$(servers_state_status "$T/ok")"

# a marker without a sha256 line cannot verify anything
mkdir -p "$T/nohash"; printf 'learned list' >"$T/nohash/servers.dat"
printf 'server=FTMO-Demo\n' >"$T/nohash/servers.dat.verified"
same "marker without sha256: unverified" "has a saved servers.dat, unverified" "$(servers_state_status "$T/nohash")"

# a matching hash is not enough: the marker must name the expected server
# (MT5_EXPECT_SERVER, else MT5_SERVER). A marker for another broker is unverified.
mkdir -p "$T/wrongsrv"; printf 'learned list' >"$T/wrongsrv/servers.dat"
h=$(sha256sum "$T/wrongsrv/servers.dat" | cut -d' ' -f1)
printf 'server=OtherBroker-Demo\nsha256=%s\n' "$h" >"$T/wrongsrv/servers.dat.verified"
same "wrong server in marker: unverified" "has a saved servers.dat, unverified" "$(MT5_SERVER=FTMO-Demo servers_state_status "$T/wrongsrv")"

exit $fail
