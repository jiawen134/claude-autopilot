#!/bin/bash
# file-changed.sh — FileChanged Hook
# Triggered when watched files change. Logs the event and notifies teammates.
# Watched files: .env, package.json, Cargo.toml, go.mod, pyproject.toml, etc.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"
# shellcheck source=../lib/common.sh
source "$LIB_DIR/common.sh"

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
init_state_dir "$PROJECT_DIR"

INPUT=$(cat)
FILE_PATH=$(json_field "$INPUT" "file_path" "")
EVENT_TYPE=$(json_field "$INPUT" "event_type" "change")
_LOG_PREFIX="file-watch"

[ -z "$FILE_PATH" ] && exit 0

BASENAME=$(basename "$FILE_PATH")

log_info "FileChanged: $BASENAME ($EVENT_TYPE)"

# Track file changes for dashboard
track_usage "file-changed" "system" "" "$EVENT_TYPE" 0 "{\"file\":\"$BASENAME\"}"

# Return additionalContext to inform the agent about the change
case "$BASENAME" in
    package.json|package-lock.json)
        MSG="[FileChanged] $BASENAME updated — dependencies may have changed. Run npm install if needed."
        ;;
    Cargo.toml|Cargo.lock)
        MSG="[FileChanged] $BASENAME updated — run cargo build to update dependencies."
        ;;
    go.mod|go.sum)
        MSG="[FileChanged] $BASENAME updated — run go mod tidy if needed."
        ;;
    pyproject.toml|requirements.txt|setup.py)
        MSG="[FileChanged] $BASENAME updated — Python dependencies may have changed."
        ;;
    .env|.env.local|.env.production)
        MSG="[FileChanged] $BASENAME updated — environment variables changed. Do NOT commit this file."
        ;;
    Makefile|CMakeLists.txt|build.gradle|build.gradle.kts|pom.xml)
        MSG="[FileChanged] $BASENAME updated — build configuration changed."
        ;;
    *)
        MSG="[FileChanged] $BASENAME updated."
        ;;
esac

if command -v jq &>/dev/null; then
    jq -cn --arg ctx "$MSG" '{"hookSpecificOutput":{"additionalContext":$ctx}}'
fi

exit 0
