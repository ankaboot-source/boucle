# Makefile — boucle quality gates
# Targets: make check | make lint | make fix | make test | make install-hooks
# pre-commit/prek hooks and CI call these same targets so behavior never drifts.

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c

SHFMT_FLAGS := -i 2 -bn -ci -sr
BATS := bats

# Shell scripts in the repo: *.sh / *.bash files + scripts in bin/ whose
# SHEBANG says shell. bin/ is a mixed toolbox — bin/check-lessons is Python,
# bin/render-preview.cjs is Node — and shellcheck does not skip a file it
# cannot parse: it reports SC1064/SC1073 and fails the whole lint run. Match
# on the shebang, the way the pre-commit hooks do (`types: [shell]`), so the
# next non-shell tool dropped into bin/ cannot turn CI red.
# Exclude .jcode/ — those scripts are upstream-vendored (synced by bin/update);
# reformatting them creates churn that the next update overwrites.
# Exclude bin/oc — it is upstream-vendored (synced by bin/update from boucle);
# the consumer copy may lag upstream's shfmt-conformant version until the next
# sync, and reformatting it locally creates churn the next update overwrites.
# NOTE: two make quirks constrain how this is written. An unescaped # starts
# a make comment even inside $(shell ...), hence \# in the pattern; and make
# matches parens inside $(shell ...), so an unbalanced ) — a `case` pattern,
# say — closes the call early. Keep every paren here balanced.
SHEBANG_RE := ^\#!.*\b(ba)?sh([[:space:]]|$$)
SH_FILES := $(shell git ls-files '*.sh' '*.bash' 'bin/*' ':!:.jcode' ':!:bin/oc' 2>/dev/null)
ALL_SH := $(shell for f in $(SH_FILES); do if echo "$$f" | grep -qE '\.(sh|bash)$$' || head -1 "$$f" 2>/dev/null | grep -qE '$(SHEBANG_RE)'; then echo "$$f"; fi; done | sort -u)

.PHONY: check lint fix test install-hooks check-sync

# Default: run everything.
check: lint test

# Manual run of the .boucle/ sync guard. Fail-open locally: a shallow clone or
# a repo with no CI context has no commit range to check, so a non-zero exit
# here is informational, not a gate. CI calls bin/check-boucle-sync directly
# (fail-closed) in the check job script block.
check-sync:
	@bin/check-boucle-sync || { echo "(check-boucle-sync skipped — likely shallow clone or no CI context)"; true; }

# Static analysis: shellcheck + shfmt diff (no modifications) + lessons lint.
lint:
	@command -v shellcheck >/dev/null 2>&1 || { echo "ERROR: shellcheck not installed (brew install shellcheck)"; exit 1; }
	@command -v shfmt >/dev/null 2>&1 || { echo "ERROR: shfmt not installed (brew install shfmt)"; exit 1; }
	@files='$(ALL_SH)'; \
	[ -z "$$files" ] && { echo "No shell scripts to check"; exit 0; }; \
	echo ">> shellcheck"; \
	printf '%s\n' $$files | xargs shellcheck -x --severity=warning; \
	echo ">> shfmt -d"; \
	printf '%s\n' $$files | xargs shfmt -d $(SHFMT_FLAGS)
	@echo ">> check-lessons"; \
	python3 bin/check-lessons LESSONS.yml

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
