# Agent Teams — AI Auto-Optimization Pipeline

## Project Type
- **Type**: Shell/Makefile (bash scripts + unit tests)
- **Test**: `make test`
- **Lint**: `make lint` (if available), `shellcheck`

## Agent Teams Configuration

### Teammate Roles

| # | Role | Name | Responsibilities |
|---|------|------|------------------|
| 1 | discoverer | QA Explorer | /qa, /benchmark, /investigate — find bugs and issues |
| 2 | fixer | Developer | /investigate, /browse — fix bugs, write code |
| 3 | reviewer | Code Auditor | /review, /cso, /codex — review code, security audit |
| 4 | designer | Visual QA | /design-review, /plan-design-review — UI quality |
| 5 | releaser | Release Eng | /document-release, /ship, /land-and-deploy, /canary |
| 6 | strategist | Architect | /autoplan, /office-hours, /plan-eng-review, /retro |

### Quality Standards
- All changes must pass `make test` before marking tasks complete
- Shell scripts must pass `shellcheck`
- Commits are atomic (one fix per commit)
- Safety valve: 15 rounds max (configurable via `AI_PIPELINE_MAX_ROUNDS`)
- Quality gate retries: 5 max (configurable via `QUALITY_GATE_MAX_RETRIES`)

### Context Management
- Auto-compaction triggers at 60% capacity (`CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=60`)
- Role round limits: discoverer=3, fixer=5, reviewer=3, designer=2, releaser=2, strategist=2
- After hitting role limit: **auto-reset and continue** (not stop) — agents are stateless
- Hook output is 1-line summaries only (no raw test/lint dumps)
- Team Lead uses `--max-turns 50`
- **All state lives on disk** in `.claude/state/` — agents recover by reading files, not from context

### State Files (`.claude/state/`)
| File | Purpose | Written by |
|------|---------|-----------|
| `progress.log` | Role cycle completions + state summaries | keep-working.sh |
| `discoveries.jsonl` | Issues found by discoverer (JSONL, `resolved:true/false`) | Teammates |
| `commits.log` | Every commit: timestamp, role, hash, message | quality-gate.sh |
| `round-{team}-{name}` | Round counter per teammate | keep-working.sh |
| `retry-{hash}` | Quality gate retry counter per task | quality-gate.sh |
| `status-{name}.json` | Current teammate status (dashboard source) | Both hooks |
| `usage.jsonl` | Hook invocation log | Both hooks |

# Compact Instructions

## For Team Lead
When compacting, preserve:
- Current Task list with owners, statuses, and priorities
- Each Teammate's name, role, and current round number
- Latest test/lint pass/fail state
- Contents of `.claude/state/progress.log` (last 3 entries)

When compacting, discard:
- Historical skill output details (/qa reports, /review checklists)
- Completed Task full descriptions (just keep ID + title)
- Hook debug logs and usage tracking details
- Full file contents previously read

## For Teammates
When compacting, preserve:
- Your role name and current Task assignment
- Files you modified in this session (paths only)
- Current test/lint pass/fail state
- The task you are working on (ID + description)

When compacting, discard:
- Full file contents (re-read when needed)
- Previous Task outputs and skill reports
- Intermediate debugging steps and exploration
- Other teammates' status (re-check via Task list)

## Recovery Protocol
When a teammate starts a new session or after compaction:
1. Read `.claude/state/progress.log` for recent history
2. Check Task list for pending/in_progress assignments
3. Run `git log --oneline -5` for recent commits
4. Resume work — no need to re-discover context

### Hooks
- **TeammateIdle** → `.claude/hooks/keep-working.sh` — drives continuous work
- **TaskCompleted** → `.claude/hooks/quality-gate.sh` — validates before marking done

### Lead Skills
The Team Lead (you) should use:
- `/careful` — enable safety guardrails before starting
- `/setup-browser-cookies` — authenticate browser sessions
- `/setup-deploy` — configure deployment (if applicable)
