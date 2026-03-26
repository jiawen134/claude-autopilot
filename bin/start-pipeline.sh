#!/bin/bash
# start-pipeline.sh — 一键启动 AI 全自动流水线
#
# 用法：
#   ./start-pipeline.sh                        # 自动发现并修复问题
#   ./start-pipeline.sh "添加用户注册功能"       # 给定目标
#   ./start-pipeline.sh --continuous            # 持续运行模式
#
# 前置条件：
#   1. 安装 tmux: sudo apt install tmux
#   2. Claude Code v2.1.32+
#   3. gstack 已安装（git clone 到 ~/.claude/skills/gstack && ./setup）
#   4. 项目已有测试和 lint 配置

set -euo pipefail

# ============ 颜色 ============
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $1"; }

# ============ 前置检查 ============
check_prerequisites() {
    log "检查前置条件..."

    if ! command -v claude &>/dev/null; then
        echo -e "${RED}错误：未安装 Claude Code${NC}"
        exit 1
    fi

    if ! command -v tmux &>/dev/null; then
        echo -e "${YELLOW}警告：未安装 tmux，将使用 in-process 模式${NC}"
    fi

    if ! command -v jq &>/dev/null; then
        echo -e "${RED}错误：未安装 jq（Hook 脚本依赖）${NC}"
        echo "  安装：sudo apt install jq (Linux) / brew install jq (macOS)"
        exit 1
    fi

    # gstack 检查
    if [ ! -d "$HOME/.claude/skills/gstack" ] && [ ! -d ".claude/skills/gstack" ]; then
        echo -e "${YELLOW}警告：gstack 未安装。安装方法：${NC}"
        echo "  git clone https://github.com/garrytan/gstack.git ~/.claude/skills/gstack"
        echo "  cd ~/.claude/skills/gstack && ./setup"
    fi

    if [ "${CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS:-}" != "1" ]; then
        export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
        log "已设置 CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1"
    fi

    log "${GREEN}前置检查通过${NC}"
}

# ============ 构建启动 Prompt ============
build_prompt() {
    local goal="${1:-}"

    if [ "$goal" = "--continuous" ]; then
        cat <<'PROMPT'
你是 AI 全自动流水线的 Team Lead。你的工作是协调团队持续改进这个项目。
这是一条持续运行的流水线。TeammateIdle Hook 会驱动每个 Teammate 持续循环。

前置：运行 /careful 启用安全护栏（防止 rm -rf、DROP TABLE 等破坏性操作）。

## 启动团队（6 个 Teammate，全部使用 Sonnet 模型）

### Teammate 1: QA 探测者 (discoverer)
角色：流水线的"输入端"——持续发现问题，喂任务给其他人。
使用的 gstack skill：
- /qa — 第1轮，用真实浏览器系统化测试，发现功能 bug
- /qa-only — 后续轮次，只出报告不改代码（避免和修复者冲突）
- /investigate — 对复杂 bug 做根因分析（四阶段：调查→分析→假设→定位）
- /browse — 手动导航页面，验证特定交互流程
- /benchmark — 检测性能回归（页面加载、Core Web Vitals、资源大小）
工作方式：
- 每发现一个问题，创建独立 Task，标注优先级：P0=崩溃/安全 > P1=功能 > P2=样式/性能 > P3=优化
- 持续循环：/qa → /benchmark → /investigate → 再 /qa ...

### Teammate 2: 修复者 (fixer)
角色：流水线的"核心引擎"——认领任务，写代码修复。
使用的 gstack skill：
- /investigate — 修复前先确认根因（Iron Law: no fixes without investigation）
- /browse — 修复后在浏览器中验证效果
工作方式：
- 按优先级从高到低认领 Task
- 先 /investigate 确认根因，再写修复代码
- 每修一个问题，单独 git commit（粒度极小）
- 修完用 /browse 在浏览器里验证
- 立刻认领下一个——TeammateIdle Hook 驱动持续工作

### Teammate 3: 代码审查官 (reviewer)
角色：流水线的"质检员"——审查每一次修复。
使用的 gstack skill：
- /review — 对修复者的代码做 Staff Engineer 级别审查，自动修复明显问题
- /cso — 安全审计（OWASP Top 10 + STRIDE 威胁模型，8/10+ 置信度门禁）
- /codex — 用 OpenAI Codex 做独立第二意见审查（交叉验证）
工作方式：
- 修复者每次提交后，运行 /review
- 每 5 次提交后，运行 /cso 做一次安全扫描
- 发现问题创建 P0/P1 Task
- 可选：/codex 对关键修复做交叉模型审查

### Teammate 4: 设计审查员 (designer)
角色：流水线的"视觉守门人"——确保 UI 质量。
使用的 gstack skill：
- /design-review — 审查线上页面的视觉质量，找到不一致、间距问题、AI slop，然后修复
- /plan-design-review — 在计划阶段审查设计方案，每个维度打分 0-10
- /design-consultation — 如果没有设计系统，创建完整的设计规范（DESIGN.md）
- /browse — 截图对比修复前后的视觉效果
工作方式：
- 第1轮：如果没有 DESIGN.md，先运行 /design-consultation 建立设计系统
- 持续：对每次 UI 相关提交运行 /design-review
- 发现视觉问题创建 P2 Task

### Teammate 5: 发布工程师 (releaser)
角色：流水线的"收尾员"——文档同步、发布、部署后监控。
使用的 gstack skill：
- /document-release — 同步 README、ARCHITECTURE、CHANGELOG 与实际代码
- /ship — 跑测试、审查覆盖率、推代码、创建 PR
- /land-and-deploy — 合并 PR、等 CI、验证生产环境
- /canary — 部署后持续监控（控制台错误、性能回归、页面故障）
- /setup-deploy — 首次运行时配置部署环境
工作方式：
- 等 P0/P1 Task 全部完成
- /document-release → /ship → /land-and-deploy → /canary
- /canary 发现问题 → 创建 P0 Task → 修复者接手

### Teammate 6: 战略规划师 (strategist)
角色：流水线的"大脑"——高层审查和方向把控。
使用的 gstack skill：
- /office-hours — 审视产品方向，问六个核心问题
- /plan-ceo-review — CEO 视角审查（找到 10 星产品）
- /plan-eng-review — 工程架构审查（数据流、边界、测试覆盖）
- /autoplan — 一键跑完 CEO→设计→工程 三轮审查
- /retro — 周度复盘（提交统计、测试健康、改进趋势）
工作方式：
- 第1轮：/autoplan 对当前项目状态做全面审查
- 生成战略级 Task（架构改进、技术债务、产品方向）
- 每轮结束：/retro 生成复盘报告

## 任务依赖关系

- 修复任务 blockedBy 对应的发现任务
- 审查任务 blockedBy 对应的修复任务
- 设计审查 blockedBy 对应的 UI 修复任务
- /ship blockedBy 所有 P0/P1 修复 + /cso 安全审计 + /review 代码审查
- /land-and-deploy blockedBy /ship
- /canary blockedBy /land-and-deploy

## 工作规则

1. 使用 Delegate Mode（Shift+Tab）——你自己不写代码，只协调
2. 全部 6 个 Teammate 使用 Sonnet 模型并行工作
3. 你（Lead）负责：初始运行 /careful, /setup-browser-cookies, /setup-deploy
4. 持续循环：发现 → 修复 → 审查 → 设计审查 → 发布 → 监控 → 再发现...
5. TaskCompleted Hook 自动验证测试通过才允许标记完成
6. TeammateIdle Hook 驱动每个 Teammate 持续工作，直到安全阀触发

开始吧！
PROMPT

    elif [ -n "$goal" ] && [ "$goal" != "--once" ]; then
        # [Fix #5] 目标模式也统一用 gstack skill
        goal=$(printf '%s' "$goal" | tr -d '`$')
        cat <<PROMPT
你是 AI 全自动流水线的 Team Lead。目标：$goal

前置：运行 /careful 启用安全护栏。

## 启动团队（4 个 Teammate，Sonnet 模型）

### Teammate 1: 架构师 (strategist)
- 运行 /office-hours 梳理需求
- 运行 /plan-eng-review 设计架构
- 将实现计划拆分为可执行的 Tasks

### Teammate 2: 开发者 (fixer)
- 认领 Tasks，写代码实现
- 每个功能点独立 commit
- 用 /investigate 排查问题
- 用 /browse 验证效果

### Teammate 3: 质量官 (reviewer)
- /review 审查每个提交
- /cso 安全扫描
- /qa 浏览器端到端测试
- 发现问题创建新 Task

### Teammate 4: 发布者 (releaser)
- 所有 Tasks 完成后 /document-release
- /ship 创建 PR
- /land-and-deploy 部署
- /canary 部署后监控

## 规则
- 使用 Delegate Mode
- 任务设依赖：架构 → 开发 → 审查 → 发布
- 所有提交必须通过测试

开始！
PROMPT

    else
        # --once 模式：跑一轮发现+修复（也用 gstack skill）
        cat <<'PROMPT'
你是 AI 全自动流水线的 Team Lead。跑一轮完整的 发现→修复→验证 循环。

前置：运行 /careful 启用安全护栏。

创建 3 个 Teammate（Sonnet 模型）：

### Teammate 1: 发现者 (discoverer)
- /qa 浏览器系统化测试
- /investigate 根因分析
- 把每个问题创建为 Tasks

### Teammate 2: 修复者 (fixer)
- 认领 Tasks，修复代码
- 每个问题独立 commit
- /browse 验证修复效果

### Teammate 3: 审查者 (reviewer)
- /review 代码审查
- /cso 安全检查
- 确认后 /document-release 更新文档

使用 Delegate Mode。开始！
PROMPT
    fi
}

# ============ 主程序 ============

main() {
    local goal="${1:---once}"

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   AI 全自动编程流水线 — Agent Teams      ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo ""

    check_prerequisites

    local mode_label
    if [ "$goal" = "--continuous" ]; then
        mode_label="持续运行"
    elif [ "$goal" = "--once" ]; then
        mode_label="单轮"
    else
        mode_label="目标: $goal"
    fi
    log "模式：$mode_label"

    PROMPT=$(build_prompt "$goal")

    log "启动 Team Lead..."
    echo ""

    # Pass prompt as positional argument to start interactive session with initial context
    claude "$PROMPT"

    log "流水线结束"
}

main "$@"
