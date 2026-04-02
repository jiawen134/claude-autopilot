#!/bin/bash
# subagent-stop.sh — SubagentStop Hook
# Tracks teammate lifecycle: logs stop events, detects pipeline completion.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"
# shellcheck source=../lib/common.sh
source "$LIB_DIR/common.sh"

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
init_state_dir "$PROJECT_DIR"

# Parse input
INPUT=$(cat)
TEAMMATE_NAME=$(json_field "$INPUT" "agent_name" "")
[ -z "$TEAMMATE_NAME" ] && TEAMMATE_NAME=$(json_field "$INPUT" "teammate_name" "unknown")
TEAM_NAME=$(json_field "$INPUT" "team_name" "default")

# Sanitize
TEAMMATE_NAME="${TEAMMATE_NAME//[^a-zA-Z0-9_-]/}"
TEAM_NAME="${TEAM_NAME//[^a-zA-Z0-9_-]/}"
[ -z "$TEAMMATE_NAME" ] && TEAMMATE_NAME="unknown"
[ -z "$TEAM_NAME" ] && TEAM_NAME="default"
_LOG_PREFIX="$TEAMMATE_NAME"

ROLE=$(detect_role "$TEAMMATE_NAME" "")

# Update status and log
write_teammate_status "$TEAMMATE_NAME" "$ROLE" "stopped" "subagent stopped" 0 0
track_usage "subagent-stop" "$TEAMMATE_NAME" "$ROLE" "stopped" 0 "{}"
log_info "[${ROLE}] Teammate stopped."

# Count active vs stopped teammates to detect pipeline completion
ACTIVE=0 STOPPED=0
if compgen -G "$STATE_DIR/status-*.json" > /dev/null 2>&1; then
    while IFS= read -r f; do
        STATUS=$(jq -r '.status // "unknown"' "$f" 2>/dev/null || echo "unknown")
        case "$STATUS" in
            stopped|idle_done) STOPPED=$((STOPPED + 1)) ;;
            *) ACTIVE=$((ACTIVE + 1)) ;;
        esac
    done < <(find "$STATE_DIR" -maxdepth 1 -name 'status-*.json' -type f)
fi

if [ "$ACTIVE" -eq 0 ] && [ "$STOPPED" -gt 0 ]; then
    log_info "All $STOPPED teammates stopped. Pipeline complete."
    write_progress "pipeline" 0 "all_stopped — $STOPPED teammates finished"
fi

exit 0
