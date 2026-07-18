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

    # An unknown flag under --json must fail with a parseable error envelope
    # (schema/status/error), not plain-text stderr, and not the ok catalog.
    test_json_error_envelope() {
        local out _rc=0
        out="$("$BASH_BIN" "$SCRIPT" --json --bogus 2>/dev/null)" || _rc=$?
        [[ "$_rc" -eq 2 ]] || return 1
        printf '%s' "$out" | jq -e \
            '.schema == "ai.repo-tool-inventory/v1" and .status == "error" and .tool == "repo-tool-inventory" and (.error | test("--bogus")) and (.commands | length) == 0' >/dev/null
    }
    run_test "--json unknown flag emits a JSON error envelope (exit 2)" test_json_error_envelope

    # The env-var form of the JSON signal must produce the same error envelope.
    test_json_error_envelope_env() {
        local out _rc=0
        out="$(AI_OUTPUT=json "$BASH_BIN" "$SCRIPT" foo 2>/dev/null)" || _rc=$?
        [[ "$_rc" -eq 2 ]] || return 1
        printf '%s' "$out" | jq -e \
            '.status == "error" and (.error | test("unexpected argument"))' >/dev/null
    }
    run_test "AI_OUTPUT=json positional arg emits a JSON error envelope" test_json_error_envelope_env

    # --introspect must now advertise non-empty modes[] and flags[].
    test_introspect_modes_flags() {
        local out
        out="$("$BASH_BIN" "$SCRIPT" --introspect 2>/dev/null || true)"
        printf '%s' "$out" | jq -e \
            '(.modes | length) > 0 and (.flags | length) > 0' >/dev/null
    }
    run_test "--introspect advertises modes[] and flags[]" test_introspect_modes_flags

    # Regression (defect 1): every JSON summary must be a single line, matching
    # the human --list table (no embedded newlines from multi-line comments).
    test_json_summary_one_line() {
        local out
        out="$("$BASH_BIN" "$SCRIPT" --json 2>/dev/null || true)"
        printf '%s' "$out" | jq -e \
            '[.commands[] | select(.summary | contains("\n"))] | length == 0' >/dev/null
    }
    run_test "--json summaries are one line (human/JSON parity)" test_json_summary_one_line
else
    skip_test "--json emits a valid command catalog" "jq not available"
    skip_test "--json summaries are one line (human/JSON parity)" "jq not available"
fi

# Regression (defect 2): an unknown flag must error (exit != 0), not silently
# fall through to the default table output.
test_unknown_flag_errors() {
    local _rc=0
    "$BASH_BIN" "$SCRIPT" --bogus >/dev/null 2>&1 || _rc=$?
    [[ "$_rc" -ne 0 ]]
}
run_test "unknown flag errors instead of default output" test_unknown_flag_errors

# A stray positional (not starting with '-') must be diagnosed as an unexpected
# argument, not a misleading "unknown flag".
test_positional_arg_error_text() {
    local out _rc=0
    out="$("$BASH_BIN" "$SCRIPT" foo 2>&1)" || _rc=$?
    [[ "$_rc" -eq 2 ]] || return 1
    printf '%s' "$out" | grep -q 'unexpected argument: foo'
}
run_test "positional arg reported as unexpected argument (not a flag)" test_positional_arg_error_text

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d  Skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
((FAIL == 0)) && printf '\033[0;32mPASSED\033[0m\n' || {
    printf '\033[0;31mFAILED\033[0m\n'
    exit 1
}
