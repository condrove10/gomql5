#!/bin/bash
# Installs MetaTrader 5 into $WINEPREFIX at image build time.
set -euo pipefail

URL_MT5="${URL_MT5:-https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe}"
TIMEOUT="${MT5_INSTALL_TIMEOUT:-900}"

Xvfb :99 -screen 0 1280x1024x24 -nolisten tcp >/tmp/xvfb.log 2>&1 &
XVFB=$!
trap 'wineserver -k || true; kill $XVFB 2>/dev/null || true' EXIT

WINEDLLOVERRIDES="mscoree,mshtml=" wineboot --init
wineserver -w
# MetaQuotes' script sets Windows 11; win10 is the safe fallback.
wine reg add 'HKEY_CURRENT_USER\Software\Wine' /v Version /t REG_SZ /d win11 /f >/dev/null 2>&1 \
  || wine reg add 'HKEY_CURRENT_USER\Software\Wine' /v Version /t REG_SZ /d win10 /f

curl -fsSL "$URL_MT5" -o /tmp/mt5setup.exe
# /auto = unattended install to the default directory, then the terminal starts.
wine /tmp/mt5setup.exe /auto &

for ((i = 0; i < TIMEOUT; i += 5)); do
  if [ -f "$MT5_DIR/terminal64.exe" ] && [ -f "$MT5_DIR/MetaEditor64.exe" ]; then
    break
  fi
  sleep 5
done
if [ ! -f "$MT5_DIR/terminal64.exe" ]; then
  echo "MetaTrader 5 was not installed within ${TIMEOUT}s" >&2
  ls -la "/opt/wine/drive_c/Program Files" >&2 || true
  exit 1
fi
# Give the installer time to finish writing files, then stop everything.
sleep 20
pkill -f terminal64.exe || true
pkill -f mt5setup.exe || true
wineserver -k || true
rm -f /tmp/mt5setup.exe
echo "MetaTrader 5 installed in $MT5_DIR"
ls "$MT5_DIR"
