#!/usr/bin/env bash
# Tests for libexec/all-f-into-one
set -euo pipefail
BASH_BIN="${BASH_BIN:-$(command -v bash)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/libexec/all-f-into-one"

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

printf 'all-f-into-one\n'

# Isolated sandbox: the command writes combined_output.txt into the CWD, so it
# must never run against the repo. Each helper builds a fresh fixture tree.
make_fixture() {
    local root
    root="$(mktemp -d)"
    mkdir -p "$root/src" "$root/node_modules/pkg" "$root/.git"
    printf 'alpha content\n' >"$root/src/keep.txt"
    printf 'beta content\n' >"$root/top.md"
    printf 'vendor noise\n' >"$root/node_modules/pkg/index.js"
    printf 'git internals\n' >"$root/.git/HEAD"
    printf '%s' "$root"
}

test_help() {
    local out _rc=0
    out="$("$BASH_BIN" "$SCRIPT" --help 2>&1)" || _rc=$?
    [[ "$_rc" -eq 0 && -n "$out" ]]
}
run_test "--help works (exit 0, non-empty)" test_help

# Combines tracked content into combined_output.txt with file markers.
test_combines() {
    local root
    root="$(make_fixture)"
    (cd "$root" && "$BASH_BIN" "$SCRIPT") >/dev/null 2>&1
    local rc=$?
    local out="$root/combined_output.txt"
    local ok=1
    [[ "$rc" -eq 0 && -f "$out" ]] || ok=0
    grep -q 'START FILE: src/keep.txt' "$out" 2>/dev/null || ok=0
    grep -q 'alpha content' "$out" 2>/dev/null || ok=0
    grep -q 'beta content' "$out" 2>/dev/null || ok=0
    rm -rf -- "$root"
    ((ok == 1))
}
run_test "combines files into combined_output.txt with markers" test_combines

# Ignored directory trees (.git, node_modules) are pruned entirely.
test_prunes_ignored() {
    local root
    root="$(make_fixture)"
    (cd "$root" && "$BASH_BIN" "$SCRIPT") >/dev/null 2>&1
    local out="$root/combined_output.txt"
    local ok=1
    grep -q 'vendor noise' "$out" 2>/dev/null && ok=0
    grep -q 'git internals' "$out" 2>/dev/null && ok=0
    rm -rf -- "$root"
    ((ok == 1))
}
run_test "prunes .git and node_modules subtrees" test_prunes_ignored

# A pre-existing output file is rotated to a timestamped .bak, not clobbered.
test_rotates_previous() {
    local root
    root="$(make_fixture)"
    printf 'previous run marker\n' >"$root/combined_output.txt"
    (cd "$root" && "$BASH_BIN" "$SCRIPT") >/dev/null 2>&1
    local ok=0
    # A backup carrying the old content must now exist alongside the fresh output.
    local bak
    for bak in "$root"/combined_output.txt.bak.*; do
        [[ -f "$bak" ]] && grep -q 'previous run marker' "$bak" && ok=1
    done
    rm -rf -- "$root"
    ((ok == 1))
}
run_test "rotates an existing output file to a .bak" test_rotates_previous

if command -v jq >/dev/null 2>&1; then
    test_json() {
        local out
        out="$("$BASH_BIN" "$SCRIPT" --introspect 2>/dev/null || true)"
        printf '%s' "$out" | jq -e \
            '.status == "ok" and .name == "all-f-into-one"' >/dev/null
    }
    run_test "--introspect emits a valid JSON contract" test_json
else
    skip_test "--introspect emits a valid JSON contract" "jq not available"
fi

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d  Skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
((FAIL == 0)) && printf '\033[0;32mPASSED\033[0m\n' || {
    printf '\033[0;31mFAILED\033[0m\n'
    exit 1
}
