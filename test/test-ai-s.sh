#!/usr/bin/env bash
# Tests for libexec/ai-s (the short search shorthand).
set -euo pipefail
BASH_BIN="${BASH_BIN:-$(command -v bash)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AI="$REPO_ROOT/bin/agent-kit"
cd "$REPO_ROOT"

PASS=0 FAIL=0
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

printf 'libexec/ai-s\n'

# `s QUERY` (no root) is equivalent to `search text QUERY <git-root>`: same result
# count as the canonical form pointed at the repo root.
test_equivalence_default() {
    local a b
    a="$(AI_OUTPUT=json "$BASH_BIN" "$AI" s emit_json libexec 2>/dev/null | jq '.results | length')"
    b="$(AI_OUTPUT=json "$BASH_BIN" "$AI" search text emit_json libexec 2>/dev/null | jq '.results | length')"
    [[ -n "$a" && "$a" == "$b" ]]
}
run_test "s QUERY ROOT matches search text QUERY ROOT" test_equivalence_default

# `s QUERY` with no root auto-detects the git top-level (finds matches that only
# exist outside the current libexec/ subtree — proving the root widened to repo).
test_root_autodetect() {
    local out
    # 'AGENTKIT_DIR_NAME' appears in install.sh at the repo root, not in libexec/.
    out="$(AI_OUTPUT=json "$BASH_BIN" "$AI" s AGENTKIT_DIR_NAME 2>/dev/null)" || return 1
    printf '%s' "$out" | jq -e '.results | length >= 1' >/dev/null 2>&1
}
run_test "s QUERY auto-detects the git root" test_root_autodetect

# --changed selects the changed-text mode.
test_changed_mode() {
    local out
    out="$(AI_OUTPUT=json "$BASH_BIN" "$AI" s export --changed 2>/dev/null)" || return 1
    printf '%s' "$out" | jq -e '.mode=="changed-text"' >/dev/null 2>&1
}
run_test "--changed maps to the changed-text mode" test_changed_mode

# --tracked selects the tracked mode.
test_tracked_mode() {
    local out
    out="$(AI_OUTPUT=json "$BASH_BIN" "$AI" s ai_search_main --tracked 2>/dev/null)" || return 1
    printf '%s' "$out" | jq -e '.mode=="tracked"' >/dev/null 2>&1
}
run_test "--tracked maps to the tracked mode" test_tracked_mode

# A value-taking flag (-C N) is paired, not misread as the ROOT positional.
test_value_flag_pairing() {
    local out
    out="$(AI_OUTPUT=json "$BASH_BIN" "$AI" s emit_json libexec -C 2 2>/dev/null)" || return 1
    # If '2' had been taken as ROOT, ai-search would have errored on a bad path.
    printf '%s' "$out" | jq -e '.status=="ok"' >/dev/null 2>&1
}
run_test "value flag '-C 2' is paired, not treated as ROOT" test_value_flag_pairing

# An explicit ROOT (second positional) is honored over the auto-detected root.
test_explicit_root() {
    local out
    out="$(AI_OUTPUT=json "$BASH_BIN" "$AI" s emit_json libexec 2>/dev/null)" || return 1
    printf '%s' "$out" | jq -e '.status=="ok" and (.results|type=="array")' >/dev/null 2>&1
}
run_test "explicit ROOT positional is honored" test_explicit_root

# Missing query is a shorthand usage error (exit 2).
test_missing_query() {
    local _rc=0
    "$BASH_BIN" "$AI" s >/dev/null 2>&1 || _rc=$?
    ((_rc == 2))
}
run_test "missing query exits 2" test_missing_query

# --help and --introspect resolve through the universal introspection surface.
test_help() {
    "$BASH_BIN" "$AI" s --help 2>/dev/null | grep -q 'Short repository search'
}
run_test "--help prints the contract" test_help

test_introspect() {
    "$BASH_BIN" "$AI" s --introspect 2>/dev/null | jq -e '.name=="ai-s"' >/dev/null 2>&1
}
run_test "--introspect emits the JSON contract" test_introspect

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d\n' "$PASS" "$FAIL"
((FAIL == 0)) && printf '\033[0;32mPASSED\033[0m\n' || {
    printf '\033[0;31mFAILED\033[0m\n'
    exit 1
}
