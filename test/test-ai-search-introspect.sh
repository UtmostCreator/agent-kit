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
    local name="$1"; shift; local _rc=0
    "$@" >/dev/null 2>&1 || _rc=$?
    if ((_rc == 0)); then PASS=$((PASS+1)); printf '  \033[0;32m✓\033[0m %s\n' "$name"
    else FAIL=$((FAIL+1)); printf '  \033[0;31m✗\033[0m %s\n' "$name"; fi
}
skip_test() { SKIP=$((SKIP+1)); printf '  \033[0;33m⊘\033[0m %s (skipped: %s)\n' "$1" "$2"; }

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
else
    skip_test "--introspect emits a valid JSON contract" "jq not available"
fi

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d  Skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
((FAIL == 0)) && printf '\033[0;32mPASSED\033[0m\n' || { printf '\033[0;31mFAILED\033[0m\n'; exit 1; }
