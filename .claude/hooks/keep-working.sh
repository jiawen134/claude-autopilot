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

ROLE=$(detect_role "$TEAMMATE_NAME" "$TEAMMATE_ROLE")

# Sanitize TEAMMATE_NAME and TEAM_NAME to prevent path traversal in file paths
TEAMMATE_NAME="${TEAMMATE_NAME//[^a-zA-Z0-9_-]/}"
TEAM_NAME="${TEAM_NAME//[^a-zA-Z0-9_-]/}"
# Guard against empty names after sanitization
[ -z "$TEAMMATE_NAME" ] && TEAMMATE_NAME="unknown"
[ -z "$TEAM_NAME" ] && TEAM_NAME="default"
_LOG_PREFIX="$TEAMMATE_NAME"

# ===== Shutdown check =====
if is_shutdown "$TEAM_NAME"; then
    log_info "Shutdown sentinel detected for team '$TEAM_NAME'. Stopping."
    exit 0
fi

# ===== 轮次计数 =====
ROUND_FILE="${STATE_DIR}/round-${TEAM_NAME}-${TEAMMATE_NAME}"
LOCK_FILE="${STATE_DIR}/lock-round-${TEAM_NAME}-${TEAMMATE_NAME}"
MAX_ROUNDS="${AI_PIPELINE_MAX_ROUNDS:-15}"
# Validate numeric env vars
[[ "$MAX_ROUNDS" =~ ^[0-9]+$ ]] || { log_warn "Invalid MAX_ROUNDS='$MAX_ROUNDS', using 15"; MAX_ROUNDS=15; }

CURRENT_ROUND=$(locked_increment "$ROUND_FILE" "$LOCK_FILE")

if [ "$CURRENT_ROUND" -gt "$MAX_ROUNDS" ]; then
    log_info "已达 ${MAX_ROUNDS} 轮上限。安全停止。"
    rm -f "$ROUND_FILE"
    exit 0
fi

# ===== 第1层：检查任务列表 =====
TASK_DIR="${HOME:-.}/.claude/tasks/$TEAM_NAME"
PENDING=0
IN_PROGRESS=0
if [ -d "$TASK_DIR" ]; then
    # grep -rl counts files-with-match (one count per file even if status appears twice — malformed files)
    PENDING=$(grep -rl '"status"[[:space:]]*:[[:space:]]*"pending"' "$TASK_DIR/" 2>/dev/null | wc -l) || PENDING=0
    IN_PROGRESS=$(grep -rl '"status"[[:space:]]*:[[:space:]]*"in_progress"' "$TASK_DIR/" 2>/dev/null | wc -l) || IN_PROGRESS=0
    # Strip whitespace (wc -l may pad with spaces on some platforms)
    PENDING="${PENDING// /}"
    IN_PROGRESS="${IN_PROGRESS// /}"
fi
REMAINING=$((PENDING + IN_PROGRESS))

if [ "$REMAINING" -gt 0 ]; then
    # 有任务 → 重置空闲计数器（含时间戳文件）
    rm -f "${STATE_DIR}/idle-${TEAM_NAME}-${TEAMMATE_NAME}" "${STATE_DIR}/idle-ts-${TEAM_NAME}-${TEAMMATE_NAME}" 2>/dev/null
    write_teammate_status "$TEAMMATE_NAME" "$ROLE" "claiming_task" "${PENDING}p+${IN_PROGRESS}ip" "$CURRENT_ROUND" "$MAX_ROUNDS"
    log_info "[${ROLE}:R${CURRENT_ROUND}] ${PENDING}p+${IN_PROGRESS}ip tasks. Claiming next."
    track_usage "keep-working" "$TEAMMATE_NAME" "$ROLE" "claim_task" "$(($(date +%s)-START_TS))" "{\"round\":$CURRENT_ROUND}"
    exit 2
fi

# ===== 第2层：主动发现 =====
detect_project

if [ -n "${TEST_CMD:-}" ]; then
    write_teammate_status "$TEAMMATE_NAME" "$ROLE" "running_tests" "$TEST_CMD" "$CURRENT_ROUND" "$MAX_ROUNDS"
    TEST_EXIT=0
    _test_outfile=$(mktemp)
    safe_run "$TEST_CMD" "$_test_outfile" || TEST_EXIT=$?
    TEST_OUTPUT=$(cat "$_test_outfile" 2>/dev/null)
    rm -f "$_test_outfile"
    if [ "$TEST_EXIT" -ne 0 ]; then
        rm -f "${STATE_DIR}/idle-${TEAM_NAME}-${TEAMMATE_NAME}" "${STATE_DIR}/idle-ts-${TEAM_NAME}-${TEAMMATE_NAME}" 2>/dev/null
        write_teammate_status "$TEAMMATE_NAME" "$ROLE" "test_failed" "exit=$TEST_EXIT" "$CURRENT_ROUND" "$MAX_ROUNDS"
        FC=$(echo "$TEST_OUTPUT" | grep -ciE "FAIL|failed|error|panic" || echo "?")
        FIRST_ERR=$(echo "$TEST_OUTPUT" | grep -m1 -iE "FAIL|ERROR|panic" || echo "unknown")
        log_error "[${ROLE}:R${CURRENT_ROUND}] TEST_FAIL(${FC}): ${FIRST_ERR:0:80}"
        track_usage "keep-working" "$TEAMMATE_NAME" "$ROLE" "test_fail" "$(($(date +%s)-START_TS))" "{\"round\":$CURRENT_ROUND}"
        exit 2
    fi
fi

if [ -n "${LINT_CMD:-}" ]; then
    write_teammate_status "$TEAMMATE_NAME" "$ROLE" "running_lint" "$LINT_CMD" "$CURRENT_ROUND" "$MAX_ROUNDS"
    LINT_EXIT=0
    _lint_outfile=$(mktemp)
    safe_run "$LINT_CMD" "$_lint_outfile" || LINT_EXIT=$?
    LINT_OUTPUT=$(cat "$_lint_outfile" 2>/dev/null)
    rm -f "$_lint_outfile"
    if [ "$LINT_EXIT" -ne 0 ]; then
        write_teammate_status "$TEAMMATE_NAME" "$ROLE" "lint_failed" "exit=$LINT_EXIT" "$CURRENT_ROUND" "$MAX_ROUNDS"
        LC=$(echo "$LINT_OUTPUT" | wc -l | tr -d ' ')
        FIRST_LINT=$(echo "$LINT_OUTPUT" | grep -m1 -iE "error|warning|:" || echo "unknown")
        log_error "[${ROLE}:R${CURRENT_ROUND}] LINT_FAIL(${LC}): ${FIRST_LINT:0:80}"
        track_usage "keep-working" "$TEAMMATE_NAME" "$ROLE" "lint_fail" "$(($(date +%s)-START_TS))" "{\"round\":$CURRENT_ROUND}"
        exit 2
    fi
fi

# ===== 第2.5层：完成检测 =====
# 没有待办任务 + 测试通过 + lint 通过 = 可能已经做完了
# 需要同时满足：次数 >= 阈值 AND 时间 >= 最小等待秒数，才认定真正空闲
# 防止快速连续的 idle hook 调用误停正在等待新任务的 Teammate
IDLE_FILE="${STATE_DIR}/idle-${TEAM_NAME}-${TEAMMATE_NAME}"
IDLE_LOCK="${STATE_DIR}/lock-idle-${TEAM_NAME}-${TEAMMATE_NAME}"
IDLE_TS_FILE="${STATE_DIR}/idle-ts-${TEAM_NAME}-${TEAMMATE_NAME}"
IDLE_THRESHOLD="${AI_PIPELINE_IDLE_THRESHOLD:-3}"
[[ "$IDLE_THRESHOLD" =~ ^[0-9]+$ ]] || { log_warn "Invalid IDLE_THRESHOLD='$IDLE_THRESHOLD', using 3"; IDLE_THRESHOLD=3; }
IDLE_MIN_SECONDS="${AI_PIPELINE_IDLE_MIN_SECONDS:-60}"
[[ "$IDLE_MIN_SECONDS" =~ ^[0-9]+$ ]] || { log_warn "Invalid IDLE_MIN_SECONDS='$IDLE_MIN_SECONDS', using 60"; IDLE_MIN_SECONDS=60; }

IDLE_COUNT=$(locked_increment "$IDLE_FILE" "$IDLE_LOCK")

# 第一次进入 idle 时记录时间戳
if [ ! -f "$IDLE_TS_FILE" ]; then
    date +%s > "$IDLE_TS_FILE"
fi

if [ "$IDLE_COUNT" -ge "$IDLE_THRESHOLD" ]; then
    # 次数够了，再检查时间：至少等够 IDLE_MIN_SECONDS 秒才停止
    FIRST_IDLE_TS=$(cat "$IDLE_TS_FILE" 2>/dev/null || echo 0)
    [[ "$FIRST_IDLE_TS" =~ ^[0-9]+$ ]] || FIRST_IDLE_TS=0
    IDLE_ELAPSED=$(( $(date +%s) - FIRST_IDLE_TS ))

    if [ "$IDLE_ELAPSED" -lt "$IDLE_MIN_SECONDS" ]; then
        # 时间不够 → 继续等（不停止），给新任务到达的时间窗口
        log_info "[${ROLE}:R${CURRENT_ROUND}] idle ${IDLE_COUNT}x / ${IDLE_ELAPSED}s < ${IDLE_MIN_SECONDS}s min, waiting"
        exit 2
    fi

    # 次数 + 时间都满足 → 真正空闲，停止
    write_teammate_status "$TEAMMATE_NAME" "$ROLE" "idle_done" "no tasks for ${IDLE_COUNT} rounds (${IDLE_ELAPSED}s), all green" "$CURRENT_ROUND" "$MAX_ROUNDS"
    log_info "[${ROLE}:R${CURRENT_ROUND}] IDLE_DONE: no tasks + tests pass for ${IDLE_COUNT} rounds (${IDLE_ELAPSED}s). Stopping."
    write_progress "$ROLE" "$CURRENT_ROUND" "idle_done — no work for ${IDLE_COUNT} rounds (${IDLE_ELAPSED}s)"
    track_usage "keep-working" "$TEAMMATE_NAME" "$ROLE" "idle_done" "$(($(date +%s)-START_TS))" "{\"round\":$CURRENT_ROUND,\"idle\":$IDLE_COUNT}"
    rm -f "$IDLE_FILE" "$IDLE_TS_FILE"
    exit 0
fi

# ===== 第3层：按角色轮转 =====
ROLE_LIMIT=$(role_limit "$ROLE")
if [ "$CURRENT_ROUND" -gt "$ROLE_LIMIT" ]; then
    # Auto-restart: reset counter and continue (Peter mode)
    # Write progress to disk so next cycle has context
    reset_role_cycle "$ROLE" "$CURRENT_ROUND" "cycle_${CURRENT_ROUND}_complete"
    CURRENT_ROUND=1
    write_teammate_status "$TEAMMATE_NAME" "$ROLE" "restarting" "cycle reset after $ROLE_LIMIT rounds" "$CURRENT_ROUND" "$MAX_ROUNDS"
    log_info "[${ROLE}:reset/${MAX_ROUNDS}] cycle done, resetting. $(state_summary)"
    track_usage "keep-working" "$TEAMMATE_NAME" "$ROLE" "cycle_reset" "$(($(date +%s)-START_TS))" "{\"round\":$CURRENT_ROUND}"
    exit 2
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

# ===== 第 3.5 层：首轮注入队友名称（帮助 Teammate 发现 peer，减少 Lead 转发瓶颈）=====
if [ "$CURRENT_ROUND" -eq 1 ]; then
    TEAM_CONFIG="${HOME:-.}/.claude/teams/${TEAM_NAME}/config.json"
    if [ -f "$TEAM_CONFIG" ] && command -v jq &>/dev/null; then
        PEERS=$(jq -r '.members[]?.name // empty' "$TEAM_CONFIG" 2>/dev/null | grep -v "^${TEAMMATE_NAME}$" | tr '\n' ',' | sed 's/,$//')
        [ -n "$PEERS" ] && log_info "[${ROLE}:R1] peers: ${PEERS}"
    fi
fi

write_teammate_status "$TEAMMATE_NAME" "$ROLE" "working" "$SKILL_MSG" "$CURRENT_ROUND" "$MAX_ROUNDS"
log_info "[${ROLE}:R${CURRENT_ROUND}] ${SKILL_MSG} | $(state_summary)"
track_usage "keep-working" "$TEAMMATE_NAME" "$ROLE" "skill_rotate" "$(($(date +%s)-START_TS))" "$(jq -cn --argjson r "$CURRENT_ROUND" --arg s "$SKILL_MSG" '{round:$r,skill:$s}')"
exit 2
