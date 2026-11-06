#!/bin/bash
# The live defaults are the user's contract: first live tick within 60 s, ticks at most 60 s behind.
set -u
cd "$(dirname "$0")/../../.."
fails=0
check() { # NAME FILE PATTERN
  if grep -Eq "$3" "$2"; then echo "ok   $1"; else echo "FAIL $1: no /$3/ in $2"; fails=$((fails + 1)); fi
}
check "Makefile LIVE_BUDGET 60" Makefile '^LIVE_BUDGET \?= 60$'
check "session.sh LIVE_BUDGET 60" scripts/session.sh 'LIVE_BUDGET="\$\{LIVE_BUDGET:-60\}"'
check "goldrec-e2e.sh LIVE_BUDGET 60" scripts/goldrec-e2e.sh '(^| )LIVE_BUDGET=60( |$)'
check "goldrec-e2e.sh MAX_LAG 60" scripts/goldrec-e2e.sh '(^| )MAX_LAG=60( |$)'
check "goldrec -max-lag 60s" apps/goldrec/main.go '"max-lag", 60\*time.Second'
[ $fails = 0 ]
