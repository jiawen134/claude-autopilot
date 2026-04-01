# Contributing to claude-autopilot

Thanks for your interest in contributing!

## Development Setup

```bash
git clone https://github.com/jiawen134/claude-autopilot.git
cd claude-autopilot
make all    # syntax + lint + test
```

### Prerequisites

- bash 4+
- [shellcheck](https://github.com/koalaman/shellcheck)
- jq

### Project Structure

```
bin/                  # Executable scripts
  start-pipeline.sh   # Entry point — launches teammates via tmux
  keep-working.sh     # TeammateIdle hook — drives work cycles
  quality-gate.sh     # TaskCompleted hook — validates changes
  dashboard.sh        # Real-time HTML dashboard generator
  usage-report.sh     # Usage analytics reporter
lib/
  common.sh           # Shared library (state, detection, safe_run)
tests/
  test_common.sh      # Unit tests for lib/common.sh
  test_bin_scripts.sh # Integration tests for bin/ scripts
SKILL.md              # Claude Code skill definition (the installer)
CLAUDE.md             # Project instructions for Claude Code
```

## Running Tests

```bash
make test     # unit + integration tests
make lint     # shellcheck static analysis
make syntax   # bash syntax check
make all      # all of the above
```

## Submitting Changes

1. Fork the repo and create a feature branch
2. Make your changes
3. Run `make all` — all checks must pass
4. Commit with conventional commit format: `feat:`, `fix:`, `docs:`, `test:`, etc.
5. Open a PR with a clear description

## Code Style

- Shell scripts follow [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html) conventions
- All scripts must pass `shellcheck -x -P lib --severity=error`
- Functions should be small and focused
- Use `local` for all function-scoped variables
- Quote all variable expansions

## Reporting Issues

Open a GitHub issue with:
- What you expected
- What actually happened
- Steps to reproduce
- Your environment (OS, bash version, Claude Code version)
