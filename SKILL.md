---
name: agent-teams
version: 1.0.0
description: |
  AI 全自动优化流水线 — 一键在任何项目上启动 Agent Teams。
  自动检测项目类型（Python/Node/Go/Rust/Java/PHP/Ruby/.NET/Swift/Flutter/C++），
  安装 Hook 配置，启动 3-6 个 AI Teammate 持续发现问题、修复、审查、发布。
  Use when asked to "auto optimize", "agent teams", "自动优化",
  "启动 AI 团队", "start pipeline", or "持续改进".
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
  - Agent
  - AskUserQuestion
---

# /agent-teams — AI 全自动优化流水线

## Preamble (run first)

```bash
# 检测项目类型（修复 || && 优先级 bug：用 if/elif 替代链式逻辑）
_PROJECT_TYPE="unknown"
if [ -f "Cargo.toml" ]; then _PROJECT_TYPE="rust"
elif [ -f "go.mod" ]; then _PROJECT_TYPE="go"
elif [ -f "pyproject.toml" ] || [ -f "setup.py" ] || [ -f "requirements.txt" ]; then _PROJECT_TYPE="python"
elif [ -f "pom.xml" ]; then _PROJECT_TYPE="java-maven"
elif [ -f "build.gradle" ] || [ -f "build.gradle.kts" ]; then _PROJECT_TYPE="java-gradle"
elif [ -f "composer.json" ]; then _PROJECT_TYPE="php"
elif [ -f "Gemfile" ]; then _PROJECT_TYPE="ruby"
elif find . -maxdepth 1 \( -name '*.sln' -o -name '*.csproj' \) -print -quit 2>/dev/null | grep -q .; then _PROJECT_TYPE="dotnet"
elif [ -f "Package.swift" ]; then _PROJECT_TYPE="swift"
elif [ -f "pubspec.yaml" ]; then _PROJECT_TYPE="flutter"
elif [ -f "CMakeLists.txt" ]; then _PROJECT_TYPE="cpp-cmake"
elif [ -f "Makefile" ] && grep -q "^test:" Makefile 2>/dev/null; then _PROJECT_TYPE="makefile"
elif [ -f "package.json" ]; then _PROJECT_TYPE="node"
fi
echo "PROJECT_TYPE: $_PROJECT_TYPE"

# 检测 git
_HAS_GIT="no"
git rev-parse --git-dir >/dev/null 2>&1 && _HAS_GIT="yes"
echo "HAS_GIT: $_HAS_GIT"

# 检测现有测试
_HAS_TESTS="no"
if [ -d "tests" ] || [ -d "test" ] || [ -d "src/test" ] || [ -d "__tests__" ] || [ -d "spec" ]; then
    _HAS_TESTS="yes"
fi
echo "HAS_TESTS: $_HAS_TESTS"

# 检测 Agent Teams 环境变量
echo "AGENT_TEAMS: ${CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS:-not_set}"

# 检测已安装的 hooks（三件齐全才算 yes）
_HAS_HOOKS="no"
if [ -f ".claude/hooks/keep-working.sh" ] && [ -f ".claude/hooks/quality-gate.sh" ] && [ -f ".claude/lib/common.sh" ]; then
    _HAS_HOOKS="yes"
fi
echo "HAS_HOOKS: $_HAS_HOOKS"

# 检测 tmux / jq / claude CLI
_HAS_TMUX="no"; command -v tmux >/dev/null 2>&1 && _HAS_TMUX="yes"
_HAS_JQ="no"; command -v jq >/dev/null 2>&1 && _HAS_JQ="yes"
_HAS_CLAUDE="no"; command -v claude >/dev/null 2>&1 && _HAS_CLAUDE="yes"
echo "HAS_TMUX: $_HAS_TMUX"
echo "HAS_JQ: $_HAS_JQ"
echo "HAS_CLAUDE: $_HAS_CLAUDE"

# 检测 gstack
_HAS_GSTACK="no"
{ [ -d "$HOME/.claude/skills/gstack" ] || [ -d ".claude/skills/gstack" ]; } && _HAS_GSTACK="yes"
echo "HAS_GSTACK: $_HAS_GSTACK"

# 检测 skill 源目录（安装时需要复制 hook 和 lib）
_SKILL_DIR=""
for _d in "$HOME/.claude/skills/agent-teams" ".claude/skills/agent-teams"; do
    [ -f "$_d/lib/common.sh" ] && _SKILL_DIR="$_d" && break
done
echo "SKILL_DIR: ${_SKILL_DIR:-not_found}"
```

## 第一步：环境检查

读取 Preamble 输出，检查以下条件：

### 必须满足
1. **HAS_GIT=yes** — 没有 git 仓库则先 `git init && git add -A && git commit -m "init"`
2. **HAS_JQ=yes** — Hook 脚本依赖 jq，没有则提示安装：`sudo apt install jq` / `brew install jq`
3. **HAS_CLAUDE=yes** — `start-pipeline.sh` 是 `claude --max-turns 50` 的包装脚本，需要 Claude Code CLI。没有则提示安装：参见 https://claude.ai/code
4. **SKILL_DIR != not_found** — 安装 Hook 需要从 skill 源目录复制文件。如果找不到，提示用户确认 agent-teams skill 的安装路径

### 建议满足
5. **HAS_TESTS=yes** — quality-gate.sh 需要测试。没有则建议先写基础测试
6. **HAS_TMUX=yes** — 多 Teammate 并行需要 tmux。没有会用 in-process 模式
7. **HAS_GSTACK=yes** — Teammate 使用 gstack skill（/qa, /review, /browse 等）。没有则提示安装：`git clone https://github.com/garrytan/gstack.git ~/.claude/skills/gstack && cd ~/.claude/skills/gstack && ./setup`

### 自动处理
8. **AGENT_TEAMS=not_set** — 自动设置环境变量
9. **HAS_HOOKS=no** — 自动安装 Hook 文件

如果有必须条件不满足，用 AskUserQuestion 确认后再继续。

## 第二步：安装 Hook 配置

如果 `HAS_HOOKS=no`（首次安装或安装不完整），执行以下安装。

如果 `HAS_HOOKS=yes` 但用户明确要求重装（如"重新安装 hooks"），也执行安装（覆盖旧文件）。

### 2.1 创建 .claude/settings.json

根据项目是否已有 `.claude/settings.json`，**合并**（不覆盖）以下配置：

根据 `HAS_TMUX` 决定 `teammateMode`：`HAS_TMUX=yes` → `"tmux"`，`HAS_TMUX=no` → `"process"`。

```json
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  },
  "teammateMode": "tmux",
  "hooks": {
    "TeammateIdle": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/keep-working.sh",
            "timeout": 300
          }
        ]
      }
    ],
    "TaskCompleted": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/quality-gate.sh",
            "timeout": 300
          }
        ]
      }
    ]
  }
}
```

如果已有 settings.json，按以下策略合并（不覆盖）：
- `env`：逐个 key 合并，已有的 key 不覆盖
- `hooks.TeammateIdle`：如果已有该数组，**追加**新 hook 到数组末尾；如果没有，创建新数组
- `hooks.TaskCompleted`：同上，追加而不是替换
- `teammateMode`：如果 `HAS_TMUX=yes` 设为 `"tmux"`，否则设为 `"process"`（in-process 模式）。如果已有值则保留
- 其他字段（permissions 等）：保留已有值不动

### 2.2 安装 Hook 脚本和共享库

从 skill 目录复制 Hook 脚本和共享库到项目（使用 Preamble 输出的 `SKILL_DIR` 路径）：

```bash
mkdir -p .claude/hooks .claude/lib
cp "${SKILL_DIR}/bin/keep-working.sh" .claude/hooks/keep-working.sh
cp "${SKILL_DIR}/bin/quality-gate.sh" .claude/hooks/quality-gate.sh
cp "${SKILL_DIR}/lib/common.sh" .claude/lib/common.sh
chmod +x .claude/hooks/keep-working.sh .claude/hooks/quality-gate.sh
```

> **关键**：`lib/common.sh` 是两个 Hook 的核心依赖。Hook 通过 `$(dirname "$SCRIPT_DIR")/lib/common.sh` 定位，即 `.claude/lib/common.sh`。缺少此文件会导致 Hook 启动即崩溃。

### 2.3 安装启动脚本

```bash
cp "${SKILL_DIR}/bin/start-pipeline.sh" .claude/start-pipeline.sh
chmod +x .claude/start-pipeline.sh
```

> 安装到 `.claude/` 目录而非项目根目录，避免污染项目。运行方式：`.claude/start-pipeline.sh`

### 2.4 项目类型适配

根据 `PROJECT_TYPE`，确保 quality-gate.sh 能正确检测：

| 类型 | 识别标志 | 测试命令 | Lint 命令 |
|------|---------|---------|---------|
| python | pyproject.toml / setup.py / requirements.txt | pytest / manage.py test | ruff check |
| node | package.json | npm test | npm run lint |
| go | go.mod | go test ./... | golangci-lint |
| rust | Cargo.toml | cargo test | cargo clippy |
| java-maven | pom.xml | mvn test | checkstyle |
| java-gradle | build.gradle(.kts) | ./gradlew test | ktlintCheck |
| php | composer.json | phpunit / pest | phpstan |
| ruby | Gemfile | rspec / rails test | rubocop |
| dotnet | *.sln / *.csproj | dotnet test | dotnet format |
| swift | Package.swift | swift test | swiftlint |
| flutter | pubspec.yaml | flutter test | dart analyze |
| cpp-cmake | CMakeLists.txt | ctest | - |
| makefile | Makefile (有 test:) | make test | make lint |

**Python 项目特殊处理**：如果没有 pyproject.toml 且没有 ruff，用 AskUserQuestion 确认后再创建：
```toml
[project]
name = "项目名"
version = "0.1.0"
requires-python = ">=3.10"

[tool.pytest.ini_options]
testpaths = ["tests"]

[tool.ruff]
line-length = 120
```

安装完毕后告知用户已配置完成。

### 2.5 补全 .gitignore

用 AskUserQuestion 确认后，追加 Agent Teams 产物的忽略规则（只追加不存在的行）：

```bash
touch .gitignore
for pattern in ".claude/state/" ".claude/start-pipeline.sh" "playwright-report/" "test-results/" "*.tmp"; do
    grep -qxF "$pattern" .gitignore 2>/dev/null || echo "$pattern" >> .gitignore
done
```

### 2.6 Timeout 适配

如果项目测试套件较慢（超过 2 分钟），需要在 `.claude/settings.json` 的 `env` 中调大超时：

```json
"env": {
  "SAFE_RUN_TIMEOUT": "300"
}
```

默认值是 120 秒。建议设为测试实际耗时的 2 倍。可以先跑一次测试计时：

```bash
time make test  # 或 npm test / pytest 等
```

### 2.7 权限配置

用 AskUserQuestion 询问用户权限偏好：

```
Teammate 执行时需要 Edit/Write/Bash 权限。请选择权限模式：

1. **逐个审批**（默认，安全）— 每个操作需要你确认
2. **自动审批安全操作** — Read/Glob/Grep/测试命令自动通过，Edit/Write/Bash 仍需确认
3. **全部自动审批**（快但有风险）— 所有操作自动通过，适合信任的项目

推荐选 2，兼顾速度和安全。
```

如果用户选 2，在 `.claude/settings.json` 中添加：
```json
"permissions": {
  "allow": ["Read", "Glob", "Grep", "Bash(make test)", "Bash(make lint)", "Bash(npm test)", "Bash(npm run lint)"]
}
```

如果用户选 3，提醒风险后设置 `"defaultMode": "auto"`。

### 2.8 Team Name 配置

默认使用项目目录名作为 team_name（如 `my-app`）。如果有多个同名目录的项目可能同时运行 Agent Teams，需要设置唯一名称：

在 `.claude/settings.json` 的 `env` 中添加：
```json
"AGENT_TEAMS_TEAM_NAME": "my-app-unique"
```

Team name 影响范围：`~/.claude/teams/<name>/`、`~/.claude/tasks/<name>/`、`.claude/state/shutdown-<name>`。不同项目如果同名目录会导致状态互相干扰。

## 第三步：需求理解 & 智能路由

### 3.1 需求输入

用 AskUserQuestion 问用户：

```
Agent Teams 已配置完毕。请描述你的需求：

- 直接说目标（如"添加用户注册功能"）
- 给需求文档路径（如"看 docs/PRD.md"）
- 粘贴需求文档内容
- 说"全面扫描"让团队自己发现问题
- 或输入数字选手动模式：1=单轮扫描 2=持续运行 3=只安装
```

**如果用户选了数字**：按对应模式执行（1→`--once`, 2→`--continuous`, 3→只安装），跳过后续步骤。

**如果用户给了文件路径**：用 Read 工具读取文件内容，作为需求输入。

**如果用户粘贴了大段文本/需求文档**：直接作为需求输入。

**如果用户说了一句话需求**：进入需求澄清（3.2）。

### 3.2 需求澄清（PM 模式）

作为产品经理，理解用户的真实意图。**不限轮数，问到清楚为止。**

**判断标准——什么叫"清楚"**：
能回答以下 5 个问题就算清楚，缺哪个问哪个：
1. **做什么**：具体要实现/修复/改进什么？
2. **为什么**：解决什么问题？给谁用？
3. **怎么验收**：用户怎么知道做完了？（可演示的行为、通过的测试）
4. **边界**：不做什么？有什么限制？（技术栈、不能动的模块、性能要求）
5. **参考**：有没有设计稿、API 文档、竞品参考？

**追问策略**：
- 每次只问 1-2 个最关键的问题，不要一口气问 5 个
- 如果用户说"你看着办"、"帮我分析"，用 Explore agent 快速扫描代码库后自行判断
- 如果用户给了需求文档，从文档中提取答案，只追问文档里没写清楚的
- bug 类需求通常只需确认复现步骤，不用问太多

### 3.3 需求持久化

需求澄清完成后，将完整需求写入磁盘，确保所有 Teammate 都能读到：

```bash
mkdir -p .claude/state
# 写入 requirements.md，包含：
# - 原始需求描述
# - 澄清后的完整需求
# - 验收标准
# - 边界和限制
# - 参考资料链接
```

Write 工具写入 `.claude/state/requirements.md`。这个文件是所有 Teammate 的需求源头：
- strategist 读它来做架构规划
- fixer 读它来理解每个任务的 why
- reviewer 读它来验证实现是否符合需求
- context 压缩后 Teammate 可以重新读取

### 3.4 规划 & 任务拆解

**极小需求（一眼看完就能判断）**：直接拆 1-2 个任务，跳到 3.5。

**小/中/大需求**：用 Agent tool 启动 1 个 strategist（model: opus, subagent_type: general-purpose）做正式规划：

strategist 的规划流程：
1. **读需求**：读 `.claude/state/requirements.md`
2. **读代码**：用 Explore agent 扫描项目结构、核心模块、已有 pattern
3. **架构设计**：
   - 需要新增哪些模块/文件？
   - 需要修改哪些现有文件？
   - 数据流怎么走？
   - 有哪些 edge case？
4. **任务拆解原则**：
   - 每个任务是独立可验证的（有明确的"做完"标准）
   - 任务之间有清晰的依赖关系（blockedBy）
   - 每个任务 description 包含：做什么 + 为什么 + 验收标准 + 涉及文件
   - 粒度适中：太大拆不动，太小浪费协调成本
   - 基础设施任务排前面（数据库表、API 路由、类型定义）
5. **输出规划文档**：写入 `.claude/state/plan.md`，包含架构图、任务列表、依赖关系、风险点

### 3.5 规模评估 & 确认启动

根据任务数量自动推荐团队配置：

| 规模 | 任务数 | 团队配置 | 执行方式 |
|------|--------|---------|---------|
| **极小** | 1-2 | fixer(Opus) 单人 | 当前会话直接 Agent 完成 + 审查 |
| **小** | 3-5 | discoverer + fixer + reviewer（3 人） | `.claude/start-pipeline.sh "需求摘要"` |
| **中** | 5-10 | strategist + fixer + reviewer + releaser（4 人） | `.claude/start-pipeline.sh "需求摘要"` |
| **大** | 10+ | 全部 6 人 | `.claude/start-pipeline.sh --continuous` |

用 AskUserQuestion 展示方案并确认：

```
需求分析 & 规划完成：

📄 需求文档：.claude/state/requirements.md
📐 架构规划：.claude/state/plan.md

📋 任务拆解（N 个）：
  1. [基础] 创建 users 表和 User 模型 — blockedBy: 无
  2. [基础] 添加 JWT 认证 middleware — blockedBy: #1
  3. [功能] 实现注册 API — blockedBy: #1
  4. [功能] 实现登录 API — blockedBy: #2
  ...

📊 规模评估：中
👥 推荐团队：strategist(Opus) + fixer(Opus) + reviewer(Opus) + releaser(Sonnet)
💰 预估成本：~$X

确认启动？（确认 / 调整团队 / 查看规划详情 / 重新描述需求）
```

### 3.6 执行

**极小需求**：
不启动 start-pipeline.sh，在当前会话直接执行：
1. 用 Agent tool 启动 1 个 fixer（model: opus）完成任务
2. 完成后用 Agent tool 启动 1 个 reviewer（model: opus）审查代码
3. 审查通过后告知用户完成

**小/中/大需求**：
按 3.5 表格的执行方式启动 start-pipeline.sh。
Teammate 启动后首先读 `.claude/state/requirements.md` 和 `.claude/state/plan.md` 获取完整上下文。

## 第四步：CLAUDE.md 检查

检查项目根目录是否有 CLAUDE.md。如果没有，创建一个包含：

1. **如果 HAS_GSTACK=yes**：gstack skill 清单（从 gstack 目录自动检测可用 skill）+ 6 个 Teammate 分工表（含 gstack skill 映射）
2. **如果 HAS_GSTACK=no**：Teammate 分工表中只列 Claude Code 内置能力（Read/Write/Edit/Bash/Agent），不列 gstack skill。注明 "安装 gstack 后可解锁 /qa, /review, /browse 等高级能力"
3. 质量标准
4. Lead 负责的 skill 列表

如果已有 CLAUDE.md，**追加** Agent Teams 相关配置（不覆盖已有内容）。

## 卸载

如果用户说 "卸载 agent-teams" / "remove agent-teams"：
1. 删除 `.claude/hooks/keep-working.sh` 和 `.claude/hooks/quality-gate.sh`
2. 删除 `.claude/lib/common.sh`（如果 `.claude/lib/` 目录为空则一并删除）
3. 从 `.claude/settings.json` 移除 TeammateIdle 和 TaskCompleted hooks，移除 `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` 环境变量
4. 删除 `.claude/start-pipeline.sh`
5. 清理 `.claude/state/shutdown-*` 哨兵文件
6. 保留 CLAUDE.md（用户可能已修改）

## 成本提醒

安装完成后提醒用户：

| 配置 | 预估消耗/小时 | 约合美元/小时 |
|------|-------------|-------------|
| 3 Teammates (1 Sonnet + 2 Opus) | ~500K tokens | ~$3.0 |
| 4 Teammates (1 Sonnet + 3 Opus) | ~900K tokens | ~$5.5 |
| 6 Teammates (3 Sonnet + 3 Opus) | ~1.3M tokens | ~$8.0 |

模型分配：fixer + reviewer + strategist 用 Opus（质量优先），discoverer + designer + releaser 用 Sonnet。

安全阀：默认 15 轮后自动停止（可通过 `AI_PIPELINE_MAX_ROUNDS` 调整）。
