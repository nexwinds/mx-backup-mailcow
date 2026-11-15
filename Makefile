SHELL := /bin/bash
SCRIPTS := install.sh sync-mailcow.sh update.sh diagnose.sh update-scripts.sh

.PHONY: all lint test release checksums clean

all: lint test

lint:
	@for f in $(SCRIPTS) scripts/build-release.sh tests/*.sh tests/lib/*.sh; do \
		bash -n "$$f" || exit 1; \
	done
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck -x -S warning $(SCRIPTS) scripts/build-release.sh tests/*.sh tests/lib/*.sh; \
	else \
		echo "shellcheck not installed, skipping static analysis"; \
	fi

test:
	bash tests/run-tests.sh

release:
	bash scripts/build-release.sh

checksums: release
	@cat dist/SHA256SUMS

clean:
	rm -rf dist
