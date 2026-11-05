#!/bin/bash
# Tests lib.sh's servers_dat_install / servers_dat_save with temp files.
# Run: bash docker/mt5/test/servers_dat_test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
fns=$(sed -n '/^servers_dat_install() {/,/^}/p; /^servers_dat_save() {/,/^}/p; /^mt5_config_dir() {/,/^}/p' "$here/../lib.sh")
[[ "$fns" == *"servers_dat_install()"* && "$fns" == *"servers_dat_save()"* ]] || { echo "FAIL: functions not found in lib.sh"; exit 1; }
eval "$fns"
fail=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
same() { # name, want, got
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}

# --- install -------------------------------------------------------------------
mkdir -p "$T/term/Config"
dest=$T/term/Config/servers.dat
printf 'stock MetaQuotes list' >"$dest"
ln "$dest" "$T/stock-link" # still names the old file only if install replaced it (rename), not rewrote it
printf 'broker list with FTMO-Demo' >"$T/broker.dat"
out=$(servers_dat_install "$T/broker.dat" "$dest"); rc=$?
same "install: succeeds" 0 "$rc"
same "install: copies the file" "broker list with FTMO-Demo" "$(cat "$dest")"
same "install: logs size and hash" "servers.dat: installed $T/broker.dat (26 bytes, sha256 " "${out%????????????)}"
same "install: atomic (new inode via rename; the old file is untouched)" "stock MetaQuotes list" "$(cat "$T/stock-link")"
same "install: no temp file left" "servers.dat" "$(ls "$T/term/Config")"

out=$(servers_dat_install "$T/broker.dat" "$T/fresh/Config/servers.dat"); rc=$?
same "install: creates the config dir" "0 broker list with FTMO-Demo" "$rc $(cat "$T/fresh/Config/servers.dat" 2>/dev/null)"

printf 'stock MetaQuotes list' >"$dest"
out=$(servers_dat_install "$T/missing.dat" "$dest"); rc=$?
same "missing source: returns 1" 1 "$rc"
same "missing source: keeps the stock list" "stock MetaQuotes list" "$(cat "$dest")"
same "missing source: says so" "servers.dat: $T/missing.dat missing or empty, keeping the stock list" "$out"
: >"$T/empty.dat"
servers_dat_install "$T/empty.dat" "$dest" >/dev/null; rc=$?
same "empty source: returns 1, keeps the stock list" "1 stock MetaQuotes list" "$rc $(cat "$dest")"

# --- save ----------------------------------------------------------------------
mkdir -p "$T/state"
printf 'learned list v1' >"$dest"
out=$(servers_dat_save "$dest" "$T/state"); rc=$?
same "save: writes a changed file" "learned list v1" "$(cat "$T/state/servers.dat" 2>/dev/null)"
same "save: logs it" "servers.dat: saved to $T/state (15 bytes, sha256 " "${out%????????????)}"
same "save: succeeds" 0 "$rc"
touch -d '2000-01-01' "$T/state/servers.dat"
before=$(stat -c %Y "$T/state/servers.dat")
out=$(servers_dat_save "$dest" "$T/state"); rc=$?
same "save unchanged: silent" "" "$out"
same "save unchanged: succeeds" 0 "$rc"
same "save unchanged: file not rewritten" "$before" "$(stat -c %Y "$T/state/servers.dat")"
printf 'learned list v2' >"$dest"
servers_dat_save "$dest" "$T/state" >/dev/null
same "save: picks up a later change" "learned list v2" "$(cat "$T/state/servers.dat")"
same "save: no temp file left" "servers.dat" "$(ls -A "$T/state")"
out=$(servers_dat_save "$T/missing.dat" "$T/state"); rc=$?
same "save without a terminal copy: silent no-op" "0  learned list v2" "$rc $out $(cat "$T/state/servers.dat")"
out=$(servers_dat_save "$dest" "$T/no-such-dir"); rc=$?
same "save without a state dir: silent no-op" "0 " "$rc $out"

# Which config folder the terminal uses (measured 2026-11-05: with both
# "Config" and "config" present it read/wrote the lowercase one).
M=$T/mt5a; mkdir -p "$M/Config"
same "only Config: use it" "$M/Config" "$(mt5_config_dir "$M")"
same "only Config: no second folder created" "Config" "$(ls "$M")"
mkdir -p "$M/config"
same "both: the lowercase one (what the terminal uses)" "$M/config" "$(mt5_config_dir "$M")"
M=$T/mt5b; mkdir -p "$M"
same "neither: create Config" "$M/Config Config" "$(mt5_config_dir "$M") $(ls "$M")"
exit $fail
