#!/bin/bash
# Starts MetaTrader 5 headless with the GoBridge EA attached.
#
# Required:  GOBRIDGE_TOKEN          shared secret (= mt5.Config.Token on the Go side)
# Optional:  GOBRIDGE_HOST           Go server host            (default host.docker.internal)
#            GOBRIDGE_PORT           Go server port            (default 7788)
#            MT5_LOGIN/MT5_PASSWORD/MT5_SERVER  broker account (else: accounts saved in the volume)
#            MT5_SYMBOL/MT5_PERIOD   chart the EA is attached to (default EURUSD / M1)
#            VNC_PASSWORD            if set, x11vnc serves the virtual screen on :5900
#            GOBRIDGE_AUTO_ALLOW     1 (default) = add GOBRIDGE_HOST to the terminal's allowed-URL
#                                    list via UI automation (allow-host.sh) on every start; 0 = manage it over VNC
set -euo pipefail

: "${GOBRIDGE_TOKEN:?GOBRIDGE_TOKEN is required}"
GOBRIDGE_HOST="${GOBRIDGE_HOST:-host.docker.internal}"
GOBRIDGE_PORT="${GOBRIDGE_PORT:-7788}"
MT5_SYMBOL="${MT5_SYMBOL:-EURUSD}"
MT5_PERIOD="${MT5_PERIOD:-M1}"

log() { echo "[gomql5-mt5] $*"; }
# shellcheck source=lib.sh
source "${GOMQL5_LIB:-/usr/local/lib/gomql5/lib.sh}" # UI helpers, bridge_connected

# The terminal's allowed-URL list silently rejects single-label names such as
# "app" (also as "http://app"); IPv4 addresses and "localhost" are accepted.
# So resolve service names to an IP here, on every start.
EA_HOST="$GOBRIDGE_HOST"
if [[ ! "$GOBRIDGE_HOST" =~ ^[0-9.]+$ ]] && [ "$GOBRIDGE_HOST" != "localhost" ]; then
  for _ in $(seq 1 30); do
    # "|| true": under set -e/pipefail a failed lookup would end the script here.
    EA_HOST=$(getent ahostsv4 "$GOBRIDGE_HOST" | awk 'NR==1 {print $1}') || true
    [ -n "$EA_HOST" ] && break
    sleep 1
  done
  if [ -z "$EA_HOST" ]; then
    log "cannot resolve $GOBRIDGE_HOST"
    exit 1
  fi
  log "resolved $GOBRIDGE_HOST -> $EA_HOST"
fi

# Write $2 to file $1 as UTF-16LE with BOM and CRLF line endings (MT5's native ini/set encoding).
# Every line, including the last, must end in CRLF: a bare trailing CR ends up in the value.
write_utf16() {
  { printf '\xff\xfe'; printf '%s\n' "$2" | sed 's/$/\r/' | iconv -f UTF-8 -t UTF-16LE; } >"$1"
}

rm -f /tmp/.X99-lock
Xvfb :99 -screen 0 1280x1024x24 -nolisten tcp >/tmp/xvfb.log 2>&1 &
if [ -n "${VNC_PASSWORD:-}" ]; then
  x11vnc -display :99 -forever -shared -rfbport 5900 -passwd "$VNC_PASSWORD" -quiet >/tmp/x11vnc.log 2>&1 &
  log "VNC on :5900"
fi

# 1. Install and compile the EA from the image (always matches the Go module).
mkdir -p "$MT5_DIR/MQL5/Experts/GoBridge" "$MT5_DIR/MQL5/Include/GoBridge" "$MT5_DIR/MQL5/Presets" "$MT5_DIR/config"
cp /opt/gobridge/mql5/Experts/GoBridge/*.mq5 "$MT5_DIR/MQL5/Experts/GoBridge/"
cp /opt/gobridge/mql5/Include/GoBridge/*.mqh "$MT5_DIR/MQL5/Include/GoBridge/"
EX5="$MT5_DIR/MQL5/Experts/GoBridge/GoBridge.ex5"
LOGF=/opt/wine/drive_c/gobridge-compile.log
rm -f "$EX5" "$LOGF"
log "compiling GoBridge.mq5"
# Path relative to the portable install dir; /log:<file> is required for a log.
(cd "$MT5_DIR" && wine MetaEditor64.exe /portable \
  '/compile:MQL5\Experts\GoBridge\GoBridge.mq5' '/log:C:\gobridge-compile.log') || true
if [ -f "$LOGF" ]; then iconv -f UTF-16LE -t UTF-8 "$LOGF" | tr -d '\r' | grep -vE 'generating code|compiling' || true; fi
if [ ! -f "$EX5" ]; then
  log "compilation failed (no GoBridge.ex5)"
  exit 1
fi

# 2. EA inputs (MQL5/Presets/GoBridge.set).
write_utf16 "$MT5_DIR/MQL5/Presets/GoBridge.set" "InpHost=$EA_HOST
InpPort=$GOBRIDGE_PORT
InpToken=$GOBRIDGE_TOKEN"

# 3. Start-up config: account, EA permissions, auto-attach.
common="[Common]
NewsEnable=0
KeepPrivate=1"
if [ -n "${MT5_LOGIN:-}" ]; then
  common="$common
Login=$MT5_LOGIN
Password=${MT5_PASSWORD:-}
Server=${MT5_SERVER:-}"
fi
# WebRequest=1 ticks "Allow WebRequest for listed URL" (verified). The URL list
# itself is stored encrypted in config/settings.ini and cannot be written from
# here, and in testing it did not survive a restart, so allow-host.sh re-adds
# GOBRIDGE_HOST through the UI on every start (GOBRIDGE_AUTO_ALLOW=1).
# The path must not contain spaces: the terminal mis-parses a quoted /config: arg.
mkdir -p /opt/wine/drive_c/gobridge
write_utf16 /opt/wine/drive_c/gobridge/gobridge.ini "$common
[Experts]
AllowLiveTrading=1
AllowDllImport=0
Enabled=1
Account=0
Profile=0
WebRequest=1
[StartUp]
Expert=GoBridge\\GoBridge
ExpertParameters=GoBridge.set
Symbol=$MT5_SYMBOL
Period=$MT5_PERIOD"


# UI automation is timing-sensitive (start-up dialogs, LiveUpdate prompts), so
# verify by watching for the EA's connection and retry until it appears.
auto_allow() {
  local delay=20
  for attempt in $(seq 1 10); do
    ALLOW_HOST_DELAY=$delay allow-host.sh "$EA_HOST" || true
    delay=5
    for _ in $(seq 1 30); do
      if bridge_connected; then
        log "EA connected to $GOBRIDGE_HOST:$GOBRIDGE_PORT (allow-host attempt $attempt)"
        return 0
      fi
      sleep 2
    done
    log "no connection to $GOBRIDGE_HOST:$GOBRIDGE_PORT yet (attempt $attempt); is the Go server up?"
  done
  log "giving up on allow-host; add $EA_HOST over VNC"
}

if [ "${GOBRIDGE_AUTO_ALLOW:-1}" = "1" ]; then
  auto_allow &
fi

log "starting terminal; EA connects to $EA_HOST:$GOBRIDGE_PORT"
cd "$MT5_DIR"
wine terminal64.exe /portable '/config:C:\gobridge\gobridge.ini' &
TERM_PID=$!

# Close the main window on SIGTERM (docker stop): the terminal only saves settings
# such as the allowed-URL list on a clean exit. Use `docker stop -t 30`.
graceful_stop() {
  log "stopping terminal"
  # Escape first: modal dialogs (e.g. the LiveUpdate "Restart" prompt) swallow Alt+F4.
  ui_lock 10 || true # don't let a stuck UI actor block shutdown
  ui_close_terminal
  for _ in $(seq 1 20); do
    pgrep -f terminal64.exe >/dev/null || break
    sleep 1
  done
  wineserver -k 2>/dev/null || true
  exit 0
}
trap graceful_stop TERM INT
wait "$TERM_PID"
