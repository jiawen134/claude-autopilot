#!/bin/bash
# session-start.sh — SessionStart Hook
# Returns recovery context as additionalContext for agents starting/resuming sessions.
# Helps agents recover state after compaction or fresh start.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"
# shellcheck source=../lib/common.sh
source "$LIB_DIR/common.sh"

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
init_state_dir "$PROJECT_DIR"

# Generate recovery context only if state files exist (avoid noise for non-pipeline sessions)
if [ -f "${STATE_DIR}/requirements.md" ] || [ -f "${STATE_DIR}/plan.md" ] || [ -f "${STATE_DIR}/progress.log" ]; then
    RECOVERY=$(generate_recovery_context)
    if [ -n "$RECOVERY" ] && command -v jq &>/dev/null; then
        jq -cn --arg ctx "$RECOVERY" '{"hookSpecificOutput":{"additionalContext":$ctx}}'
    fi
fi

exit 0
