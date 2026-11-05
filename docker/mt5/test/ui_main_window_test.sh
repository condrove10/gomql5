#!/bin/bash
# Tests lib.sh's main-window lookup with a fake xdotool. The window must be
# found by class, whatever its title: logged in to an account, MT5's title is
# "<login>: <server> - Demo Account - …" and no longer contains "MetaTrader 5"
# (seen with a live FTMO login, 2026-11-04: "allow-host: terminal window not found").
# Run: bash docker/mt5/test/ui_main_window_test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
# Fake xdotool: class search returns the windows in $FAKE_WINDOWS ("id:WxH:title ..."),
# name search matches titles, geometry comes from the same list.
cat >"$tmp/bin/xdotool" <<'FAKE'
#!/bin/bash
find_win() { for e in $FAKE_WINDOWS; do [ "${e%%:*}" = "$1" ] && echo "$e"; done; }
case "$1" in
  search)
    shift; mode="" pat=""
    while [ $# -gt 0 ]; do
      case $1 in --onlyvisible) ;; --class) mode=class; pat=$2; shift ;; --name) mode=name; pat=$2; shift ;; esac
      shift
    done
    found=1
    for e in $FAKE_WINDOWS; do
      id=${e%%:*} title=${e#*:*:}; title=${title//_/ }
      if [ "$mode" = class ] && [ "$pat" = terminal64 ]; then echo "$id"; found=0; fi
      if [ "$mode" = name ] && [[ "$title" == *"$pat"* ]]; then echo "$id"; found=0; fi
    done
    exit $found ;;
  getwindowgeometry)
    e=$(find_win "$3"); geo=${e#*:}; geo=${geo%%:*}
    echo "WINDOW=$3"; echo "X=0"; echo "Y=0"; echo "WIDTH=${geo%x*}"; echo "HEIGHT=${geo#*x}"; echo "SCREEN=0" ;;
  getwindowname)
    e=$(find_win "$2"); title=${e#*:*:}; echo "${title//_/ }" ;;
  mousemove)
    echo "$2 $3" >>"${FAKE_CLICKS:-/dev/null}" ;;
esac
FAKE
chmod +x "$tmp/bin/xdotool"
fail=0
run() { # FAKE_WINDOWS, expression -> output
  PATH="$tmp/bin:$PATH" FAKE_WINDOWS="$1" GOMQL5_LIB="$here/../lib.sh" bash -c 'source "$GOMQL5_LIB"; sleep() { :; }; '"$2"
}
check() { # name, expected, actual
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
logged_in="11:1280x1000:1515192722:_FTMO-Demo_-_Demo_Account_-_Hedge_-_[XAUUSD,H1] 12:400x300:Options"
no_account="21:1280x1000:MetaTrader_5_-_Netting_-_EURUSD,H1"
check "main window found when logged in (title without 'MetaTrader 5')" "11" "$(run "$logged_in" ui_main_window)"
check "largest window wins over a dialog" "11" "$(run "12:400x300:Options 11:1280x1000:x" ui_main_window)"
check "main window found without an account" "21" "$(run "$no_account" ui_main_window)"
check "ui_wait_main succeeds when logged in" "0" "$(run "$logged_in" 'ui_wait_main 2; echo $?')"
check "ui_wait_main fails with no window" "1" "$(run "" 'ui_wait_main 2; echo $?')"

# Toolbox tab choice by login state. Titles are the real ones from a user's
# runs (2026-11-04): authorized, login set but not authorized, logged out.
authorized="11:1280x1000:1515192722_-_FTMO-Demo:_Demo_Account_-_Read_Only_-_Hedge_-_FTMO_Global_Markets_Ltd"
not_authorized="11:1280x1000:1515192722_-_FTMO-Server2_-_Netting"
clicks() { # windows, function -> the clicked "X Y"
  local f="$tmp/clicks"; : >"$f"
  PATH="$tmp/bin:$PATH" FAKE_CLICKS="$f" FAKE_WINDOWS="$1" GOMQL5_LIB="$here/../lib.sh" bash -c 'source "$GOMQL5_LIB"; sleep() { :; }; '"$2"
  cat "$f"
}
check "authorized: Experts tab in the account layout" "656 993" "$(clicks "$authorized" ui_toolbox_experts)"
check "authorized: Journal tab in the account layout" "712 993" "$(clicks "$authorized" ui_toolbox_journal)"
check "login not authorized: plain layout" "402 993" "$(clicks "$not_authorized" ui_toolbox_experts)"
check "logged out: plain layout" "472 993" "$(clicks "$no_account" ui_toolbox_journal)"
exit $fail
