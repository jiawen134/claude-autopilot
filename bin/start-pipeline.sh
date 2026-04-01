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

# ============ 无 TTY 时自动包装进 tmux ============
if ! tty -s 2>/dev/null && command -v tmux &>/dev/null; then
    # 没有 TTY（如从 Claude Code Bash tool 后台启动），
    # 自动创建 tmux session 来提供 TTY 环境
    SESSION_NAME="claude-autopilot-$$"
    tmux new-session -d -s "$SESSION_NAME" "$0 $*"
    echo "No TTY detected. Started inside tmux session: $SESSION_NAME"
    echo "Attach with: tmux attach -t $SESSION_NAME"
    exit 0
fi

# ============ 颜色 ============
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $1"; }

# ============ Team Name（支持环境变量覆盖，避免同名目录冲突）============
TEAM_NAME="${AGENT_TEAMS_TEAM_NAME:-$(basename "$PWD")}"

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

# ============ 生命周期 & 通信规则（通用，追加到所有模式 prompt 后）============
_lifecycle_rules() {
    cat <<'LIFECYCLE'

## 生命周期管理

### 建队（第一步，在前置步骤中执行）
在创建任何 Teammate 之前，先调用 TeamCreate（team_name 见末尾 "Team Name" 段指定的名称）。
创建 Teammate 时传 team_name 参数，让它们自动加入团队。

### 通信规则（SendMessage）
Teammate 之间用 SendMessage 直接对话，不要只靠 Task 传话：
- **reviewer → fixer**：审查发现问题，直接 SendMessage 告知（附文件名+行号+修复建议）
- **discoverer → fixer**：P0 问题直接通知 fixer 优先处理
- **Lead → 全体**：逐个 SendMessage 通知每个 Teammate（**不要用 to: "\*" 广播结构化消息，会报错**）
- **strategist → Lead**：架构方案就绪时发给 Lead 审批
- **Lead → teammate**：用 SendMessage 分配任务、调整优先级、唤醒空闲 Teammate
- Teammate 空闲（idle）是正常的——Lead 随时可以 SendMessage 唤醒并分配新工作
- 每个 Teammate 读 ~/.claude/teams/{team-name}/config.json 发现队友名称，用 name（不是 agentId）通信
- SendMessage 带 summary 字段（5-10 字预览）：SendMessage({ to: "fixer", summary: "XSS in login", message: "..." })
- 消息自动投递，不需要轮询 inbox——队友的消息会自动出现在你的对话里
- Peer DM 可见性：teammate 之间 DM 时，idle 通知会包含摘要，Lead 不用回复这些摘要
- **禁止**发结构化 JSON 状态消息（如 {type:"idle"} 或 {type:"task_completed"}），用纯文本 + TaskUpdate
- **建议** Teammate 执行 skill 时，内部 spawn 的子 agent 不传 team_name，避免意外注册为团队成员导致 TeamDelete 失败。如需子 agent 与队友通信，由父 Teammate 转发

### Idle 通知处理
平台每次检测到 Teammate 空闲都会通知你（Lead），这是**正常行为**，不需要逐条回复：
- 连续收到同一 Teammate 的 idle 通知 → 它暂时无事可做，不需要干预
- 只在你有新工作要分配时才回应 idle 的 Teammate
- Hook 会在连续 3 轮无事可做后自动停止该 Teammate，无需手动处理

### Task metadata
创建 Task 时用 metadata 存结构化信息，方便排序和筛选：
  metadata: { "priority": "P0", "type": "security", "found_by": "discoverer" }
优先级：P0（崩溃/安全）> P1（功能）> P2（样式/性能）> P3（优化）
类型：bug / feature / security / perf / design / docs

### Task 工作流
- 完成一个 Task 后**立即** TaskList 查找下一个可用任务
- 优先认领 ID 最小的未分配、未阻塞任务（低 ID 先，因为早期任务常是后续任务的前置）
- 创建 Task 时设 blockedBy 依赖（如修复 blockedBy 发现，审查 blockedBy 修复）
- 如果所有可用 Task 都被阻塞，通知 Lead 或帮忙解除阻塞

### Lead 监控工具
- TaskOutput — 查看 Teammate 后台任务输出，排查卡住的情况
- TaskStop — 中止卡住的 Teammate 任务
- TaskList + TaskGet — 实时查看所有任务状态和详情

### 优雅关闭
当所有目标完成或达到安全阀上限时：
1. **逐个通知**：对每个 Teammate 分别 SendMessage 纯文本（**不要用 to: "\*" 发结构化消息，会报错**）
   示例：SendMessage({ to: "discoverer", summary: "shutdown", message: "Pipeline complete. 请完成当前工作后停止，不要认领新任务。" })
2. **写哨兵文件**：运行 touch .claude/state/shutdown-{team_name}（Hook 检测到后自动停止驱动）
3. **备份 Task 数据**：cp -r ~/.claude/tasks/{team_name}/ .claude/state/tasks-backup/ （防止 TeamDelete 丢失记录）
4. **等待 30 秒**：让 Hook 检测到哨兵并停止正在运行的 Teammate
5. **TeamDelete**：调用 TeamDelete 清理团队。如果报 active members 错误，再等 30 秒重试一次
6. **兜底**：如果重试仍失败，告知用户手动清理：rm -rf ~/.claude/teams/{team_name} ~/.claude/tasks/{team_name}

开始！
LIFECYCLE
}

# ============ 工程纪律（Superpowers 融合）============
_discipline_rules() {
    cat <<'DISCIPLINE'

## 工程纪律（Superpowers 融合）

以下铁律按角色适用，所有 Teammate 必须遵守。违反铁律 = 返工。

### 全员通用：验证铁律
完成任何工作前，执行验证循环：
1. **确定** — 什么命令能证明你的声明？
2. **执行** — 跑完整命令（不用旧结果）
3. **读取** — 看完整输出 + 退出码
4. **确认** — 结果支持你的声明后才能标完成
⛔ 禁止说"应该没问题"、"大概可以"、"看起来对了"
⛔ 不用 should / probably / seems to 等模糊词

### fixer 铁律

**收到审查反馈时：**
- 先读完全部反馈再动手（部分理解 = 错误实现）
- 有技术理由可以 pushback："Won't fix: [原因]"
- 回应只用 "Fixed" 或 "Won't fix: [原因]"，禁止客套话
- 验证反馈的技术正确性后再实现，不盲从

**TDD（测试驱动开发）— 先写测试，永远如此：**
1. RED — 先写一个会失败的测试，运行确认失败
2. GREEN — 写最少的代码让测试通过
3. REFACTOR — 清理代码，保持测试绿色
⛔ 没有失败测试 → 不许写生产代码
⛔ 先写了代码 → 删掉，从测试重来
⛔ "太简单不需要测试" → 错，简单的地方最容易出隐藏假设

**系统化调试（遇 bug 必走四阶段，禁止跳步）：**
1. 根因调查 — 读错误消息、复现、查 git diff、在组件边界加诊断日志
2. 模式分析 — 找类似的正常代码，逐项对比差异
3. 假设验证 — 一次只改一个变量，验证结果
4. 实现修复 — 先写失败测试，再修代码
⛔ Iron Law: no fixes without root cause investigation
⛔ 3 次修不好 → 质疑架构本身，不要继续修症状

### reviewer 铁律

**结构化审查（每次审查三维度）：**
1. 需求对齐 — 实现是否符合 requirements.md / plan.md？偏差是否有技术理由？
2. 代码质量 — 命名、错误处理、测试覆盖、边界情况、TDD 是否被遵守
3. 架构 — SOLID、关注点分离、可扩展性

**问题分级：**
- **Critical** — 阻断，必须修完才能继续
- **Important** — 下个 commit 前必须修
- **Minor** — 记录即可，稍后修

**反馈风格：** 直接说技术问题 + 文件名 + 行号 + 修复建议。
⛔ 禁止"Great point!"等客套话，只需 "Fixed" 或 "Won't fix: [原因]"

### strategist 铁律

**设计探索（头脑风暴）：**
- 对非 trivial 需求，必须提出 2-3 种方案 + trade-offs
- 写设计文档到 .claude/state/design-spec.md
- ⛔ 未经 Lead 或用户批准设计 → 不许进入详细规划

**YAGNI（复杂度控制）：**
- 删掉不需要的功能比加上一个功能更有价值
- 三行重复代码好过过早抽象
- 不要为假想的未来需求设计
- 每加一个概念都要问：现在真的需要吗？

**计划质量：**
- 每个任务 2-5 分钟，含确切文件路径 + 代码示例 + 验证命令
- TDD 结构：每个任务 = 写测试 → 验证失败 → 实现 → 验证通过 → commit
- ⛔ 零占位符：禁用"添加适当错误处理"、"实现相关逻辑"等模糊描述
- 自检：每个需求有对应任务？函数名跨任务一致？所有任务有验证命令？
DISCIPLINE
}

# ============ 构建启动 Prompt ============
build_prompt() {
    local goal="${1:-}"

    if [ "$goal" = "--continuous" ]; then
        cat <<'PROMPT'
你是 AI 全自动流水线的 Team Lead。你的工作是协调团队持续改进这个项目。
这是一条持续运行的流水线。TeammateIdle Hook 会驱动每个 Teammate 持续循环。

前置：
1. 运行 /careful 启用安全护栏
2. 调用 TeamCreate 建队（team_name 见末尾 Team Name 段）
3. 检查 .claude/state/progress.log — 如果存在，读取最近进度（续接上次流水线）
4. 检查 Task 列表 — 如果有未完成任务，优先分配给对应角色

## Context 管理（关键！）

Agent 是无状态的。所有进度写入 .claude/state/ 目录：
- progress.log — 每个角色完成一轮循环后写入
- discoveries.jsonl — discoverer 发现的问题
- commits.log — 每次通过 quality gate 后记录
- shutdown-{team} — 关闭哨兵文件，Hook 检测到后停止驱动

当 Teammate 的角色轮次用完时，hook 会自动重置计数并继续（不会停止）。
每个 Teammate 重启后应该：先读 requirements.md + plan.md + progress.log + Task 列表，再继续工作。

如果 .claude/state/requirements.md 存在，所有 Teammate 必须先读它理解需求背景。
如果 .claude/state/plan.md 存在，fixer 按计划实现，reviewer 按计划验收。

## Teammate 模型 & subagent_type 选择
所有角色都用 subagent_type: "general-purpose"（需要 Edit/Write/Bash）。
Read-only agents（Explore, Plan）不能做实现工作，不要用于任何角色。

模型按角色分配（用 Agent tool 的 model 参数）：
- **strategist** → model: "opus"（架构决策、产品方向需要最深推理）
- **reviewer** → model: "opus"（Staff Engineer 级别审查需要高判断力）
- **fixer** → model: "opus"（代码质量决定返工次数，Opus 一次写对减少循环）
- **discoverer** → model: "sonnet"（QA 测试和 bug 发现）
- **designer** → model: "sonnet"（视觉审查）
- **releaser** → model: "sonnet"（发布流程）

原则：写代码 + 审代码 + 定方向用 Opus（质量优先），发现 + 设计 + 发布用 Sonnet。

## Token 优化规则

### reviewer 增量审查
reviewer 每次只审查最新的 `git diff`，不要重新审查整个代码库。
对应命令：`git diff HEAD~1` 或 `git diff $(git merge-base HEAD main)..HEAD`

## 启动团队（6 个 Teammate，按角色分配模型）

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
- ⚡ **TDD 铁律**：先写失败测试 → 写最小实现 → 重构（见末尾"工程纪律"）
- ⚡ **调试四阶段**：根因 → 模式分析 → 假设验证 → 修复（禁止跳步）
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
- ⚡ **结构化审查三维度**：需求对齐 → 代码质量 → 架构（见末尾"工程纪律"）
- ⚡ **检查 fixer 是否遵守 TDD**：有生产代码变更但没有对应测试 → Critical issue
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
- ⚡ **设计探索**：对非 trivial 需求提出 2-3 种方案 + trade-offs（见末尾"工程纪律"）
- ⚡ **计划粒度**：每个任务 2-5 分钟 + TDD 结构 + 零占位符
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
2. strategist + reviewer + fixer 用 Opus（质量优先），其余 3 个用 Sonnet（执行优先）
3. 你（Lead）负责：初始运行 /careful, /setup-browser-cookies, /setup-deploy
4. 持续循环：发现 → 修复 → 审查 → 设计审查 → 发布 → 监控 → 再发现...
5. TaskCompleted Hook 自动验证测试通过才允许标记完成
6. TeammateIdle Hook 驱动每个 Teammate 持续工作，到轮次上限自动重置继续
7. **每个 Teammate 每次修复后立即 git commit**（粒度越小越安全，像 Peter 一样）
8. **Task 是唯一的真相来源**——不要靠 context 记忆，所有进度写 Task
9. **Hook 输出只看 1 行摘要**——不要展开详情，节省 context
10. **用 SendMessage 直接通信**——reviewer→fixer 直接说"这行有 bug"，不用只建 Task 转述
11. **Task 用 metadata 标优先级**——创建 Task 时设 metadata: {priority:"P0",type:"bug"}
12. **完成后优雅关闭**——发 shutdown_request → 等 response → 哨兵文件 → TeamDelete
PROMPT

    elif [ -n "$goal" ] && [ "$goal" != "--once" ]; then
        # [Fix #5] 目标模式也统一用 gstack skill
        # Sanitize shell metacharacters from user-provided goal string
        goal=$(printf '%s' "$goal" | tr -d '`$;|&(){}!<>\\')
        cat <<PROMPT
你是 AI 全自动流水线的 Team Lead。目标：$goal

前置：
1. 运行 /careful 启用安全护栏
2. 调用 TeamCreate 建队（team_name 见末尾 Team Name 段）
3. 读取 .claude/state/progress.md — 如果存在，找到"下一步"继续（续接上次流水线）
4. 读取 .claude/state/plan.md — 了解全部任务拆解

## ⛔ 关键规则：一次性创建全部 Task（防 compaction 丢失）

Lead 的 context 会被自动压缩（compaction），压缩后你会忘记未创建的任务。
因此必须在启动时**一次性把 plan.md 中的所有任务都创建为 Task**。

具体做法：
1. 读 .claude/state/plan.md，提取全部任务列表
2. 读 .claude/state/progress.md，跳过已完成的任务
3. 对每个未完成任务调用 TaskCreate，用 blockedBy 设置依赖关系
4. 确认所有任务都已创建后，再 spawn Teammates 开始工作
5. ⛔ 绝不分批创建——必须一次全部创建完

即使任务很多（20-30个），也必须全部创建。Task 系统不在你的 context 里，
不会被 compaction 清除。这是唯一可靠的进度追踪方式。

## 进度 Checkpoint（防 compaction 丢失）

每当一个 Phase 完成（该 Phase 所有 Task 都 completed），你必须：
1. 更新 .claude/state/progress.md，记录：
   - 哪些 Phase/Task 已完成
   - 当前正在进行的 Phase
   - 下一步要做什么
2. 这个文件在 compaction 后仍然可读，是你恢复记忆的唯一来源

如果你发现自己不知道该做什么（通常是 compaction 后），立刻：
1. 读 .claude/state/progress.md
2. 读 .claude/state/plan.md
3. TaskList 查看当前任务状态
4. 根据以上信息继续工作

## 启动团队（4 个 Teammate，按角色分配模型）

### Teammate 1: 架构师 (strategist) — model: opus
- 运行 /office-hours 梳理需求
- ⚡ 提出 2-3 种方案 + trade-offs，写入 .claude/state/design-spec.md
- 运行 /plan-eng-review 设计架构
- 将实现计划拆分为可执行的 Tasks（TDD 结构 + 零占位符）

### Teammate 2: 开发者 (fixer) — model: opus
- 认领 Tasks，写代码实现
- ⚡ TDD 铁律：先写失败测试 → 最小实现 → 重构
- ⚡ 调试四阶段：根因 → 分析 → 假设 → 修复
- 每个功能点独立 commit
- 用 /investigate 排查问题
- 用 /browse 验证效果

### Teammate 3: 质量官 (reviewer) — model: opus
- /review 审查每个提交（三维度：需求对齐 → 代码质量 → 架构）
- ⚡ 检查 fixer 是否遵守 TDD，无测试的代码变更 = Critical issue
- /cso 安全扫描
- /qa 浏览器端到端测试
- 发现问题创建新 Task

### Teammate 4: 发布者 (releaser) — model: sonnet
- 所有 Tasks 完成后 /document-release
- /ship 创建 PR
- /land-and-deploy 部署
- /canary 部署后监控

## 规则
- 使用 Delegate Mode
- 任务设依赖：架构 → 开发 → 审查 → 发布
- 所有提交必须通过测试
- 用 SendMessage 直接通信——reviewer→fixer 直接说问题，不只建 Task
- Task 用 metadata 标优先级——metadata: {priority:"P0",type:"bug"}
PROMPT

    else
        # --once 模式：跑一轮发现+修复（也用 gstack skill）
        cat <<'PROMPT'
你是 AI 全自动流水线的 Team Lead。跑一轮完整的 发现→修复→验证 循环。

前置：
1. 运行 /careful 启用安全护栏
2. 调用 TeamCreate 建队（team_name 见末尾 Team Name 段）

创建 3 个 Teammate（按角色分配模型）：

### Teammate 1: 发现者 (discoverer) — model: sonnet
- /qa 浏览器系统化测试
- /investigate 根因分析
- 把每个问题创建为 Tasks

### Teammate 2: 修复者 (fixer) — model: opus
- 认领 Tasks，修复代码
- ⚡ TDD 铁律：先写失败测试 → 最小实现 → 重构
- 每个问题独立 commit
- /browse 验证修复效果

### Teammate 3: 审查者 (reviewer) — model: opus
- /review 代码审查（三维度：需求对齐 → 代码质量 → 架构）
- ⚡ 无测试的代码变更 = Critical issue
- /cso 安全检查
- 确认后 /document-release 更新文档

使用 Delegate Mode。
PROMPT
    fi

    # 追加通用生命周期 & 通信规则（所有模式共享）
    _lifecycle_rules

    # 追加工程纪律（Superpowers 融合）
    _discipline_rules

    # 追加 Team Name（在 heredoc 外，变量可展开）
    printf '\n## Team Name\n使用 team_name: "%s"\n如果同名目录冲突，可通过 AGENT_TEAMS_TEAM_NAME 环境变量覆盖。\n' "$TEAM_NAME"
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

    if [ "$goal" = "--continuous" ]; then
        # Continuous mode: outer loop restarts Lead when --max-turns exhausted
        # Teammates keep running (driven by TeammateIdle hook) across Lead restarts
        # All state is on disk (.claude/state/), so new Lead picks up where old one left off
        local lead_cycle=0
        local max_lead_cycles="${AI_PIPELINE_MAX_LEAD_CYCLES:-10}"
        while [ "$lead_cycle" -lt "$max_lead_cycles" ]; do
            lead_cycle=$((lead_cycle + 1))
            log "Lead cycle ${lead_cycle}/${max_lead_cycles}"

            # Check shutdown sentinel before starting a new cycle
            if [ -f ".claude/state/shutdown-${TEAM_NAME}" ]; then
                log "Shutdown sentinel detected. Stopping Lead loop."
                break
            fi

            claude --model claude-opus-4-6 --max-turns 50 "$PROMPT" || true

            log "Lead session ended. Teammates continue via hooks."
            sleep 2
        done
        log "Lead loop 完成 (${lead_cycle} cycles)"
    else
        # Single-run modes: one Lead session
        claude --model claude-opus-4-6 --max-turns 50 "$PROMPT"
    fi

    log "流水线结束"
}

main "$@"
