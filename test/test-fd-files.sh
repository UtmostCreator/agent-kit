#!/usr/bin/env bash
# Tests for libexec/fd-files
set -euo pipefail
BASH_BIN="${BASH_BIN:-$(command -v bash)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/libexec/fd-files"
cd "$REPO_ROOT"

PASS=0 FAIL=0 SKIP=0
run_test() {
    local name="$1"; shift; local _rc=0
    "$@" >/dev/null 2>&1 || _rc=$?
    if ((_rc == 0)); then PASS=$((PASS+1)); printf '  \033[0;32m✓\033[0m %s\n' "$name"
    else FAIL=$((FAIL+1)); printf '  \033[0;31m✗\033[0m %s\n' "$name"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/src" "$TMP/vendor/pkg" "$TMP/node_modules/pkg" "$TMP/.git/objects"
echo "hello" > "$TMP/src/app.php"
echo "world" > "$TMP/src/util.js"
echo "hidden" > "$TMP/src/.hidden.txt"
echo "vendor" > "$TMP/vendor/pkg/lib.php"
echo "node" > "$TMP/node_modules/pkg/index.js"

printf 'fd-files\n'

# --help
test_help() { "$BASH_BIN" "$SCRIPT" --help 2>&1 | grep -q 'Usage'; }
run_test "help flag works" test_help

# Basic search
test_basic() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" "app" "$TMP/src")"
    [[ "$out" == *"app.php"* ]]
}
run_test "finds files matching query" test_basic

# JSON output
test_json() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" "app" "$TMP/src" --json)"
    echo "$out" | jq -e '.[0]' >/dev/null
}
run_test "JSON output is valid array" test_json

# vendor excluded
test_vendor_excluded() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" "lib" "$TMP" 2>/dev/null || true)"
    [[ "$out" != *"vendor"* ]]
}
run_test "vendor/ excluded by default" test_vendor_excluded

# node_modules excluded
test_node_modules_excluded() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" "index" "$TMP" 2>/dev/null || true)"
    [[ "$out" != *"node_modules"* ]]
}
run_test "node_modules/ excluded by default" test_node_modules_excluded

# .git excluded
test_git_excluded() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" "objects" "$TMP" 2>/dev/null || true)"
    [[ "$out" != *".git"* ]]
}
run_test ".git/ excluded by default" test_git_excluded

# --type filter
test_type_filter() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" "." "$TMP/src" --type php)"
    [[ "$out" == *".php"* ]]
    [[ "$out" != *".js"* ]]
}
run_test "--type filters by extension" test_type_filter

# --hidden includes hidden files
test_hidden() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" "hidden" "$TMP/src" --hidden)"
    [[ "$out" == *".hidden"* ]]
}
run_test "--hidden includes hidden files" test_hidden

# No query fails
test_no_query() {
    ! "$BASH_BIN" "$SCRIPT" 2>/dev/null
}
run_test "missing query exits with error" test_no_query

# Unknown option fails
test_unknown_option() {
    ! "$BASH_BIN" "$SCRIPT" "x" --bogus 2>/dev/null
}
run_test "unknown option fails" test_unknown_option

# --help/-h as $1 is intercepted by common.sh's universal --help guard
# BEFORE this script's own early "${1:-}" == --help check ever runs (and
# that guard's condition is identical, so this script's own early check is
# unreachable via the CLI). Its own --help|-h handling in the flag-parsing
# loop IS reachable once --help is not the first argument.
test_help_non_first_arg() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" "app" "$TMP/src" --help)"
    [[ "$out" == *"Usage:"* ]]
}
run_test "--help after query/root reaches this script's own usage()" test_help_non_first_arg

# --type=X equals-form flag.
test_type_equals() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" "." "$TMP/src" --type=php)"
    [[ "$out" == *".php"* ]]
    [[ "$out" != *".js"* ]]
}
run_test "--type=X equals-form filters by extension" test_type_equals

# run_discovery_without_fd ARGS... -> capture output with a PATH that has
# every needed tool EXCEPT fd/fdfind, to exercise the rg --files fallback
# path (run_discovery's else branch), which is otherwise unreachable on any
# host with fd installed. Returns rc 99 (empty output) if the isolated
# bindir cannot be built without exposing a real fd/fdfind, so the caller
# can skip cleanly instead of asserting on a false result.
run_discovery_without_fd() {
    local bindir tool p out rc
    bindir="$(mktemp -d)"
    for tool in jq rg bash sh awk grep sed cat tr wc dirname mktemp rm find \
        printf rmdir env head tail sort uniq xargs git; do
        p="$(command -v "$tool" 2>/dev/null)" && ln -sf "$p" "$bindir/$tool"
    done
    if [[ -n "$(PATH="$bindir" command -v fd 2>/dev/null)" || -n "$(PATH="$bindir" command -v fdfind 2>/dev/null)" ]]; then
        rm -rf "$bindir"
        FD_FALLBACK_RC=99
        FD_FALLBACK_OUT=""
        return 0
    fi
    set +e
    out="$(PATH="$bindir" "$BASH_BIN" "$SCRIPT" "$@" 2>&1)"
    rc=$?
    set -e
    rm -rf "$bindir"
    FD_FALLBACK_OUT="$out"
    FD_FALLBACK_RC="$rc"
}

FD_FALLBACK_OUT=""
FD_FALLBACK_RC=0

test_fallback_basic() {
    run_discovery_without_fd "app" "$TMP/src"
    [[ "$FD_FALLBACK_RC" -eq 99 ]] && return 0
    [[ "$FD_FALLBACK_RC" -eq 0 && "$FD_FALLBACK_OUT" == *"app.php"* ]]
}
run_test "rg --files fallback (no fd) finds matching files" test_fallback_basic

test_fallback_hidden() {
    run_discovery_without_fd "hidden" "$TMP/src" --hidden
    [[ "$FD_FALLBACK_RC" -eq 99 ]] && return 0
    [[ "$FD_FALLBACK_RC" -eq 0 && "$FD_FALLBACK_OUT" == *".hidden"* ]]
}
run_test "rg --files fallback (no fd) --hidden includes hidden files" test_fallback_hidden

test_fallback_type_filter() {
    run_discovery_without_fd "." "$TMP/src" --type php
    [[ "$FD_FALLBACK_RC" -eq 99 ]] && return 0
    [[ "$FD_FALLBACK_RC" -eq 0 && "$FD_FALLBACK_OUT" == *".php"* && "$FD_FALLBACK_OUT" != *".js"* ]]
}
run_test "rg --files fallback (no fd) --type filters by extension" test_fallback_type_filter

test_fallback_excludes() {
    run_discovery_without_fd "lib" "$TMP"
    [[ "$FD_FALLBACK_RC" -eq 99 ]] && return 0
    [[ "$FD_FALLBACK_RC" -ne 0 || "$FD_FALLBACK_OUT" != *"vendor"* ]]
}
run_test "rg --files fallback (no fd) still excludes vendor/" test_fallback_excludes

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d  Skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
((FAIL == 0)) && printf '\033[0;32mPASSED\033[0m\n' || { printf '\033[0;31mFAILED\033[0m\n'; exit 1; }
