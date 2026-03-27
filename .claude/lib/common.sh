#!/bin/bash
# common.sh — Agent Teams 共享函数库
# This file must be sourced, not executed directly.
[[ "${BASH_SOURCE[0]}" != "${0}" ]] || { echo "Error: source this file, don't execute it directly" >&2; exit 1; }
#
# 两个 Hook 脚本 source 此文件，统一：
# - 跨平台锁（flock / mkdir 降级）
# - POSIX JSON 解析（不依赖 grep -P）
# - 安全命令执行（不用 eval）
# - 项目类型检测（单一源）
# - 结构化日志 + DEBUG 模式
# - 原子文件写入

# ===== 日志 =====
# 用法: log_info "message"
# DEBUG=1 时输出 debug 日志
_LOG_PREFIX="${TEAMMATE_NAME:-agent}"
_LOG_LEVEL="${LOG_LEVEL:-INFO}"  # DEBUG, INFO, WARN, ERROR

_log() {
    local level="$1" msg="$2"
    local ts
    ts=$(date '+%H:%M:%S')
    echo "[$ts][$level][$_LOG_PREFIX] $msg" >&2

    # 持久化到日志文件
    if [ -n "${STATE_DIR:-}" ]; then
        local logfile="${STATE_DIR}/hook.log"
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [$level][$_LOG_PREFIX] $msg" >> "$logfile" 2>/dev/null
    fi
}
log_debug() { [ "$_LOG_LEVEL" = "DEBUG" ] && _log "DEBUG" "$1" || true; }
log_info()  { _log "INFO" "$1"; }
log_warn()  { _log "WARN" "$1"; }
log_error() { _log "ERROR" "$1"; }

# ===== 跨平台文件锁 =====
# macOS 没有 flock，用 mkdir 原子操作降级
# 用法: portable_lock "$lockfile" && ... ; portable_unlock "$lockfile"

_HAS_FLOCK=""
_check_flock() {
    if [ -z "$_HAS_FLOCK" ]; then
        if command -v flock &>/dev/null; then
            _HAS_FLOCK="yes"
        else
            _HAS_FLOCK="no"
        fi
    fi
}

# Map lockfile path → assigned FD (bash 4+ associative array)
declare -A _LOCK_FDS 2>/dev/null || true

portable_lock() {
    local lockfile="$1" timeout="${2:-5}"
    _check_flock

    if [ "$_HAS_FLOCK" = "yes" ]; then
        # Use bash {var}> auto-FD assignment to avoid hardcoded FD 200 conflicts
        # when multiple lockfiles are held concurrently.
        local fd
        exec {fd}>"$lockfile"
        if flock -w "$timeout" "$fd"; then
            _LOCK_FDS["$lockfile"]="$fd"
            return 0
        else
            exec {fd}>&-
            return 1
        fi
    else
        # mkdir 原子降级（POSIX 兼容）
        local deadline=$(($(date +%s) + timeout))
        while ! mkdir "$lockfile.d" 2>/dev/null; do
            if [ "$(date +%s)" -ge "$deadline" ]; then
                log_warn "Lock timeout: $lockfile"
                # 清理死锁：检查持有者 PID 是否存活
                if [ -d "$lockfile.d" ]; then
                    local holder_pid lock_age
                    holder_pid=$(cat "$lockfile.d/pid" 2>/dev/null || echo "")
                    lock_age=$(( $(date +%s) - $(stat -c %Y "$lockfile.d" 2>/dev/null || stat -f %m "$lockfile.d" 2>/dev/null || echo 0) ))
                    if [ "$lock_age" -gt 60 ] && { [ -z "$holder_pid" ] || ! kill -0 "$holder_pid" 2>/dev/null; }; then
                        rm -rf "$lockfile.d" 2>/dev/null
                        continue
                    fi
                fi
                return 1
            fi
            sleep 0.1 2>/dev/null || sleep 1
        done
        # 写入 PID 用于死锁检测
        echo $$ > "$lockfile.d/pid" 2>/dev/null
        return 0
    fi
}

portable_unlock() {
    local lockfile="$1"
    _check_flock

    if [ "$_HAS_FLOCK" = "yes" ]; then
        local fd="${_LOCK_FDS[$lockfile]:-}"
        if [ -n "$fd" ]; then
            exec {fd}>&-
            unset '_LOCK_FDS[$lockfile]'
        fi
    else
        rm -rf "$lockfile.d" 2>/dev/null
    fi
}

# ===== POSIX JSON 解析（不用 grep -P / jq 降级）=====
# 用法: json_field "$json_string" "field_name"

json_field() {
    local json="$1" field="$2" default="${3:-}"

    if command -v jq &>/dev/null; then
        local val
        val=$(echo "$json" | jq -r ".$field // \"\"" 2>/dev/null)
        [ -n "$val" ] && [ "$val" != "null" ] && { echo "$val"; return; }
    fi

    # POSIX sed 降级（兼容 macOS + Linux）
    # 先将转义引号 \" 替换为占位符，匹配后还原，避免截断
    local val
    val=$(printf '%s' "$json" | sed 's/\\"/\\u0022/g' | sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | sed 's/\\u0022/"/g' | head -1)
    [ -n "$val" ] && { echo "$val"; return; }


    # Fallback: unquoted numeric/boolean value
    if [ -z "$val" ]; then
        val=$(echo "$json" | sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\([^,}[:space:]]*\).*/\1/p" | head -1)
        val="${val#\"}"
        val="${val%\"}"
    fi
    [ -n "$val" ] && { echo "$val"; return; }

    echo "$default"
}

# ===== 安全命令执行（不用 eval）=====
# 用法: safe_run "cargo test" output_file
# 返回: 命令的退出码

safe_run() {
    local cmd_str="$1" outfile="${2:-/dev/null}" max_time="${3:-${SAFE_RUN_TIMEOUT:-120}}"

    # Only accept commands set internally by detect_project (hardcoded strings).
    # bash -c -- prevents the string from being interpreted as bash options.
    # Timeout prevents hanging tests from blocking the hook forever.
    if command -v timeout &>/dev/null; then
        timeout "$max_time" bash -c -- "$cmd_str" > "$outfile" 2>&1
    elif command -v gtimeout &>/dev/null; then
        gtimeout "$max_time" bash -c -- "$cmd_str" > "$outfile" 2>&1
    else
        # macOS fallback: background + kill
        bash -c -- "$cmd_str" > "$outfile" 2>&1 &
        local pid=$!
        local elapsed=0
        while kill -0 "$pid" 2>/dev/null; do
            if [ "$elapsed" -ge "$max_time" ]; then
                kill -TERM "$pid" 2>/dev/null
                wait "$pid" 2>/dev/null
                log_warn "Command timed out after ${max_time}s: ${cmd_str:0:60}"
                return 124
            fi
            sleep 1
            elapsed=$((elapsed + 1))
        done
        wait "$pid"
        return $?
    fi
    local rc=$?
    [ "$rc" -eq 124 ] && log_warn "Command timed out after ${max_time}s: ${cmd_str:0:60}"
    return $rc
}

# ===== 原子文件写入 =====
# 用法: atomic_write "$filepath" "$content"

atomic_write() {
    local filepath="$1" content="$2"
    local tmpfile
    tmpfile=$(mktemp "${filepath}.tmp.XXXXXX")
    if echo "$content" > "$tmpfile" && mv "$tmpfile" "$filepath"; then
        return 0
    else
        rm -f "$tmpfile"
        return 1
    fi
}

# ===== 带锁 JSONL 追加 =====
# 用法: append_jsonl "$filepath" "$json_line"

append_jsonl() {
    local filepath="$1" json_line="$2"
    local lockfile="${filepath}.lock"

    if portable_lock "$lockfile" 3; then
        echo "$json_line" >> "$filepath" 2>/dev/null
        portable_unlock "$lockfile"
    else
        # 锁失败也要写，宁可偶尔乱序不丢数据
        echo "$json_line" >> "$filepath" 2>/dev/null
    fi
}

# ===== 带锁的计数器读-改-写 =====
# 用法: locked_increment "$counter_file" "$lock_file"
# 输出: 增量后的值

locked_increment() {
    local counter_file="$1" lock_file="$2"
    local val=0

    if portable_lock "$lock_file" 5; then
        [ -f "$counter_file" ] && val=$(tr -dc '0-9' < "$counter_file" 2>/dev/null || echo 0)
        [ -z "$val" ] && val=0
        val=$((val + 1))
        echo "$val" > "$counter_file"
        portable_unlock "$lock_file"
    else
        # 锁失败时读取当前值 +1（可能不精确但不会卡死）
        log_warn "Lock failed for $counter_file, falling back to unprotected increment"
        [ -f "$counter_file" ] && val=$(tr -dc '0-9' < "$counter_file" 2>/dev/null || echo 0)
        [ -z "$val" ] && val=0
        val=$((val + 1))
        echo "$val" > "$counter_file" 2>/dev/null || log_warn "Failed to write $counter_file"
    fi
    echo "$val"
}

# ===== 带锁读取计数器 =====
locked_read() {
    local counter_file="$1" lock_file="$2"
    local val=0

    if portable_lock "$lock_file" 3; then
        [ -f "$counter_file" ] && val=$(tr -dc '0-9' < "$counter_file" 2>/dev/null || echo 0)
        [ -z "$val" ] && val=0
        portable_unlock "$lock_file"
    else
        [ -f "$counter_file" ] && val=$(tr -dc '0-9' < "$counter_file" 2>/dev/null || echo 0)
        [ -z "$val" ] && val=0
    fi
    echo "$val"
}

# ===== 项目类型检测（单一源）=====
# 设置全局变量: TEST_CMD, LINT_CMD, TYPE_CMD, INCREMENTAL_TEST_CMD, PROJECT_TYPE

detect_project() {
    TEST_CMD="" LINT_CMD="" TYPE_CMD="" INCREMENTAL_TEST_CMD="" PROJECT_TYPE="unknown"

    # 获取 git 改过的文件（增量测试用）
    local changed_files=""
    if git rev-parse --git-dir &>/dev/null; then
        changed_files=$(git diff --name-only HEAD~1 2>/dev/null || git diff --name-only --cached 2>/dev/null || echo "")
    fi

    if [ -f "Cargo.toml" ]; then
        PROJECT_TYPE="rust"
        TEST_CMD="cargo test"
        LINT_CMD="cargo clippy -- -D warnings"

    elif [ -f "go.mod" ]; then
        PROJECT_TYPE="go"
        TEST_CMD="go test ./..."
        command -v golangci-lint &>/dev/null && LINT_CMD="golangci-lint run"
        if [ -n "$changed_files" ]; then
            local go_pkgs
            go_pkgs=$(echo "$changed_files" | grep '\.go$' | xargs -I{} dirname {} 2>/dev/null | sort -u | sed 's|^|./|' | tr '\n' ' ')
            [ -n "$go_pkgs" ] && INCREMENTAL_TEST_CMD="go test $go_pkgs"
        fi

    elif [ -f "pyproject.toml" ] || [ -f "setup.py" ] || [ -f "requirements.txt" ]; then
        PROJECT_TYPE="python"
        if command -v pytest &>/dev/null; then
            TEST_CMD="pytest"
            if [ -f ".pytest_cache/v/cache/lastfailed" ]; then
                INCREMENTAL_TEST_CMD="pytest --lf --no-header -q"
            elif [ -n "$changed_files" ]; then
                local test_files=""
                while IFS= read -r f; do
                    [ -z "$f" ] && continue
                    local base
                    base=$(basename "$f" .py)
                    local found
                    found=$(find tests/ test/ -name "test_${base}.py" -o -name "${base}_test.py" 2>/dev/null | head -1)
                    [ -n "$found" ] && test_files="$test_files $found"
                done < <(echo "$changed_files" | grep '\.py$')
                [ -n "$test_files" ] && INCREMENTAL_TEST_CMD="pytest $test_files --no-header -q"
            fi
        elif [ -f "manage.py" ]; then
            TEST_CMD="python manage.py test"
        fi
        command -v ruff &>/dev/null && LINT_CMD="ruff check ."
        command -v mypy &>/dev/null && TYPE_CMD="mypy . --ignore-missing-imports"

    elif [ -f "pom.xml" ]; then
        PROJECT_TYPE="java-maven"
        TEST_CMD="mvn test -q"
        LINT_CMD="mvn checkstyle:check -q 2>/dev/null || true"

    elif [ -f "build.gradle" ] || [ -f "build.gradle.kts" ]; then
        PROJECT_TYPE="java-gradle"
        TEST_CMD="./gradlew test"
        LINT_CMD="./gradlew ktlintCheck 2>/dev/null || ./gradlew checkstyleMain 2>/dev/null || true"

    elif [ -f "composer.json" ]; then
        PROJECT_TYPE="php"
        [ -f "vendor/bin/phpunit" ] && TEST_CMD="vendor/bin/phpunit"
        [ -f "vendor/bin/pest" ] && TEST_CMD="vendor/bin/pest"
        [ -f "vendor/bin/phpstan" ] && LINT_CMD="vendor/bin/phpstan analyse"

    elif [ -f "Gemfile" ]; then
        PROJECT_TYPE="ruby"
        grep -q "rspec" Gemfile 2>/dev/null && TEST_CMD="bundle exec rspec"
        [ -f "bin/rails" ] && [ -z "$TEST_CMD" ] && TEST_CMD="bundle exec rails test"
        grep -q "rubocop" Gemfile 2>/dev/null && LINT_CMD="bundle exec rubocop"

    elif find . -maxdepth 1 \( -name '*.sln' -o -name '*.csproj' \) -print -quit 2>/dev/null | grep -q .; then
        PROJECT_TYPE="dotnet"
        TEST_CMD="dotnet test"
        LINT_CMD="dotnet format --verify-no-changes 2>/dev/null || true"

    elif [ -f "Package.swift" ]; then
        PROJECT_TYPE="swift"
        TEST_CMD="swift test"
        command -v swiftlint &>/dev/null && LINT_CMD="swiftlint"

    elif [ -f "pubspec.yaml" ]; then
        PROJECT_TYPE="flutter"
        TEST_CMD="flutter test"
        LINT_CMD="dart analyze"

    elif [ -f "CMakeLists.txt" ]; then
        PROJECT_TYPE="cpp-cmake"
        [ -d "build" ] && TEST_CMD="ctest --test-dir build"

    elif [ -f "Makefile" ] && grep -q "^test:" Makefile 2>/dev/null; then
        PROJECT_TYPE="makefile"
        TEST_CMD="make test"
        grep -q "^lint:" Makefile 2>/dev/null && LINT_CMD="make lint"

    elif [ -f "package.json" ]; then
        PROJECT_TYPE="node"
        grep -q '"test"' package.json 2>/dev/null && TEST_CMD="npm test"
        grep -q '"lint"' package.json 2>/dev/null && LINT_CMD="npm run lint"
        # shellcheck disable=SC2034
        grep -q '"typecheck"' package.json 2>/dev/null && TYPE_CMD="npm run typecheck"
        if [ -n "$changed_files" ] && grep -q '"jest"' package.json 2>/dev/null; then
            # shellcheck disable=SC2034
            INCREMENTAL_TEST_CMD="npx jest --changedSince=HEAD~1 --passWithNoTests"
        fi
    fi

    # Allow environment overrides
    [ -n "${AGENT_TEAMS_TEST_CMD:-}" ] && TEST_CMD="$AGENT_TEAMS_TEST_CMD"
    [ -n "${AGENT_TEAMS_LINT_CMD:-}" ] && LINT_CMD="$AGENT_TEAMS_LINT_CMD"

    log_debug "detect_project: type=$PROJECT_TYPE test='${TEST_CMD:-none}' lint='${LINT_CMD:-none}'"
}

# ===== 角色轮次上限 =====
# 用法: role_limit "$role"
# 输出: 该角色的最大轮次数

role_limit() {
    case "$1" in
        discoverer) echo 3 ;; fixer) echo 5 ;; reviewer) echo 3 ;;
        designer)   echo 2 ;; releaser) echo 2 ;; strategist) echo 2 ;;
        *)          log_warn "Unknown role '$1', defaulting to limit=1"; echo 1 ;;
    esac
}

# ===== 角色识别 =====
detect_role() {
    local teammate_name="$1" explicit_role="${2:-}"

    [ -n "$explicit_role" ] && { echo "$explicit_role"; return; }

    local name_lower
    name_lower=$(echo "$teammate_name" | tr '[:upper:]' '[:lower:]')

    case "$name_lower" in
        *discover*|qa|*"_qa"*|*"qa_"*|*"qa-"*|*"-qa"*|*探测*|*发现*|*测试*)
            echo "discoverer" ;;
        *fixer*|*修复*|*开发*|*developer*|*implementer*|*coder*)
            echo "fixer" ;;
        *review*|*审查*|*质检*|*auditor*|*checker*)
            echo "reviewer" ;;
        *design*|*设计*|*visual*|*"_ui"*|*"ui_"*|*"_ux"*|*"ux_"*)
            echo "designer" ;;
        *release*|*发布*|*deploy*|*ship*|*ops*)
            echo "releaser" ;;
        *strateg*|*规划*|*plan*|*architect*|*lead*|*战略*)
            echo "strategist" ;;
        *)
            echo "unknown" ;;
    esac
}

# ===== 状态目录初始化 =====
init_state_dir() {
    local project_dir="${1:-$PROJECT_DIR}"
    STATE_DIR="$project_dir/.claude/state"
    mkdir -p "$STATE_DIR"

    # 清理 7 天前的临时文件
    find "${TMPDIR:-/tmp}" -maxdepth 1 -name "gate-*" -type d -mtime +7 -exec rm -rf {} + 2>/dev/null || true
    find "$STATE_DIR" -name "tmp-*" -mtime +7 -delete 2>/dev/null || true

    # 日志文件轮转：超过 10MB 时截断（所有可增长的状态文件）
    local _rotate_file
    for _rotate_file in "$STATE_DIR/hook.log" "$STATE_DIR/usage.jsonl" "$STATE_DIR/discoveries.jsonl" "$STATE_DIR/progress.log" "$STATE_DIR/commits.log"; do
        if [ -f "$_rotate_file" ]; then
            local size
            size=$(stat -c%s "$_rotate_file" 2>/dev/null || stat -f%z "$_rotate_file" 2>/dev/null || echo 0)
            if [ "$size" -gt 10485760 ]; then
                tail -5000 "$_rotate_file" > "$_rotate_file.tmp" && mv "$_rotate_file.tmp" "$_rotate_file"
            fi
        fi
    done
}

# ===== 写入 Teammate 状态（仪表盘用）=====
write_teammate_status() {
    local teammate="$1" role="$2" action="$3" detail="${4:-}" round="${5:-0}" max="${6:-50}"
    local ts json
    command -v jq &>/dev/null || { log_error "jq required"; return 1; }
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    json=$(jq -cn \
        --arg teammate "$teammate" \
        --arg role "$role" \
        --argjson round "$round" \
        --argjson max_rounds "$max" \
        --arg action "$action" \
        --arg detail "$detail" \
        --arg ts "$ts" \
        '{teammate:$teammate,role:$role,round:$round,max_rounds:$max_rounds,action:$action,detail:$detail,status:$action,ts:$ts}')
    atomic_write "${STATE_DIR}/status-${teammate}.json" "$json"
}

# ===== 用量追踪 =====
track_usage() {
    local hook="$1" teammate="$2" role="${3:-}" action="${4:-}" duration="${5:-0}"
    local extra="${6:-}"
    local ts json
    command -v jq &>/dev/null || { log_error "jq required"; return 1; }
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    json=$(jq -cn \
        --arg ts "$ts" \
        --arg hook "$hook" \
        --arg teammate "$teammate" \
        --arg role "$role" \
        --arg action "$action" \
        --argjson duration_s "$duration" \
        '{ts:$ts,hook:$hook,teammate:$teammate,role:$role,action:$action,duration_s:$duration_s}')
    # Append extra fields if provided (must be a complete JSON object, e.g. '{"round":3}')
    [ -n "$extra" ] && json=$(echo "$json" | jq -c --argjson extra "$extra" '. + $extra')
    append_jsonl "${STATE_DIR}/usage.jsonl" "$json"
}

# ===== State Persistence (Context Management) =====
# All progress lives on disk, not in agent context.
# Agents are stateless — they recover by reading these files.

# Write a progress entry when a role completes a cycle
# Usage: write_progress "$role" "$round" "$summary"
# Requires: STATE_DIR set by init_state_dir
write_progress() {
    [ -n "${STATE_DIR:-}" ] || return 1
    local role="${1:-unknown}" round="${2:-0}" summary="${3:-}"
    local progress_file="${STATE_DIR}/progress.log"
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    echo "${ts} [${role}:${round}] ${summary}" >> "$progress_file"
}

# Read last N progress entries (default 10)
# Usage: entries=$(read_progress 5)
read_progress() {
    local n="${1:-10}"
    local progress_file="${STATE_DIR}/progress.log"
    tail -n "$n" "$progress_file" 2>/dev/null || echo "(no progress yet)"
}

# Append a discovery to the JSONL log
# Usage: write_discovery "$role" "$priority" "$description"
write_discovery() {
    [ -n "${STATE_DIR:-}" ] || return 1
    local role="${1:-unknown}" priority="${2:-P2}" description="${3:-}"
    local discoveries_file="${STATE_DIR}/discoveries.jsonl"
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local line
    if command -v jq &>/dev/null; then
        line=$(jq -cn --arg ts "$ts" --arg r "$role" --arg p "$priority" --arg d "$description" \
            '{ts:$ts,role:$r,priority:$p,description:$d,resolved:false}')
    else
        # Escape backslashes, quotes, newlines, tabs, carriage returns for JSON safety
        local safe_desc="${description//\\/\\\\}"
        safe_desc="${safe_desc//\"/\\\"}"
        safe_desc="${safe_desc//$'\n'/\\n}"
        safe_desc="${safe_desc//$'\t'/\\t}"
        safe_desc="${safe_desc//$'\r'/\\r}"
        line="{\"ts\":\"${ts}\",\"role\":\"${role}\",\"priority\":\"${priority}\",\"description\":\"${safe_desc}\",\"resolved\":false}"
    fi
    echo "$line" >> "$discoveries_file"
}

# Count unresolved discoveries
# Usage: count=$(count_open_discoveries)
count_open_discoveries() {
    [ -n "${STATE_DIR:-}" ] || { echo "0"; return; }
    local discoveries_file="${STATE_DIR}/discoveries.jsonl"
    if [ ! -f "$discoveries_file" ]; then
        echo "0"
        return
    fi
    grep -c '"resolved":false' "$discoveries_file" 2>/dev/null || echo "0"
}

# Log a commit for tracking
# Usage: write_commit_log "$role" "$commit_hash" "$message"
write_commit_log() {
    [ -n "${STATE_DIR:-}" ] || return 1
    local role="${1:-unknown}" hash="${2:-}" message="${3:-}"
    local commits_file="${STATE_DIR}/commits.log"
    local ts line
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    if command -v jq &>/dev/null; then
        line=$(jq -cn --arg ts "$ts" --arg r "$role" --arg h "${hash:0:8}" --arg m "$message" \
            '{ts:$ts,role:$r,hash:$h,message:$m}')
    else
        local safe_msg="${message//\\/\\\\}"
        safe_msg="${safe_msg//\"/\\\"}"
        safe_msg="${safe_msg//$'\n'/\\n}"
        safe_msg="${safe_msg//$'\t'/\\t}"
        safe_msg="${safe_msg//$'\r'/\\r}"
        line="{\"ts\":\"${ts}\",\"role\":\"${role}\",\"hash\":\"${hash:0:8}\",\"message\":\"${safe_msg}\"}"
    fi
    echo "$line" >> "$commits_file"
}

# Generate a 1-line state summary for hook output
# Usage: summary=$(state_summary)
state_summary() {
    local tasks_pending=0 tasks_done=0 discoveries=0 commits=0
    local task_dir="${HOME:-.}/.claude/tasks"

    if [ -d "$task_dir" ]; then
        tasks_pending=$(grep -rl '"status"[[:space:]]*:[[:space:]]*"pending"' "$task_dir/" 2>/dev/null | wc -l) || tasks_pending=0
        tasks_done=$(grep -rl '"status"[[:space:]]*:[[:space:]]*"completed"' "$task_dir/" 2>/dev/null | wc -l) || tasks_done=0
        tasks_pending="${tasks_pending// /}"
        tasks_done="${tasks_done// /}"
    fi

    discoveries=$(count_open_discoveries)
    if [ -f "${STATE_DIR}/commits.log" ]; then
        commits=$(wc -l < "${STATE_DIR}/commits.log" 2>/dev/null || echo 0)
        commits="${commits// /}"
    fi

    echo "tasks:${tasks_pending}p/${tasks_done}done discoveries:${discoveries}open commits:${commits}"
}

# Reset role round counter and log progress before reset
# Usage: reset_role_cycle "$role" "$round" "$reason"
reset_role_cycle() {
    local role="${1:-unknown}" round="${2:-0}" reason="${3:-cycle_complete}"
    local round_file="${STATE_DIR}/round-${TEAM_NAME:-default}-${TEAMMATE_NAME:-unknown}"

    write_progress "$role" "$round" "$reason — $(state_summary)"
    rm -f "$round_file"
}

# ===== Shutdown sentinel =====
# Lead writes this file to signal all hooks to stop gracefully.
# Usage: is_shutdown "$team_name" → returns 0 if shutdown requested
# Usage: write_shutdown_sentinel "$team_name"

is_shutdown() {
    local team="${1:-default}"
    [ -f "${STATE_DIR}/shutdown-${team}" ]
}

write_shutdown_sentinel() {
    local team="${1:-default}"
    [ -n "${STATE_DIR:-}" ] || return 1
    date -u +%Y-%m-%dT%H:%M:%SZ > "${STATE_DIR}/shutdown-${team}"
    log_info "Shutdown sentinel written for team: $team"
}
