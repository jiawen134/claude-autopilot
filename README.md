# claude-autopilot

Autonomous AI agent teams for any codebase. Point it at a project and let 3-6 AI teammates discover issues, fix bugs, review code, and ship -- continuously and without manual intervention.

## Features

- **Auto-detects your stack** -- Python, Node, Go, Rust, Java (Maven/Gradle), PHP, Ruby, .NET, Swift, Flutter, C++, and Makefile projects
- **Installs two Claude Code hooks** that drive the pipeline: `TeammateIdle` (keep working) and `TaskCompleted` (quality gate)
- **6 specialized roles** -- discoverer, fixer, reviewer, designer, releaser, strategist -- each with role-specific skill rotation
- **Disk-based state** in `.claude/state/` -- agents are stateless and recover from disk after context compaction or restart
- **Quality gate** validates every task completion against tests, lint, and type checks before allowing it to pass
- **Safety valve** -- configurable max rounds (default 15) and quality gate retry limits (default 5) prevent runaway loops
- **Real-time dashboard** (`bin/dashboard.sh`) and usage analytics (`bin/usage-report.sh`)
- **Graceful shutdown** via sentinel files -- no orphaned processes

## Prerequisites

| Tool | Required | Purpose |
|------|----------|---------|
| [Claude Code CLI](https://claude.ai/code) | Yes | Core AI engine (`claude` command) |
| [tmux](https://github.com/tmux/tmux) | Recommended | Parallel teammate sessions (falls back to in-process mode without it) |
| [jq](https://jqlang.github.io/jq/) | Yes | JSON parsing in hook scripts |
| git | Yes | Version control, incremental test detection |

Optional but recommended: [gstack](https://github.com/garrytan/gstack) skills for `/qa`, `/review`, `/browse`, `/cso`, and other advanced capabilities used by teammates.

## Quick Start

### 1. Install as a Claude Code skill

```bash
# Clone into your Claude Code skills directory
git clone https://github.com/jiawen134/claude-autopilot.git ~/.claude/skills/claude-autopilot
```

### 2. Use the skill in any project

Open Claude Code in your project directory and run:

```
/agent-teams
```

The skill will:
1. Detect your project type
2. Check prerequisites (git, jq, claude, tmux)
3. Install hooks into `.claude/hooks/` and `.claude/lib/`
4. Copy the pipeline launcher to `.claude/start-pipeline.sh`
5. Walk you through requirements gathering and team configuration
6. Launch the agent team

### 3. Or launch directly with the pipeline script

```bash
# After the skill has installed hooks into your project:

# Single round: discover -> fix -> review
.claude/start-pipeline.sh

# Goal-directed: work toward a specific objective
.claude/start-pipeline.sh "add user authentication with JWT"

# Continuous mode: keep cycling until shutdown or max rounds
.claude/start-pipeline.sh --continuous
```

## How It Works

```
start-pipeline.sh
  |
  v
Claude CLI (Team Lead, --max-turns 50)
  |
  +-- spawns Teammates via TeamCreate
  |     |
  |     +-- discoverer (finds issues, creates Tasks)
  |     +-- fixer (claims Tasks, writes code, commits)
  |     +-- reviewer (reviews commits, creates follow-up Tasks)
  |     +-- designer (visual QA)
  |     +-- releaser (docs, PRs, deploy)
  |     +-- strategist (architecture, planning)
  |
  +-- TeammateIdle hook (keep-working.sh)
  |     Fires when a teammate has nothing to do:
  |     1. Check Task queue -> claim next task
  |     2. Run tests/lint -> report failures
  |     3. Rotate through role-specific skills
  |     4. After N idle rounds + time threshold -> stop
  |
  +-- TaskCompleted hook (quality-gate.sh)
        Fires when a teammate marks a task done:
        1. Run test suite (incremental first, full on failure)
        2. Run linter
        3. Run type checker (if available)
        4. PASS -> log commit, allow completion
        5. FAIL -> bounce back for retry (up to max retries)
```

All state lives on disk in `.claude/state/`. When a teammate's context is compacted or it restarts, it reads `requirements.md`, `plan.md`, `progress.log`, and the Task list to resume where it left off.

## Teammate Roles

| # | Role | Name | Model | What it does |
|---|------|------|-------|-------------|
| 1 | discoverer | QA Explorer | Sonnet | Finds bugs via `/qa`, `/benchmark`, `/investigate`. Creates Tasks with priority labels. |
| 2 | fixer | Developer | Opus | Claims Tasks, writes code using TDD (test first, then implement). Commits each fix atomically. |
| 3 | reviewer | Code Auditor | Opus | Reviews every commit on three dimensions: requirement alignment, code quality, architecture. Runs `/cso` security audits. |
| 4 | designer | Visual QA | Sonnet | Reviews UI quality with `/design-review`. Creates `DESIGN.md` design system if none exists. |
| 5 | releaser | Release Eng | Sonnet | Syncs docs, creates PRs (`/ship`), deploys (`/land-and-deploy`), monitors (`/canary`). |
| 6 | strategist | Architect | Opus | High-level planning with `/autoplan`, `/office-hours`. Produces 2-3 design alternatives with trade-offs. |

Team size scales with task count: 3 teammates for small jobs, 4 for medium, all 6 for large efforts.

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `AI_PIPELINE_MAX_ROUNDS` | `15` | Maximum work rounds per teammate before stopping |
| `QUALITY_GATE_MAX_RETRIES` | `5` | Max quality gate failures per task before force-passing |
| `AI_PIPELINE_IDLE_THRESHOLD` | `3` | Consecutive idle rounds before considering a teammate done |
| `AI_PIPELINE_IDLE_MIN_SECONDS` | `60` | Minimum idle time (seconds) before stopping a teammate |
| `AI_PIPELINE_MAX_LEAD_CYCLES` | `10` | Max Team Lead restart cycles in continuous mode |
| `SAFE_RUN_TIMEOUT` | `120` | Timeout (seconds) for test/lint commands |
| `AGENT_TEAMS_TEAM_NAME` | `$(basename $PWD)` | Unique team name (set this if multiple projects share a directory name) |
| `AGENT_TEAMS_TEST_CMD` | (auto-detected) | Override the test command |
| `AGENT_TEAMS_LINT_CMD` | (auto-detected) | Override the lint command |
| `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` | `60` | Context window percentage that triggers auto-compaction |
| `LOG_LEVEL` | `INFO` | Hook log verbosity (`DEBUG`, `INFO`, `WARN`, `ERROR`) |

### Role Round Limits

Each role has a per-cycle round limit. When reached, the counter resets and the teammate continues (it does not stop):

| Role | Rounds per cycle |
|------|-----------------|
| discoverer | 3 |
| fixer | 5 |
| reviewer | 3 |
| designer | 2 |
| releaser | 2 |
| strategist | 2 |

### Settings File

The skill writes hook configuration to `.claude/settings.json` in your project. Key fields:

```json
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  },
  "teammateMode": "tmux",
  "hooks": {
    "TeammateIdle": [{ "hooks": [{ "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/keep-working.sh", "timeout": 300 }] }],
    "TaskCompleted": [{ "hooks": [{ "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/quality-gate.sh", "timeout": 300 }] }]
  }
}
```

## State Files

All pipeline state is written to `.claude/state/` and persists across agent restarts:

| File | Purpose |
|------|---------|
| `requirements.md` | Full requirements from intake phase |
| `plan.md` | Architecture and task breakdown |
| `progress.log` | Role cycle completions and state summaries |
| `discoveries.jsonl` | Issues found by discoverer (JSONL with `resolved` flag) |
| `commits.log` | Every commit that passed the quality gate |
| `status-{name}.json` | Current teammate status (used by dashboard) |
| `usage.jsonl` | Hook invocation log with timing data |
| `round-{team}-{name}` | Round counter per teammate |
| `retry-{hash}` | Quality gate retry counter per task |
| `shutdown-{team}` | Graceful shutdown sentinel |

## Safety

**Max rounds**: Each teammate stops after `AI_PIPELINE_MAX_ROUNDS` (default 15) total rounds. Role-specific limits trigger earlier cycle resets but do not stop work.

**Quality gate**: Every task completion runs through tests and lint. Failures bounce the task back to the teammate. After `QUALITY_GATE_MAX_RETRIES` (default 5) consecutive failures on the same task, it force-passes to prevent infinite loops.

**Graceful shutdown**: The Team Lead writes a sentinel file (`.claude/state/shutdown-{team}`). Both hooks check for this file on every invocation and stop driving work when found.

**Idle detection**: Requires both a count threshold (3 consecutive idle rounds) and a time threshold (60 seconds) before stopping a teammate. This prevents premature shutdown when tasks are still being created.

**Command execution**: All test/lint commands run through `safe_run()` with a configurable timeout (default 120s). Commands are executed via `bash -c` with timeout protection -- no `eval`.

**Input sanitization**: Teammate names and team names are sanitized to alphanumeric characters, hyphens, and underscores to prevent path traversal.

## Project Structure

```
.
├── SKILL.md              # Claude Code skill definition (the installer)
├── CLAUDE.md             # Project instructions for Claude Code
├── Makefile              # test, lint, syntax, sync, clean
├── bin/
│   ├── start-pipeline.sh # Entry point -- launches Team Lead via claude CLI
│   ├── keep-working.sh   # TeammateIdle hook -- drives continuous work
│   ├── quality-gate.sh   # TaskCompleted hook -- validates before marking done
│   ├── dashboard.sh      # Real-time HTML dashboard
│   └── usage-report.sh   # Usage analytics
├── lib/
│   └── common.sh         # Shared library (state, locking, project detection, logging)
└── tests/
    ├── test_common.sh    # Unit tests for lib/common.sh
    └── test_bin_scripts.sh # Integration tests for bin/ scripts
```

## Development

```bash
# Run all checks (syntax + lint + tests)
make all

# Run unit and integration tests
make test

# Run ShellCheck static analysis
make lint

# Check bash syntax
make syntax

# Sync bin/ scripts to .claude/hooks/ (for local testing)
make sync

# Clean up state files
make clean
```

All shell scripts must pass `shellcheck` with no errors. Tests use plain bash assertions (no external test framework).

## License

MIT
