#!/bin/bash
# keep-working.sh — TeammateIdle Hook
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
TEAM_NAME=$(json_field "$INPUT" "team_name" "default")
TEAMMATE_NAME=$(json_field "$INPUT" "teammate_name" "unknown")
TEAMMATE_ROLE=$(json_field "$INPUT" "teammate_role" "")
_LOG_PREFIX="$TEAMMATE_NAME"

ROLE=$(detect_role "$TEAMMATE_NAME" "$TEAMMATE_ROLE")

# ===== 轮次计数 =====
ROUND_FILE="${STATE_DIR}/round-${TEAM_NAME}-${TEAMMATE_NAME}"
LOCK_FILE="${STATE_DIR}/lock-round-${TEAM_NAME}-${TEAMMATE_NAME}"
MAX_ROUNDS="${AI_PIPELINE_MAX_ROUNDS:-50}"

CURRENT_ROUND=$(locked_increment "$ROUND_FILE" "$LOCK_FILE")

if [ "$CURRENT_ROUND" -gt "$MAX_ROUNDS" ]; then
    log_info "已达 ${MAX_ROUNDS} 轮上限。安全停止。"
    rm -f "$ROUND_FILE"
    exit 0
fi

# ===== 第1层：检查任务列表 =====
TASK_DIR="${HOME:-.}/.claude/tasks/$TEAM_NAME"
PENDING=0 IN_PROGRESS=0
if [ -d "$TASK_DIR" ]; then
    PENDING=$(grep -rl '"status"[[:space:]]*:[[:space:]]*"pending"' "$TASK_DIR/" 2>/dev/null | wc -l || echo 0)
    IN_PROGRESS=$(grep -rl '"status"[[:space:]]*:[[:space:]]*"in_progress"' "$TASK_DIR/" 2>/dev/null | wc -l || echo 0)
fi
REMAINING=$((PENDING + IN_PROGRESS))

if [ "$REMAINING" -gt 0 ]; then
    write_teammate_status "$TEAMMATE_NAME" "$ROLE" "claiming_task" "${PENDING}p+${IN_PROGRESS}ip" "$CURRENT_ROUND" "$MAX_ROUNDS"
    log_info "[${ROLE}:${CURRENT_ROUND}/${MAX_ROUNDS}] 还有 ${PENDING} 待处理 + ${IN_PROGRESS} 进行中。认领下一个。"
    track_usage "keep-working" "$TEAMMATE_NAME" "$ROLE" "claim_task" "$(($(date +%s)-START_TS))" "\"round\":$CURRENT_ROUND"
    exit 2
fi

# ===== 第2层：主动发现 =====
detect_project

if [ -n "${TEST_CMD:-}" ]; then
    write_teammate_status "$TEAMMATE_NAME" "$ROLE" "running_tests" "$TEST_CMD" "$CURRENT_ROUND" "$MAX_ROUNDS"
    TEST_EXIT=0
    TEST_OUTPUT=$(bash -c "$TEST_CMD" 2>&1) || TEST_EXIT=$?
    if [ "$TEST_EXIT" -ne 0 ]; then
        write_teammate_status "$TEAMMATE_NAME" "$ROLE" "test_failed" "exit=$TEST_EXIT" "$CURRENT_ROUND" "$MAX_ROUNDS"
        FC=$(echo "$TEST_OUTPUT" | grep -ciE "FAIL|failed|error|panic" || echo "?")
        log_error "[${ROLE}:${CURRENT_ROUND}/${MAX_ROUNDS}] 测试失败（${FC} 处）！创建修复任务。"
        echo "$TEST_OUTPUT" | tail -20 >&2
        track_usage "keep-working" "$TEAMMATE_NAME" "$ROLE" "test_fail" "$(($(date +%s)-START_TS))" "\"round\":$CURRENT_ROUND"
        exit 2
    fi
fi

if [ -n "${LINT_CMD:-}" ]; then
    write_teammate_status "$TEAMMATE_NAME" "$ROLE" "running_lint" "$LINT_CMD" "$CURRENT_ROUND" "$MAX_ROUNDS"
    LINT_EXIT=0
    LINT_OUTPUT=$(bash -c "$LINT_CMD" 2>&1) || LINT_EXIT=$?
    if [ "$LINT_EXIT" -ne 0 ]; then
        write_teammate_status "$TEAMMATE_NAME" "$ROLE" "lint_failed" "exit=$LINT_EXIT" "$CURRENT_ROUND" "$MAX_ROUNDS"
        log_error "[${ROLE}:${CURRENT_ROUND}/${MAX_ROUNDS}] Lint 问题！创建修复任务。"
        echo "$LINT_OUTPUT" | tail -15 >&2
        track_usage "keep-working" "$TEAMMATE_NAME" "$ROLE" "lint_fail" "$(($(date +%s)-START_TS))" "\"round\":$CURRENT_ROUND"
        exit 2
    fi
fi

# ===== 第3层：按角色轮转 =====
role_limit() {
    case "$1" in
        discoverer) echo 20 ;; fixer) echo 10 ;; reviewer) echo 8 ;;
        designer)   echo 6 ;;  releaser) echo 6 ;; strategist) echo 8 ;;
        *)          echo 3 ;;
    esac
}

ROLE_LIMIT=$(role_limit "$ROLE")
if [ "$CURRENT_ROUND" -gt "$ROLE_LIMIT" ]; then
    write_teammate_status "$TEAMMATE_NAME" "$ROLE" "idle" "done after $ROLE_LIMIT rounds" "$CURRENT_ROUND" "$MAX_ROUNDS"
    log_info "[${ROLE}:${CURRENT_ROUND}/${MAX_ROUNDS}] 已完成 ${ROLE_LIMIT} 轮。休息。"
    rm -f "$ROUND_FILE"
    track_usage "keep-working" "$TEAMMATE_NAME" "$ROLE" "idle" "$(($(date +%s)-START_TS))" "\"round\":$CURRENT_ROUND"
    exit 0
fi

SKILL_MSG=""
case "$ROLE" in
    discoverer)
        SKILLS=("/qa — 系统化浏览器测试" "/benchmark — 性能回归检测" "/qa-only — 只出报告" "/investigate — 根因分析")
        SKILL_MSG="${SKILLS[$((CURRENT_ROUND % ${#SKILLS[@]}))]}" ;;
    fixer)      SKILL_MSG="/investigate 扫描遗漏 + /browse 验证" ;;
    reviewer)
        SKILLS=("/review — 代码审查" "/cso — 安全审计" "/codex — 交叉审查")
        SKILL_MSG="${SKILLS[$((CURRENT_ROUND % ${#SKILLS[@]}))]}" ;;
    designer)
        SKILLS=("/design-review — 视觉审查" "/plan-design-review — 设计打分" "/browse — 截图检查")
        SKILL_MSG="${SKILLS[$((CURRENT_ROUND % ${#SKILLS[@]}))]}" ;;
    releaser)
        SKILLS=("/document-release — 文档" "/ship — PR" "/land-and-deploy — 部署" "/canary — 监控")
        SKILL_MSG="${SKILLS[$((CURRENT_ROUND % ${#SKILLS[@]}))]}" ;;
    strategist)
        SKILLS=("/autoplan — 三轮审查" "/office-hours — 产品方向" "/plan-eng-review — 架构" "/retro — 复盘")
        SKILL_MSG="${SKILLS[$((CURRENT_ROUND % ${#SKILLS[@]}))]}" ;;
    *)          SKILL_MSG="角色未识别，请检查任务列表" ;;
esac

write_teammate_status "$TEAMMATE_NAME" "$ROLE" "working" "$SKILL_MSG" "$CURRENT_ROUND" "$MAX_ROUNDS"
log_info "[${ROLE}:${CURRENT_ROUND}/${MAX_ROUNDS}] 请运行 ${SKILL_MSG}"
track_usage "keep-working" "$TEAMMATE_NAME" "$ROLE" "skill_rotate" "$(($(date +%s)-START_TS))" "\"round\":$CURRENT_ROUND,\"skill\":\"$SKILL_MSG\""
exit 2
