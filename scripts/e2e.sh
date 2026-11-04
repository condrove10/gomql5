#!/bin/bash
# e2e.sh - end-to-end smoke test: real MT5 terminal (Wine, Docker) + GoBridge EA
# + the Go example app. Passes only when the app receives a tick through the EA.
# Evidence (logs, screenshots) is always collected, pass or fail.
#
# Usage: scripts/e2e.sh [options]
#   --build          build gomql5/mt5:local first (else it must exist)
#   --compose        run docker-compose.yml (service name "app") instead of host networking
#   --keep           leave the terminal running afterwards (inspect with scripts/mt5ctl.sh)
#   --token T        token given to the EA (default e2e-token)
#   --app-token T    token the Go app expects (default: same; set differently to test rejection)
#   --port P         Go server port, host mode (default 7788)
#   --timeout S      seconds to wait for the first tick (default 300)
#   --out DIR        evidence directory (default e2e-out/<timestamp>)
#
# Build-time environment (all optional, for proxies/rate limits):
#   E2E_CA_CERT=path  CA bundle passed as the ca_cert build secret
#   HTTPS_PROXY/HTTP_PROXY  passed as build args, and builds use --network host
#   BASE_IMAGE, GO_IMAGE    base image overrides (e.g. mirror.gcr.io/library/...)
#
# Exit 0 = tick received; 1 = failure (reason printed, evidence in --out).
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD=0 COMPOSE=0 KEEP=0 TOKEN=e2e-token APP_TOKEN="" PORT=7788 TIMEOUT=300 OUT=""
while [ $# -gt 0 ]; do
  case $1 in
    --build) BUILD=1 ;;
    --compose) COMPOSE=1 ;;
    --keep) KEEP=1 ;;
    --token) TOKEN=$2; shift ;;
    --app-token) APP_TOKEN=$2; shift ;;
    --port) PORT=$2; shift ;;
    --timeout) TIMEOUT=$2; shift ;;
    --out) OUT=$2; shift ;;
    -h | --help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "e2e: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
APP_TOKEN="${APP_TOKEN:-$TOKEN}"
TS=$(date +%Y%m%d-%H%M%S)
OUT="${OUT:-e2e-out/$TS}"
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
IMAGE=gomql5/mt5:local
PROJECT=gomql5e2e
NAME=gomql5-e2e-$TS
APP_PID=""

say() { echo "[e2e] $*"; }

build_args() {
  local a=()
  if [ -n "${HTTPS_PROXY:-${https_proxy:-}}" ]; then
    local p="${HTTPS_PROXY:-${https_proxy:-}}"
    a+=(--network host --build-arg "HTTPS_PROXY=$p" --build-arg "https_proxy=$p"
      --build-arg "HTTP_PROXY=${HTTP_PROXY:-$p}" --build-arg "http_proxy=${HTTP_PROXY:-$p}")
  fi
  [ -n "${E2E_CA_CERT:-}" ] && a+=(--secret "id=ca_cert,src=$E2E_CA_CERT")
  [ -n "${BASE_IMAGE:-}" ] && a+=(--build-arg "BASE_IMAGE=$BASE_IMAGE")
  [ -n "${GO_IMAGE:-}" ] && a+=(--build-arg "GO_IMAGE=$GO_IMAGE")
  printf '%s\n' "${a[@]}"
}

if [ $BUILD = 1 ]; then
  say "building $IMAGE (log: $OUT/build.log)"
  mapfile -t BA < <(build_args)
  DOCKER_BUILDKIT=1 docker build "${BA[@]}" -f docker/mt5/Dockerfile -t "$IMAGE" . >"$OUT/build.log" 2>&1 ||
    { say "FAIL: image build failed"; tail -20 "$OUT/build.log"; exit 1; }
fi
docker image inspect "$IMAGE" >/dev/null 2>&1 || { say "FAIL: $IMAGE missing (use --build)"; exit 1; }

collect() {
  local c=$1
  say "collecting evidence in $OUT"
  docker logs "$c" >"$OUT/container.log" 2>&1 || true
  if [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = "true" ]; then
    scripts/mt5ctl.sh -c "$c" -o "$OUT" status >"$OUT/status.txt" 2>&1 || true
    scripts/mt5ctl.sh -c "$c" -o "$OUT" logs terminal 200 >"$OUT/terminal.log" 2>&1 || true
    scripts/mt5ctl.sh -c "$c" -o "$OUT" logs compile >"$OUT/compile.log" 2>&1 || true
    scripts/mt5ctl.sh -c "$c" -o "$OUT" shot screen >/dev/null 2>&1 || true
    scripts/mt5ctl.sh -c "$c" -o "$OUT" goto experts-log >/dev/null 2>&1 || true
  fi
}

# --- run ---------------------------------------------------------------------
if [ $COMPOSE = 0 ]; then
  say "host mode: Go app on 127.0.0.1:$PORT, terminal container $NAME"
  go build -o "$OUT/basic" ./examples/basic
  GOBRIDGE_TOKEN="$APP_TOKEN" "$OUT/basic" -listen "127.0.0.1:$PORT" -ticks 1 >"$OUT/app.log" 2>&1 &
  APP_PID=$!
  docker run -d --rm --name "$NAME" --network host --shm-size 512m \
    -e GOBRIDGE_TOKEN="$TOKEN" -e GOBRIDGE_HOST=127.0.0.1 -e GOBRIDGE_PORT="$PORT" "$IMAGE" >/dev/null
  CONTAINER=$NAME
  app_log() { cat "$OUT/app.log"; }
else
  [ "$APP_TOKEN" = "$TOKEN" ] || { say "--app-token is host mode only"; exit 2; }
  say "compose mode: project $PROJECT"
  mapfile -t BA < <(build_args)
  DOCKER_BUILDKIT=1 docker build "${BA[@]}" -f examples/basic/Dockerfile -t "$PROJECT-app" . >"$OUT/app-build.log" 2>&1 ||
    { say "FAIL: app image build failed"; tail -20 "$OUT/app-build.log"; exit 1; }
  printf 'GOBRIDGE_TOKEN=%s\n' "$TOKEN" >"$OUT/compose.env"
  docker compose -p "$PROJECT" --env-file "$OUT/compose.env" up -d --no-build >"$OUT/compose-up.log" 2>&1 ||
    { say "FAIL: compose up"; cat "$OUT/compose-up.log"; exit 1; }
  CONTAINER=$PROJECT-mt5-1
  app_log() { docker compose -p "$PROJECT" logs --no-log-prefix app 2>&1; }
fi

cleanup() {
  [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null || true
  if [ $KEEP = 1 ]; then
    say "--keep: terminal left running as $CONTAINER (scripts/mt5ctl.sh -c $CONTAINER status)"
  elif [ $COMPOSE = 1 ]; then
    docker compose -p "$PROJECT" down -v -t 30 >/dev/null 2>&1 || true
  else
    docker stop -t 30 "$NAME" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# --- wait ----------------------------------------------------------------------
result="" reason=""
deadline=$((SECONDS + TIMEOUT))
while [ $SECONDS -lt $deadline ]; do
  if app_log | grep -q '^tick '; then result=pass; break; fi
  if app_log | grep -q 'handshake rejected'; then
    result=fail reason="Go server rejected the EA: $(app_log | grep -o 'handshake rejected[^"]*' | head -1)"; break
  fi
  if docker logs "$CONTAINER" 2>&1 | grep -qE 'compilation failed|cannot resolve'; then
    result=fail reason="container: $(docker logs "$CONTAINER" 2>&1 | grep -E 'compilation failed|cannot resolve' | head -1)"; break
  fi
  if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" != "true" ]; then
    result=fail reason="terminal container exited"; break
  fi
  sleep 5
done
[ -n "$result" ] || { result=fail; reason="no tick within ${TIMEOUT}s"; }

app_log >"$OUT/app.log.final" 2>&1 || true
collect "$CONTAINER"

if [ "$result" = pass ]; then
  say "PASS: $(app_log | grep -m1 'connected:' | sed 's/^[0-9/: ]*//')"
  say "      $(app_log | grep -m1 '^tick ')"
  exit 0
fi
say "FAIL: $reason"
say "      evidence: $OUT (container.log, app.log.final, terminal.log, screen.png, experts-log.png)"
exit 1
