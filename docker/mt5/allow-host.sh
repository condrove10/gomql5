#!/bin/bash
# Adds a host to Tools > Options > Expert Advisors > "Allow WebRequest for listed
# URL" by driving the terminal UI with xdotool. MQL5 SocketConnect only reaches
# hosts on that list, and the terminal stores it encrypted (config/settings.ini),
# so it cannot be written as a file.
#
# Usage (inside the container, terminal running):  allow-host.sh <ip|localhost>
# The list rejects single-label names like "app"; entrypoint.sh passes an IP.
# Coordinates live in /usr/local/lib/gomql5/lib.sh (docker/mt5/lib.sh).
set -euo pipefail
HOST="${1:?usage: allow-host.sh <host>}"
# shellcheck source=lib.sh
source "${GOMQL5_LIB:-/usr/local/lib/gomql5/lib.sh}"

ui_wait_main 120 || { echo "[gomql5-mt5] allow-host: terminal window not found" >&2; exit 1; }
sleep "${ALLOW_HOST_DELAY:-20}" # let start-up dialogs (account wizard, LiveUpdate) appear

ui_lock 120 || { echo "[gomql5-mt5] allow-host: UI lock busy" >&2; exit 1; }
ui_open_options_experts
ui_options_add_url "$HOST"
ui_options_ok
# Success shows as the EA connecting (entrypoint.sh watches for it and retries).
echo "[gomql5-mt5] allow-host: requested $HOST"
