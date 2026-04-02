#!/bin/bash
# permission-gate.sh — PermissionRequest Hook
# Auto-approves safe operations, blocks dangerous ones, passes through the rest.
# Based on Claude Code source: exit with JSON {"approve":true} to auto-approve.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"
# shellcheck source=../lib/common.sh
source "$LIB_DIR/common.sh"

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
init_state_dir "$PROJECT_DIR"

INPUT=$(cat)
TOOL_NAME=$(json_field "$INPUT" "tool_name" "")
COMMAND=$(json_field "$INPUT" "command" "")
_LOG_PREFIX="permission"

# Normalize command for matching (lowercase, trim whitespace)
CMD_LOWER=$(echo "$COMMAND" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//')

# === ALWAYS APPROVE (safe, read-only operations) ===
case "$TOOL_NAME" in
    Read|Glob|Grep|WebFetch|WebSearch|TaskList|TaskGet|TaskCreate|TaskUpdate|SendMessage)
        echo '{"decision":"approve","reason":"read-only or coordination tool"}'
        exit 0
        ;;
esac

# === BASH: pattern-based approval/denial ===
if [ "$TOOL_NAME" = "Bash" ] || [ "$TOOL_NAME" = "BashTool" ]; then
    # DENY dangerous commands
    case "$CMD_LOWER" in
        *"rm -rf /"*|*"rm -rf ~"*|*"rm -rf \$HOME"*)
            log_warn "BLOCKED: dangerous rm -rf: ${COMMAND:0:60}"
            echo '{"decision":"deny","reason":"dangerous rm -rf target blocked by permission-gate"}'
            exit 0
            ;;
        *"--force"*|*"--hard"*|*"--no-verify"*)
            # git push --force, git reset --hard, --no-verify
            log_warn "BLOCKED: force/hard/no-verify: ${COMMAND:0:60}"
            echo '{"decision":"deny","reason":"force/hard/no-verify operations blocked by permission-gate"}'
            exit 0
            ;;
        *"drop table"*|*"drop database"*|*"truncate"*)
            log_warn "BLOCKED: destructive SQL: ${COMMAND:0:60}"
            echo '{"decision":"deny","reason":"destructive SQL blocked by permission-gate"}'
            exit 0
            ;;
    esac

    # APPROVE safe commands
    case "$CMD_LOWER" in
        "git status"*|"git diff"*|"git log"*|"git branch"*|"git show"*|"git rev-parse"*)
            echo '{"decision":"approve","reason":"safe git read command"}'
            exit 0
            ;;
        "ls "*|"ls"|"pwd"|"which "*|"cat "*|"head "*|"tail "*|"wc "*|"echo "*)
            echo '{"decision":"approve","reason":"safe read command"}'
            exit 0
            ;;
        "make test"*|"make lint"*|"make check"*|"make build"*)
            echo '{"decision":"approve","reason":"safe build/test command"}'
            exit 0
            ;;
        "npm test"*|"npm run lint"*|"npm run test"*|"npm run build"*|"npm run typecheck"*)
            echo '{"decision":"approve","reason":"safe npm command"}'
            exit 0
            ;;
        "cargo test"*|"cargo clippy"*|"cargo check"*|"cargo build"*)
            echo '{"decision":"approve","reason":"safe cargo command"}'
            exit 0
            ;;
        "go test"*|"go vet"*|"go build"*|"golangci-lint"*)
            echo '{"decision":"approve","reason":"safe go command"}'
            exit 0
            ;;
        "pytest"*|"python -m pytest"*|"ruff check"*|"mypy "*|"python manage.py test"*)
            echo '{"decision":"approve","reason":"safe python command"}'
            exit 0
            ;;
        "dotnet test"*|"dotnet build"*|"swift test"*|"flutter test"*|"dart analyze"*)
            echo '{"decision":"approve","reason":"safe build/test command"}'
            exit 0
            ;;
        "shellcheck"*|"jq "*|"date"*|"whoami"|"hostname"|"uname"*)
            echo '{"decision":"approve","reason":"safe utility command"}'
            exit 0
            ;;
        "git add "*|"git commit "*|"git stash"*)
            echo '{"decision":"approve","reason":"safe git write command"}'
            exit 0
            ;;
        "mkdir "*|"touch "*|"cp "*|"mv "*)
            echo '{"decision":"approve","reason":"safe file operation"}'
            exit 0
            ;;
    esac
fi

# === Edit/Write: always approve (agents need to modify files) ===
case "$TOOL_NAME" in
    Edit|Write|NotebookEdit)
        echo '{"decision":"approve","reason":"file modification approved for agent workflow"}'
        exit 0
        ;;
esac

# === PASS-THROUGH: let user/system decide ===
# Return nothing (empty stdout) to defer to default permission handling
exit 0
