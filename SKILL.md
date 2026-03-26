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

## 第三步：选择运行模式

用 AskUserQuestion 询问用户：

```
Agent Teams 已配置完毕。选择运行模式：

1. 🔍 单轮扫描 — 3 个 Teammate（发现→修复→审查），跑一轮就停
2. 🎯 目标驱动 — 4 个 Teammate，给定一个目标让 AI 团队实现
3. 🔄 持续运行 — 6 个 Teammate，Peter Steinberger 模式（持续循环）
4. ⚙️ 只安装不运行 — 配置好后手动启动

选哪个？（1/2/3/4）
```

### 模式 1：单轮扫描
```bash
./start-pipeline.sh
```

### 模式 2：目标驱动
再次 AskUserQuestion 询问目标，然后：
```bash
./start-pipeline.sh "用户输入的目标"
```

### 模式 3：持续运行
```bash
./start-pipeline.sh --continuous
```

### 模式 4：只安装
输出安装完成信息和手动启动指南。

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
4. 保留 CLAUDE.md（用户可能已修改）

## 成本提醒

安装完成后提醒用户：

| 配置 | 预估消耗/小时 | 约合美元/小时 |
|------|-------------|-------------|
| 3 Teammates (Sonnet) | ~300K tokens | ~$0.9 |
| 4 Teammates (Sonnet) | ~500K tokens | ~$1.5 |
| 6 Teammates (Sonnet) | ~800K tokens | ~$2.4 |

安全阀：默认 50 轮后自动停止（可通过 `AI_PIPELINE_MAX_ROUNDS` 调整）。
