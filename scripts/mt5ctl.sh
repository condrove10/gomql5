#!/bin/bash
# mt5ctl.sh - look at and drive a running gomql5 MT5 container from the host.
#
# The terminal runs headless (Xvfb :99, no window manager), so this is how you
# "see" it: take screenshots, navigate to the screens that matter, read the
# UTF-16 logs, check the EA's TCP connection. UI coordinates come from the
# container's /usr/local/lib/gomql5/lib.sh (docker/mt5/lib.sh).
#
# Usage: scripts/mt5ctl.sh [-c CONTAINER] [-o OUTDIR] <command> [args]
#
#   status                    container, terminal process, EA connection, last Experts lines
#   shot [NAME] [CROP]        screenshot -> OUTDIR/NAME.png; CROP = options|urllist|toolbox|WxH+X+Y
#   goto experts-log          open Toolbox > Experts (EA Print output), screenshot it
#   goto journal              open Toolbox > Journal (terminal log), screenshot it
#   goto options              open Tools > Options > Experts, screenshot it, close it
#   goto allowlist            same, cropped to the allowed-URL list
#   dismiss                   Escape twice (account wizard, LiveUpdate prompt, open dialogs)
#   find-broker NAME [WAIT]   File > Open an Account, search the broker directory for NAME,
#                             wait WAIT s (default 30), screenshot the result, close the wizard
#
# UI-driving commands (goto, dismiss, click, key, type) hold the container's UI
# lock, so they wait while allow-host.sh is clicking; `shot` does not.
#   click X Y | key KEYS... | type TEXT
#   logs [terminal|metaeditor|compile] [N]   last N lines (default 40), decoded
#   conn [PORT]               exit 0 if the EA holds an ESTABLISHED connection to PORT
#   exec CMD...               run a shell command in the container with lib.sh sourced
#
# CONTAINER defaults to the only running container labelled org.gomql5.role=mt5.
# OUTDIR defaults to ./mt5ctl-out. Screenshots are 1280x1024 PNGs; read them with
# an image viewer (or Claude's Read tool) to check what the terminal shows.
set -euo pipefail

C="${MT5_CONTAINER:-}"
OUT="${MT5CTL_OUT:-./mt5ctl-out}"
while getopts "c:o:h" opt; do
  case $opt in
    c) C=$OPTARG ;;
    o) OUT=$OPTARG ;;
    h) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) exit 2 ;;
  esac
done
shift $((OPTIND - 1))
cmd="${1:-}"
[ -n "$cmd" ] || { echo "usage: $0 [-c CONTAINER] [-o OUTDIR] <command> (see -h)" >&2; exit 2; }
shift

die() { echo "mt5ctl: $*" >&2; exit 1; }

if [ -z "$C" ]; then
  mapfile -t found < <(docker ps --filter label=org.gomql5.role=mt5 --format '{{.Names}}')
  case ${#found[@]} in
    0) die "no running container labelled org.gomql5.role=mt5 (use -c NAME)" ;;
    1) C=${found[0]} ;;
    *) die "several mt5 containers running (${found[*]}); pick one with -c" ;;
  esac
fi
[ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)" = "true" ] || die "container '$C' is not running"

# Run bash in the container with the helper library loaded.
cx() { docker exec "$C" bash -c 'source /usr/local/lib/gomql5/lib.sh; '"$1"; }
# Same, holding the UI lock (waits while allow-host.sh is clicking).
cxui() { cx 'ui_lock 120 || { echo "mt5ctl: UI lock busy" >&2; exit 1; }; '"$1"; }

crop_of() {
  case "${1:-}" in
    "") echo "" ;;
    options) echo '$UI_CROP_OPTIONS' ;;
    urllist) echo '$UI_CROP_URLLIST' ;;
    toolbox) echo '$UI_CROP_TOOLBOX' ;;
    *x*+*+*) echo "$1" ;;
    *) die "unknown crop '$1' (options|urllist|toolbox|WxH+X+Y)" ;;
  esac
}

fetch() { # NAME: copy /tmp/mt5ctl.png out of the container
  mkdir -p "$OUT"
  docker cp -q "$C:/tmp/mt5ctl.png" "$OUT/$1.png"
  echo "$OUT/$1.png"
}

# Plain screenshots take no lock: catching another actor mid-sequence is useful.
shot() { # NAME [CROP]
  local name="${1:-shot-$(date +%H%M%S)}" crop
  crop=$(crop_of "${2:-}")
  cx "ui_shot /tmp/mt5ctl.png \"$crop\""
  fetch "$name"
}

case "$cmd" in
  status)
    echo "container: $C ($(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "$C"))"
    if cx 'pgrep -f terminal64.exe >/dev/null'; then echo "terminal:  running"; else echo "terminal:  NOT running"; fi
    port=$(docker exec "$C" printenv GOBRIDGE_PORT 2>/dev/null || echo 7788)
    if cx "bridge_connected $port"; then echo "EA link:   connected (port $port)"; else echo "EA link:   not connected (port $port)"; fi
    echo "--- container log (last 5)"; docker logs "$C" 2>&1 | grep -v 'information' | tail -5
    ;;
  shot) shot "${1:-}" "${2:-}" ;;
  goto)
    case "${1:-}" in
      experts-log) cxui 'ui_dismiss; ui_toolbox_experts; ui_shot /tmp/mt5ctl.png "$UI_CROP_TOOLBOX"'; fetch experts-log ;;
      journal) cxui 'ui_dismiss; ui_toolbox_journal; ui_shot /tmp/mt5ctl.png "$UI_CROP_TOOLBOX"'; fetch journal ;;
      options) cxui 'ui_open_options_experts; ui_shot /tmp/mt5ctl.png "$UI_CROP_OPTIONS"; ui_dismiss'; fetch options ;;
      allowlist) cxui 'ui_open_options_experts; ui_shot /tmp/mt5ctl.png "$UI_CROP_URLLIST"; ui_dismiss'; fetch allowlist ;;
      *) die "goto: experts-log|journal|options|allowlist" ;;
    esac
    ;;
  dismiss) cxui 'ui_dismiss' ;;
  find-broker)
    [ $# -ge 1 ] || die "find-broker NAME [WAIT]"
    docker exec "$C" bash -c 'source /usr/local/lib/gomql5/lib.sh; ui_lock 120 && ui_find_company "$1" && sleep "$2" && ui_shot /tmp/mt5ctl.png "$UI_CROP_ACCOUNT" && ui_dismiss' _ "$1" "${2:-30}"
    fetch "find-broker-$1"
    ;;
  click) [ $# -eq 2 ] || die "click X Y"; cxui "ui_click $1 $2" ;;
  key) [ $# -ge 1 ] || die "key KEYS..."; cxui "xdotool key $*" ;;
  type) [ $# -ge 1 ] || die "type TEXT"; docker exec "$C" bash -c 'source /usr/local/lib/gomql5/lib.sh; ui_lock 120 && xdotool type --delay 50 "$1"' _ "$*" ;;
  logs)
    n="${2:-40}"
    case "${1:-terminal}" in
      terminal) cx "mt5_log \"\$MT5_DIR/logs/\$(date +%Y%m%d).log\" | tail -n $n" ;;
      metaeditor) cx "mt5_log \"\$MT5_DIR/logs/metaeditor.log\" | tail -n $n" ;;
      compile) cx "mt5_log /opt/wine/drive_c/gobridge-compile.log | grep -v 'generating code' | tail -n $n" ;;
      *) die "logs: terminal|metaeditor|compile" ;;
    esac
    ;;
  conn)
    port="${1:-$(docker exec "$C" printenv GOBRIDGE_PORT 2>/dev/null || echo 7788)}"
    if cx "bridge_connected $port"; then echo "connected"; else echo "not connected"; exit 1; fi
    ;;
  exec) [ $# -ge 1 ] || die "exec CMD..."; cx "$*" ;;
  *) die "unknown command '$cmd' (see -h)" ;;
esac
