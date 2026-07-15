#!/usr/bin/env bash
# Smoke tests for thin read-only wrapper scripts:
#   repo-stats, ai-file-freshness
set -euo pipefail
BASH_BIN="${BASH_BIN:-$(command -v bash)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
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

printf 'misc wrappers\n'

# repo-stats: prints a numeric tracked-file count.
test_repo_stats() {
    local out
    out="$("$BASH_BIN" "$REPO_ROOT/libexec/repo-stats")"
    [[ "$out" =~ ^[0-9]+$ ]]
}
run_test "repo-stats prints a numeric count" test_repo_stats

# repo-stats --help: emits the sh-introspect --format=help contract, exit 0.
test_repo_stats_help() {
    local out _rc=0
    out="$("$BASH_BIN" "$REPO_ROOT/libexec/repo-stats" --help 2>&1)" || _rc=$?
    [[ "$_rc" -eq 0 && "$out" == *"repo-stats"* ]]
}
run_test "repo-stats --help prints contract, exit 0" test_repo_stats_help

# repo-stats -h: same short-flag path.
test_repo_stats_help_short() {
    local out _rc=0
    out="$("$BASH_BIN" "$REPO_ROOT/libexec/repo-stats" -h 2>&1)" || _rc=$?
    [[ "$_rc" -eq 0 && -n "$out" ]]
}
run_test "repo-stats -h prints contract, exit 0" test_repo_stats_help_short

# repo-stats --introspect: emits the machine-readable JSON contract, exit 0.
test_repo_stats_introspect() {
    local out _rc=0
    out="$("$BASH_BIN" "$REPO_ROOT/libexec/repo-stats" --introspect 2>&1)" || _rc=$?
    [[ "$_rc" -eq 0 ]] || return 1
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$out" | jq -e '.schema == "ai.sh-introspect/v1"' >/dev/null
    else
        [[ "$out" == *"schema"* ]]
    fi
}
run_test "repo-stats --introspect emits JSON contract, exit 0" test_repo_stats_introspect

# ai-file-freshness: read-only git status wrapper, exit 0.
test_file_freshness() {
    "$BASH_BIN" "$REPO_ROOT/libexec/ai-file-freshness" >/dev/null 2>&1
}
run_test "ai-file-freshness runs (exit 0)" test_file_freshness

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d  Skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
if ((FAIL > 0)); then
    printf '\033[0;31mFAILED\033[0m\n'
    exit 1
fi
printf '\033[0;32mPASSED\033[0m\n'
