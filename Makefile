SHELL := /bin/bash
SHELLCHECK := $(shell command -v shellcheck 2>/dev/null || echo "$(HOME)/.local/bin/shellcheck")
SCRIPTS := lib/common.sh bin/quality-gate.sh bin/keep-working.sh bin/start-pipeline.sh bin/usage-report.sh bin/dashboard.sh .claude/lib/common.sh .claude/hooks/keep-working.sh .claude/hooks/quality-gate.sh

.PHONY: help test lint syntax all clean sync

help: ## Show this help message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'

all: syntax lint test ## Run syntax check, lint, and tests

# 语法检查
syntax: ## Check bash syntax for all scripts
	@echo "=== Bash Syntax Check ==="
	@for f in $(SCRIPTS); do bash -n $$f && echo "  OK: $$f" || exit 1; done

# ShellCheck 静态分析
lint: ## Run ShellCheck static analysis
	@echo "=== ShellCheck ==="
	@$(SHELLCHECK) --severity=error $(SCRIPTS) && echo "  PASS: no errors" || exit 1
	@$(SHELLCHECK) --severity=warning $(SCRIPTS) 2>&1 | head -30 || true

# 单元测试
test: ## Run unit and integration tests
	@echo "=== Unit Tests ==="
	@bash tests/test_common.sh
	@echo ""
	@echo "=== Integration Tests ==="
	@bash tests/test_bin_scripts.sh
	@echo ""
	@echo "=========================================="
	@echo "  All tests passed"
	@echo "=========================================="

# 清理状态（开发用）
clean: ## Remove generated state files
	rm -rf .claude/state/
	rm -rf "${TMPDIR:-/tmp}"/gate-* "${TMPDIR:-/tmp}"/test-bin-*

sync: ## Copy bin/ to .claude/hooks/ and lib/ to .claude/lib/
	@mkdir -p .claude/hooks .claude/lib
	@cp bin/quality-gate.sh .claude/hooks/quality-gate.sh
	@cp bin/keep-working.sh .claude/hooks/keep-working.sh
	@cp lib/common.sh .claude/lib/common.sh
	@cp bin/dashboard.sh .claude/dashboard.sh
	@echo "  Synced bin/ -> .claude/hooks/ and lib/ -> .claude/lib/"
