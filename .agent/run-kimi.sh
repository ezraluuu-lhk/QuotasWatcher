#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT_DIR="$ROOT_DIR/.agent"
LOG_DIR="$AGENT_DIR/logs"

cd "$ROOT_DIR"
mkdir -p "$LOG_DIR"

if [[ ! -s "$AGENT_DIR/KIMI_TASK.md" ]]; then
    echo "Missing or empty .agent/KIMI_TASK.md" >&2
    exit 1
fi

timestamp="$(date '+%Y%m%d-%H%M%S')"
stdout_log="$LOG_DIR/kimi-${timestamp}.stdout.log"
stderr_log="$LOG_DIR/kimi-${timestamp}.stderr.log"

prompt="$(cat "$AGENT_DIR/KIMI_TASK.md")"

echo "Starting Kimi execution cycle..."
echo "Assistant output: $stdout_log"
echo "Tool/progress log: $stderr_log"

kimi -p "$prompt" \
    > >(tee "$stdout_log") \
    2> >(tee "$stderr_log" >&2)

echo "Kimi execution cycle completed."