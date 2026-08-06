# Makefile — boucle quality gates
# Targets: make check | make lint | make fix | make test | make install-hooks
# pre-commit/prek hooks and CI call these same targets so behavior never drifts.

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c

SHFMT_FLAGS := -i 2 -bn -ci -sr
BATS := bats

# Shell scripts in the repo: *.sh files + extensionless scripts in bin/.
# Exclude .jcode/ — those scripts are upstream-vendored (synced by bin/update);
# reformatting them creates churn that the next update overwrites.
SRC_SH := $(shell git ls-files '*.sh' '*.bash' ':!:.jcode' 2>/dev/null)
BIN_SH := $(shell git ls-files 'bin/*' 2>/dev/null | grep -v '\.cjs$$' || true)
ALL_SH := $(strip $(SRC_SH) $(BIN_SH))

.PHONY: check lint fix test install-hooks

# Default: run everything.
check: lint test

# Static analysis: shellcheck + shfmt diff (no modifications).
lint:
	@command -v shellcheck >/dev/null 2>&1 || { echo "ERROR: shellcheck not installed (brew install shellcheck)"; exit 1; }
	@command -v shfmt >/dev/null 2>&1 || { echo "ERROR: shfmt not installed (brew install shfmt)"; exit 1; }
	@files='$(ALL_SH)'; \
	[ -z "$$files" ] && { echo "No shell scripts to check"; exit 0; }; \
	echo ">> shellcheck"; \
	printf '%s\n' $$files | xargs shellcheck -x --severity=warning; \
	echo ">> shfmt -d"; \
	printf '%s\n' $$files | xargs shfmt -d $(SHFMT_FLAGS)

# Apply formatting in place (local use only).
fix:
	@command -v shfmt >/dev/null 2>&1 || { echo "ERROR: shfmt not installed (brew install shfmt)"; exit 1; }
	@files='$(ALL_SH)'; \
	[ -z "$$files" ] && { echo "No shell scripts to format"; exit 0; }; \
	printf '%s\n' $$files | xargs shfmt -w $(SHFMT_FLAGS); \
	echo "Formatted $$files"

# Run bats unit tests.
test:
	@command -v $(BATS) >/dev/null 2>&1 || { echo "ERROR: bats not installed (brew install bats-core)"; exit 1; }
	@$(BATS) --formatter tap test/

# Install pre-commit hooks (prek preferred, falls back to pre-commit).
install-hooks:
	@if command -v prek >/dev/null 2>&1; then \
		echo "Installing hooks via prek..."; \
		prek install -f; \
	elif command -v pre-commit >/dev/null 2>&1; then \
		echo "Installing hooks via pre-commit..."; \
		pre-commit install --install-hooks; \
	else \
		echo "ERROR: neither prek nor pre-commit installed."; \
		echo "Install one:  brew install prek   (recommended, no Python)"; \
		echo "          or:  brew install pre-commit"; \
		exit 1; \
	fi
	@echo "Hooks installed. Run 'make check' to validate."
