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
elif ls ./*.sln ./*.csproj 2>/dev/null | head -1 >/dev/null 2>&1; then _PROJECT_TYPE="dotnet"
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

# 检测已安装的 hooks
_HAS_HOOKS="no"
[ -f ".claude/hooks/keep-working.sh" ] && _HAS_HOOKS="yes"
echo "HAS_HOOKS: $_HAS_HOOKS"

# 检测 tmux / jq
_HAS_TMUX="no"; command -v tmux >/dev/null 2>&1 && _HAS_TMUX="yes"
_HAS_JQ="no"; command -v jq >/dev/null 2>&1 && _HAS_JQ="yes"
echo "HAS_TMUX: $_HAS_TMUX"
echo "HAS_JQ: $_HAS_JQ"
```

## 第一步：环境检查

读取 Preamble 输出，检查以下条件：

### 必须满足
1. **HAS_GIT=yes** — 没有 git 仓库则先 `git init && git add -A && git commit -m "init"`
2. **HAS_JQ=yes** — Hook 脚本依赖 jq，没有则提示安装：`sudo apt install jq` / `brew install jq`

### 建议满足
3. **HAS_TESTS=yes** — quality-gate.sh 需要测试。没有则建议先写基础测试
4. **HAS_TMUX=yes** — 多 Teammate 并行需要 tmux。没有会用 in-process 模式

### 自动处理
5. **AGENT_TEAMS=not_set** — 自动设置环境变量
6. **HAS_HOOKS=no** — 自动安装 Hook 文件

如果有必须条件不满足，用 AskUserQuestion 确认后再继续。

## 第二步：安装 Hook 配置

如果 `HAS_HOOKS=no`，执行以下安装：

### 2.1 创建 .claude/settings.json

根据项目是否已有 `.claude/settings.json`，**合并**（不覆盖）以下配置：

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

如果已有 settings.json，只合并 `hooks` 和 `env` 字段，保留其他已有配置。

### 2.2 安装 Hook 脚本

从 skill 目录复制 Hook 脚本到项目：

```bash
mkdir -p .claude/hooks
cp "${CLAUDE_SKILL_DIR}/bin/keep-working.sh" .claude/hooks/keep-working.sh
cp "${CLAUDE_SKILL_DIR}/bin/quality-gate.sh" .claude/hooks/quality-gate.sh
chmod +x .claude/hooks/keep-working.sh .claude/hooks/quality-gate.sh
```

### 2.3 安装启动脚本

```bash
cp "${CLAUDE_SKILL_DIR}/bin/start-pipeline.sh" ./start-pipeline.sh
chmod +x start-pipeline.sh
```

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

**Python 项目特殊处理**：如果没有 pyproject.toml 且没有 ruff：
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

**小/中/大需求**：用 Agent tool 启动 1 个 strategist（model: opus, subagent_type: planner）做正式规划：

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
| **小** | 3-5 | discoverer + fixer + reviewer（3 人） | `./start-pipeline.sh "需求摘要"` |
| **中** | 5-10 | strategist + fixer + reviewer + releaser（4 人） | `./start-pipeline.sh "需求摘要"` |
| **大** | 10+ | 全部 6 人 | `./start-pipeline.sh --continuous` |

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

1. gstack skill 清单（从 gstack 目录自动检测可用 skill）
2. 6 个 Teammate 分工表
3. 质量标准
4. Lead 负责的 skill 列表

如果已有 CLAUDE.md，**追加** Agent Teams 相关配置（不覆盖已有内容）。

## 卸载

如果用户说 "卸载 agent-teams" / "remove agent-teams"：
1. 删除 `.claude/hooks/keep-working.sh` 和 `.claude/hooks/quality-gate.sh`
2. 从 `.claude/settings.json` 移除 TeammateIdle 和 TaskCompleted hooks
3. 删除 `start-pipeline.sh`
4. 清理 `.claude/state/shutdown-*` 哨兵文件
5. 保留 CLAUDE.md（用户可能已修改）

## 成本提醒

安装完成后提醒用户：

| 配置 | 预估消耗/小时 | 约合美元/小时 |
|------|-------------|-------------|
| 3 Teammates (1 Sonnet + 2 Opus) | ~500K tokens | ~$3.0 |
| 4 Teammates (1 Sonnet + 3 Opus) | ~900K tokens | ~$5.5 |
| 6 Teammates (3 Sonnet + 3 Opus) | ~1.3M tokens | ~$8.0 |

模型分配：fixer + reviewer + strategist 用 Opus（质量优先），discoverer + designer + releaser 用 Sonnet。

安全阀：默认 50 轮后自动停止（可通过 `AI_PIPELINE_MAX_ROUNDS` 调整）。
