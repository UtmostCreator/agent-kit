#!/usr/bin/env bash
# Tests for libexec/internal/repomix-context-tree
set -euo pipefail
BASH_BIN="${BASH_BIN:-$(command -v bash)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/libexec/internal/repomix-context-tree"
cd "$REPO_ROOT"

PASS=0 FAIL=0 SKIP=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Pack a clean fixture, not this toolkit's own tree (lib/secrets.sh would trip
# the packer's secret guard and fail these functional tests).
FIX="$TMP/fixture"
mkdir -p "$FIX/src"
printf '# Sample\n' >"$FIX/README.md"
printf 'package main\nfunc main() {}\n' >"$FIX/src/main.go"
( cd "$FIX" && git init -q && git add -A \
    && git -c user.email=t@t -c user.name=t commit -qm init ) >/dev/null 2>&1 || true

run_test() {
    local name="$1"; shift; local _rc=0
    "$@" >/dev/null 2>&1 || _rc=$?
    if ((_rc == 0)); then PASS=$((PASS+1)); printf '  \033[0;32m✓\033[0m %s\n' "$name"
    else FAIL=$((FAIL+1)); printf '  \033[0;31m✗\033[0m %s\n' "$name"; fi
}
skip_test() { SKIP=$((SKIP+1)); printf '  \033[0;33m⊘\033[0m %s (skipped: %s)\n' "$1" "$2"; }

printf 'repomix-context-tree\n'

# Missing command fails
test_no_command() { ! "$BASH_BIN" "$SCRIPT" 2>/dev/null; }
run_test "missing command fails" test_no_command

# --help
test_help() { "$BASH_BIN" "$SCRIPT" --help 2>&1 | grep -qi 'usage'; }
run_test "help flag works" test_help

# analyze requires scc
if command -v scc >/dev/null 2>&1; then
    test_analyze() {
        "$BASH_BIN" "$SCRIPT" analyze "$FIX" --output-dir "$TMP/tree-out" 2>/dev/null
        [[ -d "$TMP/tree-out" ]]
    }
    run_test "analyze command produces output" test_analyze
else
    skip_test "analyze command produces output" "scc not installed"
fi

# clean/purge require confirmation — skip interactive tests
test_unknown_cmd() {
    ! "$BASH_BIN" "$SCRIPT" nonexistent 2>/dev/null
}
run_test "unknown command fails" test_unknown_cmd

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d  Skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
((FAIL == 0)) && printf '\033[0;32mPASSED\033[0m\n' || { printf '\033[0;31mFAILED\033[0m\n'; exit 1; }
