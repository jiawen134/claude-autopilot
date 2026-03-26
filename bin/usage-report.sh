#!/bin/bash
# usage-report.sh — 从 .claude/state/usage.jsonl 生成用量日报
#
# 用法: ./usage-report.sh [project_dir]

set -uo pipefail

PROJECT_DIR="${1:-${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"
STATE_DIR="$PROJECT_DIR/.claude/state"
USAGE_FILE="$STATE_DIR/usage.jsonl"

if [ ! -f "$USAGE_FILE" ]; then
    echo "没有用量数据。运行 /agent-teams 后会自动记录。"
    exit 0
fi

TOTAL_EVENTS=$(wc -l < "$USAGE_FILE")
TODAY=$(date +%Y-%m-%d)
TODAY_EVENTS=$(grep -c "$TODAY" "$USAGE_FILE" 2>/dev/null || echo 0)

echo "=========================================="
echo "  Agent Teams 用量报告"
echo "  项目: $(basename "$PROJECT_DIR")"
echo "  日期: $TODAY"
echo "=========================================="
echo ""

# 按 Teammate 统计
echo "--- 按 Teammate ---"
if command -v jq &>/dev/null; then
    jq -r '.teammate' "$USAGE_FILE" 2>/dev/null | sort | uniq -c | sort -rn | while read -r count name; do
        printf "  %-20s %d 次\n" "$name" "$count"
    done
    echo ""

    # 按 Hook 统计
    echo "--- 按 Hook ---"
    jq -r '.hook' "$USAGE_FILE" 2>/dev/null | sort | uniq -c | sort -rn | while read -r count name; do
        printf "  %-20s %d 次\n" "$name" "$count"
    done
    echo ""

    # 按结果统计
    echo "--- 按结果 ---"
    PASS=$(jq -r 'select(.outcome=="pass") | .outcome' "$USAGE_FILE" 2>/dev/null | wc -l)
    FAIL=$(jq -r 'select(.outcome=="fail") | .outcome' "$USAGE_FILE" 2>/dev/null | wc -l)
    echo "  通过: $PASS"
    echo "  打回: $FAIL"
    [ "$((PASS + FAIL))" -gt 0 ] && echo "  通过率: $(( PASS * 100 / (PASS + FAIL) ))%"
    echo ""

    # 总耗时
    echo "--- 耗时 ---"
    TOTAL_DURATION=$(jq -r '.duration_s // 0' "$USAGE_FILE" 2>/dev/null | paste -sd+ | bc 2>/dev/null || echo "?")
    echo "  总耗时: ${TOTAL_DURATION}s"
    echo "  事件总数: $TOTAL_EVENTS (今日: $TODAY_EVENTS)"

    # 按角色统计轮次
    echo ""
    echo "--- 按角色轮次 ---"
    jq -r 'select(.role != null) | .role' "$USAGE_FILE" 2>/dev/null | sort | uniq -c | sort -rn | while read -r count role; do
        printf "  %-15s %d 轮\n" "$role" "$count"
    done
else
    # 无 jq 时用 grep 简单统计
    echo "  总事件: $TOTAL_EVENTS (今日: $TODAY_EVENTS)"
    echo "  quality-gate 调用: $(grep -c "quality-gate" "$USAGE_FILE" 2>/dev/null || echo 0)"
    echo "  keep-working 调用: $(grep -c "keep-working" "$USAGE_FILE" 2>/dev/null || echo 0)"
    echo ""
    echo "  (安装 jq 可获得更详细的报告)"
fi

echo ""
echo "=========================================="
