#!/bin/bash
# common.sh — Agent Teams 共享函数库
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
log_debug() { [ "$_LOG_LEVEL" = "DEBUG" ] && _log "DEBUG" "$1"; }
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

portable_lock() {
    local lockfile="$1" timeout="${2:-5}"
    _check_flock

    if [ "$_HAS_FLOCK" = "yes" ]; then
        exec 200>"$lockfile"
        flock -w "$timeout" 200
        return $?
    else
        # mkdir 原子降级（POSIX 兼容）
        local deadline=$(($(date +%s) + timeout))
        while ! mkdir "$lockfile.d" 2>/dev/null; do
            if [ "$(date +%s)" -ge "$deadline" ]; then
                log_warn "Lock timeout: $lockfile"
                # 清理可能的死锁（超过 60s 的锁）
                if [ -d "$lockfile.d" ]; then
                    local lock_age
                    lock_age=$(( $(date +%s) - $(stat -c %Y "$lockfile.d" 2>/dev/null || stat -f %m "$lockfile.d" 2>/dev/null || echo 0) ))
                    if [ "$lock_age" -gt 60 ]; then
                        rmdir "$lockfile.d" 2>/dev/null
                        continue
                    fi
                fi
                return 1
            fi
            sleep 0.1 2>/dev/null || sleep 1
        done
        return 0
    fi
}

portable_unlock() {
    local lockfile="$1"
    _check_flock

    if [ "$_HAS_FLOCK" = "yes" ]; then
        exec 200>&-
    else
        rmdir "$lockfile.d" 2>/dev/null
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
    local val
    val=$(echo "$json" | sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1)
    [ -n "$val" ] && { echo "$val"; return; }

    echo "$default"
}

# ===== 安全命令执行（不用 eval）=====
# 用法: safe_run "cargo test" output_file
# 返回: 命令的退出码

safe_run() {
    local cmd_str="$1" outfile="${2:-/dev/null}"

    # 用 bash -c 隔离执行，避免当前 shell 的变量注入
    bash -c "$cmd_str" > "$outfile" 2>&1
    return $?
}

# ===== 原子文件写入 =====
# 用法: atomic_write "$filepath" "$content"

atomic_write() {
    local filepath="$1" content="$2"
    local tmpfile="${filepath}.tmp.$$"
    echo "$content" > "$tmpfile" && mv "$tmpfile" "$filepath"
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
        [ -f "$counter_file" ] && val=$(cat "$counter_file" 2>/dev/null || echo 0)
        val=$((val + 1))
        echo "$val" > "$counter_file"
        portable_unlock "$lock_file"
    else
        # 锁失败时读取当前值 +1（可能不精确但不会卡死）
        [ -f "$counter_file" ] && val=$(cat "$counter_file" 2>/dev/null || echo 0)
        val=$((val + 1))
    fi
    echo "$val"
}

# ===== 带锁读取计数器 =====
locked_read() {
    local counter_file="$1" lock_file="$2"
    local val=0

    if portable_lock "$lock_file" 3; then
        [ -f "$counter_file" ] && val=$(cat "$counter_file" 2>/dev/null || echo 0)
        portable_unlock "$lock_file"
    else
        [ -f "$counter_file" ] && val=$(cat "$counter_file" 2>/dev/null || echo 0)
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
                for f in $(echo "$changed_files" | grep '\.py$'); do
                    local base
                    base=$(basename "$f" .py)
                    local found
                    found=$(find tests/ test/ -name "test_${base}.py" -o -name "${base}_test.py" 2>/dev/null | head -1)
                    [ -n "$found" ] && test_files="$test_files $found"
                done
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

    elif ls ./*.sln ./*.csproj 2>/dev/null | head -1 &>/dev/null; then
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
        grep -q '"typecheck"' package.json 2>/dev/null && TYPE_CMD="npm run typecheck"
        if [ -n "$changed_files" ] && grep -q '"jest"' package.json 2>/dev/null; then
            INCREMENTAL_TEST_CMD="npx jest --changedSince=HEAD~1 --passWithNoTests"
        fi
    fi

    log_debug "detect_project: type=$PROJECT_TYPE test='${TEST_CMD:-none}' lint='${LINT_CMD:-none}'"
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
    find "$STATE_DIR" -name "gate-*" -type d -mtime +7 -exec rm -rf {} + 2>/dev/null || true
    find "$STATE_DIR" -name "tmp-*" -mtime +7 -delete 2>/dev/null || true

    # 日志文件轮转：超过 10MB 时截断
    local logfile="$STATE_DIR/hook.log"
    if [ -f "$logfile" ]; then
        local size
        size=$(stat -c%s "$logfile" 2>/dev/null || stat -f%z "$logfile" 2>/dev/null || echo 0)
        if [ "$size" -gt 10485760 ]; then
            tail -5000 "$logfile" > "$logfile.tmp" && mv "$logfile.tmp" "$logfile"
        fi
    fi
}

# ===== 写入 Teammate 状态（仪表盘用）=====
write_teammate_status() {
    local teammate="$1" role="$2" action="$3" detail="${4:-}" round="${5:-0}" max="${6:-50}"
    local json="{\"teammate\":\"$teammate\",\"role\":\"$role\",\"round\":$round,\"max_rounds\":$max,\"action\":\"$action\",\"detail\":\"$detail\",\"status\":\"$action\",\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"
    atomic_write "${STATE_DIR}/status-${teammate}.json" "$json"
}

# ===== 用量追踪 =====
track_usage() {
    local hook="$1" teammate="$2" role="${3:-}" action="${4:-}" duration="${5:-0}"
    local extra="${6:-}"
    local json="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"hook\":\"$hook\",\"teammate\":\"$teammate\",\"role\":\"$role\",\"action\":\"$action\",\"duration_s\":$duration${extra:+,$extra}}"
    append_jsonl "${STATE_DIR}/usage.jsonl" "$json"
}
