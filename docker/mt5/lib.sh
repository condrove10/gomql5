# shellcheck shell=bash
# gomql5 container helpers, installed as /usr/local/lib/gomql5/lib.sh.
# Sourced by entrypoint.sh, allow-host.sh and (via docker exec) scripts/mt5ctl.sh.
#
# UI coordinates are for the 1280x1024 Xvfb screen started by entrypoint.sh and
# were recorded against MT5 build 6295/6296 (Wine 11.21). If a build moves
# something, re-measure with `scripts/mt5ctl.sh shot` and update it HERE only.
# There is no window manager: keyboard focus is unreliable (Ctrl+O can land in a
# chart's quick-navigation box), so menus are driven with the mouse.

export DISPLAY="${DISPLAY:-:99}"

# --- coordinates "X Y" ----------------------------------------------------
UI_MENU_TOOLS="215 41"            # menu bar: Tools
UI_MENU_TOOLS_OPTIONS="240 274"   # Tools > Options...
UI_OPTIONS_TAB_EXPERTS="515 410"  # Options dialog: "Experts" tab
UI_OPTIONS_URL_ADD_ROW="500 631"  # Experts tab: "+ add new URL" row
UI_OPTIONS_OK="759 765"           # Options dialog: OK
UI_TOOLBOX_TAB_EXPERTS="402 993"  # bottom Toolbox: "Experts" tab (EA Print output)
UI_TOOLBOX_TAB_JOURNAL="472 993"  # bottom Toolbox: "Journal" tab (terminal log)
UI_MENU_FILE="20 41"              # menu bar: File
UI_MENU_FILE_OPEN_ACCOUNT="75 344" # File > Open an Account (company search wizard)
UI_ACCOUNT_SEARCH_FIELD="570 360" # wizard: "add new company like 'CompanyName'..." field
UI_ACCOUNT_SEARCH_FIND="903 360"  # wizard: "Find your company" button
UI_ACCOUNT_FIRST_ROW="600 400"    # wizard: first company row (a found company is pre-selected)
UI_ACCOUNT_NEXT="830 765"         # wizard: "Next >"
UI_ACCOUNT_EXISTING="343 599"     # page 2: "Connect with an existing trade account" radio
UI_ACCOUNT_LOGIN="490 626"        # page 2: Login field
UI_ACCOUNT_PASSWORD="490 653"     # page 2: Password field
UI_ACCOUNT_SERVER="540 682"       # page 2: Server pick-list (not editable; lists the company's servers)
UI_ACCOUNT_FINISH="840 765"       # page 2: "Finish"

# --- crop regions for screenshots (ImageMagick geometry WxH+X+Y) ---------------
UI_CROP_OPTIONS="620x380+350+395"  # whole Options dialog
UI_CROP_URLLIST="620x140+350+590"  # "Allow WebRequest for listed URL" + list
UI_CROP_TOOLBOX="1280x320+0+680"   # Toolbox (Experts/Journal rows)
UI_CROP_ACCOUNT="700x520+296+270"  # File > Open an Account wizard

# --- locking ----------------------------------------------------------------
# Only one actor may drive the UI at a time: allow-host.sh (and its retries),
# the shutdown handler and scripts/mt5ctl.sh all take this lock. Without it a
# retry and a walkthrough interleave clicks and both derail (observed).
UI_LOCK=/tmp/gomql5-ui.lock

# ui_lock [timeout-seconds]: take the lock on fd 9 for the rest of the shell.
ui_lock() {
  exec 9>"$UI_LOCK"
  flock -w "${1:-120}" 9
}

# --- actions ----------------------------------------------------------------
ui_click() { xdotool mousemove "$1" "$2" click 1; }

# Print the terminal's main window id: the largest visible window of class
# terminal64 (Wine sets WM_CLASS from the exe). Don't match on the title: it is
# "MetaTrader 5 - Netting - EURUSD,H1" only while no account is logged in;
# logged in it becomes "<login>: <server> - Demo Account - …", and a
# title search then finds nothing (seen with a live FTMO login, 2026-11-04,
# build 6300: "allow-host: terminal window not found").
ui_main_window() {
  local w best="" max=0 area WINDOW X Y WIDTH HEIGHT SCREEN
  for w in $(xdotool search --onlyvisible --class terminal64 2>/dev/null); do
    eval "$(xdotool getwindowgeometry --shell "$w" 2>/dev/null)" || continue
    area=$((${WIDTH:-0} * ${HEIGHT:-0}))
    if [ "$area" -gt "$max" ]; then max=$area; best=$w; fi
  done
  [ -n "$best" ] && echo "$best"
}

# Wait until the terminal's main window exists (default 120 s).
ui_wait_main() {
  for _ in $(seq 1 "${1:-120}"); do
    [ -n "$(ui_main_window)" ] && return 0
    sleep 1
  done
  return 1
}

# Escape twice: closes the account wizard, the LiveUpdate "Restart" prompt or an
# open Options dialog (Escape = Cancel / Later).
ui_dismiss() {
  xdotool key Escape 2>/dev/null || true; sleep 1
  xdotool key Escape 2>/dev/null || true; sleep 1
}

ui_open_options_experts() {
  ui_dismiss
  ui_click $UI_MENU_TOOLS; sleep 2
  ui_click $UI_MENU_TOOLS_OPTIONS; sleep 3
  ui_click $UI_OPTIONS_TAB_EXPERTS; sleep 2
}

# Type an entry into the allowed-URL list (Options > Experts must be open).
# A single click to select, then a double-click to enter edit mode.
ui_options_add_url() {
  ui_click $UI_OPTIONS_URL_ADD_ROW; sleep 1
  xdotool click --repeat 2 --delay 80 1; sleep 1
  xdotool type --delay 50 "$1"
  xdotool key Return; sleep 1
}

ui_options_ok() { ui_click $UI_OPTIONS_OK; sleep 1; }

# Search the MetaQuotes broker directory for a company (e.g. "FTMO") in
# File > Open an Account. A successful search adds that company's servers
# (e.g. FTMO-Demo) to the terminal, which a config login to an unknown server
# needs. Leaves the wizard open on the result list (screenshot it, then
# ui_dismiss); it never proceeds to open an account. Click and type are one
# xdotool call: with no window manager, focus is lost between calls (observed:
# separate calls typed nothing). Verified up to the search starting (field
# greyed out) on build 6295; the result list is unverified because the
# sandbox could not reach the directory.
ui_find_company() {
  ui_dismiss
  ui_click $UI_MENU_FILE; sleep 2
  ui_click $UI_MENU_FILE_OPEN_ACCOUNT; sleep 4
  # shellcheck disable=SC2086
  xdotool mousemove ${UI_ACCOUNT_SEARCH_FIELD} click 1 sleep 0.5 type --delay 80 "$1"
  sleep 1
  ui_click $UI_ACCOUNT_SEARCH_FIND
}

# Log in to an existing account through File > Open an Account:
#   ui_login_existing COMPANY INDEX [SEARCH_WAIT]
# COMPANY is searched in the broker directory (empty: use the first listed
# company, i.e. MetaQuotes); INDEX picks the INDEX-th entry (0 = first) of the
# company's server list, which is a pick-list that ignores typed names (Wine's
# type-ahead matches one letter only). Login and password come from
# $MT5_LOGIN / $MT5_PASSWORD (the container env); nothing is echoed.
# Writes /tmp/mt5ctl-servers.png (the open server list) and
# /tmp/mt5ctl-login.png (the filled form; the password field is masked).
# Why: a config login (Server=FTMO-Demo) to a server the stock terminal does
# not know falls back to MetaQuotes-Demo ("authorization on MetaQuotes-Demo
# failed (Invalid account)", user's run 2026-11-04); this path makes the
# terminal learn the company's servers first. Page 2 coordinates measured on
# build 6295 with MetaQuotes Ltd.; with a found company they are unverified.
ui_login_existing() {
  local company=$1 index=${2:-0} wait=${3:-20} i
  [ -n "${MT5_LOGIN:-}" ] && [ -n "${MT5_PASSWORD:-}" ] || { echo "ui_login_existing: MT5_LOGIN/MT5_PASSWORD not set" >&2; return 1; }
  [ "$company" = - ] && company="" # "-": first listed company (testing without the directory)
  if [ -n "$company" ]; then
    ui_find_company "$company"
    sleep "$wait" # the directory search; the found company ends up selected
  else
    ui_dismiss
    ui_click $UI_MENU_FILE; sleep 2
    ui_click $UI_MENU_FILE_OPEN_ACCOUNT; sleep 4
    ui_click $UI_ACCOUNT_FIRST_ROW; sleep 1
  fi
  ui_click $UI_ACCOUNT_NEXT
  # Page 2 ignores input for a while after it appears (observed: typed
  # login/password and the server click were dropped 6 s after Next, and
  # worked once the page had settled). Wait, then fill twice: Ctrl+A makes
  # re-typing idempotent, so a dropped first attempt is harmless.
  sleep "${UI_ACCOUNT_PAGE_WAIT:-20}"
  ui_click $UI_ACCOUNT_EXISTING; sleep 0.5
  for i in 1 2; do
    # shellcheck disable=SC2086
    xdotool mousemove ${UI_ACCOUNT_LOGIN} click 1 sleep 0.3 key ctrl+a type --delay 60 "$MT5_LOGIN"
    sleep 0.5
    # shellcheck disable=SC2086
    xdotool mousemove ${UI_ACCOUNT_PASSWORD} click 1 sleep 0.3 key ctrl+a type --delay 60 "$MT5_PASSWORD"
    sleep 1.5
  done
  ui_click $UI_ACCOUNT_SERVER; sleep 1.5          # opens the list
  xdotool key Home; sleep 0.3
  for ((i = 0; i < index; i++)); do xdotool key Down; sleep 0.2; done
  ui_shot /tmp/mt5ctl-servers.png "$UI_CROP_ACCOUNT"
  xdotool key Return; sleep 1                      # closes the list on the highlighted entry
  ui_shot /tmp/mt5ctl-login.png "$UI_CROP_ACCOUNT"
  ui_click $UI_ACCOUNT_FINISH
}

ui_toolbox_experts() { ui_click $UI_TOOLBOX_TAB_EXPERTS; sleep 1; }
ui_toolbox_journal() { ui_click $UI_TOOLBOX_TAB_JOURNAL; sleep 1; }

# Screenshot the virtual screen: ui_shot <out.png> [crop-geometry]
ui_shot() {
  import -window root "$1"
  if [ -n "${2:-}" ]; then
    convert "$1" -crop "$2" +repage "$1"
  fi
}

# Clean exit: the terminal saves settings only when its main window is closed.
ui_close_terminal() {
  ui_dismiss
  local w
  w=$(ui_main_window || true)
  [ -n "$w" ] && xdotool windowfocus "$w" 2>/dev/null || true
  xdotool key alt+F4 2>/dev/null || true
}

# --- non-UI -----------------------------------------------------------------
# True when some process holds an ESTABLISHED TCP connection to remote port $1
# (default $GOBRIDGE_PORT). Only existing tables are read: /proc/net/tcp6 is
# absent when IPv6 is off, and a missing file makes awk exit 2.
bridge_connected() {
  local port="${1:-${GOBRIDGE_PORT:-7788}}" hex f files=()
  hex=$(printf '%04X' "$port")
  for f in /proc/net/tcp /proc/net/tcp6; do [ -r "$f" ] && files+=("$f"); done
  awk -v p=":$hex" '$3 ~ p"$" && $4 == "01" { found = 1 } END { exit !found }' "${files[@]}"
}

# Print an MT5 UTF-16LE log as UTF-8 without CRs.
mt5_log() { iconv -f UTF-16LE -t UTF-8 "$1" | tr -d '\r'; }
