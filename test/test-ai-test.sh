#!/usr/bin/env bash
# Tests for libexec/ai-test (fused ai-test-select + run-test-focused +
# run-repo-tests). Replaces test-ai-test-select.sh, which tested the
# pre-fusion standalone ai-test-select engine. run-test-focused and
# run-repo-tests had no dedicated test file before fusion; this file adds
# focused argument-parsing/--help/--introspect/error-path coverage for the
# run and all modes but deliberately never invokes a real phpunit run or the
# real heavy whole-suite run here, matching the restraint the pre-fusion
# engines' (lack of) test coverage already implied.
set -euo pipefail
BASH_BIN="${BASH_BIN:-$(command -v bash)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/libexec/ai-test"
cd "$REPO_ROOT"

PASS=0 FAIL=0 SKIP=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

run_test() {
    local name="$1"; shift; local _rc=0
    "$@" >/dev/null 2>&1 || _rc=$?
    if ((_rc == 0)); then PASS=$((PASS+1)); printf '  \033[0;32m✓\033[0m %s\n' "$name"
    else FAIL=$((FAIL+1)); printf '  \033[0;31m✗\033[0m %s\n' "$name"; fi
}
skip_test() { SKIP=$((SKIP+1)); printf '  \033[0;33m⊘\033[0m %s (skipped: %s)\n' "$1" "$2"; }

printf 'ai-test\n'

# =============================================================================
# select (fused from ai-test-select)
# =============================================================================

test_select_help() { "$BASH_BIN" "$SCRIPT" select --help 2>&1 | grep -q 'Usage'; }
run_test "select --help works" test_select_help

test_select_no_mode() { ! "$BASH_BIN" "$SCRIPT" select 2>/dev/null; }
run_test "select missing mode exits with error" test_select_no_mode

test_select_changed() {
    local out
    out="$(AI_LOG_DIR="$TMP/logs" AI_EVENT_LOG="$TMP/logs/ev.jsonl" "$BASH_BIN" "$SCRIPT" select changed 2>/dev/null)"
    echo "$out" | jq -e '.input_files' >/dev/null
    echo "$out" | jq -e '.candidate_tests' >/dev/null
    echo "$out" | jq -e '.recommended_commands' >/dev/null
}
run_test "select changed returns JSON with required keys" test_select_changed

test_select_file_mode() {
    local out
    out="$(AI_LOG_DIR="$TMP/logs2" AI_EVENT_LOG="$TMP/logs2/ev.jsonl" "$BASH_BIN" "$SCRIPT" select file lib/common.sh 2>/dev/null)"
    echo "$out" | jq -e '.input_files' >/dev/null
}
run_test "select file mode returns JSON" test_select_file_mode

test_select_json_mode() {
    local out
    out="$(AI_LOG_DIR="$TMP/logs3" AI_EVENT_LOG="$TMP/logs3/ev.jsonl" "$BASH_BIN" "$SCRIPT" select json 2>/dev/null)"
    echo "$out" | jq -e '.candidate_tests' >/dev/null
}
run_test "select json mode returns JSON" test_select_json_mode

test_select_symbol() {
    local out
    out="$(AI_LOG_DIR="$TMP/logs4" AI_EVENT_LOG="$TMP/logs4/ev.jsonl" "$BASH_BIN" "$SCRIPT" select symbol "log_info" 2>/dev/null)"
    echo "$out" | jq -e '.candidate_tests' >/dev/null
}
run_test "select symbol mode searches for symbol usage" test_select_symbol

test_select_unknown_mode() {
    ! AI_LOG_DIR="$TMP/logs5" AI_EVENT_LOG="$TMP/logs5/ev.jsonl" "$BASH_BIN" "$SCRIPT" select nonexistent 2>/dev/null
}
run_test "select unknown mode fails" test_select_unknown_mode

# =============================================================================
# run (fused from run-test-focused). Argument-parsing/error-path coverage
# only — never invokes a real phpunit run in this test file.
# =============================================================================

test_run_help() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" run --help 2>&1)"
    [[ "$out" == *"agent-kit test run"* ]]
}
run_test "run --help prints usage" test_run_help

if command -v jq >/dev/null 2>&1; then
    test_run_introspect() {
        local out
        out="$("$BASH_BIN" "$SCRIPT" run --introspect 2>&1)"
        jq -e '.schema == "ai.sh-introspect/v1"' <<<"$out" >/dev/null
    }
    run_test "run --introspect emits a valid contract" test_run_introspect
else
    skip_test "run --introspect emits a valid contract" "jq not installed"
fi

test_run_no_args() {
    local rc=0
    "$BASH_BIN" "$SCRIPT" run >/dev/null 2>&1 || rc=$?
    ((rc == 2))
}
run_test "run missing filter/path exits 2" test_run_no_args

if [[ -x vendor/bin/phpunit ]]; then
    skip_test "run reports missing vendor/bin/phpunit" "vendor/bin/phpunit is present"
else
    test_run_missing_phpunit() {
        local rc=0
        "$BASH_BIN" "$SCRIPT" run --filter NoSuchTest >/dev/null 2>&1 || rc=$?
        ((rc == 1))
    }
    run_test "run reports missing vendor/bin/phpunit" test_run_missing_phpunit
fi

# =============================================================================
# all (fused from run-repo-tests). Argument-parsing/error-path coverage
# only — NEVER invokes the real whole-suite run here (heavy/slow); the
# pre-fusion standalone run-repo-tests had no dedicated automated test file
# either, so this preserves the same restraint.
# =============================================================================

test_all_help() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" all --help 2>&1)"
    [[ "$out" == *"agent-kit test all"* ]]
}
run_test "all --help prints usage" test_all_help

if command -v jq >/dev/null 2>&1; then
    test_all_introspect() {
        local out
        out="$("$BASH_BIN" "$SCRIPT" all --introspect 2>&1)"
        jq -e '.schema == "ai.sh-introspect/v1"' <<<"$out" >/dev/null
    }
    run_test "all --introspect emits a valid contract" test_all_introspect
else
    skip_test "all --introspect emits a valid contract" "jq not installed"
fi

test_all_bad_paratest_procs() {
    local rc=0
    PARATEST_PROCS=abc "$BASH_BIN" "$SCRIPT" all >/dev/null 2>&1 || rc=$?
    ((rc == 2))
}
run_test "all rejects non-numeric PARATEST_PROCS" test_all_bad_paratest_procs

# =============================================================================
# group-level dispatch
# =============================================================================

test_group_help() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" --help 2>&1 || true)"
    [[ "$out" == *"agent-kit test"* ]]
}
run_test "group --help prints usage" test_group_help

test_group_unknown_mode() {
    local rc=0
    "$BASH_BIN" "$SCRIPT" bogus >/dev/null 2>&1 || rc=$?
    ((rc == 2))
}
run_test "unknown top-level mode exits 2" test_group_unknown_mode

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d  Skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
((FAIL == 0)) && printf '\033[0;32mPASSED\033[0m\n' || { printf '\033[0;31mFAILED\033[0m\n'; exit 1; }
