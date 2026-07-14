#!/usr/bin/env bash
# Tests for bin/agent-kit (the dispatcher).
set -euo pipefail
BASH_BIN="${BASH_BIN:-$(command -v bash)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AI="$REPO_ROOT/bin/agent-kit"
cd "$REPO_ROOT"

PASS=0 FAIL=0
run_test() {
    local name="$1"; shift; local _rc=0
    "$@" >/dev/null 2>&1 || _rc=$?
    if ((_rc == 0)); then PASS=$((PASS+1)); printf '  \033[0;32m✓\033[0m %s\n' "$name"
    else FAIL=$((FAIL+1)); printf '  \033[0;31m✗\033[0m %s\n' "$name"; fi
}

printf 'bin/agent-kit\n'

# --list exits 0 and enumerates commands.
test_list() {
    local out
    out="$("$BASH_BIN" "$AI" --list 2>/dev/null || true)"
    printf '%s' "$out" | grep -q 'ai-search'
}
run_test "--list enumerates commands (exit 0)" test_list

# `agent-kit <name>` resolves the exact libexec file.
test_exact_resolution() {
    "$BASH_BIN" "$AI" repo-stats --help >/dev/null 2>&1
}
run_test "resolves an exact command name" test_exact_resolution

# `agent-kit search` resolves via the ai- prefix fallback to libexec/ai-search.
test_prefix_resolution() {
    local out
    out="$(AI_OUTPUT=json "$BASH_BIN" "$AI" search doctor 2>/dev/null || true)"
    printf '%s' "$out" | grep -q '"tool":"ai-search"'
}
run_test "resolves via the ai- prefix fallback" test_prefix_resolution

# `agent-kit search capabilities` routes through ai-search to the compatibility
# introspection implementation.
test_search_capabilities() {
    local out
    out="$($BASH_BIN "$AI" search capabilities 2>/dev/null || true)"
    printf '%s' "$out" | grep -q 'FULL CAPABILITY MAP'
}
run_test "routes search capabilities to introspection" test_search_capabilities

# `agent-kit search batch` routes through ai-search to the ai-search-multi
# batch implementation.
test_search_batch() {
    local out
    out="$(AI_OUTPUT=json "$BASH_BIN" "$AI" search batch changed-files . 2>/dev/null || true)"
    printf '%s' "$out" | jq -e 'type=="array"' >/dev/null 2>&1
}
run_test "routes search batch to ai-search-multi" test_search_batch

# `agent-kit context estimate` routes through ai-context to query-usage.
test_context_estimate() {
    local out
    out="$($BASH_BIN "$AI" context estimate README.md 2>/dev/null || true)"
    printf '%s' "$out" | grep -q 'query_usage:'
}
run_test "routes context estimate to query-usage" test_context_estimate

# `agent-kit repo stats` routes through ai-repo to repo-stats.
test_repo_stats() {
    local out
    out="$($BASH_BIN "$AI" repo stats 2>/dev/null || true)"
    [[ "$out" =~ ^[0-9]+$ ]]
}
run_test "routes repo stats to repo-stats" test_repo_stats

# `agent-kit inspect shell` routes through ai-inspect to sh-introspect.
test_inspect_shell() {
    local out
    out="$($BASH_BIN "$AI" inspect shell libexec/ai-search 2>/dev/null || true)"
    printf '%s' "$out" | grep -q 'static introspection'
}
run_test "routes inspect shell to sh-introspect" test_inspect_shell

# `agent-kit session checkpoint --help` routes through ai-session to
# session-checkpoint (using --help avoids creating a real snapshot). --help is
# intercepted by lib/common.sh's universal guard before session-checkpoint's
# own usage(), so assert on the script's header description instead.
test_session_checkpoint() {
    local out
    out="$($BASH_BIN "$AI" session checkpoint --help 2>/dev/null || true)"
    printf '%s' "$out" | grep -q 'repository-local checkpoint'
}
run_test "routes session checkpoint to session-checkpoint" test_session_checkpoint

# `agent-kit git origin --help` routes through ai-git to the fused origin module.
test_git_origin() {
    local out
    out="$($BASH_BIN "$AI" git origin --help 2>/dev/null || true)"
    printf '%s' "$out" | grep -q 'Detects the branch'
}
run_test "routes git origin to the ai-git origin module" test_git_origin

# `agent-kit verify refs --help` routes through the fused ai-verify to the file-refs module.
test_verify_refs() {
    local out
    out="$($BASH_BIN "$AI" verify refs --help 2>&1 || true)"
    printf '%s' "$out" | grep -q 'orphaned'
}
run_test "routes verify refs to the fused file-refs module" test_verify_refs

# `agent-kit test select changed` routes through the fused ai-test to the select module.
test_test_select() {
    local out
    out="$(AI_OUTPUT=json $BASH_BIN "$AI" test select json 2>/dev/null || true)"
    printf '%s' "$out" | jq -e 'type=="object" or type=="array"' >/dev/null 2>&1
}
run_test "routes test select to the fused ai-test select module" test_test_select

# --version prints the VERSION file content and exits 0.
test_version() {
    local out
    out="$("$BASH_BIN" "$AI" --version 2>/dev/null)" || return 1
    [[ "$out" == "agent-kit $(tr -d '[:space:]' < "$REPO_ROOT/VERSION")" ]]
}
run_test "--version prints the version (exit 0)" test_version

# Unknown command fails with exit 2.
test_unknown() {
    local _rc=0
    "$BASH_BIN" "$AI" definitely-not-a-command >/dev/null 2>&1 || _rc=$?
    ((_rc == 2))
}
run_test "unknown command exits 2" test_unknown

# No arguments prints the list but exits non-zero (2).
test_no_args() {
    local _rc=0
    "$BASH_BIN" "$AI" >/dev/null 2>&1 || _rc=$?
    ((_rc == 2))
}
run_test "no arguments exits 2" test_no_args

# SECURITY: a command name with a path must never escape libexec/ and exec an
# arbitrary file. Regression guard for the traversal fix.
test_path_traversal_blocked() {
    local evil rc=0
    evil="$(mktemp)"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$evil"
    # Build enough ../ to reach filesystem root, then point at the evil file.
    local up="../../../../../../../../../../../../.."
    "$BASH_BIN" "$AI" "${up}${evil}" >/dev/null 2>&1 || rc=$?
    rm -f "$evil"
    # Must be rejected (exit 2), NOT executed.
    ((rc == 2))
}
run_test "rejects path-like command names (no traversal)" test_path_traversal_blocked

# A leading dot is rejected too.
test_dotfile_rejected() {
    local _rc=0
    "$BASH_BIN" "$AI" .bashrc >/dev/null 2>&1 || _rc=$?
    ((_rc == 2))
}
run_test "rejects dotfile-style names" test_dotfile_rejected

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d\n' "$PASS" "$FAIL"
((FAIL == 0)) && printf '\033[0;32mPASSED\033[0m\n' || { printf '\033[0;31mFAILED\033[0m\n'; exit 1; }
