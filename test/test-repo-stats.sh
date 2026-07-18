#!/usr/bin/env bash
# Tests for the repo-stats command.
#
# Regression coverage:
#   - Run outside a git repository must NOT print a misleading numeric '0' to
#     stdout while the underlying git command has failed. Instead it must exit
#     non-zero with the error confined to stderr and empty stdout.
set -euo pipefail
BASH_BIN="${BASH_BIN:-$(command -v bash)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0 FAIL=0 SKIP=0
run_test() {
    local name="$1"
    shift
    local _rc=0
    "$@" || _rc=$?
    if ((_rc == 0)); then
        PASS=$((PASS + 1))
        printf '  \033[0;32m✓\033[0m %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        printf '  \033[0;31m✗\033[0m %s\n' "$name"
    fi
}

printf 'repo-stats\n'

# Inside the repo: prints a numeric tracked-file count on stdout, exit 0.
test_inside_repo_numeric() {
    local out _rc=0
    out="$(cd "$REPO_ROOT" && "$BASH_BIN" "$REPO_ROOT/libexec/repo-stats" 2>/dev/null)" || _rc=$?
    [[ "$_rc" -eq 0 && "$out" =~ ^[0-9]+$ ]]
}
run_test "prints numeric count inside a git repo" test_inside_repo_numeric

# Regression: outside a git repo, stdout must be empty (no misleading '0') and
# exit code must be non-zero. Before the fix, stdout contained '0'.
test_outside_repo_no_misleading_zero() {
    local tmp out _rc=0
    tmp="$(mktemp -d)"
    out="$(cd "$tmp" && "$BASH_BIN" "$REPO_ROOT/libexec/repo-stats" 2>/dev/null)" || _rc=$?
    rmdir "$tmp" 2>/dev/null || true
    # Must fail (non-zero) and print nothing to stdout.
    [[ "$_rc" -ne 0 && -z "$out" ]]
}
run_test "outside a git repo: non-zero exit, empty stdout (no misleading 0)" test_outside_repo_no_misleading_zero

# Regression: the git-repo error must be reported on stderr.
test_outside_repo_stderr_message() {
    local tmp err _rc=0
    tmp="$(mktemp -d)"
    err="$(cd "$tmp" && "$BASH_BIN" "$REPO_ROOT/libexec/repo-stats" 2>&1 >/dev/null)" || _rc=$?
    rmdir "$tmp" 2>/dev/null || true
    [[ "$_rc" -ne 0 && -n "$err" ]]
}
run_test "outside a git repo: error reported on stderr" test_outside_repo_stderr_message

# --json (and AI_OUTPUT=json) emit an ai.repo-stats/v1 envelope with a numeric
# tracked_files count and status:"ok", exit 0. Opt-in and additive.
test_json_envelope() {
    local out _rc=0
    out="$(cd "$REPO_ROOT" && "$BASH_BIN" "$REPO_ROOT/libexec/repo-stats" --json 2>/dev/null)" || _rc=$?
    [[ "$_rc" -eq 0 ]] || return 1
    printf '%s' "$out" | jq -e \
        '.schema=="ai.repo-stats/v1" and .status=="ok" and .tool=="repo-stats" and (.tracked_files|type=="number")' >/dev/null
}
run_test "--json emits ai.repo-stats/v1 envelope with numeric tracked_files" test_json_envelope

test_ai_output_env_envelope() {
    local out _rc=0
    out="$(cd "$REPO_ROOT" && AI_OUTPUT=json "$BASH_BIN" "$REPO_ROOT/libexec/repo-stats" 2>/dev/null)" || _rc=$?
    [[ "$_rc" -eq 0 ]] || return 1
    printf '%s' "$out" | jq -e '.schema=="ai.repo-stats/v1" and .status=="ok"' >/dev/null
}
run_test "AI_OUTPUT=json emits the same ai.repo-stats/v1 envelope" test_ai_output_env_envelope

# Backward compat: the bare default invocation still prints ONLY a numeric count
# on stdout (no label, no envelope), so existing callers/scripts are unaffected.
test_default_still_bare_integer() {
    local out _rc=0
    out="$(cd "$REPO_ROOT" && "$BASH_BIN" "$REPO_ROOT/libexec/repo-stats" 2>/dev/null)" || _rc=$?
    [[ "$_rc" -eq 0 && "$out" =~ ^[0-9]+$ ]]
}
run_test "default invocation still prints a bare integer (no envelope)" test_default_still_bare_integer

# Outside a git repo with --json: an error envelope (status:"error"), exit non-zero.
test_json_error_envelope_outside_repo() {
    local tmp out _rc=0
    tmp="$(mktemp -d)"
    out="$(cd "$tmp" && "$BASH_BIN" "$REPO_ROOT/libexec/repo-stats" --json 2>/dev/null)" || _rc=$?
    rmdir "$tmp" 2>/dev/null || true
    [[ "$_rc" -ne 0 ]] || return 1
    printf '%s' "$out" | jq -e '.schema=="ai.repo-stats/v1" and .status=="error"' >/dev/null
}
run_test "outside a git repo with --json: status:\"error\" envelope, non-zero exit" test_json_error_envelope_outside_repo

# --introspect exposes the --json flag in its machine-readable contract.
test_introspect_lists_json_flag() {
    local out _rc=0
    out="$(cd "$REPO_ROOT" && "$BASH_BIN" "$REPO_ROOT/libexec/repo-stats" --introspect 2>/dev/null)" || _rc=$?
    [[ "$_rc" -eq 0 ]] || return 1
    printf '%s' "$out" | jq -e '.flags | index("--json")' >/dev/null
}
run_test "--introspect lists the --json flag" test_introspect_lists_json_flag

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d  Skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
if ((FAIL > 0)); then
    printf '\033[0;31mFAILED\033[0m\n'
    exit 1
fi
printf '\033[0;32mPASSED\033[0m\n'
