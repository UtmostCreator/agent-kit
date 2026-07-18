#!/usr/bin/env bash
# Tests for libexec/ai-search-introspect
set -euo pipefail
BASH_BIN="${BASH_BIN:-$(command -v bash)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/libexec/ai-search-introspect"
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

printf 'ai-search-introspect\n'

# Default report: renders the capability map live from source and exits cleanly.
test_report() {
    local out _rc=0
    out="$("$BASH_BIN" "$SCRIPT" 2>/dev/null)" || _rc=$?
    [[ "$_rc" -eq 0 && -n "$out" ]] &&
        printf '%s' "$out" | grep -q 'CAPABILITY MAP'
}
run_test "report runs (exit 0) and shows the capability map" test_report

# The report is parsed from the real source files, so known mode families appear.
test_report_modes() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" 2>/dev/null || true)"
    printf '%s' "$out" | grep -q 'MODES' &&
        printf '%s' "$out" | grep -q 'ai-search'
}
run_test "report lists search modes parsed from source" test_report_modes

test_help() {
    local out _rc=0
    out="$("$BASH_BIN" "$SCRIPT" --help 2>&1)" || _rc=$?
    [[ "$_rc" -eq 0 && -n "$out" ]]
}
run_test "--help works (exit 0, non-empty)" test_help

# --probe additionally runtime-probes every mode; must still exit 0.
test_probe() {
    "$BASH_BIN" "$SCRIPT" --probe >/dev/null 2>&1
}
run_test "--probe reaches every mode (exit 0)" test_probe

if command -v jq >/dev/null 2>&1; then
    test_json() {
        local out
        out="$("$BASH_BIN" "$SCRIPT" --introspect 2>/dev/null || true)"
        printf '%s' "$out" | jq -e \
            '.status == "ok" and .name == "ai-search-introspect"' >/dev/null
    }
    run_test "--introspect emits a valid JSON contract" test_json

    # --introspect now advertises the real --probe/--json flags (populated via the
    # header's `# Flags:` line) so an agent can discover them machine-readably.
    test_introspect_flags() {
        local out
        out="$("$BASH_BIN" "$SCRIPT" --introspect 2>/dev/null || true)"
        printf '%s' "$out" | jq -e \
            '(.flags | index("--probe")) and (.flags | index("--json"))' >/dev/null
    }
    run_test "--introspect flags[] advertises --probe and --json" test_introspect_flags

    # --json emits the parsed capability surface under the sibling ai.<tool>/v1
    # envelope convention (schema + status + tool), with mode families populated.
    test_json_capabilities() {
        local out
        out="$("$BASH_BIN" "$SCRIPT" --json 2>/dev/null || true)"
        printf '%s' "$out" | jq -e '
            .schema == "ai.ai-search-introspect/v1" and
            .status == "ok" and
            .tool == "ai-search-introspect" and
            (.modes.content | length) > 0 and
            (.flags | length) > 0 and
            (.env | index("AI_OUTPUT"))' >/dev/null
    }
    run_test "--json emits the ai.ai-search-introspect/v1 capability envelope" test_json_capabilities

    # The AI_OUTPUT=json env var is the repo-wide activation and must match --json.
    test_json_env_form() {
        local out
        out="$(AI_OUTPUT=json "$BASH_BIN" "$SCRIPT" 2>/dev/null || true)"
        printf '%s' "$out" | jq -e \
            '.schema == "ai.ai-search-introspect/v1" and .status == "ok"' >/dev/null
    }
    run_test "AI_OUTPUT=json env form emits the JSON capability envelope" test_json_env_form
else
    skip_test "--introspect emits a valid JSON contract" "jq not available"
    skip_test "--introspect flags[] advertises --probe and --json" "jq not available"
    skip_test "--json emits the ai.ai-search-introspect/v1 capability envelope" "jq not available"
    skip_test "AI_OUTPUT=json env form emits the JSON capability envelope" "jq not available"
fi

# An unrecognized argument fails (exit 2) and prints an actionable valid-args hint.
test_unknown_arg_hint() {
    local err _rc=0
    err="$("$BASH_BIN" "$SCRIPT" --bogus 2>&1 >/dev/null)" || _rc=$?
    [[ "$_rc" -eq 2 ]] && printf '%s' "$err" | grep -q 'valid args:'
}
run_test "unknown argument exits 2 with a valid-args hint" test_unknown_arg_hint

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d  Skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
((FAIL == 0)) && printf '\033[0;32mPASSED\033[0m\n' || {
    printf '\033[0;31mFAILED\033[0m\n'
    exit 1
}
