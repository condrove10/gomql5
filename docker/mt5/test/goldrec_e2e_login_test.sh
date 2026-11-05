#!/bin/bash
# Tests goldrec-e2e.sh's config-login failure detection (login_failure)
# against terminal journals (ensure_live, which acts on it, is covered by
# goldrec_e2e_budget_test.sh):
#   * testdata/journal-ftmo-wizard.txt: a real FTMO run (2026-11-04, login
#     replaced). Its config login to FTMO-Demo fell back to MetaQuotes-Demo
#     ("authorization on MetaQuotes-Demo failed"), then the (since removed)
#     wizard hit FTMO-Server4, -Server5, -Server, -Server3, -Server2;
#   * a synthetic successful login ("authorized on FTMO-Demo through ...").
# Run: bash docker/mt5/test/goldrec_e2e_login_test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../../../scripts/goldrec-e2e.sh"
wizard="$here/testdata/journal-ftmo-wizard.txt"
defs=$(sed -n '/^SERVERS_DAT_HINT=/p; /^login_failure() {/,/^}/p' "$script")
[[ "$defs" == *"login_failure()"* ]] || { echo "FAIL: functions not found"; exit 1; }
fail=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
printf '%s\t0\t%s\t%s\t%s\n' \
  CS 08:00:01.100 Terminal 'MetaTrader 5 x64 build 6300 started for MetaQuotes Ltd.' \
  QE 08:00:02.200 Network "'12345678': no connection to FTMO-Demo" \
  KL 08:00:04.900 Network "'12345678': authorized on FTMO-Demo through Access Point EU 1 (ping: 23.11 ms, build 5833)" \
  NM 08:00:05.000 Broker 'FTMO-Demo: no demo/preliminary groups on server side' \
  DH 08:00:05.300 Network "'12345678': terminal synchronized with FTMO S.R.O.: 0 positions, 0 orders, 931 symbols" \
  >"$T/success.txt"
grep -v MetaQuotes-Demo "$wizard" >"$T/rejected.txt" # FTMO-Server4..2 reject, no fallback

# lf SERVER JOURNAL: login_failure's message and status, under set -euo pipefail.
lf() { bash -c 'set -euo pipefail; eval "$1"; login_failure "$2" <"$3" && echo "status=0" || echo "status=1"' _ "$defs" "$1" "$2" 2>&1; }
has() { # name, output, substring
  if [[ "$2" == *"$3"* ]]; then echo "ok   $1"; else echo "FAIL $1: no '$3' in: $(echo "$2" | tr '\n' '|')"; fail=1; fi
}
hasnt() {
  if [[ "$2" != *"$3"* ]]; then echo "ok   $1"; else echo "FAIL $1: unexpected '$3' in: $(echo "$2" | tr '\n' '|')"; fail=1; fi
}

out=$(lf FTMO-Demo "$wizard")
has "unknown server: names the fallback" "$out" "does not know MT5_SERVER=FTMO-Demo and fell back to MetaQuotes-Demo"
has "unknown server: quotes the journal" "$out" "authorization on MetaQuotes-Demo failed (Invalid account)"
has "unknown server: says to provide servers.dat" "$out" "MT5_SERVERS_DAT=/path/to/servers.dat"
has "unknown server: offers address:port" "$out" "MT5_SERVER=address:port"
has "unknown server: detected" "$out" "status=0"

out=$(lf FTMO-Server4 "$T/rejected.txt")
has "server rejects the account: says so" "$out" "FTMO-Server4 rejected the login"
has "server rejects the account: check credentials" "$out" "check MT5_LOGIN/MT5_PASSWORD"
has "server rejects the account: detected" "$out" "status=0"

out=$(lf FTMO-Demo "$T/rejected.txt")
has "other servers' failures and Broker lines don't count" "$out" "status=1"

out=$(lf MetaQuotes-Demo "$wizard")
has "MT5_SERVER=MetaQuotes-Demo: a rejection, not a fallback" "$out" "MetaQuotes-Demo rejected the login"

out=$(lf FTMO-Demo "$T/success.txt")
has "successful login: no failure" "$out" "status=1"
hasnt "successful login: silent" "$out" "rejected"

out=$(lf FTMO-Demo /dev/null)
has "empty journal: no failure" "$out" "status=1"

exit $fail
