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
        echo "  FAIL: $desc (expected exit 0)"
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
echo "=== write_teammate_status ==="
write_teammate_status "alice" "fixer" "working" "fixing bug" 3 50
STATUS_FILE="$STATE_DIR/status-alice.json"
assert_ok "status file created" test -f "$STATUS_FILE"
assert_eq "teammate field" "alice" "$(jq -r '.teammate' "$STATUS_FILE" 2>/dev/null)"
assert_eq "role field" "fixer" "$(jq -r '.role' "$STATUS_FILE" 2>/dev/null)"
assert_eq "action field" "working" "$(jq -r '.action' "$STATUS_FILE" 2>/dev/null)"
assert_eq "detail field" "fixing bug" "$(jq -r '.detail' "$STATUS_FILE" 2>/dev/null)"
assert_eq "round field" "3" "$(jq -r '.round' "$STATUS_FILE" 2>/dev/null)"
assert_eq "max_rounds field" "50" "$(jq -r '.max_rounds' "$STATUS_FILE" 2>/dev/null)"
# Special chars in detail must not break JSON
write_teammate_status "bob" "reviewer" "done" 'has "quotes" & <tags>' 1 10
assert_ok "special chars: valid JSON" jq '.' "$STATE_DIR/status-bob.json"
assert_eq "special chars: detail preserved" 'has "quotes" & <tags>' "$(jq -r '.detail' "$STATE_DIR/status-bob.json" 2>/dev/null)"

echo ""
echo "=== track_usage ==="
USAGE_TEST="$STATE_DIR/track-usage-test.jsonl"
# Override STATE_DIR temporarily so track_usage writes to a fresh file
_ORIG_STATE_DIR="$STATE_DIR"
STATE_DIR="$TEST_TMP/track-state"
mkdir -p "$STATE_DIR"
track_usage "quality-gate" "alice" "fixer" "pass" 5
assert_ok "usage file created" test -f "$STATE_DIR/usage.jsonl"
LAST=$(tail -1 "$STATE_DIR/usage.jsonl")
assert_eq "hook field" "quality-gate" "$(echo "$LAST" | jq -r '.hook' 2>/dev/null)"
assert_eq "teammate field" "alice" "$(echo "$LAST" | jq -r '.teammate' 2>/dev/null)"
assert_eq "action field" "pass" "$(echo "$LAST" | jq -r '.action' 2>/dev/null)"
assert_eq "duration field" "5" "$(echo "$LAST" | jq -r '.duration_s' 2>/dev/null)"
track_usage "keep-working" "bob" "reviewer" "claim_task" 1
assert_eq "second entry appended" "2" "$(wc -l < "$STATE_DIR/usage.jsonl")"
STATE_DIR="$_ORIG_STATE_DIR"

echo ""
echo "=== detect_project (makefile type) ==="
PROJ_TMP="$TEST_TMP/proj-make"
mkdir -p "$PROJ_TMP"
printf 'test:\n\techo ok\nlint:\n\techo lint\n' > "$PROJ_TMP/Makefile"
_ORIG_DIR="$PWD"
cd "$PROJ_TMP"
detect_project
cd "$_ORIG_DIR"
assert_eq "makefile project type" "makefile" "$PROJECT_TYPE"
assert_eq "makefile TEST_CMD" "make test" "$TEST_CMD"
assert_eq "makefile LINT_CMD" "make lint" "$LINT_CMD"

echo ""
echo "=== detect_project (node type) ==="
NODE_TMP="$TEST_TMP/proj-node"
mkdir -p "$NODE_TMP"
printf '{"name":"test","scripts":{"test":"jest","lint":"eslint .","typecheck":"tsc"}}\n' > "$NODE_TMP/package.json"
cd "$NODE_TMP"
detect_project
cd "$_ORIG_DIR"
assert_eq "node project type" "node" "$PROJECT_TYPE"
assert_eq "node TEST_CMD" "npm test" "$TEST_CMD"
assert_eq "node LINT_CMD" "npm run lint" "$LINT_CMD"
assert_eq "node TYPE_CMD" "npm run typecheck" "$TYPE_CMD"

echo ""
echo "=========================================="
echo "  Results: $PASS passed, $FAIL failed, $TOTAL total"
echo "=========================================="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
