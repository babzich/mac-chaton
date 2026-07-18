#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="LeChaton"
BUNDLE_ID="com.vincentbach.LeChaton"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_LOG="${TMPDIR:-/tmp}/lechaton-tuist-run.log"
APP_RUNNER_PID=""

cd "$ROOT_DIR"
pkill -x "$APP_NAME" >/dev/null 2>&1 || true

start_app() {
  mise exec -- tuist run "$APP_NAME" --generate >"$RUN_LOG" 2>&1 &
  APP_RUNNER_PID=$!
}

cleanup_app() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  if [[ -n "$APP_RUNNER_PID" ]] && kill -0 "$APP_RUNNER_PID" >/dev/null 2>&1; then
    kill "$APP_RUNNER_PID" >/dev/null 2>&1 || true
    wait "$APP_RUNNER_PID" 2>/dev/null || true
  fi
}

wait_for_app() {
  local attempt
  for attempt in {1..120}; do
    if pgrep -x "$APP_NAME" >/dev/null; then
      return 0
    fi
    sleep 0.25
  done
  sed -n '1,200p' "$RUN_LOG" >&2 || true
  return 1
}

case "$MODE" in
  run)
    exec mise exec -- tuist run "$APP_NAME" --generate
    ;;
  --debug|debug)
    trap cleanup_app EXIT INT TERM
    start_app
    wait_for_app
    lldb -p "$(pgrep -x -n "$APP_NAME")"
    ;;
  --logs|logs)
    trap cleanup_app EXIT INT TERM
    start_app
    wait_for_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    trap cleanup_app EXIT INT TERM
    start_app
    wait_for_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    trap cleanup_app EXIT INT TERM
    start_app
    wait_for_app
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
