SHELL := /bin/bash
SHELLCHECK := $(shell command -v shellcheck 2>/dev/null || echo "$(HOME)/.local/bin/shellcheck")
SCRIPTS := lib/common.sh bin/quality-gate.sh bin/keep-working.sh bin/start-pipeline.sh bin/usage-report.sh bin/dashboard.sh

.PHONY: test lint syntax all clean

all: syntax lint test

# 语法检查
syntax:
	@echo "=== Bash Syntax Check ==="
	@for f in $(SCRIPTS); do bash -n $$f && echo "  OK: $$f" || exit 1; done

# ShellCheck 静态分析
lint:
	@echo "=== ShellCheck ==="
	@$(SHELLCHECK) --severity=error $(SCRIPTS) && echo "  PASS: no errors" || exit 1
	@$(SHELLCHECK) --severity=warning $(SCRIPTS) 2>&1 | head -30 || true

# 单元测试
test:
	@echo "=== Unit Tests ==="
	@bash tests/test_common.sh

# 清理状态（开发用）
clean:
	rm -rf .claude/state/
	rm -f /tmp/ai-pipeline-* /tmp/quality-gate-*
