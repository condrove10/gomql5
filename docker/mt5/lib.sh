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

# Wait until the terminal's main window exists (default 120 s).
ui_wait_main() {
  for _ in $(seq 1 "${1:-120}"); do
    xdotool search --name "MetaTrader 5" >/dev/null 2>&1 && return 0
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
  w=$(xdotool search --name "MetaTrader 5" 2>/dev/null | head -1 || true)
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
