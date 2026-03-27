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

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    TOTAL=$((TOTAL + 1))
    if echo "$haystack" | grep -qF "$needle"; then
        PASS=$((PASS + 1))
        echo "  PASS: $desc"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $desc (expected to contain '$needle', got '$haystack')"
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
assert_eq "escaped quotes in value" 'hello"world' "$(json_field '{"msg":"hello\"world"}' "msg")"

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
echo "=== role_limit ==="
assert_eq "fixer limit" "5" "$(role_limit "fixer")"
assert_eq "discoverer limit" "3" "$(role_limit "discoverer")"
# Unknown role should warn and return 1
UNKNOWN_LIMIT=$(role_limit "bogus_role" 2>/dev/null)
assert_eq "unknown role returns 1" "1" "$UNKNOWN_LIMIT"
WARN_OUTPUT=$(role_limit "bogus_role" 2>&1 >/dev/null)
TOTAL=$((TOTAL+1))
if echo "$WARN_OUTPUT" | grep -q "Unknown role"; then
    PASS=$((PASS+1))
    echo "  PASS: unknown role emits warning"
else
    FAIL=$((FAIL+1))
    echo "  FAIL: unknown role should emit warning (got: $WARN_OUTPUT)"
fi

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

# safe_run timeout test
TOTAL=$((TOTAL+1))
echo -n "  "
SAFE_RUN_TIMEOUT=1 safe_run "sleep 10" "$TEST_TMP/timeout.txt" 1
TIMEOUT_RC=$?
if [ "$TIMEOUT_RC" -eq 124 ]; then
    echo "PASS: safe_run timeout returns 124"
    PASS=$((PASS+1))
else
    echo "FAIL: safe_run timeout (expected rc=124, got=$TIMEOUT_RC)"
    FAIL=$((FAIL+1))
fi

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
echo "=== detect_project (rust type) ==="
RUST_TMP="$TEST_TMP/proj-rust"
mkdir -p "$RUST_TMP"
touch "$RUST_TMP/Cargo.toml"
cd "$RUST_TMP"
detect_project
cd "$_ORIG_DIR"
assert_eq "rust project type" "rust" "$PROJECT_TYPE"
assert_eq "rust TEST_CMD" "cargo test" "$TEST_CMD"
assert_eq "rust LINT_CMD" "cargo clippy -- -D warnings" "$LINT_CMD"

echo ""
echo "=== detect_project (go type) ==="
GO_TMP="$TEST_TMP/proj-go"
mkdir -p "$GO_TMP"
touch "$GO_TMP/go.mod"
cd "$GO_TMP"
detect_project
cd "$_ORIG_DIR"
assert_eq "go project type" "go" "$PROJECT_TYPE"
assert_eq "go TEST_CMD" "go test ./..." "$TEST_CMD"

echo ""
echo "=== detect_project (python type) ==="
PY_TMP="$TEST_TMP/proj-python"
mkdir -p "$PY_TMP"
touch "$PY_TMP/pyproject.toml"
cd "$PY_TMP"
detect_project
cd "$_ORIG_DIR"
assert_eq "python project type" "python" "$PROJECT_TYPE"
assert_contains "python TEST_CMD contains pytest" "pytest" "$TEST_CMD"

echo ""
echo "=== detect_project (java-maven type) ==="
MVN_TMP="$TEST_TMP/proj-maven"
mkdir -p "$MVN_TMP"
touch "$MVN_TMP/pom.xml"
cd "$MVN_TMP"
detect_project
cd "$_ORIG_DIR"
assert_eq "java-maven project type" "java-maven" "$PROJECT_TYPE"
assert_contains "java-maven TEST_CMD contains mvn" "mvn" "$TEST_CMD"

echo ""
echo "=== detect_project (java-gradle type) ==="
GRADLE_TMP="$TEST_TMP/proj-gradle"
mkdir -p "$GRADLE_TMP"
touch "$GRADLE_TMP/build.gradle"
cd "$GRADLE_TMP"
detect_project
cd "$_ORIG_DIR"
assert_eq "java-gradle project type" "java-gradle" "$PROJECT_TYPE"
assert_contains "java-gradle TEST_CMD contains gradle" "gradle" "$TEST_CMD"

echo ""
echo "=== detect_project (php type) ==="
PHP_TMP="$TEST_TMP/proj-php"
mkdir -p "$PHP_TMP/vendor/bin"
touch "$PHP_TMP/composer.json"
touch "$PHP_TMP/vendor/bin/phpunit"
cd "$PHP_TMP"
detect_project
cd "$_ORIG_DIR"
assert_eq "php project type" "php" "$PROJECT_TYPE"
assert_contains "php TEST_CMD contains phpunit" "phpunit" "$TEST_CMD"

# ===== State Persistence Tests =====
echo ""
echo "=== State Persistence ==="

# Test write_progress + read_progress
TOTAL=$((TOTAL+1))
echo -n "write_progress appends entry... "
rm -f "$STATE_DIR/progress.log"
write_progress "fixer" "3" "cycle complete"
if grep -q "\[fixer:3\] cycle complete" "$STATE_DIR/progress.log" 2>/dev/null; then
    echo "PASS"; PASS=$((PASS+1))
else
    echo "FAIL"; FAIL=$((FAIL+1))
fi

write_progress "reviewer" "2" "review done"
LC=$(wc -l < "$STATE_DIR/progress.log" | tr -d ' ')
assert_eq "write_progress appends multiple" "2" "$LC"

TOTAL=$((TOTAL+1))
echo -n "read_progress returns last entry... "
RESULT=$(read_progress 1)
if echo "$RESULT" | grep -q "reviewer"; then
    echo "PASS"; PASS=$((PASS+1))
else
    echo "FAIL (got: $RESULT)"; FAIL=$((FAIL+1))
fi

rm -f "$STATE_DIR/progress.log"
RESULT=$(read_progress 5)
assert_eq "read_progress no file fallback" "(no progress yet)" "$RESULT"

# Test write_discovery + count_open_discoveries
TOTAL=$((TOTAL+1))
echo -n "write_discovery creates JSONL... "
rm -f "$STATE_DIR/discoveries.jsonl"
write_discovery "discoverer" "P1" "button fails"
if grep -q '"resolved":false' "$STATE_DIR/discoveries.jsonl" 2>/dev/null; then
    echo "PASS"; PASS=$((PASS+1))
else
    echo "FAIL"; FAIL=$((FAIL+1))
fi

write_discovery "discoverer" "P0" "crash"
RESULT=$(count_open_discoveries)
assert_eq "count_open_discoveries counts" "2" "$RESULT"

rm -f "$STATE_DIR/discoveries.jsonl"
RESULT=$(count_open_discoveries)
assert_eq "count_open_discoveries no file" "0" "$RESULT"

# Test write_commit_log
TOTAL=$((TOTAL+1))
echo -n "write_commit_log appends... "
rm -f "$STATE_DIR/commits.log"
write_commit_log "fixer" "abc12345" "fix login"
if grep -q '"role":"fixer"' "$STATE_DIR/commits.log" 2>/dev/null && grep -q '"hash":"abc12345"' "$STATE_DIR/commits.log" 2>/dev/null; then
    echo "PASS"; PASS=$((PASS+1))
else
    echo "FAIL"; FAIL=$((FAIL+1))
fi

# Test state_summary
TOTAL=$((TOTAL+1))
echo -n "state_summary returns formatted... "
rm -f "$STATE_DIR/commits.log" "$STATE_DIR/discoveries.jsonl"
echo "line1" > "$STATE_DIR/commits.log"
echo "line2" >> "$STATE_DIR/commits.log"
RESULT=$(state_summary)
if echo "$RESULT" | grep -q "commits:2"; then
    echo "PASS"; PASS=$((PASS+1))
else
    echo "FAIL (got: $RESULT)"; FAIL=$((FAIL+1))
fi

# Test reset_role_cycle
TOTAL=$((TOTAL+1))
echo -n "reset_role_cycle resets round file... "
TEAM_NAME="default"
TEAMMATE_NAME="testbot"
_ROUND_FILE="${STATE_DIR}/round-${TEAM_NAME}-${TEAMMATE_NAME}"
echo "5" > "$_ROUND_FILE"
rm -f "$STATE_DIR/progress.log"
reset_role_cycle "fixer" "5" "test_reset"
if [ ! -f "$_ROUND_FILE" ]; then
    echo "PASS"; PASS=$((PASS+1))
else
    echo "FAIL (round file still exists)"; FAIL=$((FAIL+1))
fi

TOTAL=$((TOTAL+1))
echo -n "reset_role_cycle writes progress... "
if grep -q "test_reset" "$STATE_DIR/progress.log" 2>/dev/null; then
    echo "PASS"; PASS=$((PASS+1))
else
    echo "FAIL"; FAIL=$((FAIL+1))
fi

# ===== Shutdown Sentinel Tests =====
echo ""
echo "=== Shutdown Sentinel ==="

# Test is_shutdown returns false when no sentinel
TOTAL=$((TOTAL+1))
echo -n "is_shutdown returns false when no sentinel... "
rm -f "$STATE_DIR/shutdown-testteam"
if ! is_shutdown "testteam"; then
    echo "PASS"; PASS=$((PASS+1))
else
    echo "FAIL (should return false)"; FAIL=$((FAIL+1))
fi

# Test write_shutdown_sentinel creates file
TOTAL=$((TOTAL+1))
echo -n "write_shutdown_sentinel creates file... "
write_shutdown_sentinel "testteam" 2>/dev/null
if [ -f "$STATE_DIR/shutdown-testteam" ]; then
    echo "PASS"; PASS=$((PASS+1))
else
    echo "FAIL"; FAIL=$((FAIL+1))
fi

# Test is_shutdown returns true after write
TOTAL=$((TOTAL+1))
echo -n "is_shutdown returns true after write... "
if is_shutdown "testteam"; then
    echo "PASS"; PASS=$((PASS+1))
else
    echo "FAIL"; FAIL=$((FAIL+1))
fi

# Test sentinel contains timestamp
TOTAL=$((TOTAL+1))
echo -n "sentinel file contains timestamp... "
SENTINEL_CONTENT=$(cat "$STATE_DIR/shutdown-testteam" 2>/dev/null)
if echo "$SENTINEL_CONTENT" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T'; then
    echo "PASS"; PASS=$((PASS+1))
else
    echo "FAIL (got: $SENTINEL_CONTENT)"; FAIL=$((FAIL+1))
fi

# Test default team name
TOTAL=$((TOTAL+1))
echo -n "is_shutdown uses 'default' team... "
rm -f "$STATE_DIR/shutdown-default"
echo "ts" > "$STATE_DIR/shutdown-default"
if is_shutdown; then
    echo "PASS"; PASS=$((PASS+1))
else
    echo "FAIL"; FAIL=$((FAIL+1))
fi
rm -f "$STATE_DIR/shutdown-default" "$STATE_DIR/shutdown-testteam"

# ===== JSON Fallback Escaping Tests =====
echo ""
echo "=== JSON Fallback Escaping ==="

# Test write_discovery with newlines in description (fallback path)
TOTAL=$((TOTAL+1))
echo -n "write_discovery escapes newlines... "
rm -f "$STATE_DIR/discoveries.jsonl"
_ORIG_PATH="$PATH"
# Force fallback by temporarily hiding jq
PATH="/usr/bin:/bin"
hash -r 2>/dev/null
write_discovery "tester" "P1" "line1
line2"
PATH="$_ORIG_PATH"
hash -r 2>/dev/null
# Verify single JSON line (no raw newline breaking JSONL)
LC_DISC=$(wc -l < "$STATE_DIR/discoveries.jsonl" | tr -d ' ')
if [ "$LC_DISC" = "1" ]; then
    echo "PASS"; PASS=$((PASS+1))
else
    echo "FAIL (expected 1 line, got $LC_DISC)"; FAIL=$((FAIL+1))
fi

# Test write_commit_log with tabs in message (fallback path)
TOTAL=$((TOTAL+1))
echo -n "write_commit_log escapes tabs... "
rm -f "$STATE_DIR/commits.log"
PATH="/usr/bin:/bin"
hash -r 2>/dev/null
write_commit_log "tester" "abc123" "fix	tab	issue"
PATH="$_ORIG_PATH"
hash -r 2>/dev/null
LC_COMMIT=$(wc -l < "$STATE_DIR/commits.log" | tr -d ' ')
if [ "$LC_COMMIT" = "1" ]; then
    echo "PASS"; PASS=$((PASS+1))
else
    echo "FAIL (expected 1 line, got $LC_COMMIT)"; FAIL=$((FAIL+1))
fi

# ===== Empty Name Sanitization Tests =====
echo ""
echo "=== Empty Name Sanitization ==="

# Test that keep-working.sh handles all-special-char names
KW_SANITIZE_PROJ="$TEST_TMP/kw-sanitize"
mkdir -p "$KW_SANITIZE_PROJ/.claude/state"
echo "50" > "$KW_SANITIZE_PROJ/.claude/state/round-default-unknown"
TOTAL=$((TOTAL+1))
echo -n "empty teammate name defaults to 'unknown'... "
KW_SANITIZE_EXIT=0
(export CLAUDE_PROJECT_DIR="$KW_SANITIZE_PROJ" AI_PIPELINE_MAX_ROUNDS=50; \
 echo '{"teammate_name":"../../../","team_name":"../../../","teammate_role":"fixer"}' | bash "$PROJECT_DIR/bin/keep-working.sh") >/dev/null 2>&1 || KW_SANITIZE_EXIT=$?
# Should exit 0 (hits MAX_ROUNDS for round-default-unknown) and not crash
if [ "$KW_SANITIZE_EXIT" -eq 0 ]; then
    echo "PASS"; PASS=$((PASS+1))
else
    echo "FAIL (exit=$KW_SANITIZE_EXIT)"; FAIL=$((FAIL+1))
fi

echo ""
echo "=========================================="
echo "  Results: $PASS passed, $FAIL failed, $TOTAL total"
echo "=========================================="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
