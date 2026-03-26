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
- Safety valve: 50 rounds max (configurable via `AI_PIPELINE_MAX_ROUNDS`)
- Quality gate retries: 5 max (configurable via `QUALITY_GATE_MAX_RETRIES`)

### Hooks
- **TeammateIdle** → `.claude/hooks/keep-working.sh` — drives continuous work
- **TaskCompleted** → `.claude/hooks/quality-gate.sh` — validates before marking done

### Lead Skills
The Team Lead (you) should use:
- `/careful` — enable safety guardrails before starting
- `/setup-browser-cookies` — authenticate browser sessions
- `/setup-deploy` — configure deployment (if applicable)
