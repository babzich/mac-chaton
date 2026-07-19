#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="LeChaton"
BUNDLE_ID="com.vincentbach.LeChaton"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_LOG="${TMPDIR:-/tmp}/lechaton-tuist-run.log"
APP_RUNNER_PID=""

cd "$ROOT_DIR"

request_app_shutdown() {
  local attempt
  if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    return 0
  fi

  if ! /usr/bin/osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1; then
    echo "Unable to request LeChaton's graceful shutdown. Quit the running app and retry." >&2
    return 1
  fi

  for attempt in {1..120}; do
    if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
      return 0
    fi
    if (( attempt % 20 == 0 )); then
      /usr/bin/osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    fi
    sleep 0.25
  done

  echo "LeChaton did not confirm shutdown; refusing to start a replacement runtime." >&2
  pgrep -x "$APP_NAME" >&2 || true
  return 1
}

request_app_shutdown

start_app() {
  mise exec -- tuist run "$APP_NAME" --generate >"$RUN_LOG" 2>&1 &
  APP_RUNNER_PID=$!
}

cleanup_app() {
  local command_status=$?
  local cleanup_status=0
  trap - EXIT INT TERM

  request_app_shutdown || cleanup_status=$?
  if [[ -n "$APP_RUNNER_PID" ]] && kill -0 "$APP_RUNNER_PID" >/dev/null 2>&1; then
    kill "$APP_RUNNER_PID" >/dev/null 2>&1 || true
    wait "$APP_RUNNER_PID" 2>/dev/null || true
  fi

  if (( command_status != 0 )); then
    exit "$command_status"
  fi
  exit "$cleanup_status"
}

install_cleanup_trap() {
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap cleanup_app EXIT
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
    install_cleanup_trap
    start_app
    wait_for_app
    wait "$APP_RUNNER_PID"
    ;;
  --debug|debug)
    install_cleanup_trap
    start_app
    wait_for_app
    lldb -p "$(pgrep -x -n "$APP_NAME")"
    ;;
  --logs|logs)
    install_cleanup_trap
    start_app
    wait_for_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    install_cleanup_trap
    start_app
    wait_for_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    install_cleanup_trap
    start_app
    wait_for_app
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
