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
TEAMMATE_NAME=$(json_field "$INPUT" "teammate_name" "unknown")
TEAM_NAME=$(json_field "$INPUT" "team_name" "default")
_LOG_PREFIX="$TEAMMATE_NAME"

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
    log_warn "'$TASK_SUBJECT' 已被打回 ${MAX_RETRIES} 次。强制放行。"
    rm -f "$RETRY_FILE"
    exit 0
fi

log_info "验证: $TASK_SUBJECT (${RETRY_COUNT}+1/${MAX_RETRIES})"

# ===== 检测项目 =====
detect_project

# ===== 质量检查 =====
FAILED=false
TMPDIR_GATE=$(mktemp -d "${STATE_DIR}/gate-XXXXXX")
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
                log_error "全量测试也失败"
                grep -iE "FAIL|ERROR|panic|assert" "$TMPDIR_GATE/test_full.txt" 2>/dev/null | head -15 >&2
                tail -10 "$TMPDIR_GATE/test_full.txt" >&2
                FAILED=true
            fi
        else
            log_error "测试失败"
            grep -iE "FAIL|ERROR|panic|assert" "$TMPDIR_GATE/test.txt" 2>/dev/null | head -15 >&2
            tail -10 "$TMPDIR_GATE/test.txt" >&2
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
        log_error "Lint 未通过"
        head -20 "$TMPDIR_GATE/lint.txt" >&2
        FAILED=true
    fi
fi

# 3. 类型检查
if [ "$FAILED" = false ] && [ -n "${TYPE_CMD:-}" ]; then
    log_info "类型检查: $TYPE_CMD"
    if ! safe_run "$TYPE_CMD" "$TMPDIR_GATE/type.txt"; then
        log_error "类型检查未通过"
        head -15 "$TMPDIR_GATE/type.txt" >&2
        FAILED=true
    fi
fi

# ===== 追踪 + 判定 =====
DURATION=$(( $(date +%s) - START_TS ))
OUTCOME="pass"
[ "$FAILED" = true ] && OUTCOME="fail"

track_usage "quality-gate" "$TEAMMATE_NAME" "" "$OUTCOME" "$DURATION" "\"task\":\"$TASK_SUBJECT\",\"retry\":$RETRY_COUNT"
write_teammate_status "$TEAMMATE_NAME" "" "quality-gate:$OUTCOME" "$TASK_SUBJECT"

if [ "$FAILED" = true ]; then
    locked_increment "$RETRY_FILE" "$LOCK_FILE" > /dev/null
    log_warn "请修复后再标记完成。(第 $((RETRY_COUNT+1))/${MAX_RETRIES} 次打回)"
    exit 2
fi

rm -f "$RETRY_FILE"
log_info "通过！'$TASK_SUBJECT' 已验证。(${DURATION}s)"
exit 0
