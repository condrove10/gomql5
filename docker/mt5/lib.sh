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
# Logged in to an account the Toolbox gains Trade/Exposure/History/Company tabs
# and Experts/Journal move right (measured on a user's FTMO-Demo screenshot, build 6300).
UI_TOOLBOX_TAB_EXPERTS_ACCOUNT="656 993"
UI_TOOLBOX_TAB_JOURNAL_ACCOUNT="712 993"

# --- crop regions for screenshots (ImageMagick geometry WxH+X+Y) ---------------
UI_CROP_OPTIONS="620x380+350+395"  # whole Options dialog
UI_CROP_URLLIST="620x140+350+590"  # "Allow WebRequest for listed URL" + list
UI_CROP_TOOLBOX="1280x320+0+680"   # Toolbox (Experts/Journal rows)

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

# True when an account is authorized: the main window title then reads
# "<login> - <server>: Demo Account - Read Only - …" (or "Real Account");
# logged out it is "MetaTrader 5 - …", and with a login that failed to
# authorize "<login> - <server> - Netting" (both with the plain Toolbox).
ui_account_authorized() {
  local w
  w=$(ui_main_window) || return 1
  [[ "$(xdotool getwindowname "$w" 2>/dev/null)" == *" Account - "* ]]
}
ui_toolbox_experts() {
  if ui_account_authorized; then ui_click $UI_TOOLBOX_TAB_EXPERTS_ACCOUNT; else ui_click $UI_TOOLBOX_TAB_EXPERTS; fi
  sleep 1
}
ui_toolbox_journal() {
  if ui_account_authorized; then ui_click $UI_TOOLBOX_TAB_JOURNAL_ACCOUNT; else ui_click $UI_TOOLBOX_TAB_JOURNAL; fi
  sleep 1
}

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

# --- trade-server list (config/servers.dat) ----------------------------------
# A config login (Server=NAME in [Common]) only works when the terminal can
# resolve NAME: MetaQuotes documents Server as "address and port number of a
# trade server separated with a colon", and a name resolves only if
# config/servers.dat already lists it. The stock install lists MetaQuotes
# servers only, so Server=FTMO-Demo fell back to MetaQuotes-Demo ("Invalid
# account"). Fix: install a servers.dat that knows the broker (e.g. copied from
# a desktop MT5 that has logged in once) and keep the terminal's own copy after
# every start, so one successful login teaches all later starts.

# servers_dat_install SRC DEST: copy SRC over DEST atomically; prints a log line.
servers_dat_install() {
  local src=$1 dest=$2 tmp
  [ -s "$src" ] || { echo "servers.dat: $src missing or empty, keeping the stock list"; return 1; }
  mkdir -p "$(dirname "$dest")"
  tmp="$dest.gomql5-tmp"
  cp "$src" "$tmp" && mv -f "$tmp" "$dest" || return 1
  echo "servers.dat: installed $src ($(stat -c %s "$dest") bytes, sha256 $(sha256sum "$dest" | cut -c1-12))"
}

# servers_dat_save SRC DIR: keep a copy of the terminal's servers.dat in DIR
# when it changed; silent when unchanged.
servers_dat_save() {
  local src=$1 dir=$2 tmp
  [ -s "$src" ] && [ -d "$dir" ] || return 0
  cmp -s "$src" "$dir/servers.dat" 2>/dev/null && return 0
  tmp="$dir/.servers.dat.tmp"
  cp "$src" "$tmp" && mv -f "$tmp" "$dir/servers.dat" &&
    echo "servers.dat: saved to $dir ($(stat -c %s "$dir/servers.dat") bytes, sha256 $(sha256sum "$dir/servers.dat" | cut -c1-12))"
}

# Print an MT5 UTF-16LE log as UTF-8 without CRs.
mt5_log() { iconv -f UTF-16LE -t UTF-8 "$1" | tr -d '\r'; }
