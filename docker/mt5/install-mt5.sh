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

# --- slim the prefix (same RUN layer, so the space is really saved) ---------
# Installer leftovers: the web installer's download cache and temp files.
rm -rf "$WINEPREFIX/drive_c/users/root/AppData/Roaming/MetaQuotes/WebInstall" \
  "$WINEPREFIX/drive_c/users/root/Temp/"* "$WINEPREFIX/drive_c/windows/temp/"* \
  /tmp/.wine-* 2>/dev/null || true

# wineboot copies every builtin DLL/EXE into system32 and syswow64 (~1.4 GB).
# Those copies are byte-identical to Wine's own; replace each with a symlink.
# A file that differs (or has no Wine counterpart) is left alone.
dedup_dir() { # $1 = prefix dir, $2 = Wine's builtin dir
  local dir=$1 src=$2 f base n=0
  [ -d "$dir" ] && [ -d "$src" ] || return 0
  while IFS= read -r -d '' f; do
    base=$(basename "$f")
    if [ -f "$src/$base" ] && cmp -s "$f" "$src/$base"; then
      ln -sf "$src/$base" "$f"
      n=$((n + 1))
    fi
  done < <(find "$dir" -type f -print0)
  echo "dedup: $n files in $dir -> $src"
}
WINE_LIB=$(dirname "$(readlink -f "$(command -v wine)")")/../lib/wine
dedup_dir "$WINEPREFIX/drive_c/windows/system32" "$WINE_LIB/x86_64-windows"
dedup_dir "$WINEPREFIX/drive_c/windows/syswow64" "$WINE_LIB/i386-windows"
du -sh "$WINEPREFIX/drive_c/windows" "$WINEPREFIX"
