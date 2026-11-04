#!/bin/bash
# Adds a host to Tools > Options > Expert Advisors > "Allow WebRequest for listed
# URL" by driving the terminal UI with xdotool. MQL5 SocketConnect only reaches
# hosts on that list, and the terminal stores it encrypted (config/settings.ini),
# so it cannot be written as a file.
#
# Usage (inside the container, terminal running):  allow-host.sh <ip|localhost>
# The list rejects single-label names like "app"; entrypoint.sh passes an IP.
# Coordinates assume the 1280x1024 Xvfb screen started by entrypoint.sh and were
# recorded against MT5 build 6296. If a future build moves the dialog, do it once
# over VNC instead (VNC_PASSWORD); the setting persists in the volume.
set -euo pipefail
HOST="${1:?usage: allow-host.sh <host>}"
export DISPLAY="${DISPLAY:-:99}"

for _ in $(seq 1 120); do
  xdotool search --name "MetaTrader 5" >/dev/null 2>&1 && break
  sleep 1
done
sleep "${ALLOW_HOST_DELAY:-20}" # let start-up dialogs (account wizard, LiveUpdate) appear

xdotool key Escape; sleep 1; xdotool key Escape; sleep 1 # close start-up dialogs
# There is no window manager, so keyboard focus is unreliable: use the mouse.
xdotool mousemove 215 41 click 1; sleep 2                 # Tools menu
xdotool mousemove 240 274 click 1; sleep 3                # Options...
xdotool mousemove 515 410 click 1; sleep 2                # "Experts" tab
xdotool mousemove 500 631 click 1; sleep 1                # select "add new URL" row
xdotool click --repeat 2 --delay 80 1; sleep 1            # double-click: edit
xdotool type --delay 50 "$HOST"; xdotool key Return; sleep 1
xdotool mousemove 759 765 click 1                         # OK
# The terminal persists this to config/settings.ini only on a clean shutdown
# (entrypoint.sh closes the window on SIGTERM). Success shows as the EA connecting.
echo "[gomql5-mt5] allow-host: requested $HOST"
