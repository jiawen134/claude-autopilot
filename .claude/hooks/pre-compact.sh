#!/bin/bash
# pre-compact.sh — PreCompact Hook
# Saves a state snapshot before context compaction so agents can recover.
# Triggered by Claude Code's PreCompact event — fires before auto-compaction.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"
# shellcheck source=../lib/common.sh
source "$LIB_DIR/common.sh"

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
init_state_dir "$PROJECT_DIR"

# Save full state snapshot to disk before compaction wipes context
save_state_snapshot

log_info "PreCompact: state snapshot saved to ${STATE_DIR}/pre-compact-snapshot.md"

exit 0
