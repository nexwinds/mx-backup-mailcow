#!/usr/bin/env bash
#
# Test suite entry point.
#
set -uo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1

if [[ -n "${MXB_TEST_TOOLS:-}" ]]; then
    PATH="$MXB_TEST_TOOLS:$PATH"
    export PATH
fi

missing=0
for tool in jq bash tar sha256sum; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf 'missing required test tool: %s\n' "$tool" >&2
        missing=1
    fi
done
if [[ "$missing" -ne 0 ]]; then
    printf '\nOn Windows, set MXB_TEST_TOOLS to a directory containing jq.exe and shellcheck.exe.\n' >&2
    exit 1
fi

passed=0
failed=0
failed_names=()

for test_file in tests/test-*.sh; do
    [[ -f "$test_file" ]] || continue
    printf '\n=== %s ===\n' "$test_file"
    if bash "$test_file"; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
        failed_names+=("$test_file")
    fi
done

printf '\n==============================\n'
printf 'test files: %d passed, %d failed\n' "$passed" "$failed"
if [[ "$failed" -ne 0 ]]; then
    printf 'failed:\n'
    printf '  %s\n' "${failed_names[@]}"
    exit 1
fi
exit 0
