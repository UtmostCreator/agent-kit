#!/usr/bin/env bash
# Tests for libexec/repo-tool-inventory
set -euo pipefail
BASH_BIN="${BASH_BIN:-$(command -v bash)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/libexec/repo-tool-inventory"
cd "$REPO_ROOT"

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

printf 'repo-tool-inventory\n'

# repo-tool-inventory is now a pure-Bash command catalog built on sh-introspect.
test_runs() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" 2>/dev/null || true)"
    printf '%s' "$out" | grep -q 'ai-search'
}
run_test "table lists commands with summaries" test_runs

test_help() {
    local out _rc=0
    out="$("$BASH_BIN" "$SCRIPT" --help 2>&1)" || _rc=$?
    [[ "$_rc" -eq 0 && -n "$out" ]]
}
run_test "--help works (exit 0, non-empty)" test_help

if command -v jq >/dev/null 2>&1; then
    test_json() {
        local out
        out="$("$BASH_BIN" "$SCRIPT" --json 2>/dev/null || true)"
        printf '%s' "$out" | jq -e \
            '.status == "ok" and .tool == "repo-tool-inventory" and (.commands | length) > 0' >/dev/null
    }
    run_test "--json emits a valid command catalog" test_json
else
    skip_test "--json emits a valid command catalog" "jq not available"
fi

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d  Skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
((FAIL == 0)) && printf '\033[0;32mPASSED\033[0m\n' || {
    printf '\033[0;31mFAILED\033[0m\n'
    exit 1
}
