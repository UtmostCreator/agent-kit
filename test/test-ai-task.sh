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

# Unknown mode must exit 2 with a quoted-mode, expected-list message --
# matching the convention the sibling group routers (ai-repo/ai-inspect/
# ai-session) use, not the generic die() helper's bare exit 1.
test_unknown_mode_exit_code_and_message() {
    local out _rc=0
    out="$(AI_LOG_DIR="$TMP/logs7b" AI_EVENT_LOG="$TMP/logs7b/ev.jsonl" "$BASH_BIN" "$SCRIPT" bogus-mode 2>&1)" || _rc=$?
    [[ "$_rc" -eq 2 && "$out" == "restsift task: unknown mode 'bogus-mode' (expected list|verify|test|lint|typecheck|json|todos)" ]]
}
run_test "unknown mode exits 2 with a quoted mode name and expected-list hint" test_unknown_mode_exit_code_and_message

# `--list` specifically is a common miskeystroke (it IS a valid top-level
# `restsift --list` flag, but subcommand modes are always bare words, e.g.
# `restsift task list`) -- must fail the same clear way as any other
# unrecognized mode, not silently do something else.
test_dashdash_list_is_rejected_as_unknown_mode() {
    local out _rc=0
    out="$(AI_LOG_DIR="$TMP/logs7c" AI_EVENT_LOG="$TMP/logs7c/ev.jsonl" "$BASH_BIN" "$SCRIPT" --list 2>&1)" || _rc=$?
    [[ "$_rc" -eq 2 && "$out" == *"unknown mode '--list'"* ]]
}
run_test "'--list' is rejected as an unknown mode (use bare 'list')" test_dashdash_list_is_rejected_as_unknown_mode

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

# Regression: a malformed/unparseable package.json must NOT abort `list`/`json`
# mode. It should degrade gracefully (empty package_scripts) exactly like a
# missing package.json, and still emit a valid JSON inventory with exit 0 --
# not crash under set -e with raw jq parse errors (defect 1).
FIX_BADPKG="$TMP/fixture-bad-package-json"
mkdir -p "$FIX_BADPKG"
printf '{ this is not valid json,,, }\n' >"$FIX_BADPKG/package.json"
test_malformed_package_json_list_degrades() {
    local out _rc=0
    out="$(run_in_fixture "$FIX_BADPKG" list)" || _rc=$?
    [[ "$_rc" -eq 0 ]] || return 1
    echo "$out" | jq -e '.package_scripts == {}' >/dev/null
}
run_test "malformed package.json: list degrades to empty package_scripts (exit 0)" test_malformed_package_json_list_degrades

# Regression: the same malformed package.json must not leak raw jq stderr noise
# in recommend modes -- stdout carries the fallback recommendation and stderr
# stays clean, matching how a missing package.json is handled silently (defect 2).
test_malformed_package_json_test_no_stderr_noise() {
    local out err _rc=0
    err="$TMP/fixture-bad-package-json.err"
    out="$(
        cd "$FIX_BADPKG" || exit 1
        mkdir -p .logs
        AI_LOG_DIR="$FIX_BADPKG/.logs" AI_EVENT_LOG="$FIX_BADPKG/.logs/ev.jsonl" \
            "$BASH_BIN" "$SCRIPT" test 2>"$err"
    )" || _rc=$?
    [[ "$_rc" -eq 0 ]] || return 1
    [[ -n "$out" ]] || return 1
    [[ ! -s "$err" ]]
}
run_test "malformed package.json: test mode emits no jq stderr noise" test_malformed_package_json_test_no_stderr_noise

# --- Opt-in ai.task/v1 JSON envelope (AI_OUTPUT=json / --json). The DEFAULT
# (raw) output of every mode is unchanged; the envelope is additive and only
# appears when explicitly requested, so agents can version-gate the contract.

# AI_OUTPUT=json wraps `list` in the envelope with schema/status/mode + data.
test_env_json_list_envelope() {
    local out
    out="$(cd "$FIX_SCRIPTS" && mkdir -p .logs &&
        AI_LOG_DIR="$FIX_SCRIPTS/.logs" AI_EVENT_LOG="$FIX_SCRIPTS/.logs/ev.jsonl" \
            AI_OUTPUT=json "$BASH_BIN" "$SCRIPT" list 2>/dev/null)"
    echo "$out" | jq -e '.schema == "ai.task/v1" and .status == "ok" and .tool == "restsift" and .mode == "list" and (.data.package_manager != null)' >/dev/null
}
run_test "AI_OUTPUT=json list emits ai.task/v1 envelope wrapping the inventory" test_env_json_list_envelope

# The --json flag (trailing, after the mode) produces the same envelope.
test_flag_json_list_envelope() {
    local out
    out="$(run_in_fixture "$FIX_SCRIPTS" list --json)"
    echo "$out" | jq -e '.schema == "ai.task/v1" and .mode == "list" and (.data.package_scripts.test != null)' >/dev/null
}
run_test "list --json emits ai.task/v1 envelope" test_flag_json_list_envelope

# Recommend modes under --json carry a structured {intent,command,source,fallback}
# data object; a real package.json script is fallback:false with provenance.
test_flag_json_recommend_real_script() {
    local out
    out="$(run_in_fixture "$FIX_SCRIPTS" test --json)"
    echo "$out" | jq -e '.schema == "ai.task/v1" and .mode == "test" and .data.intent == "test" and .data.command == "npm test" and .data.source == "package.json#scripts.test" and .data.fallback == false' >/dev/null
}
run_test "test --json recommend envelope: real script has provenance + fallback:false" test_flag_json_recommend_real_script

# The generic ai-verify fallback is flagged fallback:true with source "generic".
test_flag_json_recommend_fallback() {
    local out
    out="$(run_in_fixture "$FIX_EMPTY" verify --json)"
    echo "$out" | jq -e '.data.command == "scripts/ai/ai-verify.sh ." and .data.source == "generic" and .data.fallback == true' >/dev/null
}
run_test "verify --json recommend envelope: generic fallback is fallback:true" test_flag_json_recommend_fallback

# BACKWARD COMPAT: default (no AI_OUTPUT / no --json) output is the raw inventory
# with the fields at top level and NO envelope keys leaking in.
test_default_list_has_no_envelope() {
    local out
    out="$(run_in_fixture "$FIX_SCRIPTS" list)"
    echo "$out" | jq -e '(has("schema") | not) and (.package_manager != null)' >/dev/null
}
run_test "default list has no envelope keys (raw inventory, unchanged)" test_default_list_has_no_envelope

# BACKWARD COMPAT: default recommend output stays the bare command line, no JSON.
test_default_recommend_is_bare_command() {
    [[ "$(run_in_fixture "$FIX_SCRIPTS" test)" == "npm test" ]]
}
run_test "default recommend output is the bare command line (unchanged)" test_default_recommend_is_bare_command

# --- todos mode: scan Markdown checkboxes ([ ]/[x]) with per-file stats. -------
# Fixture tree: a partial plan, a fully-complete file, a not-started file, a
# file with a non-standard [-] state, and a prose-only .md with no checkboxes.
FIX_TODOS="$TMP/fixture-todos"
mkdir -p "$FIX_TODOS/docs/sub" "$FIX_TODOS/.logs"
printf '# Plan\n- [x] done one\n- [x] done two\n- [ ] pending a\n- [ ] pending b\n- [-] cancelled\n' >"$FIX_TODOS/docs/plan.md"
printf '# Sub\n* [x] a\n1. [ ] numbered pending\n  - [ ] nested pending\n' >"$FIX_TODOS/docs/sub/tasks.md"
printf '# Complete\n- [x] all\n- [x] done\n' >"$FIX_TODOS/docs/sub/done.md"
printf '# Fresh\n- [ ] not started one\n- [ ] not started two\n' >"$FIX_TODOS/docs/fresh.md"
printf '# Prose only\nNo checkboxes here at all.\n' >"$FIX_TODOS/docs/readme.md"

# Whole-project scan: the totals footer reflects every checkbox across files.
test_todos_project_totals() {
    local out
    out="$(run_in_fixture "$FIX_TODOS" todos)"
    # 5 done, 6 pending across 4 files-with-tasks (readme.md excluded).
    echo "$out" | grep -q '4 file(s) with tasks' &&
        echo "$out" | grep -q '5 done / 6 pending'
}
run_test "todos: project scan reports per-file + totals" test_todos_project_totals

# A prose-only .md (no checkboxes) must not appear in the table.
test_todos_excludes_no_checkbox_files() {
    local out
    out="$(run_in_fixture "$FIX_TODOS" todos)"
    ! echo "$out" | grep -q 'readme.md'
}
run_test "todos: files with no checkboxes are omitted" test_todos_excludes_no_checkbox_files

# Single-file scope: only that file's counts are reported.
test_todos_single_file() {
    local out
    out="$(run_in_fixture "$FIX_TODOS" todos docs/plan.md)"
    echo "$out" | grep -q 'docs/plan.md' &&
        echo "$out" | grep -q '1 file(s) with tasks' &&
        ! echo "$out" | grep -q 'sub/tasks.md'
}
run_test "todos: single-file scope reports only that file" test_todos_single_file

# Directory scope: recursive, but bounded to the subtree.
test_todos_directory_scope() {
    local out
    out="$(run_in_fixture "$FIX_TODOS" todos docs/sub)"
    echo "$out" | grep -q 'tasks.md' &&
        echo "$out" | grep -q 'done.md' &&
        ! echo "$out" | grep -q 'plan.md'
}
run_test "todos: directory scope scans the subtree recursively" test_todos_directory_scope

# --json envelope: schema/mode plus a totals object with done/pending/percent.
test_todos_json_envelope() {
    local out
    out="$(run_in_fixture "$FIX_TODOS" todos --json)"
    echo "$out" | jq -e '.schema == "ai.task/v1" and .mode == "todos"
        and .data.totals.done == 5 and .data.totals.pending == 6
        and .data.totals.total == 12 and .data.totals.other == 1
        and .data.totals.files_with_tasks == 4
        and .data.totals.percent_complete == 41
        and .data.totals.percent_remaining == 59
        and (.data.files | length) == 4' >/dev/null
}
run_test "todos --json emits ai.task/v1 envelope with per-file + totals" test_todos_json_envelope

# A fully-complete file is percent_complete:100 in the JSON per-file array.
test_todos_json_complete_file() {
    local out
    out="$(run_in_fixture "$FIX_TODOS" todos docs/sub/done.md --json)"
    echo "$out" | jq -e '.data.files[0].percent_complete == 100
        and .data.totals.complete_files == 1' >/dev/null
}
run_test "todos --json: fully-complete file is percent_complete:100" test_todos_json_complete_file

# A non-standard state ([-]) is counted as "other", not done/pending.
test_todos_other_state() {
    local out
    out="$(run_in_fixture "$FIX_TODOS" todos docs/plan.md --json)"
    echo "$out" | jq -e '.data.files[0].other == 1 and .data.files[0].done == 2 and .data.files[0].pending == 2' >/dev/null
}
run_test "todos: non-standard [-] state counted as other" test_todos_other_state

# --pending lists each unchecked item as PATH:LINE: text.
test_todos_pending_list() {
    local out
    out="$(run_in_fixture "$FIX_TODOS" todos docs/plan.md --pending)"
    echo "$out" | grep -qE 'docs/plan.md:4:pending a' &&
        echo "$out" | grep -qE 'docs/plan.md:5:pending b'
}
run_test "todos --pending lists unchecked items as PATH:LINE: text" test_todos_pending_list

# An empty directory (no Markdown at all) reports the no-checkboxes message,
# still exit 0.
FIX_TODOS_EMPTY="$TMP/fixture-todos-empty"
mkdir -p "$FIX_TODOS_EMPTY"
test_todos_empty_dir() {
    local out _rc=0
    out="$(run_in_fixture "$FIX_TODOS_EMPTY" todos)" || _rc=$?
    [[ "$_rc" -eq 0 ]] && echo "$out" | grep -q 'No Markdown checkboxes found'
}
run_test "todos: empty directory reports no checkboxes (exit 0)" test_todos_empty_dir

# A nonexistent path is a hard error (exit 1), not a silent empty report --
# the die() must escape the process substitution, not just its subshell.
test_todos_bad_path_errors() {
    local _rc=0
    run_in_fixture "$FIX_TODOS" todos does-not-exist >/dev/null 2>&1 || _rc=$?
    [[ "$_rc" -ne 0 ]]
}
run_test "todos: nonexistent path fails (nonzero exit)" test_todos_bad_path_errors

# BACKWARD COMPAT: default todos output is a human table, not a JSON envelope.
test_todos_default_no_envelope() {
    local out
    out="$(run_in_fixture "$FIX_TODOS" todos)"
    ! echo "$out" | grep -q '"schema"'
}
run_test "todos: default output is a human table (no envelope keys)" test_todos_default_no_envelope

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d  Skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
((FAIL == 0)) && printf '\033[0;32mPASSED\033[0m\n' || {
    printf '\033[0;31mFAILED\033[0m\n'
    exit 1
}
