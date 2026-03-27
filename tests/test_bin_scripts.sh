#!/bin/bash
# test_bin_scripts.sh — Integration tests for bin/ scripts
# Tests quality-gate.sh, keep-working.sh, dashboard.sh, usage-report.sh
# Run: bash tests/test_bin_scripts.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# ===== Test Framework =====
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

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    TOTAL=$((TOTAL + 1))
    if echo "$haystack" | grep -qF "$needle"; then
        PASS=$((PASS + 1))
        echo "  PASS: $desc"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $desc (expected to contain '$needle')"
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    TOTAL=$((TOTAL + 1))
    if ! echo "$haystack" | grep -qF "$needle"; then
        PASS=$((PASS + 1))
        echo "  PASS: $desc"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $desc (should NOT contain '$needle')"
    fi
}

# Helper: run a bin script with CLAUDE_PROJECT_DIR set and optional stdin
run_script() {
    local proj="$1" script="$2" input="$3"
    shift 3
    (export CLAUDE_PROJECT_DIR="$proj"; echo "$input" | bash "$script" "$@")
}

# ===== Shared temp dir =====
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-bin-XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT

# ===== quality-gate.sh =====
echo "=== quality-gate.sh ==="

QG="$PROJECT_DIR/bin/quality-gate.sh"

# Test: exits 0 when no test commands are detected (no matching project files)
GATE_PROJ="$TEST_TMP/gate-proj"
mkdir -p "$GATE_PROJ/.claude/state"
QG_EXIT=0
run_script "$GATE_PROJ" "$QG" '{"teammate_name":"alice","team_name":"test","task_subject":"fix bug"}' >/dev/null 2>&1 || QG_EXIT=$?
assert_eq "exit 0 when no tests detected" "0" "$QG_EXIT"

# Test: exits 2 when test command fails
FAIL_PROJ="$TEST_TMP/fail-proj"
mkdir -p "$FAIL_PROJ/.claude/state"
printf 'test:\n\t@exit 1\n' > "$FAIL_PROJ/Makefile"
QG_FAIL_EXIT=0
run_script "$FAIL_PROJ" "$QG" '{"teammate_name":"bob","team_name":"test","task_subject":"failing task"}' >/dev/null 2>&1 || QG_FAIL_EXIT=$?
assert_eq "exits 2 when test fails" "2" "$QG_FAIL_EXIT"

# Verify retry file was created
if command -v sha256sum &>/dev/null; then
    TASK_HASH=$(echo "test:failing task" | sha256sum | cut -c1-16)
elif command -v shasum &>/dev/null; then
    TASK_HASH=$(echo "test:failing task" | shasum -a 256 | cut -c1-16)
else
    TASK_HASH=$(echo "test:failing task" | cksum | cut -d' ' -f1)
fi
RETRY_FILE="$FAIL_PROJ/.claude/state/retry-${TASK_HASH}"
assert_ok "retry file created after failure" test -f "$RETRY_FILE"

# Test: force-passes (exits 0) after MAX_RETRIES
FORCE_PROJ="$TEST_TMP/force-proj"
mkdir -p "$FORCE_PROJ/.claude/state"
printf 'test:\n\t@exit 1\n' > "$FORCE_PROJ/Makefile"
if command -v sha256sum &>/dev/null; then
    FORCE_HASH=$(echo "test:force task" | sha256sum | cut -c1-16)
elif command -v shasum &>/dev/null; then
    FORCE_HASH=$(echo "test:force task" | shasum -a 256 | cut -c1-16)
else
    FORCE_HASH=$(echo "test:force task" | cksum | cut -d' ' -f1)
fi
echo "5" > "$FORCE_PROJ/.claude/state/retry-${FORCE_HASH}"
FORCE_EXIT=0
(export CLAUDE_PROJECT_DIR="$FORCE_PROJ" QUALITY_GATE_MAX_RETRIES=5; \
 echo '{"teammate_name":"carol","team_name":"test","task_subject":"force task"}' | bash "$QG") >/dev/null 2>&1 || FORCE_EXIT=$?
assert_eq "force-passes at MAX_RETRIES" "0" "$FORCE_EXIT"

# Test: path traversal in TEAMMATE_NAME doesn't escape STATE_DIR
SAFE_PROJ="$TEST_TMP/safe-proj"
mkdir -p "$SAFE_PROJ/.claude/state"
run_script "$SAFE_PROJ" "$QG" '{"teammate_name":"../../../tmp/pwned","team_name":"test","task_subject":"safe"}' >/dev/null 2>&1 || true
# The status file should be in the state dir, not escaped
TOTAL=$((TOTAL + 1))
if ls /tmp/pwned*.json 2>/dev/null | grep -q .; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: path traversal created file outside STATE_DIR"
else
    PASS=$((PASS + 1))
    echo "  PASS: path traversal TEAMMATE_NAME is sanitized"
fi

# ===== keep-working.sh =====
echo ""
echo "=== keep-working.sh ==="

KW="$PROJECT_DIR/bin/keep-working.sh"

# Test: exits 0 at MAX_ROUNDS limit
KW_PROJ="$TEST_TMP/kw-proj"
mkdir -p "$KW_PROJ/.claude/state"
echo "50" > "$KW_PROJ/.claude/state/round-kwtest-dave"
KW_MAX_EXIT=0
(export CLAUDE_PROJECT_DIR="$KW_PROJ" AI_PIPELINE_MAX_ROUNDS=50; \
 echo '{"teammate_name":"dave","team_name":"kwtest","teammate_role":"fixer"}' | bash "$KW") >/dev/null 2>&1 || KW_MAX_EXIT=$?
assert_eq "exits 0 at MAX_ROUNDS" "0" "$KW_MAX_EXIT"

# Test: exits 2 when tasks remain
KW_TASK_PROJ="$TEST_TMP/kw-task"
mkdir -p "$KW_TASK_PROJ/.claude/state"
TASK_DIR_KW="${HOME:-.}/.claude/tasks/kwtask-$$"
mkdir -p "$TASK_DIR_KW"
echo '{"status":"pending","subject":"fix something"}' > "$TASK_DIR_KW/task1.json"
KW_TASKS_EXIT=0
(export CLAUDE_PROJECT_DIR="$KW_TASK_PROJ"; \
 echo "{\"teammate_name\":\"eve\",\"team_name\":\"kwtask-$$\",\"teammate_role\":\"fixer\"}" | bash "$KW") >/dev/null 2>&1 || KW_TASKS_EXIT=$?
assert_eq "exits 2 when tasks remain" "2" "$KW_TASKS_EXIT"
rm -rf "$TASK_DIR_KW"

# Test: discoverer exits 2 (auto-restart) after role_limit=3 rounds
KW_DISC_PROJ="$TEST_TMP/kw-disc"
mkdir -p "$KW_DISC_PROJ/.claude/state"
echo "4" > "$KW_DISC_PROJ/.claude/state/round-kwdisc-frank"
KW_DISC_EXIT=0
(export CLAUDE_PROJECT_DIR="$KW_DISC_PROJ" AI_PIPELINE_MAX_ROUNDS=50; \
 echo '{"teammate_name":"frank","team_name":"kwdisc","teammate_role":"discoverer"}' | bash "$KW") >/dev/null 2>&1 || KW_DISC_EXIT=$?
assert_eq "discoverer exits 2 (auto-restart) after role_limit=3" "2" "$KW_DISC_EXIT"

# Test: fixer exits 2 when active (has rounds remaining)
KW_ACTIVE_PROJ="$TEST_TMP/kw-active"
mkdir -p "$KW_ACTIVE_PROJ/.claude/state"
echo "1" > "$KW_ACTIVE_PROJ/.claude/state/round-kwactive-grace"
KW_ACTIVE_EXIT=0
(export CLAUDE_PROJECT_DIR="$KW_ACTIVE_PROJ" AI_PIPELINE_MAX_ROUNDS=50; \
 echo '{"teammate_name":"grace","team_name":"kwactive","teammate_role":"fixer"}' | bash "$KW") >/dev/null 2>&1 || KW_ACTIVE_EXIT=$?
assert_eq "exits 2 when fixer has rounds remaining" "2" "$KW_ACTIVE_EXIT"

# ===== usage-report.sh =====
echo ""
echo "=== usage-report.sh ==="

UR="$PROJECT_DIR/bin/usage-report.sh"

# Test: exits 0 and prints message with no usage file
UR_EMPTY="$TEST_TMP/ur-empty"
mkdir -p "$UR_EMPTY/.claude/state"
UR_EMPTY_OUTPUT=$(CLAUDE_PROJECT_DIR="$UR_EMPTY" bash "$UR" 2>/dev/null)
UR_EMPTY_EXIT=$?
assert_eq "exits 0 with no usage file" "0" "$UR_EMPTY_EXIT"
assert_contains "no data message shown" "没有用量数据" "$UR_EMPTY_OUTPUT"

# Test: exits 0 and generates report with usage data
UR_DATA="$TEST_TMP/ur-data"
mkdir -p "$UR_DATA/.claude/state"
cat > "$UR_DATA/.claude/state/usage.jsonl" <<'EOF'
{"ts":"2026-01-01T12:00:00Z","hook":"quality-gate","teammate":"alice","role":"fixer","action":"pass","duration_s":3}
{"ts":"2026-01-01T12:01:00Z","hook":"keep-working","teammate":"bob","role":"reviewer","action":"claim_task","duration_s":1}
EOF
UR_DATA_OUTPUT=$(CLAUDE_PROJECT_DIR="$UR_DATA" bash "$UR" 2>/dev/null)
UR_DATA_EXIT=$?
assert_eq "exits 0 with usage data" "0" "$UR_DATA_EXIT"
assert_contains "report header shown" "Agent Teams" "$UR_DATA_OUTPUT"

# ===== dashboard.sh =====
echo ""
echo "=== dashboard.sh ==="

DB="$PROJECT_DIR/bin/dashboard.sh"

# Test: generates HTML file with no status data
DB_EMPTY="$TEST_TMP/db-empty"
mkdir -p "$DB_EMPTY"
DB_EMPTY_EXIT=0
(export CLAUDE_PROJECT_DIR="$DB_EMPTY"; bash "$DB") >/dev/null 2>&1 || DB_EMPTY_EXIT=$?
assert_eq "exits 0 with no state dir" "0" "$DB_EMPTY_EXIT"
assert_ok "HTML file created" test -f "$DB_EMPTY/.claude/state/dashboard.html"
DB_EMPTY_HTML=$(cat "$DB_EMPTY/.claude/state/dashboard.html" 2>/dev/null || echo "")
assert_contains "HTML doctype present" "<!DOCTYPE html>" "$DB_EMPTY_HTML"

# Test: HTML contains teammate data from status file
DB_DATA="$TEST_TMP/db-data"
mkdir -p "$DB_DATA/.claude/state"
cat > "$DB_DATA/.claude/state/status-alice.json" <<'EOF'
{"teammate":"alice","role":"fixer","round":3,"max_rounds":50,"action":"working","detail":"fixing bug","status":"working","ts":"2026-01-01T12:00:00Z"}
EOF
DB_DATA_EXIT=0
(export CLAUDE_PROJECT_DIR="$DB_DATA"; bash "$DB") >/dev/null 2>&1 || DB_DATA_EXIT=$?
assert_eq "exits 0 with status data" "0" "$DB_DATA_EXIT"
DB_DATA_HTML=$(cat "$DB_DATA/.claude/state/dashboard.html" 2>/dev/null || echo "")
assert_contains "teammate shown in HTML" "alice" "$DB_DATA_HTML"

# Test: XSS — raw <script> tag must not appear unescaped in HTML output
DB_XSS="$TEST_TMP/db-xss"
mkdir -p "$DB_XSS/.claude/state"
cat > "$DB_XSS/.claude/state/status-xss.json" <<'EOF'
{"teammate":"<script>alert(1)</script>","role":"fixer","round":1,"max_rounds":50,"action":"working","detail":"<img src=x>","status":"working","ts":"2026-01-01T12:00:00Z"}
EOF
(export CLAUDE_PROJECT_DIR="$DB_XSS"; bash "$DB") >/dev/null 2>&1 || true
DB_XSS_HTML=$(cat "$DB_XSS/.claude/state/dashboard.html" 2>/dev/null || echo "")
assert_not_contains "XSS: script tag escaped in HTML" "<script>alert(1)</script>" "$DB_XSS_HTML"

# ===== start-pipeline.sh =====
echo ""
echo "=== start-pipeline.sh ==="

SP="$PROJECT_DIR/bin/start-pipeline.sh"

# Test: check_prerequisites fails when jq is missing
# Override `command` via exported function so `command -v jq` returns false,
# while all other `command -v` calls (claude, tmux) use real lookup.
SP_NOJQ="$TEST_TMP/sp-nojq"
mkdir -p "$SP_NOJQ/fake-bin"
printf '#!/bin/sh\ntrue\n' > "$SP_NOJQ/fake-bin/claude"
chmod +x "$SP_NOJQ/fake-bin/claude"
SP_NOJQ_EXIT=0
(
  command() {
    if [ "${1:-}" = "-v" ] && [ "${2:-}" = "jq" ]; then return 1; fi
    builtin command "$@"
  }
  export -f command
  export PATH="$SP_NOJQ/fake-bin:$PATH"
  bash "$SP" 2>/dev/null
) || SP_NOJQ_EXIT=$?
assert_eq "check_prerequisites exits 1 when jq missing" "1" "$SP_NOJQ_EXIT"


echo ""
echo "=========================================="
echo "  Results: $PASS passed, $FAIL failed, $TOTAL total"
echo "=========================================="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
