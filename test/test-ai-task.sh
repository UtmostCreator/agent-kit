#!/usr/bin/env bash
# Tests for libexec/ai-task
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/libexec/ai-task"
cd "$REPO_ROOT"
BASH_BIN="${BASH_BIN:-$(command -v bash)}"

PASS=0 FAIL=0 SKIP=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

run_test() {
    local name="$1"; shift; local _rc=0
    "$@" >/dev/null 2>&1 || _rc=$?
    if ((_rc == 0)); then PASS=$((PASS+1)); printf '  \033[0;32m✓\033[0m %s\n' "$name"
    else FAIL=$((FAIL+1)); printf '  \033[0;31m✗\033[0m %s\n' "$name"; fi
}
skip_test() { SKIP=$((SKIP+1)); printf '  \033[0;33m⊘\033[0m %s (skipped: %s)\n' "$1" "$2"; }

printf 'ai-task\n'

# --help
test_help() { "$BASH_BIN" "$SCRIPT" --help 2>&1 | grep -q 'Usage'; }
run_test "help flag works" test_help

# list mode produces JSON inventory
test_list() {
    local out
    out="$(AI_LOG_DIR="$TMP/logs" AI_EVENT_LOG="$TMP/logs/ev.jsonl" "$BASH_BIN" "$SCRIPT" list 2>/dev/null)"
    echo "$out" | jq -e '.package_manager' >/dev/null
    echo "$out" | jq -e '.composer_scripts' >/dev/null
    echo "$out" | jq -e '.just_tasks' >/dev/null
}
run_test "list mode returns inventory JSON" test_list

# json mode (alias for list)
test_json() {
    local out
    out="$(AI_LOG_DIR="$TMP/logs2" AI_EVENT_LOG="$TMP/logs2/ev.jsonl" "$BASH_BIN" "$SCRIPT" json 2>/dev/null)"
    echo "$out" | jq -e '.package_manager' >/dev/null
}
run_test "json mode returns inventory JSON" test_json

# verify recommends a command
test_verify() {
    local out
    out="$(AI_LOG_DIR="$TMP/logs3" AI_EVENT_LOG="$TMP/logs3/ev.jsonl" "$BASH_BIN" "$SCRIPT" verify 2>/dev/null)"
    [[ -n "$out" ]]
}
run_test "verify mode recommends a command" test_verify

# test recommends a command
test_test() {
    local out
    out="$(AI_LOG_DIR="$TMP/logs4" AI_EVENT_LOG="$TMP/logs4/ev.jsonl" "$BASH_BIN" "$SCRIPT" test 2>/dev/null)"
    [[ -n "$out" ]]
}
run_test "test mode recommends a command" test_test

# lint recommends a command
test_lint() {
    local out
    out="$(AI_LOG_DIR="$TMP/logs5" AI_EVENT_LOG="$TMP/logs5/ev.jsonl" "$BASH_BIN" "$SCRIPT" lint 2>/dev/null)"
    [[ -n "$out" ]]
}
run_test "lint mode recommends a command" test_lint

# typecheck recommends a command
test_typecheck() {
    local out
    out="$(AI_LOG_DIR="$TMP/logs6" AI_EVENT_LOG="$TMP/logs6/ev.jsonl" "$BASH_BIN" "$SCRIPT" typecheck 2>/dev/null)"
    [[ -n "$out" ]]
}
run_test "typecheck mode recommends a command" test_typecheck

# Unknown mode fails
test_unknown() {
    ! AI_LOG_DIR="$TMP/logs7" AI_EVENT_LOG="$TMP/logs7/ev.jsonl" "$BASH_BIN" "$SCRIPT" nonexistent 2>/dev/null
}
run_test "unknown mode fails" test_unknown

# --- Fixture-driven coverage: the tests above all run inside the repo's own
# root (which has package.json but no lock file, no composer.json, no
# Makefile/justfile/Taskfile), so most package_manager()/recommend_command()
# branches were never exercised. Build small fixture project directories and
# `cd` into each so the script's cwd-relative file checks hit different paths.

run_in_fixture() {
    local dir="$1"
    shift
    (
        cd "$dir" || exit 1
        mkdir -p .logs
        AI_LOG_DIR="$dir/.logs" AI_EVENT_LOG="$dir/.logs/ev.jsonl" "$BASH_BIN" "$SCRIPT" "$@" 2>/dev/null
    )
}

# No package.json/lock files/composer/make/just/taskfile at all: package
# manager is "unknown" and every recommend_* falls back to ai-verify.sh.
FIX_EMPTY="$TMP/fixture-empty"
mkdir -p "$FIX_EMPTY"
test_no_project_files_unknown_pm() {
    local out
    out="$(run_in_fixture "$FIX_EMPTY" list)"
    echo "$out" | jq -e '.package_manager == "unknown"' >/dev/null
}
run_test "no project files: package_manager is unknown" test_no_project_files_unknown_pm

test_no_project_files_verify_fallback() {
    local out
    out="$(run_in_fixture "$FIX_EMPTY" verify)"
    [[ "$out" == "scripts/ai/ai-verify.sh ." ]]
}
run_test "no project files: verify falls back to ai-verify.sh" test_no_project_files_verify_fallback

# pnpm-lock.yaml alone (no package.json) selects pnpm.
FIX_PNPM="$TMP/fixture-pnpm"
mkdir -p "$FIX_PNPM"
touch "$FIX_PNPM/pnpm-lock.yaml"
test_pnpm_lock_detected() {
    local out
    out="$(run_in_fixture "$FIX_PNPM" list)"
    echo "$out" | jq -e '.package_manager == "pnpm"' >/dev/null
}
run_test "pnpm-lock.yaml selects pnpm as package manager" test_pnpm_lock_detected

# package-lock.json alone (no package.json) selects npm.
FIX_NPMLOCK="$TMP/fixture-npmlock"
mkdir -p "$FIX_NPMLOCK"
touch "$FIX_NPMLOCK/package-lock.json"
test_npm_lock_detected() {
    local out
    out="$(run_in_fixture "$FIX_NPMLOCK" list)"
    echo "$out" | jq -e '.package_manager == "npm"' >/dev/null
}
run_test "package-lock.json selects npm as package manager" test_npm_lock_detected

# yarn.lock alone (no package.json) selects yarn.
FIX_YARN="$TMP/fixture-yarn"
mkdir -p "$FIX_YARN"
touch "$FIX_YARN/yarn.lock"
test_yarn_lock_detected() {
    local out
    out="$(run_in_fixture "$FIX_YARN" list)"
    echo "$out" | jq -e '.package_manager == "yarn"' >/dev/null
}
run_test "yarn.lock selects yarn as package manager" test_yarn_lock_detected

# Declared "packageManager" field in package.json wins over lock-file sniffing.
FIX_DECLARED="$TMP/fixture-declared-pm"
mkdir -p "$FIX_DECLARED"
cat >"$FIX_DECLARED/package.json" <<'EOF'
{"name":"fixture","packageManager":"pnpm@8.1.0","scripts":{"test":"echo test","lint":"echo lint","typecheck":"echo tc","verify":"echo verify"}}
EOF
touch "$FIX_DECLARED/yarn.lock"
test_declared_package_manager_wins() {
    local out
    out="$(run_in_fixture "$FIX_DECLARED" list)"
    echo "$out" | jq -e '.package_manager == "pnpm"' >/dev/null
}
run_test "declared packageManager field wins over lock-file sniffing" test_declared_package_manager_wins

# package.json with matching scripts drives the "<pm> run <script>" / "<pm> <script>"
# recommend branches (has_package_script).
FIX_SCRIPTS="$TMP/fixture-scripts"
mkdir -p "$FIX_SCRIPTS"
cat >"$FIX_SCRIPTS/package.json" <<'EOF'
{"name":"fixture","scripts":{"test":"echo test","lint":"echo lint","typecheck":"echo tc","verify":"echo verify"}}
EOF
test_pkg_script_verify() {
    [[ "$(run_in_fixture "$FIX_SCRIPTS" verify)" == "npm run verify" ]]
}
run_test "package.json scripts.verify -> npm run verify" test_pkg_script_verify

test_pkg_script_test() {
    [[ "$(run_in_fixture "$FIX_SCRIPTS" test)" == "npm test" ]]
}
run_test "package.json scripts.test -> npm test" test_pkg_script_test

test_pkg_script_lint() {
    [[ "$(run_in_fixture "$FIX_SCRIPTS" lint)" == "npm run lint" ]]
}
run_test "package.json scripts.lint -> npm run lint" test_pkg_script_lint

test_pkg_script_typecheck() {
    [[ "$(run_in_fixture "$FIX_SCRIPTS" typecheck)" == "npm run typecheck" ]]
}
run_test "package.json scripts.typecheck -> npm run typecheck" test_pkg_script_typecheck

# composer.json scripts.verify (no package.json) -> composer run-script verify.
FIX_COMPOSER_VERIFY="$TMP/fixture-composer-verify"
mkdir -p "$FIX_COMPOSER_VERIFY"
cat >"$FIX_COMPOSER_VERIFY/composer.json" <<'EOF'
{"name":"fixture/composer","scripts":{"verify":"phpunit"}}
EOF
test_composer_verify_script() {
    [[ "$(run_in_fixture "$FIX_COMPOSER_VERIFY" verify)" == "composer run-script verify" ]]
}
run_test "composer.json scripts.verify -> composer run-script verify" test_composer_verify_script

# composer.json present with vendor/bin/phpunit executable (no package.json,
# no scripts.test) -> vendor/bin/phpunit recommend for test.
FIX_PHPUNIT="$TMP/fixture-phpunit"
mkdir -p "$FIX_PHPUNIT/vendor/bin"
echo '{}' >"$FIX_PHPUNIT/composer.json"
printf '#!/bin/sh\n' >"$FIX_PHPUNIT/vendor/bin/phpunit"
chmod +x "$FIX_PHPUNIT/vendor/bin/phpunit"
test_composer_phpunit_test() {
    [[ "$(run_in_fixture "$FIX_PHPUNIT" test)" == "vendor/bin/phpunit" ]]
}
run_test "composer.json + vendor/bin/phpunit -> vendor/bin/phpunit" test_composer_phpunit_test

# composer.json present with vendor/bin/pest executable (no phpunit) -> pest.
FIX_PEST="$TMP/fixture-pest"
mkdir -p "$FIX_PEST/vendor/bin"
echo '{}' >"$FIX_PEST/composer.json"
printf '#!/bin/sh\n' >"$FIX_PEST/vendor/bin/pest"
chmod +x "$FIX_PEST/vendor/bin/pest"
test_composer_pest_test() {
    [[ "$(run_in_fixture "$FIX_PEST" test)" == "vendor/bin/pest" ]]
}
run_test "composer.json + vendor/bin/pest (no phpunit) -> vendor/bin/pest" test_composer_pest_test

# composer.json present with vendor/bin/pint executable -> lint recommend.
FIX_PINT="$TMP/fixture-pint"
mkdir -p "$FIX_PINT/vendor/bin"
echo '{}' >"$FIX_PINT/composer.json"
printf '#!/bin/sh\n' >"$FIX_PINT/vendor/bin/pint"
chmod +x "$FIX_PINT/vendor/bin/pint"
test_composer_pint_lint() {
    [[ "$(run_in_fixture "$FIX_PINT" lint)" == "vendor/bin/pint --test" ]]
}
run_test "composer.json + vendor/bin/pint -> vendor/bin/pint --test" test_composer_pint_lint

# composer.json present with vendor/bin/phpstan executable, no tsconfig ->
# typecheck recommend.
FIX_PHPSTAN="$TMP/fixture-phpstan"
mkdir -p "$FIX_PHPSTAN/vendor/bin"
echo '{}' >"$FIX_PHPSTAN/composer.json"
printf '#!/bin/sh\n' >"$FIX_PHPSTAN/vendor/bin/phpstan"
chmod +x "$FIX_PHPSTAN/vendor/bin/phpstan"
test_composer_phpstan_typecheck() {
    [[ "$(run_in_fixture "$FIX_PHPSTAN" typecheck)" == "vendor/bin/phpstan analyse" ]]
}
run_test "composer.json + vendor/bin/phpstan -> vendor/bin/phpstan analyse" test_composer_phpstan_typecheck

# tsconfig.json + package.json (no scripts.typecheck) -> "<pm> exec tsc --noEmit".
FIX_TSCONFIG="$TMP/fixture-tsconfig"
mkdir -p "$FIX_TSCONFIG"
echo '{"name":"fixture"}' >"$FIX_TSCONFIG/package.json"
echo '{}' >"$FIX_TSCONFIG/tsconfig.json"
test_tsconfig_typecheck() {
    [[ "$(run_in_fixture "$FIX_TSCONFIG" typecheck)" == "npm exec tsc --noEmit" ]]
}
run_test "tsconfig.json (no typecheck script) -> npm exec tsc --noEmit" test_tsconfig_typecheck

# justfile with a `verify` recipe: recommend_command verify prefers `just verify`.
if command -v just >/dev/null 2>&1; then
    FIX_JUST="$TMP/fixture-just"
    mkdir -p "$FIX_JUST"
    cat >"$FIX_JUST/justfile" <<'EOF'
verify:
    echo verify

build:
    echo build
EOF
    test_just_verify_recipe() {
        [[ "$(run_in_fixture "$FIX_JUST" verify)" == "just verify" ]]
    }
    run_test "justfile with verify recipe -> just verify" test_just_verify_recipe

    test_just_tasks_listed() {
        local out
        out="$(run_in_fixture "$FIX_JUST" list)"
        echo "$out" | jq -e '(.just_tasks | length) > 0' >/dev/null
    }
    run_test "justfile tasks appear in just_tasks inventory" test_just_tasks_listed
else
    skip_test "justfile with verify recipe -> just verify" "just not available"
    skip_test "justfile tasks appear in just_tasks inventory" "just not available"
fi

# Makefile targets are listed in make_tasks inventory.
FIX_MAKE="$TMP/fixture-make"
mkdir -p "$FIX_MAKE"
cat >"$FIX_MAKE/Makefile" <<'EOF'
build:
	echo build

test:
	echo test
EOF
test_make_tasks_listed() {
    local out
    out="$(run_in_fixture "$FIX_MAKE" list)"
    echo "$out" | jq -e '.make_tasks | index("build") != null and index("test") != null' >/dev/null
}
run_test "Makefile targets appear in make_tasks inventory" test_make_tasks_listed

# Taskfile.yml tasks are listed in taskfile_tasks inventory (needs yq).
if command -v yq >/dev/null 2>&1; then
    FIX_TASKFILE="$TMP/fixture-taskfile"
    mkdir -p "$FIX_TASKFILE"
    cat >"$FIX_TASKFILE/Taskfile.yml" <<'EOF'
version: '3'
tasks:
  build:
    cmds:
      - echo build
  test:
    cmds:
      - echo test
EOF
    test_taskfile_tasks_listed() {
        local out
        out="$(run_in_fixture "$FIX_TASKFILE" list)"
        echo "$out" | jq -e '(.taskfile_tasks | length) > 0' >/dev/null
    }
    run_test "Taskfile.yml tasks appear in taskfile_tasks inventory" test_taskfile_tasks_listed
else
    skip_test "Taskfile.yml tasks appear in taskfile_tasks inventory" "yq not available"
fi

# composer.json scripts surface in the JSON inventory's composer_scripts field.
test_composer_scripts_in_inventory() {
    local out
    out="$(run_in_fixture "$FIX_COMPOSER_VERIFY" list)"
    echo "$out" | jq -e '.composer_scripts.verify == "phpunit"' >/dev/null
}
run_test "composer.json scripts appear in composer_scripts inventory" test_composer_scripts_in_inventory

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d  Skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
((FAIL == 0)) && printf '\033[0;32mPASSED\033[0m\n' || { printf '\033[0;31mFAILED\033[0m\n'; exit 1; }
