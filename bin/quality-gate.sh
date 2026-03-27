#!/bin/bash
# quality-gate.sh — TaskCompleted Hook
# v4: 使用 lib/common.sh 共享库，修复全部 P0 问题

set -uo pipefail
START_TS=$(date +%s)

# ===== 加载共享库 =====
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"
# shellcheck source=../lib/common.sh
source "$LIB_DIR/common.sh"

# ===== 初始化 =====
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$PROJECT_DIR" || exit 1
init_state_dir "$PROJECT_DIR"

# ===== 解析输入 =====
INPUT=$(cat)
TASK_SUBJECT=$(json_field "$INPUT" "task_subject" "unknown task")
TASK_SUBJECT="$(printf '%s' "$TASK_SUBJECT" | tr -d '\000-\037\177')"
TASK_SUBJECT="${TASK_SUBJECT:0:512}"
TEAMMATE_NAME=$(json_field "$INPUT" "teammate_name" "unknown")
TEAMMATE_ROLE=$(json_field "$INPUT" "teammate_role" "")
TEAM_NAME=$(json_field "$INPUT" "team_name" "default")

# Sanitize to prevent path traversal in file paths
TEAMMATE_NAME="${TEAMMATE_NAME//[^a-zA-Z0-9_-]/}"
TEAM_NAME="${TEAM_NAME//[^a-zA-Z0-9_-]/}"
_LOG_PREFIX="$TEAMMATE_NAME"
ROLE=$(detect_role "$TEAMMATE_NAME" "$TEAMMATE_ROLE")

# ===== Shutdown check =====
if is_shutdown "$TEAM_NAME"; then
    log_info "Shutdown sentinel detected. Passing through."
    exit 0
fi

# ===== 重试计数 =====
if command -v sha256sum &>/dev/null; then
    TASK_HASH=$(echo "${TEAM_NAME}:${TASK_SUBJECT}" | sha256sum | cut -c1-16)
elif command -v shasum &>/dev/null; then
    TASK_HASH=$(echo "${TEAM_NAME}:${TASK_SUBJECT}" | shasum -a 256 | cut -c1-16)
else
    TASK_HASH=$(echo "${TEAM_NAME}:${TASK_SUBJECT}" | cksum | cut -d' ' -f1)
fi

RETRY_FILE="${STATE_DIR}/retry-${TASK_HASH}"
LOCK_FILE="${STATE_DIR}/lock-retry-${TASK_HASH}"
MAX_RETRIES="${QUALITY_GATE_MAX_RETRIES:-5}"

RETRY_COUNT=$(locked_read "$RETRY_FILE" "$LOCK_FILE")

if [ "$RETRY_COUNT" -ge "$MAX_RETRIES" ]; then
    log_warn "FORCE_PASS(${MAX_RETRIES}x): '${TASK_SUBJECT:0:60}'"
    rm -f "$RETRY_FILE"
    exit 0
fi

log_info "GATE: '${TASK_SUBJECT:0:60}' (try ${RETRY_COUNT}+1/${MAX_RETRIES})"

# ===== 检测项目 =====
detect_project

# ===== 质量检查 =====
FAILED=false
TMPDIR_GATE=$(mktemp -d "${TMPDIR:-/tmp}/gate-XXXXXX")
trap 'rm -rf "$TMPDIR_GATE"' EXIT

# 1. 测试（优先增量）
if [ -n "${TEST_CMD:-}" ]; then
    ACTUAL_CMD="${INCREMENTAL_TEST_CMD:-$TEST_CMD}"
    IS_INCR="no"
    [ -n "${INCREMENTAL_TEST_CMD:-}" ] && IS_INCR="yes"

    log_info "测试(incremental=$IS_INCR): $ACTUAL_CMD"
    if ! safe_run "$ACTUAL_CMD" "$TMPDIR_GATE/test.txt"; then
        if [ "$IS_INCR" = "yes" ]; then
            log_info "增量失败，跑全量确认..."
            if ! safe_run "$TEST_CMD" "$TMPDIR_GATE/test_full.txt"; then
                FC=$(grep -ciE "FAIL|ERROR" "$TMPDIR_GATE/test_full.txt" 2>/dev/null || echo "?")
                FIRST_ERR=$(grep -m1 -iE "FAIL|ERROR|panic" "$TMPDIR_GATE/test_full.txt" 2>/dev/null || echo "unknown")
                log_error "TEST_FAIL(full,${FC}): ${FIRST_ERR:0:80}"
                FAILED=true
            fi
        else
            FC=$(grep -ciE "FAIL|ERROR" "$TMPDIR_GATE/test.txt" 2>/dev/null || echo "?")
            FIRST_ERR=$(grep -m1 -iE "FAIL|ERROR|panic" "$TMPDIR_GATE/test.txt" 2>/dev/null || echo "unknown")
            log_error "TEST_FAIL(${FC}): ${FIRST_ERR:0:80}"
            FAILED=true
        fi
    fi
else
    log_debug "跳过测试（未检测到命令）"
fi

# 2. Lint
if [ "$FAILED" = false ] && [ -n "${LINT_CMD:-}" ]; then
    log_info "Lint: $LINT_CMD"
    if ! safe_run "$LINT_CMD" "$TMPDIR_GATE/lint.txt"; then
        FIRST_LINT=$(grep -m1 -iE "error|warning|:" "$TMPDIR_GATE/lint.txt" 2>/dev/null || echo "unknown")
        log_error "LINT_FAIL: ${FIRST_LINT:0:80}"
        FAILED=true
    fi
fi

# 3. 类型检查
if [ "$FAILED" = false ] && [ -n "${TYPE_CMD:-}" ]; then
    log_info "类型检查: $TYPE_CMD"
    if ! safe_run "$TYPE_CMD" "$TMPDIR_GATE/type.txt"; then
        FIRST_TYPE=$(grep -m1 -iE "error|:" "$TMPDIR_GATE/type.txt" 2>/dev/null || echo "unknown")
        log_error "TYPE_FAIL: ${FIRST_TYPE:0:80}"
        FAILED=true
    fi
fi

# ===== 追踪 + 判定 =====
DURATION=$(( $(date +%s) - START_TS ))
OUTCOME="pass"
[ "$FAILED" = true ] && OUTCOME="fail"

track_usage "quality-gate" "$TEAMMATE_NAME" "" "$OUTCOME" "$DURATION" "$(jq -cn --arg t "$TASK_SUBJECT" --argjson r "$RETRY_COUNT" '{task:$t,retry:$r}')"
write_teammate_status "$TEAMMATE_NAME" "$ROLE" "quality-gate:$OUTCOME" "$TASK_SUBJECT" 0 0

if [ "$FAILED" = true ]; then
    locked_increment "$RETRY_FILE" "$LOCK_FILE" > /dev/null
    log_warn "BOUNCE(${RETRY_COUNT}+1/${MAX_RETRIES}): fix and retry"
    exit 2
fi

rm -f "$RETRY_FILE"
# Log successful task completion for state recovery
LATEST_COMMIT=$(git log --oneline -1 2>/dev/null || echo "no-commit")
write_commit_log "${ROLE}" "${LATEST_COMMIT%% *}" "$TASK_SUBJECT"
log_info "PASS: '${TASK_SUBJECT:0:60}' (${DURATION}s)"
exit 0
