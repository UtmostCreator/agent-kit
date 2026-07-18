#!/usr/bin/env bash
# Tests for libexec/ai-test (fused ai-test-select + run-test-focused +
# run-repo-tests). Replaces test-ai-test-select.sh, which tested the
# pre-fusion standalone ai-test-select engine. run-test-focused and
# run-repo-tests had no dedicated test file before fusion; this file adds
# focused argument-parsing/--help/--introspect/error-path coverage for the
# run and all modes but deliberately never invokes a real phpunit run or the
# real heavy whole-suite run here, matching the restraint the pre-fusion
# engines' (lack of) test coverage already implied.
set -euo pipefail
BASH_BIN="${BASH_BIN:-$(command -v bash)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/libexec/ai-test"
cd "$REPO_ROOT"

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

# Prints a drop-in replacement PATH (a single flat directory of symlinks)
# that resolves every executable currently on $PATH except $1. Used by
# isolation tests below that need a binary to be truly absent.
#
# This symlinks-everything-but-X approach (not whole-directory removal) is
# required for correctness on a real Linux host: system binaries share
# directories (e.g. php and mktemp both live in /usr/bin on stock Ubuntu),
# so stripping "every PATH entry that resolves $1" also silently deletes
# unrelated tools the calling test still needs afterward (mktemp, grep,
# etc.), breaking it in a way that looks unrelated to $1 at all. That only
# went unnoticed in the Nix dev sandbox, where every tool lives in its own
# isolated store path and never shares a directory with anything else --
# confirmed against a real single-directory PATH layout (see PR review).
path_without() {
    local bin="$1"
    local fakebin="$TMP/path-without-${bin//[^A-Za-z0-9_.-]/_}"
    mkdir -p "$fakebin"
    local dir f base
    local -a dirs=() sources=()
    local -A seen=()
    seen["$bin"]=1
    IFS=':' read -ra dirs <<<"$PATH"
    for dir in "${dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        for f in "$dir"/*; do
            [[ -x "$f" && -f "$f" ]] || continue
            # ${f##*/} (not `basename "$f"`) avoids forking a process per
            # PATH entry -- on a PATH with hundreds of entries that was the
            # dominant cost of this helper (~6-7s), now sub-0.1s.
            base="${f##*/}"
            [[ -n "${seen[$base]:-}" ]] && continue
            seen["$base"]=1
            sources+=("$f")
        done
    done
    local i
    for ((i = 0; i < ${#sources[@]}; i += 500)); do
        ln -sf -- "${sources[@]:i:500}" "$fakebin" 2>/dev/null || true
    done
    printf '%s' "$fakebin"
}

printf 'ai-test\n'

# =============================================================================
# select (fused from ai-test-select)
# =============================================================================

test_select_help() { "$BASH_BIN" "$SCRIPT" select --help 2>&1 | grep -q 'Usage'; }
run_test "select --help works" test_select_help

test_select_no_mode() { ! "$BASH_BIN" "$SCRIPT" select 2>/dev/null; }
run_test "select missing mode exits with error" test_select_no_mode

test_select_changed() {
    local out
    out="$(AI_LOG_DIR="$TMP/logs" AI_EVENT_LOG="$TMP/logs/ev.jsonl" "$BASH_BIN" "$SCRIPT" select changed 2>/dev/null)"
    echo "$out" | jq -e '.input_files' >/dev/null
    echo "$out" | jq -e '.candidate_tests' >/dev/null
    echo "$out" | jq -e '.recommended_commands' >/dev/null
}
run_test "select changed returns JSON with required keys" test_select_changed

test_select_file_mode() {
    local out
    out="$(AI_LOG_DIR="$TMP/logs2" AI_EVENT_LOG="$TMP/logs2/ev.jsonl" "$BASH_BIN" "$SCRIPT" select file lib/common.sh 2>/dev/null)"
    echo "$out" | jq -e '.input_files' >/dev/null
}
run_test "select file mode returns JSON" test_select_file_mode

# Regression (defect 3): `select file` with no PATH must emit a documented,
# usage-style error — NOT a raw bash parameter-expansion message that leaks the
# module path, an internal line number, and the positional-parameter name.
test_select_file_missing_path_clean_error() {
    local err rc=0
    err="$("$BASH_BIN" "$SCRIPT" select file 2>&1 >/dev/null)" || rc=$?
    ((rc != 0)) || return 1
    [[ "$err" == *"restsift test select file"* ]] || return 1
    [[ "$err" != *"line "* && "$err" != *"file required"* ]]
}
run_test "select file with missing PATH emits a clean usage error, not a raw bash message" test_select_file_missing_path_clean_error

test_select_json_mode() {
    local out
    out="$(AI_LOG_DIR="$TMP/logs3" AI_EVENT_LOG="$TMP/logs3/ev.jsonl" "$BASH_BIN" "$SCRIPT" select json 2>/dev/null)"
    echo "$out" | jq -e '.candidate_tests' >/dev/null
}
run_test "select json mode returns JSON" test_select_json_mode

test_select_symbol() {
    local out
    out="$(AI_LOG_DIR="$TMP/logs4" AI_EVENT_LOG="$TMP/logs4/ev.jsonl" "$BASH_BIN" "$SCRIPT" select symbol "log_info" 2>/dev/null)"
    echo "$out" | jq -e '.candidate_tests' >/dev/null
}
run_test "select symbol mode searches for symbol usage" test_select_symbol

test_select_symbol_zero_matches() {
    # Built at runtime (never written as a literal token in this repo) so
    # rg's "test/**"-style globs can't accidentally match this very file.
    local symbol out
    symbol="NoSuchSymbol_${BASHPID:-$$}_$(date +%s%N 2>/dev/null || echo static)"
    out="$(AI_LOG_DIR="$TMP/logs4b" AI_EVENT_LOG="$TMP/logs4b/ev.jsonl" "$BASH_BIN" "$SCRIPT" select symbol "$symbol" 2>/dev/null)"
    [[ "$(echo "$out" | jq -e '.candidate_tests | length')" == "0" ]]
}
run_test "select symbol with zero matches returns an empty candidate_tests array" test_select_symbol_zero_matches

# Regression: `select symbol` with no SYMBOL must emit a documented, usage-style
# error (exit 2) — NOT a raw bash parameter-expansion message that leaks the
# module path, an internal line number, and the positional-parameter name.
test_select_symbol_missing_arg_clean_error() {
    local err rc=0
    err="$("$BASH_BIN" "$SCRIPT" select symbol 2>&1 >/dev/null)" || rc=$?
    ((rc == 2)) || return 1
    [[ "$err" == *"restsift test select symbol"* ]] || return 1
    [[ "$err" != *"line "* && "$err" != *"symbol required"* ]]
}
run_test "select symbol with missing SYMBOL emits a clean usage error, not a raw bash message" test_select_symbol_missing_arg_clean_error

test_select_unknown_mode() {
    ! AI_LOG_DIR="$TMP/logs5" AI_EVENT_LOG="$TMP/logs5/ev.jsonl" "$BASH_BIN" "$SCRIPT" select nonexistent 2>/dev/null
}
run_test "select unknown mode fails" test_select_unknown_mode

# An unknown `select` sub-mode must exit 2 (matching the top-level dispatcher
# and the file/symbol missing-arg paths) with a clean ERROR line naming the
# offending value — not exit 1 via die() with an unnamed value.
test_select_unknown_mode_exits_2() {
    local err rc=0
    err="$(AI_LOG_DIR="$TMP/logs5b" AI_EVENT_LOG="$TMP/logs5b/ev.jsonl" "$BASH_BIN" "$SCRIPT" select bogus 2>&1 >/dev/null)" || rc=$?
    ((rc == 2)) || return 1
    [[ "$err" == *"unknown mode 'bogus'"* ]]
}
run_test "select unknown mode exits 2 with a clean ERROR naming the value" test_select_unknown_mode_exits_2

# `select changed` outside a git worktree must emit one clean, parseable line
# and exit 1 — NOT let `git diff` dump multi-line fatal/usage text while still
# "succeeding" with an empty JSON body.
test_select_changed_non_git_clean_error() (
    local nongit err rc=0
    nongit="$(mktemp -d)"
    cd "$nongit" || return 1
    err="$(AI_LOG_DIR="$nongit/logs" AI_EVENT_LOG="$nongit/logs/ev.jsonl" "$BASH_BIN" "$SCRIPT" select changed 2>&1 >/dev/null)" || rc=$?
    rm -rf "$nongit"
    ((rc == 1)) || return 1
    [[ "$err" == *"must run inside a git worktree"* ]] || return 1
    (($(printf '%s\n' "$err" | wc -l) <= 2))
)
run_test "select changed in a non-git dir emits one clean line and exits 1" test_select_changed_non_git_clean_error

# Under AI_OUTPUT=json, when candidate_tests are found but no runner resolves
# (empty recommended_commands), the envelope carries a `hint` so the empty
# array is not misread as "nothing to run". Default output (no AI_OUTPUT) stays
# byte-identical and carries no hint key.
test_select_hint_when_json_and_no_runner() (
    local repo out
    repo="$(mktemp -d)"
    cd "$repo" || return 1
    git init -q . || return 1
    mkdir -p src tests
    : >src/Foo.php
    : >tests/FooTest.php
    git add -A || return 1
    out="$(AI_OUTPUT=json AI_LOG_DIR="$repo/logs" AI_EVENT_LOG="$repo/logs/ev.jsonl" "$BASH_BIN" "$SCRIPT" select changed 2>/dev/null)"
    echo "$out" | jq -e '(.candidate_tests | length) > 0' >/dev/null || { rm -rf "$repo"; return 1; }
    echo "$out" | jq -e '(.recommended_commands | length) == 0' >/dev/null || { rm -rf "$repo"; return 1; }
    echo "$out" | jq -e 'has("hint")' >/dev/null || { rm -rf "$repo"; return 1; }
    out="$(AI_LOG_DIR="$repo/logs" AI_EVENT_LOG="$repo/logs/ev.jsonl" "$BASH_BIN" "$SCRIPT" select changed 2>/dev/null)"
    rm -rf "$repo"
    ! echo "$out" | jq -e 'has("hint")' >/dev/null
)
run_test "select adds a hint under AI_OUTPUT=json when tests found but no runner (none by default)" test_select_hint_when_json_and_no_runner

# -----------------------------------------------------------------------
# select — direct module unit tests. Sources lib/ai-test/select.sh directly
# (bypassing the CLI/common.sh boilerplate) to exercise helper-function
# branches that select changed/file/symbol only reach incidentally.
# -----------------------------------------------------------------------

test_select_find_tests_for_symbol_without_rg() (
    source "$REPO_ROOT/lib/ai-test/select.sh"
    local filtered out
    filtered="$(path_without rg)" || return 1
    PATH="$filtered"
    ! command -v rg >/dev/null 2>&1 || return 1
    out="$(ai_test_select_find_tests_for_symbol "SomeSymbolThatDoesNotMatter")"
    [[ -z "$out" ]]
)
run_test "find_tests_for_symbol degrades to empty without rg on PATH" test_select_find_tests_for_symbol_without_rg

test_select_command_for_test_php_artisan() (
    source "$REPO_ROOT/lib/ai-test/select.sh"
    local dir
    dir="$(mktemp -d)"
    cd "$dir" || return 1
    touch artisan
    [[ "$(ai_test_select_command_for_test "tests/FooTest.php")" == "php artisan test tests/FooTest.php" ]]
)
run_test "command_for_test picks artisan for a Laravel-style project" test_select_command_for_test_php_artisan

test_select_command_for_test_php_pest() (
    source "$REPO_ROOT/lib/ai-test/select.sh"
    local dir
    dir="$(mktemp -d)"
    cd "$dir" || return 1
    mkdir -p vendor/bin
    : >vendor/bin/pest
    chmod +x vendor/bin/pest
    [[ "$(ai_test_select_command_for_test "tests/FooTest.php")" == "vendor/bin/pest tests/FooTest.php" ]]
)
run_test "command_for_test picks pest when artisan is absent" test_select_command_for_test_php_pest

test_select_command_for_test_php_phpunit() (
    source "$REPO_ROOT/lib/ai-test/select.sh"
    local dir
    dir="$(mktemp -d)"
    cd "$dir" || return 1
    mkdir -p vendor/bin
    : >vendor/bin/phpunit
    chmod +x vendor/bin/phpunit
    [[ "$(ai_test_select_command_for_test "tests/FooTest.php")" == "vendor/bin/phpunit tests/FooTest.php" ]]
)
run_test "command_for_test picks phpunit when artisan/pest are absent" test_select_command_for_test_php_phpunit

test_select_command_for_test_js_pnpm() (
    source "$REPO_ROOT/lib/ai-test/select.sh"
    local dir
    dir="$(mktemp -d)"
    cd "$dir" || return 1
    : >pnpm-lock.yaml
    : >package.json
    [[ "$(ai_test_select_command_for_test "src/Foo.test.js")" == "pnpm test -- src/Foo.test.js" ]]
)
run_test "command_for_test picks pnpm when pnpm-lock.yaml is present" test_select_command_for_test_js_pnpm

test_select_command_for_test_js_npm() (
    source "$REPO_ROOT/lib/ai-test/select.sh"
    local dir
    dir="$(mktemp -d)"
    cd "$dir" || return 1
    : >package.json
    [[ "$(ai_test_select_command_for_test "src/Foo.test.js")" == "npm test -- src/Foo.test.js" ]]
)
run_test "command_for_test picks npm when pnpm-lock.yaml is absent" test_select_command_for_test_js_npm

test_select_command_for_test_unmatched_extension() (
    source "$REPO_ROOT/lib/ai-test/select.sh"
    local dir
    dir="$(mktemp -d)"
    cd "$dir" || return 1
    [[ -z "$(ai_test_select_command_for_test "README.md")" ]]
)
run_test "command_for_test returns nothing for an unmatched extension" test_select_command_for_test_unmatched_extension

# Regression (defect 2): find_tests_for_stem must not treat a stem's OWN source
# file as one of its tests. The bare-stem branch previously made the Test|Spec
# suffix optional, so `render-adapters.php` (the source) matched itself. A real
# `<stem>Test.php` outside a tests/ dir must still be selected.
test_select_find_tests_for_stem_excludes_source_file() (
    source "$REPO_ROOT/lib/ai-test/select.sh"
    local dir out
    dir="$(mktemp -d)"
    cd "$dir" || return 1
    git init -q . || return 1
    mkdir -p tools lib
    : >tools/render-adapters.php
    : >lib/render-adaptersTest.php
    git add -A || return 1
    out="$(ai_test_select_find_tests_for_stem "render-adapters")"
    # the stem's own source file must NOT be a candidate test...
    ! grep -qx 'tools/render-adapters.php' <<<"$out" || return 1
    # ...but a genuine *Test.php for the stem still must be.
    grep -qx 'lib/render-adaptersTest.php' <<<"$out"
)
run_test "find_tests_for_stem excludes the stem's own source file but keeps real Test files" test_select_find_tests_for_stem_excludes_source_file

# =============================================================================
# run (fused from run-test-focused). Argument-parsing/error-path coverage
# only — never invokes a real phpunit run in this test file.
# =============================================================================

test_run_help() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" run --help 2>&1)"
    [[ "$out" == *"restsift test run"* ]]
}
run_test "run --help prints usage" test_run_help

if command -v jq >/dev/null 2>&1; then
    test_run_introspect() {
        local out
        out="$("$BASH_BIN" "$SCRIPT" run --introspect 2>&1)"
        jq -e '.schema == "ai.sh-introspect/v1"' <<<"$out" >/dev/null
    }
    run_test "run --introspect emits a valid contract" test_run_introspect
else
    skip_test "run --introspect emits a valid contract" "jq not installed"
fi

test_run_no_args() {
    local rc=0
    "$BASH_BIN" "$SCRIPT" run >/dev/null 2>&1 || rc=$?
    ((rc == 2))
}
run_test "run missing filter/path exits 2" test_run_no_args

if [[ -x vendor/bin/phpunit ]]; then
    skip_test "run reports missing vendor/bin/phpunit" "vendor/bin/phpunit is present"
else
    test_run_missing_phpunit() {
        local rc=0
        "$BASH_BIN" "$SCRIPT" run --filter NoSuchTest >/dev/null 2>&1 || rc=$?
        ((rc == 1))
    }
    run_test "run reports missing vendor/bin/phpunit" test_run_missing_phpunit
fi

# Regression (defect 1): `run` must execute phpunit against the CALLER's repo
# root (its cwd), not the toolkit's own install dir (restsift, which the CLI
# resolves via AI_TEST_LIBEXEC_DIR/.. and which has no vendor/bin/phpunit). A
# stub php records whether it was launched inside the caller repo (identified by
# a sentinel file); with the old ROOT it bailed on the toolkit's missing phpunit
# before ever reaching the stub, so the marker stayed empty.
test_run_uses_caller_repo_root() (
    local fake_repo php_stub marker
    fake_repo="$(mktemp -d)"
    mkdir -p "$fake_repo/vendor/bin"
    : >"$fake_repo/vendor/bin/phpunit"
    chmod +x "$fake_repo/vendor/bin/phpunit"
    : >"$fake_repo/phpunit.xml.dist"
    : >"$fake_repo/CALLER_REPO_SENTINEL"

    marker="$(mktemp)"
    php_stub="$(mktemp)"
    cat >"$php_stub" <<STUB
#!/usr/bin/env bash
[[ -e CALLER_REPO_SENTINEL ]] && printf 'ok\n' >>"$marker"
exit 0
STUB
    chmod +x "$php_stub"

    cd "$fake_repo" || return 1
    PHP_BIN="$php_stub" TEST_TIMEOUT=10 "$BASH_BIN" "$SCRIPT" run --filter NoSuchTest >/dev/null 2>&1 || true

    grep -q ok "$marker"
)
run_test "run executes phpunit against the caller's repo root, not the toolkit install dir" test_run_uses_caller_repo_root

# =============================================================================
# all (fused from run-repo-tests). Argument-parsing/error-path coverage
# only — NEVER invokes the real whole-suite run here (heavy/slow); the
# pre-fusion standalone run-repo-tests had no dedicated automated test file
# either, so this preserves the same restraint.
# =============================================================================

test_all_help() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" all --help 2>&1)"
    [[ "$out" == *"restsift test all"* ]]
}
run_test "all --help prints usage" test_all_help

if command -v jq >/dev/null 2>&1; then
    test_all_introspect() {
        local out
        out="$("$BASH_BIN" "$SCRIPT" all --introspect 2>&1)"
        jq -e '.schema == "ai.sh-introspect/v1"' <<<"$out" >/dev/null
    }
    run_test "all --introspect emits a valid contract" test_all_introspect
else
    skip_test "all --introspect emits a valid contract" "jq not installed"
fi

test_all_bad_paratest_procs() {
    local rc=0
    PARATEST_PROCS=abc "$BASH_BIN" "$SCRIPT" all >/dev/null 2>&1 || rc=$?
    ((rc == 2))
}
run_test "all rejects non-numeric PARATEST_PROCS" test_all_bad_paratest_procs

# -----------------------------------------------------------------------
# all — direct module unit tests. Sources lib/ai-test/run-all.sh directly
# and either calls ai_test_all_run_job in isolation with trivial fixture
# commands, or invokes ai_test_all_main against a throwaway fake repo tree
# with trivial stub commands standing in for paratest/phpunit/bats. NEVER
# invokes a real phpunit/paratest/whole-suite run — matching the restraint
# documented above the "all" CLI tests.
# -----------------------------------------------------------------------

test_all_run_job_captures_success_output() (
    source "$REPO_ROOT/lib/ai-test/run-all.sh"
    _wrapper() {
        local JOBS=() NAMES=() LOGS=()
        local TMP_DIR TIMEOUT_BIN="" SUITE_TIMEOUT=5
        TMP_DIR="$(mktemp -d)"
        trap 'rm -rf "$TMP_DIR"' RETURN
        ai_test_all_run_job "trivial-ok" bash -c 'echo hello; exit 0'
        [[ "${#JOBS[@]}" -eq 1 && "${NAMES[0]}" == "trivial-ok" ]] || return 1
        wait "${JOBS[0]}"
        local rc=$?
        grep -q hello "${LOGS[0]}" || return 1
        ((rc == 0))
    }
    _wrapper
)
run_test "ai_test_all_run_job captures a passing job's output and exit code" test_all_run_job_captures_success_output

test_all_run_job_captures_failure_exit_code() (
    source "$REPO_ROOT/lib/ai-test/run-all.sh"
    _wrapper() {
        local JOBS=() NAMES=() LOGS=()
        local TMP_DIR TIMEOUT_BIN="" SUITE_TIMEOUT=5
        TMP_DIR="$(mktemp -d)"
        trap 'rm -rf "$TMP_DIR"' RETURN
        ai_test_all_run_job "trivial-fail" bash -c 'echo boom >&2; exit 7'
        wait "${JOBS[0]}"
        local rc=$?
        grep -q boom "${LOGS[0]}" || return 1
        ((rc == 7))
    }
    _wrapper
)
run_test "ai_test_all_run_job captures a failing job's output and exit code" test_all_run_job_captures_failure_exit_code

test_all_run_job_without_timeout_binary_warns() (
    source "$REPO_ROOT/lib/ai-test/run-all.sh"
    _wrapper() {
        local JOBS=() NAMES=() LOGS=()
        local TMP_DIR TIMEOUT_BIN="" SUITE_TIMEOUT=5
        TMP_DIR="$(mktemp -d)"
        trap 'rm -rf "$TMP_DIR"' RETURN
        local warn_file
        warn_file="$(mktemp)"
        ai_test_all_run_job "no-timeout" true 2>"$warn_file"
        wait "${JOBS[0]}"
        local rc=$?
        local warn
        warn="$(cat "$warn_file")"
        rm -f "$warn_file"
        [[ "$warn" == *"no timeout/gtimeout binary"* ]] && ((rc == 0))
    }
    _wrapper
)
run_test "ai_test_all_run_job warns on stderr when no timeout binary is set" test_all_run_job_without_timeout_binary_warns

test_all_run_job_with_timeout_binary() (
    source "$REPO_ROOT/lib/ai-test/run-all.sh"
    _wrapper() {
        local JOBS=() NAMES=() LOGS=()
        # shellcheck disable=SC2034  # TIMEOUT_BIN/SUITE_TIMEOUT are read via
        # dynamic scope by ai_test_all_run_job() (sourced from a variable
        # path shellcheck can't statically follow), not directly in this file.
        local TMP_DIR TIMEOUT_BIN SUITE_TIMEOUT=5
        # shellcheck disable=SC2034
        TIMEOUT_BIN="$(command -v timeout)" || return 1
        TMP_DIR="$(mktemp -d)"
        trap 'rm -rf "$TMP_DIR"' RETURN
        ai_test_all_run_job "with-timeout" true
        wait "${JOBS[0]}"
        local rc=$?
        ((rc == 0))
    }
    _wrapper
)
if command -v timeout >/dev/null 2>&1; then
    run_test "ai_test_all_run_job runs jobs under a timeout binary when available" test_all_run_job_with_timeout_binary
else
    skip_test "ai_test_all_run_job runs jobs under a timeout binary when available" "timeout not installed"
fi

# Builds a minimal fake repo tree under a fresh tmpdir with just enough
# structure (a fast tests/scripts/ai/run-all-tests.sh stub, no vendor/ or
# tests/shell by default) for ai_test_all_main to run end-to-end quickly
# without ever touching a real phpunit/paratest/bats invocation.
make_fake_all_repo_root() {
    local root
    root="$(mktemp -d)"
    mkdir -p "$root/libexec" "$root/tests/scripts/ai"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$root/tests/scripts/ai/run-all-tests.sh"
    chmod +x "$root/tests/scripts/ai/run-all-tests.sh"
    printf '%s' "$root"
}

test_all_max_paratest_procs_clamp() (
    local fake_root marker php_stub
    fake_root="$(make_fake_all_repo_root)"
    mkdir -p "$fake_root/vendor/bin"
    : >"$fake_root/vendor/bin/paratest"
    chmod +x "$fake_root/vendor/bin/paratest"

    marker="$(mktemp)"
    php_stub="$(mktemp)"
    cat >"$php_stub" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$marker"
exit 0
STUB
    chmod +x "$php_stub"

    AI_TEST_LIBEXEC_DIR="$fake_root/libexec"
    export AI_TEST_LIBEXEC_DIR
    source "$REPO_ROOT/lib/ai-test/run-all.sh"

    cd "$fake_root" || return 1
    (PARATEST_PROCS=999 MAX_PARATEST_PROCS=3 PHP_BIN="$php_stub" SUITE_TIMEOUT=5 ai_test_all_main >/dev/null 2>&1) || true

    grep -q -- '--processes=3' "$marker"
)
run_test "all clamps PARATEST_PROCS to MAX_PARATEST_PROCS" test_all_max_paratest_procs_clamp

test_all_php_bin_prefers_native_over_exe() (
    local fake_root fakebin marker
    fake_root="$(make_fake_all_repo_root)"

    fakebin="$(mktemp -d)"
    marker="$(mktemp)"
    cat >"$fakebin/php" <<STUB
#!/usr/bin/env bash
printf 'php:%s\n' "\$*" >>"$marker"
exit 0
STUB
    chmod +x "$fakebin/php"
    cat >"$fakebin/php.exe" <<STUB
#!/usr/bin/env bash
printf 'php.exe:%s\n' "\$*" >>"$marker"
exit 0
STUB
    chmod +x "$fakebin/php.exe"

    AI_TEST_LIBEXEC_DIR="$fake_root/libexec"
    export AI_TEST_LIBEXEC_DIR
    PATH="$fakebin:$PATH"
    unset PHP_BIN
    source "$REPO_ROOT/lib/ai-test/run-all.sh"

    cd "$fake_root" || return 1
    (SUITE_TIMEOUT=5 ai_test_all_main >/dev/null 2>&1) || true

    grep -q '^php:' "$marker" && ! grep -q '^php\.exe:' "$marker"
)

test_all_php_bin_falls_back_to_exe_when_no_native() (
    local fake_root fakebin marker filtered
    fake_root="$(make_fake_all_repo_root)"

    fakebin="$(mktemp -d)"
    marker="$(mktemp)"
    cat >"$fakebin/php.exe" <<STUB
#!/usr/bin/env bash
printf 'php.exe:%s\n' "\$*" >>"$marker"
exit 0
STUB
    chmod +x "$fakebin/php.exe"

    filtered="$(path_without php)" || return 1

    AI_TEST_LIBEXEC_DIR="$fake_root/libexec"
    export AI_TEST_LIBEXEC_DIR
    PATH="$fakebin:$filtered"
    ! command -v php >/dev/null 2>&1 || return 1
    unset PHP_BIN
    source "$REPO_ROOT/lib/ai-test/run-all.sh"

    cd "$fake_root" || return 1
    (SUITE_TIMEOUT=5 ai_test_all_main >/dev/null 2>&1) || true

    grep -q '^php\.exe:' "$marker"
)

if command -v php >/dev/null 2>&1; then
    run_test "all prefers a native php over php.exe when both resolve" test_all_php_bin_prefers_native_over_exe
    run_test "all falls back to php.exe when no native php resolves" test_all_php_bin_falls_back_to_exe_when_no_native
else
    skip_test "all prefers a native php over php.exe when both resolve" "php not installed"
    skip_test "all falls back to php.exe when no native php resolves" "php not installed"
fi

test_all_bats_skip_when_missing_or_no_tests_dir() (
    local fake_root out
    fake_root="$(make_fake_all_repo_root)"

    AI_TEST_LIBEXEC_DIR="$fake_root/libexec"
    export AI_TEST_LIBEXEC_DIR
    PHP_BIN="true"
    export PHP_BIN
    source "$REPO_ROOT/lib/ai-test/run-all.sh"

    cd "$fake_root" || return 1
    out="$(SUITE_TIMEOUT=5 ai_test_all_main 2>&1)" || true
    [[ "$out" == *"skip: bats-shell-tests (bats not installed or tests/shell missing)"* ]]
)
run_test "all skips bats-shell-tests when tests/shell is missing" test_all_bats_skip_when_missing_or_no_tests_dir

test_all_bats_runs_real_trivial_test() (
    local fake_root out
    fake_root="$(make_fake_all_repo_root)"
    mkdir -p "$fake_root/tests/shell"
    printf '#!/usr/bin/env bats\n\n@test "trivial passes" {\n  true\n}\n' >"$fake_root/tests/shell/trivial.bats"

    AI_TEST_LIBEXEC_DIR="$fake_root/libexec"
    export AI_TEST_LIBEXEC_DIR
    PHP_BIN="true"
    export PHP_BIN
    source "$REPO_ROOT/lib/ai-test/run-all.sh"

    cd "$fake_root" || return 1
    out="$(SUITE_TIMEOUT=15 ai_test_all_main 2>&1)" || true
    [[ "$out" == *"start: bats-shell-tests"* && "$out" == *"pass: bats-shell-tests"* ]]
)
if command -v bats >/dev/null 2>&1; then
    run_test "all actually runs a trivial passing bats suite" test_all_bats_runs_real_trivial_test
else
    skip_test "all actually runs a trivial passing bats suite" "bats not installed"
fi

test_all_php_paratest_package_skip_when_no_test_files() (
    local fake_root out
    fake_root="$(make_fake_all_repo_root)"
    mkdir -p "$fake_root/packages/ai-kit-tests/tests"
    : >"$fake_root/packages/ai-kit-tests/phpunit.xml.dist"

    AI_TEST_LIBEXEC_DIR="$fake_root/libexec"
    export AI_TEST_LIBEXEC_DIR
    PHP_BIN="true"
    export PHP_BIN
    source "$REPO_ROOT/lib/ai-test/run-all.sh"

    cd "$fake_root" || return 1
    out="$(SUITE_TIMEOUT=5 ai_test_all_main 2>&1)" || true
    [[ "$out" == *"skip: php-paratest-package (no package Test.php files yet)"* ]]
)
run_test "all skips php-paratest-package when no *Test.php files exist yet" test_all_php_paratest_package_skip_when_no_test_files

# Regression (defect 1): `all` must run the CALLER repo's suites (its cwd), not
# the toolkit install dir derived from AI_TEST_LIBEXEC_DIR/... AI_TEST_LIBEXEC_DIR
# points at an unrelated dir with NO tests/scripts/ai/run-all-tests.sh; only when
# ROOT tracks the caller's cwd does the sentinel-writing script-tests stub run.
test_all_uses_caller_repo_root() (
    local fake_repo other marker
    fake_repo="$(mktemp -d)"
    mkdir -p "$fake_repo/tests/scripts/ai"
    marker="$(mktemp)"
    rm -f "$marker"
    cat >"$fake_repo/tests/scripts/ai/run-all-tests.sh" <<STUB
#!/usr/bin/env bash
printf 'ran\n' >"$marker"
exit 0
STUB
    chmod +x "$fake_repo/tests/scripts/ai/run-all-tests.sh"

    other="$(mktemp -d)"
    mkdir -p "$other/libexec"
    AI_TEST_LIBEXEC_DIR="$other/libexec"
    export AI_TEST_LIBEXEC_DIR
    PHP_BIN="true"
    export PHP_BIN
    source "$REPO_ROOT/lib/ai-test/run-all.sh"

    cd "$fake_repo" || return 1
    (SUITE_TIMEOUT=15 ai_test_all_main >/dev/null 2>&1) || true

    [[ -f "$marker" ]] && grep -q ran "$marker"
)
run_test "all runs the caller repo's suites, not the toolkit install dir" test_all_uses_caller_repo_root

# =============================================================================
# group-level dispatch
# =============================================================================

test_group_help() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" --help 2>&1 || true)"
    [[ "$out" == *"restsift test"* ]]
}
run_test "group --help prints usage" test_group_help

test_group_unknown_mode() {
    local rc=0
    "$BASH_BIN" "$SCRIPT" bogus >/dev/null 2>&1 || rc=$?
    ((rc == 2))
}
run_test "unknown top-level mode exits 2" test_group_unknown_mode

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d  Skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
((FAIL == 0)) && printf '\033[0;32mPASSED\033[0m\n' || {
    printf '\033[0;31mFAILED\033[0m\n'
    exit 1
}
