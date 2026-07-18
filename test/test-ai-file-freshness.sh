#!/usr/bin/env bash
# Tests for libexec/ai-file-freshness.
#
# Focus: the default (human) surface stays byte-for-byte backward compatible --
# `git status --short` of the watched paths, exit 0 even outside a repo -- while
# the additive --json / AI_OUTPUT=json envelope and --exit-code gate are
# opt-in. Asserts the ai.file-freshness/v1 schema/status/state keys and that
# --exit-code returns nonzero only when a watched path is dirty.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/libexec/ai-file-freshness"
BASH_BIN="${BASH_BIN:-$(command -v bash)}"

PASS=0 FAIL=0 SKIP=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

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

printf 'ai-file-freshness\n'

# Build a fresh, committed (clean) repo with the watched paths populated.
make_clean_repo() {
    local dir="$1"
    mkdir -p "$dir/docs" "$dir/.github" "$dir/.opencode"
    printf 'x\n' >"$dir/docs/a.md"
    printf 'agents\n' >"$dir/AGENTS.md"
    git -C "$dir" init -q
    git -C "$dir" config user.email t@t.t
    git -C "$dir" config user.name t
    git -C "$dir" add -A
    git -C "$dir" commit -qm init
}

# --- backward compatibility: default (human) mode -------------------------------

# A clean repo prints nothing and exits 0, exactly as before.
test_default_clean_empty() {
    local dir="$TMP/clean" out _rc=0
    make_clean_repo "$dir"
    out="$(cd "$dir" && "$BASH_BIN" "$SCRIPT")" || _rc=$?
    [[ "$_rc" -eq 0 && -z "$out" ]]
}
run_test "default: clean repo is empty stdout, exit 0" test_default_clean_empty

# A dirty watched path prints the raw `git status --short` porcelain, exit 0.
test_default_dirty_porcelain() {
    local dir="$TMP/dirty" out _rc=0
    make_clean_repo "$dir"
    printf 'changed\n' >"$dir/docs/a.md"
    out="$(cd "$dir" && "$BASH_BIN" "$SCRIPT")" || _rc=$?
    [[ "$_rc" -eq 0 && "$out" == *" M docs/a.md"* ]]
}
run_test "default: dirty repo prints porcelain, exit 0" test_default_dirty_porcelain

# Outside a git repo the default mode still exits 0 with empty stdout (unchanged).
test_default_not_a_repo() {
    local dir="$TMP/norepo" out _rc=0
    mkdir -p "$dir"
    out="$(cd "$dir" && "$BASH_BIN" "$SCRIPT")" || _rc=$?
    [[ "$_rc" -eq 0 && -z "$out" ]]
}
run_test "default: outside a repo is empty stdout, exit 0" test_default_not_a_repo

# An unknown argument is still a usage error (exit 2) and now names the value.
test_unknown_arg() {
    local out _rc=0
    out="$("$BASH_BIN" "$SCRIPT" --bogus 2>&1)" || _rc=$?
    [[ "$_rc" -eq 2 && "$out" == *"--bogus"* ]]
}
run_test "unknown argument fails exit 2 and names the value" test_unknown_arg

# --- additive JSON envelope -----------------------------------------------------

if command -v jq >/dev/null 2>&1; then
    # --json on a clean repo: ai.file-freshness/v1, status ok, state clean, count 0.
    test_json_clean() {
        local dir="$TMP/jclean" out
        make_clean_repo "$dir"
        out="$(cd "$dir" && "$BASH_BIN" "$SCRIPT" --json)" || return 1
        echo "$out" | jq -e '.schema == "ai.file-freshness/v1" and .status == "ok" and .tool == "file-freshness" and .state == "clean" and .count == 0' >/dev/null
    }
    run_test "--json clean repo: schema/status/state ok, count 0" test_json_clean

    # --json on a dirty repo: state stale with a parsed {status_code, path} entry.
    test_json_stale() {
        local dir="$TMP/jstale" out
        make_clean_repo "$dir"
        printf 'changed\n' >"$dir/docs/a.md"
        out="$(cd "$dir" && "$BASH_BIN" "$SCRIPT" --json)" || return 1
        echo "$out" | jq -e '.state == "stale" and .count >= 1' >/dev/null || return 1
        echo "$out" | jq -e '(.entries[] | select(.path == "docs/a.md") | .status_code) != null' >/dev/null
    }
    run_test "--json dirty repo: state stale with parsed entries" test_json_stale

    # AI_OUTPUT=json is the toolkit-wide signal and yields the same envelope.
    test_ai_output_env() {
        local dir="$TMP/jenv" out
        make_clean_repo "$dir"
        out="$(cd "$dir" && AI_OUTPUT=json "$BASH_BIN" "$SCRIPT")" || return 1
        echo "$out" | jq -e '.schema == "ai.file-freshness/v1" and .state == "clean"' >/dev/null
    }
    run_test "AI_OUTPUT=json emits the same envelope" test_ai_output_env

    # Outside a repo the envelope is a distinct state, status still ok.
    test_json_not_a_repo() {
        local dir="$TMP/jnorepo" out
        mkdir -p "$dir"
        out="$(cd "$dir" && "$BASH_BIN" "$SCRIPT" --json)" || return 1
        echo "$out" | jq -e '.status == "ok" and .state == "not-a-repo" and .count == 0' >/dev/null
    }
    run_test "--json outside a repo: state not-a-repo" test_json_not_a_repo
else
    skip_test "--json clean repo envelope" "jq not installed"
    skip_test "--json dirty repo envelope" "jq not installed"
    skip_test "AI_OUTPUT=json envelope" "jq not installed"
    skip_test "--json not-a-repo state" "jq not installed"
fi

# --- additive --exit-code gate --------------------------------------------------

# --exit-code on a clean repo exits 0.
test_exit_code_clean() {
    local dir="$TMP/eclean" _rc=0
    make_clean_repo "$dir"
    (cd "$dir" && "$BASH_BIN" "$SCRIPT" --exit-code) >/dev/null 2>&1 || _rc=$?
    [[ "$_rc" -eq 0 ]]
}
run_test "--exit-code clean repo exits 0" test_exit_code_clean

# --exit-code on a dirty repo exits 1 and still prints the porcelain.
test_exit_code_stale() {
    local dir="$TMP/estale" out _rc=0
    make_clean_repo "$dir"
    printf 'changed\n' >"$dir/docs/a.md"
    out="$(cd "$dir" && "$BASH_BIN" "$SCRIPT" --exit-code 2>&1)" || _rc=$?
    [[ "$_rc" -eq 1 && "$out" == *"docs/a.md"* ]]
}
run_test "--exit-code dirty repo exits 1 and prints porcelain" test_exit_code_stale

# --introspect exposes the additive flags.
if command -v jq >/dev/null 2>&1; then
    test_introspect_flags() {
        local out
        out="$("$BASH_BIN" "$SCRIPT" --introspect 2>/dev/null)" || return 1
        echo "$out" | jq -e '(.flags | index("--json")) != null and (.flags | index("--exit-code")) != null' >/dev/null
    }
    run_test "--introspect lists --json and --exit-code flags" test_introspect_flags
else
    skip_test "--introspect lists flags" "jq not installed"
fi

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d  Skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
((FAIL == 0)) && printf '\033[0;32mPASSED\033[0m\n' || {
    printf '\033[0;31mFAILED\033[0m\n'
    exit 1
}
