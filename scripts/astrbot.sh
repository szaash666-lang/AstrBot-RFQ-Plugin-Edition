#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNTIME_DIR="$PROJECT_DIR/data/temp"
PID_FILE="$RUNTIME_DIR/astrbot.pid"
LOG_FILE="$RUNTIME_DIR/astrbot.log"
DASHBOARD_URL="${ASTRBOT_DASHBOARD_URL:-http://localhost:6185}"

usage() {
    printf '%s\n' \
        "Usage: $0 [start|stop|restart|status|logs]" \
        "" \
        "Commands:" \
        "  start    Start AstrBot in the background (default)." \
        "  stop     Stop the AstrBot process started by this script." \
        "  restart  Restart AstrBot." \
        "  status   Show the managed process status." \
        "  logs     Follow the AstrBot log."
}

read_pid() {
    if [[ ! -f "$PID_FILE" ]]; then
        return 1
    fi

    local pid
    pid="$(tr -d '[:space:]' < "$PID_FILE")"
    if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
        return 1
    fi

    printf '%s' "$pid"
}

is_managed_process() {
    local pid="$1"
    local command_line
    local process_dir=""

    if ! kill -0 "$pid" 2>/dev/null; then
        return 1
    fi

    command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    if [[ "$command_line" != *"main.py"* ]]; then
        return 1
    fi

    if [[ -e "/proc/$pid/cwd" ]]; then
        process_dir="$(readlink "/proc/$pid/cwd" 2>/dev/null || true)"
    elif command -v lsof >/dev/null 2>&1; then
        process_dir="$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')"
    fi

    [[ -z "$process_dir" || "$process_dir" == "$PROJECT_DIR" ]]
}

start_astrbot() {
    mkdir -p "$RUNTIME_DIR"

    local pid=""
    if pid="$(read_pid)"; then
        if is_managed_process "$pid"; then
            printf 'AstrBot is already running (PID %s).\n' "$pid"
            printf 'Dashboard: %s\n' "$DASHBOARD_URL"
            return
        fi

        if kill -0 "$pid" 2>/dev/null; then
            printf 'Refusing to overwrite %s: PID %s belongs to another process.\n' \
                "$PID_FILE" "$pid" >&2
            return 1
        fi

        rm -f "$PID_FILE"
    elif [[ -f "$PID_FILE" ]]; then
        printf 'Removing invalid PID file: %s\n' "$PID_FILE"
        rm -f "$PID_FILE"
    fi

    if command -v curl >/dev/null 2>&1 \
        && curl --silent --fail --max-time 2 "$DASHBOARD_URL" >/dev/null 2>&1; then
        printf 'A service is already responding at %s but is not managed by this script.\n' \
            "$DASHBOARD_URL" >&2
        return 1
    fi

    if [[ ! -d "$PROJECT_DIR/.venv" ]]; then
        if ! command -v uv >/dev/null 2>&1; then
            printf "Cannot create the Python environment: 'uv' is not in PATH.\n" >&2
            return 1
        fi
        printf 'Python environment not found; running uv sync...\n'
        (cd "$PROJECT_DIR" && uv sync)
    fi

    local python_bin="$PROJECT_DIR/.venv/bin/python"
    if [[ ! -x "$python_bin" && -x "$PROJECT_DIR/.venv/Scripts/python.exe" ]]; then
        python_bin="$PROJECT_DIR/.venv/Scripts/python.exe"
    fi
    if [[ ! -x "$python_bin" ]]; then
        printf 'Cannot start AstrBot: virtual-environment Python was not found.\n' >&2
        return 1
    fi

    printf '\n[%s] Starting AstrBot\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"
    pid="$("$python_bin" -c '
import subprocess
import sys

project_dir, log_file = sys.argv[1:]
with open(log_file, "ab", buffering=0) as log:
    process = subprocess.Popen(
        [sys.executable, "main.py"],
        cwd=project_dir,
        stdin=subprocess.DEVNULL,
        stdout=log,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
print(process.pid)
' "$PROJECT_DIR" "$LOG_FILE")"
    printf '%s\n' "$pid" > "$PID_FILE"

    local ready=0
    local attempt=0
    while [[ "$attempt" -lt 30 ]]; do
        if ! is_managed_process "$pid"; then
            printf 'AstrBot exited during startup. Recent log output:\n' >&2
            tail -n 30 "$LOG_FILE" >&2 || true
            rm -f "$PID_FILE"
            return 1
        fi

        if ! command -v curl >/dev/null 2>&1 \
            || curl --silent --fail --max-time 2 "$DASHBOARD_URL" >/dev/null 2>&1; then
            ready=1
            break
        fi

        sleep 1
        attempt=$((attempt + 1))
    done

    printf 'AstrBot started (PID %s).\n' "$pid"
    printf 'Dashboard: %s\n' "$DASHBOARD_URL"
    printf 'Log: %s\n' "$LOG_FILE"
    if [[ "$ready" -eq 0 ]]; then
        printf 'Dashboard readiness timed out; AstrBot is still running. Check the log.\n'
    fi
}

stop_astrbot() {
    local pid=""
    if ! pid="$(read_pid)"; then
        if [[ -f "$PID_FILE" ]]; then
            printf 'Cannot stop AstrBot: invalid PID file %s.\n' "$PID_FILE" >&2
            return 1
        fi

        printf 'AstrBot is not running under this script.\n'
        return
    fi

    if ! kill -0 "$pid" 2>/dev/null; then
        rm -f "$PID_FILE"
        printf 'AstrBot is not running; removed the stale PID file.\n'
        return
    fi

    if ! is_managed_process "$pid"; then
        printf 'Refusing to stop PID %s because it is not AstrBot from this repository.\n' \
            "$pid" >&2
        return 1
    fi

    printf 'Stopping AstrBot (PID %s)...\n' "$pid"
    kill "$pid"

    local attempt=0
    while kill -0 "$pid" 2>/dev/null && [[ "$attempt" -lt 15 ]]; do
        sleep 1
        attempt=$((attempt + 1))
    done

    if kill -0 "$pid" 2>/dev/null; then
        printf 'AstrBot did not stop within 15 seconds; sending SIGKILL.\n' >&2
        kill -KILL "$pid"
    fi

    rm -f "$PID_FILE"
    printf 'AstrBot stopped.\n'
}

show_status() {
    local pid=""
    if ! pid="$(read_pid)"; then
        if [[ -f "$PID_FILE" ]]; then
            printf 'AstrBot status is unknown: invalid PID file %s.\n' "$PID_FILE"
            return 1
        fi

        printf 'AstrBot is not running under this script.\n'
        return 1
    fi

    if is_managed_process "$pid"; then
        printf 'AstrBot is running (PID %s).\n' "$pid"
        printf 'Dashboard: %s\n' "$DASHBOARD_URL"
        printf 'Log: %s\n' "$LOG_FILE"
        return
    fi

    if kill -0 "$pid" 2>/dev/null; then
        printf 'PID %s is running but does not match AstrBot from this repository.\n' \
            "$pid" >&2
    else
        printf 'AstrBot is not running; PID file is stale.\n'
    fi
    return 1
}

command="${1:-start}"
case "$command" in
    start)
        start_astrbot
        ;;
    stop)
        stop_astrbot
        ;;
    restart)
        stop_astrbot
        start_astrbot
        ;;
    status)
        show_status
        ;;
    logs)
        if [[ ! -f "$LOG_FILE" ]]; then
            printf 'Log file does not exist yet: %s\n' "$LOG_FILE" >&2
            exit 1
        fi
        tail -n 100 -f "$LOG_FILE"
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        printf 'Unknown command: %s\n\n' "$command" >&2
        usage >&2
        exit 2
        ;;
esac
