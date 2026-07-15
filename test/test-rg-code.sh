#!/usr/bin/env bash
# Tests for libexec/rg-code
set -euo pipefail
BASH_BIN="${BASH_BIN:-$(command -v bash)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/libexec/rg-code"
cd "$REPO_ROOT"

PASS=0 FAIL=0 SKIP=0
run_test() {
    local name="$1"; shift
    local _rc=0
    "$@" >/dev/null 2>&1 || _rc=$?
    if ((_rc == 0)); then PASS=$((PASS+1)); printf '  \033[0;32m✓\033[0m %s\n' "$name"
    else FAIL=$((FAIL+1)); printf '  \033[0;31m✗\033[0m %s\n' "$name"; fi
}
skip_test() { SKIP=$((SKIP+1)); printf '  \033[0;33m⊘\033[0m %s (skipped: %s)\n' "$1" "$2"; }

# Create temp test directory
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/src"
cat > "$TMP/src/app.php" <<'PHP'
<?php
class UserService {
    public function login() { return true; }
    public function logout() { return false; }
}
PHP
cat > "$TMP/src/helper.js" <<'JS'
function login() { return true; }
function logout() { return false; }
module.exports = { login, logout };
JS
mkdir -p "$TMP/vendor/pkg"
echo "vendor code login" > "$TMP/vendor/pkg/lib.php"
mkdir -p "$TMP/node_modules/pkg"
echo "node_modules login" > "$TMP/node_modules/pkg/index.js"

printf 'rg-code\n'

# --help is parsed as pattern (no dedicated help flag)
# Test usage prints when no args given
test_no_args() { ! "$BASH_BIN" "$SCRIPT" 2>/dev/null; }
run_test "missing args fails" test_no_args

# Basic text search
test_basic() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" "login" "$TMP/src")"
    [[ "$out" == *"login"* ]]
}
run_test "basic pattern search finds matches" test_basic

test_smart_case_default() {
    printf 'AlphaBeta\n' > "$TMP/src/case.txt"
    local out
    out="$($BASH_BIN "$SCRIPT" "alphabeta" "$TMP/src")"
    [[ "$out" == *"AlphaBeta"* ]]
}
run_test "lowercase query uses smart-case matching" test_smart_case_default

test_uppercase_stays_case_sensitive() {
    local out
    out="$($BASH_BIN "$SCRIPT" "ALPHABETA" "$TMP/src" 2>/dev/null || true)"
    [[ -z "$out" ]]
}
run_test "uppercase query stays case-sensitive by default" test_uppercase_stays_case_sensitive

test_ignore_case_flag() {
    local out
    out="$($BASH_BIN "$SCRIPT" "ALPHABETA" "$TMP/src" --ignore-case)"
    [[ "$out" == *"AlphaBeta"* ]]
}
run_test "--ignore-case forces case-insensitive matches" test_ignore_case_flag

# JSON output
test_json() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" "login" "$TMP/src" --json)"
    echo "$out" | jq -e '.[0].file' >/dev/null
    echo "$out" | jq -e '.[0].line' >/dev/null
}
run_test "JSON output has file and line" test_json

# --files output
test_files() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" "login" "$TMP/src" --files)"
    [[ "$out" == *"app.php"* ]]
}
run_test "--files lists matching files" test_files

# --count output
test_count() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" "login" "$TMP/src" --count)"
    [[ "$out" =~ [0-9] ]]
}
run_test "--count returns numeric counts" test_count

# vendor excluded by default
test_vendor_excluded() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" "login" "$TMP" --files 2>/dev/null || true)"
    [[ "$out" != *"vendor"* ]]
}
run_test "vendor/ excluded by default" test_vendor_excluded

# node_modules excluded by default
test_node_modules_excluded() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" "login" "$TMP" --files 2>/dev/null || true)"
    [[ "$out" != *"node_modules"* ]]
}
run_test "node_modules/ excluded by default" test_node_modules_excluded

# Mode: php
test_mode_php() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" "login" "$TMP/src" --mode php --files)"
    [[ "$out" == *".php"* ]]
    [[ "$out" != *".js"* ]]
}
run_test "mode php filters to .php files" test_mode_php

# Mode: js
test_mode_js() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" "login" "$TMP/src" --mode js --files)"
    [[ "$out" == *".js"* ]]
    [[ "$out" != *".php"* ]]
}
run_test "mode js filters to .js files" test_mode_js

# Mode: config
test_mode_config() {
    echo '{"key": "login"}' > "$TMP/src/config.json"
    local out
    out="$("$BASH_BIN" "$SCRIPT" "login" "$TMP/src" --mode config --files)"
    [[ "$out" == *".json"* ]]
}
run_test "mode config filters to config files" test_mode_config

# Context lines
test_context() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" "login" "$TMP/src/app.php" --context 1)"
    local lines
    lines="$(echo "$out" | wc -l | tr -d ' ')"
    ((lines > 1))
}
run_test "--context adds surrounding lines" test_context

# --type filter
test_type() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" "login" "$TMP/src" --type js --files)"
    [[ "$out" == *".js"* ]]
}
run_test "--type filters by extension" test_type

# No matches returns exit 1 (rg behavior)
test_no_matches() {
    ! "$BASH_BIN" "$SCRIPT" "definitely_no_match_xyz_$$" "$TMP/src" >/dev/null 2>&1
}
run_test "no matches returns non-zero exit" test_no_matches

# Unknown mode fails
test_unknown_mode() {
    ! "$BASH_BIN" "$SCRIPT" "login" "$TMP/src" --mode nonexistent >/dev/null 2>&1
}
run_test "unknown mode fails" test_unknown_mode

# Unknown option fails
test_unknown_option() {
    ! "$BASH_BIN" "$SCRIPT" "login" "$TMP/src" --bogus >/dev/null 2>&1
}
run_test "unknown option fails" test_unknown_option

# --help / -h prints usage and exits 0.
test_help_flag() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" "login" "$TMP/src" --help)"
    [[ "$out" == *"Usage:"* ]]
}
run_test "--help prints usage" test_help_flag

test_h_flag() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" "login" "$TMP/src" -h)"
    [[ "$out" == *"Usage:"* ]]
}
run_test "-h prints usage" test_h_flag

# --mode=X / --context=N / --type=X equals-form flags.
test_mode_equals() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" "login" "$TMP/src" --mode=php --files)"
    [[ "$out" == *".php"* ]]
}
run_test "--mode=X equals-form filters to .php files" test_mode_equals

test_context_equals() {
    local out lines
    out="$("$BASH_BIN" "$SCRIPT" "login" "$TMP/src/app.php" --context=1)"
    lines="$(echo "$out" | wc -l | tr -d ' ')"
    ((lines > 1))
}
run_test "--context=N equals-form adds surrounding lines" test_context_equals

test_type_equals() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" "login" "$TMP/src" --type=js --files)"
    [[ "$out" == *".js"* ]]
}
run_test "--type=X equals-form filters by extension" test_type_equals

# Mode: all (disables default ignore rules; -uuu).
test_mode_all() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" "login" "$TMP/src" --mode all)"
    [[ "$out" == *"login"* ]]
}
run_test "mode all searches with -uuu" test_mode_all

# Mode: tracked (git grep; exits early with the git grep exit code).
test_mode_tracked() {
    local out rc=0
    git -C "$TMP" init -q
    git -C "$TMP" config user.email "test@example.com"
    git -C "$TMP" config user.name "Test User"
    git -C "$TMP" add src/app.php
    out="$("$BASH_BIN" "$SCRIPT" "login" "$TMP" --mode tracked)" || rc=$?
    [[ "$out" == *"login"* ]] && ((rc == 0))
}
run_test "mode tracked uses git grep" test_mode_tracked

test_mode_tracked_no_match_exit() {
    git -C "$TMP" init -q 2>/dev/null || true
    ! "$BASH_BIN" "$SCRIPT" "definitely_no_match_xyz_$$" "$TMP" --mode tracked >/dev/null 2>&1
}
run_test "mode tracked propagates git grep's non-zero exit on no match" test_mode_tracked_no_match_exit

# Mode: blade
test_mode_blade() {
    mkdir -p "$TMP/resources/views"
    echo '{{ $login }}' > "$TMP/resources/views/home.blade.php"
    local out
    out="$("$BASH_BIN" "$SCRIPT" "login" "$TMP/resources" --mode blade --files)"
    [[ "$out" == *".blade.php"* ]]
}
run_test "mode blade filters to .blade.php files" test_mode_blade

# Mode: kotlin
test_mode_kotlin() {
    mkdir -p "$TMP/app/src"
    echo 'fun login() {}' > "$TMP/app/src/Login.kt"
    local out
    out="$("$BASH_BIN" "$SCRIPT" "login" "$TMP/app/src" --mode kotlin --files)"
    [[ "$out" == *".kt"* ]]
}
run_test "mode kotlin filters to .kt/.kts files" test_mode_kotlin

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d  Skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
((FAIL == 0)) && printf '\033[0;32mPASSED\033[0m\n' || { printf '\033[0;31mFAILED\033[0m\n'; exit 1; }
