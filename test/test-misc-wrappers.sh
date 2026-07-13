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
    local name="$1"; shift; local _rc=0
    "$@" >/dev/null 2>&1 || _rc=$?
    if ((_rc == 0)); then PASS=$((PASS+1)); printf '  \033[0;32m✓\033[0m %s\n' "$name"
    else FAIL=$((FAIL+1)); printf '  \033[0;31m✗\033[0m %s\n' "$name"; fi
}

printf 'misc wrappers\n'

# repo-stats: prints a numeric tracked-file count.
test_repo_stats() {
    local out
    out="$("$BASH_BIN" "$REPO_ROOT/libexec/repo-stats")"
    [[ "$out" =~ ^[0-9]+$ ]]
}
run_test "repo-stats prints a numeric count" test_repo_stats

# ai-file-freshness: read-only git status wrapper, exit 0.
test_file_freshness() {
    "$BASH_BIN" "$REPO_ROOT/libexec/ai-file-freshness" >/dev/null 2>&1
}
run_test "ai-file-freshness runs (exit 0)" test_file_freshness

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d  Skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
if ((FAIL > 0)); then printf '\033[0;31mFAILED\033[0m\n'; exit 1; fi
printf '\033[0;32mPASSED\033[0m\n'
