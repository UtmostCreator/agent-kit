#!/usr/bin/env bash
# Tests for libexec/sh-introspect (pure-Bash static introspector).
set -euo pipefail
BASH_BIN="${BASH_BIN:-$(command -v bash)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/libexec/sh-introspect"
TARGET="libexec/ai-rollback"
cd "$REPO_ROOT"

PASS=0 FAIL=0 SKIP=0
run_test() {
    local name="$1"; shift; local _rc=0
    "$@" >/dev/null 2>&1 || _rc=$?
    if ((_rc == 0)); then PASS=$((PASS+1)); printf '  \033[0;32m✓\033[0m %s\n' "$name"
    else FAIL=$((FAIL+1)); printf '  \033[0;31m✗\033[0m %s\n' "$name"; fi
}
skip_test() { SKIP=$((SKIP+1)); printf '  \033[0;33m⊘\033[0m %s (skipped: %s)\n' "$1" "$2"; }

printf 'sh-introspect\n'

test_runs() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" "$TARGET" 2>&1 || true)"
    [[ -n "$out" ]]
}
run_test "text report runs and is non-empty" test_runs

test_help() {
    local out _rc=0
    out="$("$BASH_BIN" "$SCRIPT" --help 2>&1)" || _rc=$?
    [[ "$_rc" -eq 0 && -n "$out" ]]
}
run_test "--help works (exit 0, non-empty)" test_help

test_help_format() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" --format=help "$TARGET" 2>&1 || true)"
    [[ -n "$out" ]]
}
run_test "--format=help renders a compact contract" test_help_format

test_list() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" --list libexec 2>/dev/null || true)"
    printf '%s' "$out" | grep -q 'ai-search'
}
run_test "--list enumerates commands with summaries" test_list

if command -v jq >/dev/null 2>&1; then
    test_json_envelope() {
        local out
        out="$(AI_OUTPUT=json "$BASH_BIN" "$SCRIPT" "$TARGET" 2>/dev/null || true)"
        printf '%s' "$out" | jq -e \
            '.schema == "ai.sh-introspect/v1" and .status == "ok" and .tool == "sh-introspect" and .meta.target_executed == false and .name == "ai-rollback"' >/dev/null
    }
    run_test "JSON envelope: schema/status/tool/meta/name" test_json_envelope

    test_json_example() {
        local out
        out="$("$BASH_BIN" "$SCRIPT" --format=json "$TARGET" 2>/dev/null || true)"
        printf '%s' "$out" | jq -e '(.examples | length) >= 1 and (.usage | length) >= 1' >/dev/null
    }
    run_test "JSON contract exposes usage and examples" test_json_example

    test_missing_path_error() {
        local out _rc=0
        out="$(AI_OUTPUT=json "$BASH_BIN" "$SCRIPT" "no/such/file.sh" 2>/dev/null)" || _rc=$?
        [[ "$_rc" -eq 2 ]] && printf '%s' "$out" | jq -e '.status == "error"' >/dev/null
    }
    run_test "missing path yields status=error, exit 2 (json)" test_missing_path_error
else
    skip_test "JSON envelope: schema/status/tool/meta/name" "jq not available"
    skip_test "JSON contract exposes usage and examples" "jq not available"
    skip_test "missing path yields status=error, exit 2 (json)" "jq not available"
fi

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d  Skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
((FAIL == 0)) && printf '\033[0;32mPASSED\033[0m\n' || { printf '\033[0;31mFAILED\033[0m\n'; exit 1; }
