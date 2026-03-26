#!/bin/bash
# test_common.sh — lib/common.sh 的单元测试
# 运行: bash tests/test_common.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# 加载被测模块
TEAMMATE_NAME="test-runner"
PROJECT_DIR="$PROJECT_DIR"
source "$PROJECT_DIR/lib/common.sh"

# ===== 测试框架 =====
PASS=0 FAIL=0 TOTAL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    TOTAL=$((TOTAL + 1))
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        echo "  PASS: $desc"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $desc (expected='$expected', got='$actual')"
    fi
}

assert_ok() {
    local desc="$1"
    shift
    TOTAL=$((TOTAL + 1))
    if "$@" >/dev/null 2>&1; then
        PASS=$((PASS + 1))
        echo "  PASS: $desc"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $desc (exit code $?)"
    fi
}

assert_fail() {
    local desc="$1"
    shift
    TOTAL=$((TOTAL + 1))
    if ! "$@" >/dev/null 2>&1; then
        PASS=$((PASS + 1))
        echo "  PASS: $desc"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $desc (expected failure, got success)"
    fi
}

# ===== 测试临时目录 =====
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT
STATE_DIR="$TEST_TMP/state"
mkdir -p "$STATE_DIR"

echo "=== json_field ==="
assert_eq "basic field" "hello" "$(json_field '{"name":"hello"}' "name")"
assert_eq "missing field returns default" "fallback" "$(json_field '{"name":"hello"}' "age" "fallback")"
assert_eq "nested quotes" "hello world" "$(json_field '{"msg":"hello world"}' "msg")"
assert_eq "empty json" "default" "$(json_field '{}' "name" "default")"
assert_eq "number-like value" "42" "$(json_field '{"count":"42"}' "count")"

echo ""
echo "=== detect_role ==="
assert_eq "english discoverer" "discoverer" "$(detect_role "qa-discoverer" "")"
assert_eq "english fixer" "fixer" "$(detect_role "code-fixer" "")"
assert_eq "english reviewer" "reviewer" "$(detect_role "code-reviewer" "")"
assert_eq "english designer" "designer" "$(detect_role "ui-designer" "")"
assert_eq "english releaser" "releaser" "$(detect_role "release-manager" "")"
assert_eq "english strategist" "strategist" "$(detect_role "tech-strategist" "")"
assert_eq "chinese 修复" "fixer" "$(detect_role "修复者" "")"
assert_eq "chinese 发现" "discoverer" "$(detect_role "发现者" "")"
assert_eq "chinese 审查" "reviewer" "$(detect_role "审查官" "")"
assert_eq "chinese 设计" "designer" "$(detect_role "设计师" "")"
assert_eq "chinese 发布" "releaser" "$(detect_role "发布者" "")"
assert_eq "chinese 规划" "strategist" "$(detect_role "规划师" "")"
assert_eq "explicit role override" "custom-role" "$(detect_role "random-name" "custom-role")"
assert_eq "unknown name" "unknown" "$(detect_role "Thomas" "")"
assert_eq "case insensitive" "discoverer" "$(detect_role "QA-DISCOVERER" "")"
# 关键：prefix 不应该匹配 fixer
assert_eq "prefix should NOT match fixer" "unknown" "$(detect_role "prefix-handler" "")"

echo ""
echo "=== atomic_write ==="
atomic_write "$TEST_TMP/test.txt" "hello"
assert_eq "write content" "hello" "$(cat "$TEST_TMP/test.txt")"
atomic_write "$TEST_TMP/test.txt" "updated"
assert_eq "overwrite content" "updated" "$(cat "$TEST_TMP/test.txt")"

echo ""
echo "=== locked_increment ==="
COUNTER_FILE="$TEST_TMP/counter"
LOCK_FILE="$TEST_TMP/counter.lock"
V1=$(locked_increment "$COUNTER_FILE" "$LOCK_FILE")
assert_eq "first increment" "1" "$V1"
V2=$(locked_increment "$COUNTER_FILE" "$LOCK_FILE")
assert_eq "second increment" "2" "$V2"
V3=$(locked_increment "$COUNTER_FILE" "$LOCK_FILE")
assert_eq "third increment" "3" "$V3"

echo ""
echo "=== locked_read ==="
V=$(locked_read "$COUNTER_FILE" "$LOCK_FILE")
assert_eq "read counter" "3" "$V"
V_MISSING=$(locked_read "$TEST_TMP/nonexistent" "$LOCK_FILE")
assert_eq "read missing returns 0" "0" "$V_MISSING"

echo ""
echo "=== append_jsonl ==="
JSONL_FILE="$TEST_TMP/events.jsonl"
append_jsonl "$JSONL_FILE" '{"event":"a"}'
append_jsonl "$JSONL_FILE" '{"event":"b"}'
LINE_COUNT=$(wc -l < "$JSONL_FILE")
assert_eq "jsonl has 2 lines" "2" "$LINE_COUNT"

echo ""
echo "=== safe_run ==="
assert_ok "true succeeds" safe_run "echo hello" "$TEST_TMP/out.txt"
assert_eq "output captured" "hello" "$(cat "$TEST_TMP/out.txt")"
assert_fail "false fails" safe_run "exit 1" "$TEST_TMP/fail.txt"

echo ""
echo "=== portable_lock / unlock ==="
LOCK_TEST="$TEST_TMP/test.lock"
assert_ok "lock succeeds" portable_lock "$LOCK_TEST" 2
portable_unlock "$LOCK_TEST"
assert_ok "re-lock after unlock" portable_lock "$LOCK_TEST" 2
portable_unlock "$LOCK_TEST"

echo ""
echo "=== init_state_dir ==="
init_state_dir "$TEST_TMP/project"
assert_ok "state dir exists" test -d "$TEST_TMP/project/.claude/state"

echo ""
echo "=========================================="
echo "  Results: $PASS passed, $FAIL failed, $TOTAL total"
echo "=========================================="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
