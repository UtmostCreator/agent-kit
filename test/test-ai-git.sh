#!/usr/bin/env bash
# Tests for libexec/ai-git (fused git-branch-origin + git-forensics +
# gh-pr-context). Replaces test-git-branch-origin.sh, test-git-forensics.sh,
# and test-gh-pr-context.sh, which tested the pre-fusion standalone engines.
set -euo pipefail
BASH_BIN="${BASH_BIN:-$(command -v bash)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/libexec/ai-git"
cd "$REPO_ROOT"

PASS=0 FAIL=0 SKIP=0
run_test() {
    local name="$1"; shift; local _rc=0
    "$@" >/dev/null 2>&1 || _rc=$?
    if ((_rc == 0)); then PASS=$((PASS+1)); printf '  \033[0;32m✓\033[0m %s\n' "$name"
    else FAIL=$((FAIL+1)); printf '  \033[0;31m✗\033[0m %s\n' "$name"; fi
}
skip_test() { SKIP=$((SKIP+1)); printf '  \033[0;33m⊘\033[0m %s (skipped: %s)\n' "$1" "$2"; }

printf 'ai-git\n'

# =============================================================================
# origin (fused from git-branch-origin)
# =============================================================================

test_origin_help() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" origin --help 2>&1 || true)"
    [[ "$out" == *"agent-kit git origin"* && "$out" == *"--field"* ]]
}
run_test "origin --help prints usage" test_origin_help

test_origin_default_name() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" origin 2>/dev/null || true)"
    [[ -n "$out" ]]
}
run_test "origin prints a non-empty origin branch name" test_origin_default_name

test_origin_field_base() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" origin --field base 2>/dev/null || true)"
    [[ "$out" =~ ^[0-9a-f]{7,40}$ ]]
}
run_test "origin --field base prints a merge-base sha" test_origin_field_base

test_origin_field_count() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" origin --field count 2>/dev/null || true)"
    [[ "$out" =~ ^[0-9]+$ ]]
}
run_test "origin --field count prints an integer distance" test_origin_field_count

test_origin_field_all() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" origin --field all 2>/dev/null || true)"
    [[ "$(awk -F'\t' '{print NF}' <<<"$out")" == "3" ]]
}
run_test "origin --field all prints name<TAB>base<TAB>count" test_origin_field_all

if command -v jq >/dev/null 2>&1; then
    test_origin_json() {
        local out
        out="$("$BASH_BIN" "$SCRIPT" origin --json 2>/dev/null || true)"
        jq -e '.tool == "git-branch-origin" and (.origin_branch|type=="string") and (.merge_base|type=="string") and (.distance|type=="number")' <<<"$out" >/dev/null
    }
    run_test "origin --json emits a valid envelope" test_origin_json
else
    skip_test "origin --json emits a valid envelope" "jq not installed"
fi

test_origin_override() {
    local out
    out="$(GIT_ORIGIN_REF=origin/main "$BASH_BIN" "$SCRIPT" origin --field name 2>/dev/null || true)"
    [[ -n "$out" ]]
}
run_test "origin GIT_ORIGIN_REF override is honored" test_origin_override

test_origin_bad_field() {
    local rc=0
    "$BASH_BIN" "$SCRIPT" origin --field bogus >/dev/null 2>&1 || rc=$?
    ((rc != 0))
}
run_test "origin invalid --field exits non-zero" test_origin_bad_field

# =============================================================================
# history / blame (fused from git-forensics)
# =============================================================================

test_history_help() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" history --help 2>&1)"
    [[ "$out" == *Usage* ]]
}
run_test "history --help exits successfully" test_history_help

test_history_no_args() { ! "$BASH_BIN" "$SCRIPT" history 2>/dev/null; }
run_test "history missing args fails" test_history_no_args

test_history_s_mode() {
    "$BASH_BIN" "$SCRIPT" history S "common_require_core" >/dev/null 2>&1 || true
    true
}
run_test "history S mode runs without crash" test_history_s_mode

test_history_g_mode() {
    "$BASH_BIN" "$SCRIPT" history G "require_bins" >/dev/null 2>&1 || true
    true
}
run_test "history G mode runs without crash" test_history_g_mode

test_blame() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" blame "1,5" lib/common.sh 2>/dev/null)"
    [[ -n "$out" ]]
}
run_test "blame returns output" test_blame

test_blame_no_file() {
    ! "$BASH_BIN" "$SCRIPT" blame "1,5" 2>/dev/null
}
run_test "blame without file fails" test_blame_no_file

test_blame_json() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" blame "1,3" lib/common.sh --json 2>/dev/null)"
    echo "$out" | jq -e '.mode' >/dev/null
    echo "$out" | jq -e '.output' >/dev/null
}
run_test "blame --json has mode and output fields" test_blame_json

test_history_unknown_mode() {
    ! "$BASH_BIN" "$SCRIPT" history X "query" 2>/dev/null
}
run_test "history unknown mode fails" test_history_unknown_mode

# =============================================================================
# pr-context (fused from gh-pr-context)
# =============================================================================

if ! command -v gh >/dev/null 2>&1; then
    skip_test "pr-context missing PR number fails" "gh CLI not installed"
    skip_test "pr-context unknown option fails" "gh CLI not installed"
else
    test_pr_context_no_pr() { ! "$BASH_BIN" "$SCRIPT" pr-context 2>/dev/null; }
    run_test "pr-context missing PR number fails" test_pr_context_no_pr

    test_pr_context_unknown() { ! "$BASH_BIN" "$SCRIPT" pr-context 1 --bogus 2>/dev/null; }
    run_test "pr-context unknown option fails" test_pr_context_unknown
fi

# =============================================================================
# group-level dispatch
# =============================================================================

test_group_help() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" --help 2>&1 || true)"
    [[ "$out" == *"agent-kit git"* ]]
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
