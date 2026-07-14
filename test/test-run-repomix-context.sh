#!/usr/bin/env bash
# Tests for libexec/internal/run-repomix-context
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/libexec/internal/run-repomix-context"
cd "$REPO_ROOT"
BASH_BIN="${BASH_BIN:-$(command -v bash)}"

PASS=0 FAIL=0 SKIP=0
run_test() {
    local name="$1"
    shift
    local _rc=0
    "$@" >/dev/null 2>&1 || _rc=$?
    if ((_rc == 0)); then
        PASS=$((PASS + 1))
        printf '  \033[0;32m✓\033[0m %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        printf '  \033[0;31m✗\033[0m %s\n' "$name"
    fi
}
skip_test() {
    SKIP=$((SKIP + 1))
    printf '  \033[0;33m⊘\033[0m %s (skipped: %s)\n' "$1" "$2"
}

printf 'run-repomix-context\n'

# --help
test_help() { "$BASH_BIN" "$SCRIPT" --help 2>&1 | grep -q 'Usage'; }
run_test "help flag works" test_help

# --help routes through the uniform sh-introspect --format=help view. It surfaces
# the description, Usage, and a runnable Example parsed from the script header.
test_help_examples() {
    local out
    out="$($BASH_BIN "$SCRIPT" --help 2>&1)"
    [[ "$out" == *"Usage:"* ]]
    [[ "$out" == *"Example:"* ]]
    [[ "$out" == *"run-repomix-context"* ]]
}
run_test "help shows usage and a runnable example" test_help_examples

# Delegates to repomix-context-tree
if command -v scc >/dev/null 2>&1 && command -v repomix >/dev/null 2>&1; then
    test_runs() {
        local out
        out="$("$BASH_BIN" "$SCRIPT" . --top 1 2>&1 || true)"
        [[ -n "$out" ]]
    }
    run_test "delegates to repomix-context-tree" test_runs
else
    skip_test "delegates to repomix-context-tree" "scc or repomix not installed"
fi

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d  Skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
if ((FAIL == 0)); then
    printf '\033[0;32mPASSED\033[0m\n'
else
    printf '\033[0;31mFAILED\033[0m\n'
    exit 1
fi
