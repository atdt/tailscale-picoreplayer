SHELL_SCRIPTS := $(shell git ls-files '*.sh') .githooks/pre-commit

.PHONY: check install-hooks setup

check:
	shellcheck $(SHELL_SCRIPTS)

install-hooks:
	@git config --local core.hooksPath .githooks
	@echo "Git hooks enabled for this checkout."

setup: check install-hooks
