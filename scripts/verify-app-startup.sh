#!/bin/bash
set -euo pipefail

app_path="${1:?Usage: verify-app-startup.sh /path/to/boringNotch.app}"
startup_log="$(mktemp -t boring-notch-startup)"
app_pid=""
cleanup() {
    if [[ -n "$app_pid" ]] && kill -0 "$app_pid" 2>/dev/null; then
        kill "$app_pid" 2>/dev/null || true
        for ((cleanup_attempt=0; cleanup_attempt<30; cleanup_attempt++)); do
            kill -0 "$app_pid" 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 "$app_pid" 2>/dev/null; then
            kill -9 "$app_pid" 2>/dev/null || true
        fi
        wait "$app_pid" 2>/dev/null || true
    fi
    rm -f "$startup_log"
}
trap cleanup EXIT

"$app_path/Contents/MacOS/boringNotch" >"$startup_log" 2>&1 &
app_pid=$!
for ((attempt=0; attempt<10; attempt++)); do
    sleep 1
    if ! kill -0 "$app_pid" 2>/dev/null; then
        wait "$app_pid" 2>/dev/null || true
        cat "$startup_log"
        echo "FAIL: application exited during startup" >&2
        exit 1
    fi
done
echo "PASS: application stayed running for 10 seconds"
