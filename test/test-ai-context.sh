#!/usr/bin/env bash
# Tests for libexec/ai-context (fused pack, file, diff, estimate, status, ensure
# modes; generate/tree are covered by test-run-repomix-context.sh /
# test-repomix-context-tree.sh against their relocated libexec/internal/ paths).
#
# Ports every assertion from the former standalone test files:
#   test-pack-context.sh, test-run-repomix-file.sh, test-ai-diff-context.sh,
#   test-query-usage.sh, test-repomix-freshness.sh (which also covered
#   repomix-ensure-fresh; there was never a separate test-repomix-ensure-fresh.sh)
# adapted to call `libexec/ai-context <mode> ...` instead of the old standalone
# script paths.
#
# Phase 3b coverage tests below source lib/ai-diff-context/helpers.sh and
# lib/ai-context/{status,ensure}.sh directly (via fixed, effectively-constant
# path variables assigned once near their first use) inside throwaway
# subshells, so unit-level functions (parse_common_option, write_diff_artifact,
# pack_files_list, ...) can be exercised without going through the full CLI.
# Some locals set in those subshells (SESSION_DIR, OUTPUT_DIR, DRY_RUN,
# INCLUDE_TESTS, REPOMIX_WARN_DAYS, REPOMIX_MAX_DAYS, ...) are only read by the
# dynamically-sourced functions, matching lib/ai-diff-context/*.sh's own
# "cross-module globals via dynamic scope" shellcheck disable convention.
# shellcheck disable=SC1090,SC2034
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/libexec/ai-context"
cd "$REPO_ROOT"
BASH_BIN="${BASH_BIN:-$(command -v bash)}"
TIMEOUT_BIN="$(command -v gtimeout || command -v timeout || true)"

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

# ---------------------------------------------------------------------------
# Shared fixture helpers for the Phase 3b coverage tests below: ai-diff-context
# commands/helpers (lib/ai-diff-context/{commands,helpers}.sh) and
# ai-context status/ensure/pack/file (lib/ai-context/{status,ensure,pack,file}.sh).
# ---------------------------------------------------------------------------

# A git repo with an initial (empty) commit, ready for further commits/edits.
make_git_fixture() {
    local dir="$1"
    mkdir -p "$dir"
    (
        cd "$dir" && git init -q &&
            git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    ) >/dev/null 2>&1
}

# A fake `gh` binary that answers the two subcommands ai-diff-context uses:
# `gh pr view <n> --json files --jq '.files[].path'` and `gh pr diff <n>`.
make_fake_gh() {
    local bin_dir="$1"
    mkdir -p "$bin_dir"
    cat >"$bin_dir/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
"pr view")
    printf '%s\n' "${FAKE_GH_FILES:-README.md}"
    ;;
"pr diff")
    printf 'diff --git a/README.md b/README.md\n+hello\n'
    ;;
*)
    exit 1
    ;;
esac
FAKE_GH
    chmod +x "$bin_dir/gh"
}

# A restricted PATH directory that symlinks the currently-resolved core tools
# the non-packer code paths need (git, jq, coreutils, ...) WITHOUT
# repomix/files-to-prompt/code2prompt, so `command -v <packer>` reliably fails
# even though the real packers stay installed elsewhere on PATH.
make_bin_dir_without_packers() {
    local bin_dir="$1"
    mkdir -p "$bin_dir"
    local tool resolved
    for tool in git jq sort sed paste wc tr date mktemp mkdir cat rm dirname \
        basename grep cp env uname find head tail cut readlink realpath; do
        resolved="$(command -v "$tool" 2>/dev/null || true)"
        [[ -n "$resolved" ]] && ln -sf "$resolved" "$bin_dir/$tool"
    done
}

printf 'ai-context\n'

# ---------------------------------------------------------------------------
# top-level --help
# ---------------------------------------------------------------------------
test_toplevel_help() { "$BASH_BIN" "$SCRIPT" --help 2>&1 | grep -q 'Usage'; }
run_test "top-level help flag works" test_toplevel_help

# ===========================================================================
# pack (formerly test-pack-context.sh)
# ===========================================================================

# Pack a clean fixture, not this toolkit's own tree (lib/secrets.sh would trip
# the packer's secret guard and fail these functional backend tests).
PACK_FIX="$TMP/pack-fixture"
mkdir -p "$PACK_FIX"
printf '# Sample\nhello world\n' >"$PACK_FIX/README.md"
(
    cd "$PACK_FIX" && git init -q && git add -A &&
        git -c user.email=t@t -c user.name=t commit -qm init
) >/dev/null 2>&1 || true

test_pack_help() { "$BASH_BIN" "$SCRIPT" pack --help 2>&1 | grep -q 'Usage'; }
run_test "pack: help flag works" test_pack_help

test_pack_auto_fallback() {
    local out
    out="$(cd "$PACK_FIX" && OUTPUT_DIR="$TMP/pack-out" "$BASH_BIN" "$SCRIPT" pack auto --include "README.md" 2>&1 || true)"
    [[ -n "$out" ]]
}
run_test "pack: auto backend attempts context pack" test_pack_auto_fallback

if command -v files-to-prompt >/dev/null 2>&1; then
    test_pack_files_to_prompt() {
        (cd "$PACK_FIX" && OUTPUT_DIR="$TMP/pack-out2" "$BASH_BIN" "$SCRIPT" pack files-to-prompt README.md) 2>/dev/null
    }
    run_test "pack: files-to-prompt backend works" test_pack_files_to_prompt
else
    skip_test "pack: files-to-prompt backend works" "files-to-prompt not installed"
fi

if command -v repomix >/dev/null 2>&1; then
    test_pack_repomix() {
        (cd "$PACK_FIX" && OUTPUT_DIR="$TMP/pack-out3" "$BASH_BIN" "$SCRIPT" pack repomix --include "README.md") 2>/dev/null
    }
    run_test "pack: repomix backend works" test_pack_repomix
else
    skip_test "pack: repomix backend works" "repomix not installed"
fi

if command -v code2prompt >/dev/null 2>&1; then
    test_pack_code2prompt() {
        # code2prompt 4.x prints --help and exits 2 when given no positional
        # PATH_TO_ANALYZE at all, despite documenting a "." default; pass it
        # explicitly.
        (cd "$PACK_FIX" && OUTPUT_DIR="$TMP/pack-out-c2p" "$BASH_BIN" "$SCRIPT" pack code2prompt .) 2>/dev/null
    }
    run_test "pack: code2prompt backend works" test_pack_code2prompt
else
    skip_test "pack: code2prompt backend works" "code2prompt not installed"
fi

# ---------------------------------------------------------------------------
# pack: additional coverage (Phase 3b, lib/ai-context/pack.sh) — backend
# selection die branches (unreachable from the CLI dispatcher, tested by
# calling ai_context_pack_select_backend directly) and the TOKEN_BUDGET warn
# branch.
# ---------------------------------------------------------------------------

test_pack_select_backend_unknown_dies() {
    ! (
        cd "$TMP" &&
            source "$REPO_ROOT/lib/common.sh" &&
            source "$REPO_ROOT/lib/ai-context/pack.sh"
        ai_context_pack_select_backend bogus-backend
    ) 2>/dev/null
}
run_test "pack: unknown backend dies" test_pack_select_backend_unknown_dies

PACK_NO_PACKER_BIN="$TMP/ctx-pack-no-packer-bin"
make_bin_dir_without_packers "$PACK_NO_PACKER_BIN"

test_pack_select_backend_auto_no_packer_dies() {
    ! (
        cd "$TMP" &&
            PATH="$PACK_NO_PACKER_BIN" &&
            source "$REPO_ROOT/lib/common.sh" &&
            source "$REPO_ROOT/lib/ai-context/pack.sh"
        ai_context_pack_select_backend auto
    ) 2>/dev/null
}
run_test "pack: auto backend dies when no packer is installed" test_pack_select_backend_auto_no_packer_dies

test_pack_token_budget_warns_when_exceeded() {
    local err
    err="$(cd "$PACK_FIX" && OUTPUT_DIR="$TMP/pack-out-budget" TOKEN_BUDGET=1 "$BASH_BIN" "$SCRIPT" pack auto --include "README.md" 2>&1 >/dev/null || true)"
    grep -qi 'exceeding budget' <<<"$err"
}
# `pack auto` needs at least one real packer on PATH (repomix,
# files-to-prompt, or code2prompt — see ai_context_pack_select_backend); none
# of them are installed by this repo's own CI workflow, so without this guard
# the test fails on "no supported context packer found" instead of the
# TOKEN_BUDGET warning it's actually meant to exercise.
if command -v repomix >/dev/null 2>&1 || command -v files-to-prompt >/dev/null 2>&1 ||
    command -v code2prompt >/dev/null 2>&1; then
    run_test "pack: warns when packed output exceeds TOKEN_BUDGET" test_pack_token_budget_warns_when_exceeded
else
    skip_test "pack: warns when packed output exceeds TOKEN_BUDGET" "no context packer installed"
fi

# ===========================================================================
# file (formerly test-run-repomix-file.sh)
# ===========================================================================

test_file_help() { "$BASH_BIN" "$SCRIPT" file --help 2>&1 | grep -q 'Usage'; }
run_test "file: help flag works" test_file_help

make_fake_repomix() {
    local bin_dir="$1"
    mkdir -p "$bin_dir"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'set -euo pipefail\n'
        printf "OUTPUT=''\n"
        printf 'while (($# > 0)); do\n'
        printf '    case "$1" in\n'
        printf '    --output)\n'
        printf '        OUTPUT="$2"\n'
        printf '        shift 2\n'
        printf '        ;;\n'
        printf '    --style | --split-output | --include-logs-count)\n'
        printf '        shift 2\n'
        printf '        ;;\n'
        printf '    --stdin | --compress | --include-logs | --include-diffs)\n'
        printf '        shift\n'
        printf '        ;;\n'
        printf '    *)\n'
        printf '        shift\n'
        printf '        ;;\n'
        printf '    esac\n'
        printf 'done\n'
        printf '[[ -n "$OUTPUT" ]]\n'
        printf 'mkdir -p "$(dirname "$OUTPUT")"\n'
        printf 'cat >"$OUTPUT"\n'
    } >"$bin_dir/repomix"
    chmod +x "$bin_dir/repomix"
}

test_file_default_output_uses_relative_repo_path() {
    local tmp repo bin_dir expected output_text manifest_text

    tmp="$(mktemp -d "${TMPDIR:-/tmp}/ai-context-file-test.XXXXXX")"
    repo="$tmp/repo"
    bin_dir="$tmp/bin"
    mkdir -p "$repo/docs/ai/shared/nuxt"
    printf '{"cache":true}\n' >"$repo/docs/ai/shared/nuxt/nuxt-cache.json"
    make_fake_repomix "$bin_dir"

    PATH="$bin_dir:$PATH" "$BASH_BIN" "$SCRIPT" file "$repo" "$repo/docs/ai/shared/nuxt/nuxt-cache.json"

    expected="$repo/.repomix-context/single-file/docs__ai__shared__nuxt__nuxt-cache.json.xml"
    [[ -f "$expected" ]]
    output_text="$(tr -d '\r\n' <"$expected")"
    [[ "$output_text" == "docs/ai/shared/nuxt/nuxt-cache.json" ]]

    manifest_text="$(jq -r '.file' "$repo/.repomix-context/single-file/run-manifest.json")"
    [[ "$manifest_text" == "docs/ai/shared/nuxt/nuxt-cache.json" ]]

    rm -rf "$tmp"
}
run_test "file: packs exact file with default output" test_file_default_output_uses_relative_repo_path

test_file_custom_output_and_style() {
    local tmp repo bin_dir expected output_text

    tmp="$(mktemp -d "${TMPDIR:-/tmp}/ai-context-file-test.XXXXXX")"
    repo="$tmp/repo"
    bin_dir="$tmp/bin"
    mkdir -p "$repo/docs/ai/shared/nuxt"
    printf '{"cache":true}\n' >"$repo/docs/ai/shared/nuxt/nuxt-cache.json"
    make_fake_repomix "$bin_dir"

    PATH="$bin_dir:$PATH" "$BASH_BIN" "$SCRIPT" file "$repo" "docs/ai/shared/nuxt/nuxt-cache.json" --style json --output custom/nuxt-cache.json --no-compress

    expected="$repo/custom/nuxt-cache.json"
    [[ -f "$expected" ]]
    output_text="$(tr -d '\r\n' <"$expected")"
    [[ "$output_text" == "docs/ai/shared/nuxt/nuxt-cache.json" ]]

    rm -rf "$tmp"
}
run_test "file: supports custom output and style" test_file_custom_output_and_style

# ---------------------------------------------------------------------------
# file: additional coverage (Phase 3b, lib/ai-context/file.sh) — mechanical
# arg-validation and error paths.
# ---------------------------------------------------------------------------

test_file_missing_file_arg_errors() {
    local err
    err="$("$BASH_BIN" "$SCRIPT" file 2>&1 >/dev/null || true)"
    grep -q 'FILE argument is required' <<<"$err"
}
run_test "file: missing FILE argument errors" test_file_missing_file_arg_errors

test_file_repo_not_found_errors() {
    local err
    err="$("$BASH_BIN" "$SCRIPT" file "$TMP/does-not-exist-repo" some.txt 2>&1 >/dev/null || true)"
    grep -q 'repository root not found' <<<"$err"
}
run_test "file: nonexistent repo root errors" test_file_repo_not_found_errors

test_file_absolute_path_outside_repo_errors() {
    local repo outside err
    repo="$(mktemp -d "${TMPDIR:-/tmp}/ai-context-file-outside.XXXXXX")"
    outside="$(mktemp -d "${TMPDIR:-/tmp}/ai-context-file-elsewhere.XXXXXX")"
    printf 'x\n' >"$outside/elsewhere.txt"
    err="$("$BASH_BIN" "$SCRIPT" file "$repo" "$outside/elsewhere.txt" 2>&1 >/dev/null || true)"
    rm -rf "$repo" "$outside"
    grep -q 'not inside repository root' <<<"$err"
}
run_test "file: absolute file path outside repo root errors" test_file_absolute_path_outside_repo_errors

FILE_NO_REPOMIX_BIN="$TMP/file-no-repomix-bin"
make_bin_dir_without_packers "$FILE_NO_REPOMIX_BIN"

test_file_repomix_not_on_path_errors() {
    local repo err
    repo="$(mktemp -d "${TMPDIR:-/tmp}/ai-context-file-norepomix.XXXXXX")"
    printf 'x\n' >"$repo/f.txt"
    err="$(PATH="$FILE_NO_REPOMIX_BIN" "$BASH_BIN" "$SCRIPT" file "$repo" f.txt 2>&1 >/dev/null || true)"
    rm -rf "$repo"
    grep -q 'repomix not found on PATH' <<<"$err"
}
run_test "file: repomix missing from PATH errors" test_file_repomix_not_on_path_errors

test_file_unknown_option_errors() {
    local err
    err="$("$BASH_BIN" "$SCRIPT" file repo file.txt --bogus 2>&1 >/dev/null || true)"
    grep -q 'unknown option: --bogus' <<<"$err"
}
run_test "file: unknown option errors" test_file_unknown_option_errors

test_file_style_missing_value_errors() {
    local err
    err="$("$BASH_BIN" "$SCRIPT" file repo file.txt --style 2>&1 >/dev/null || true)"
    grep -q -- '--style requires a value' <<<"$err"
}
run_test "file: --style without a value errors" test_file_style_missing_value_errors

test_file_output_missing_value_errors() {
    local err
    err="$("$BASH_BIN" "$SCRIPT" file repo file.txt --output 2>&1 >/dev/null || true)"
    grep -q -- '--output requires a value' <<<"$err"
}
run_test "file: --output without a value errors" test_file_output_missing_value_errors

test_file_double_dash_passthrough_positionals() {
    local tmp repo bin_dir expected ok
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/ai-context-file-dashdash.XXXXXX")"
    repo="$tmp/repo"
    bin_dir="$tmp/bin"
    mkdir -p "$repo/docs"
    printf '{"a":1}\n' >"$repo/docs/data.json"
    make_fake_repomix "$bin_dir"

    PATH="$bin_dir:$PATH" "$BASH_BIN" "$SCRIPT" file -- "$repo" "docs/data.json"

    expected="$repo/.repomix-context/single-file/docs__data.json.xml"
    ok=0
    [[ -f "$expected" ]] && ok=1

    rm -rf "$tmp"
    ((ok == 1))
}
run_test "file: -- passthrough still collects positionals" test_file_double_dash_passthrough_positionals

# ===========================================================================
# diff (formerly test-ai-diff-context.sh)
# ===========================================================================

test_diff_help() { "$BASH_BIN" "$SCRIPT" diff --help 2>&1 | grep -q 'Usage'; }
run_test "diff: help flag works" test_diff_help

test_diff_no_mode() { ! "$BASH_BIN" "$SCRIPT" diff 2>/dev/null; }
run_test "diff: missing mode fails" test_diff_no_mode

test_diff_unknown() {
    ! AI_CONTEXT_DIR="$TMP/ctx6" "$BASH_BIN" "$SCRIPT" diff nonexistent 2>/dev/null
}
run_test "diff: unknown mode fails" test_diff_unknown

test_diff_since_no_ref() {
    ! AI_CONTEXT_DIR="$TMP/ctx7" "$BASH_BIN" "$SCRIPT" diff since 2>/dev/null
}
run_test "diff: since without ref fails" test_diff_since_no_ref

test_diff_since_dry_run_no_tests_finishes() {
    [[ -n "$TIMEOUT_BIN" ]] || return 2

    local out
    out="$(AI_SESSION_DURABLE_LOG=0 "$TIMEOUT_BIN" 5 "$BASH_BIN" "$SCRIPT" diff since HEAD~1 --dry-run --no-tests 2>/dev/null)"

    grep -q '"dry_run": true' <<<"$out"
}

# Needs at least two commits so HEAD~1 resolves.
if [[ -z "$TIMEOUT_BIN" ]]; then
    skip_test "diff: since dry-run no-tests finishes and prints dry-run JSON" "no timeout binary"
elif ! git rev-parse --verify -q HEAD~1 >/dev/null 2>&1; then
    skip_test "diff: since dry-run no-tests finishes and prints dry-run JSON" "repository has no HEAD~1"
else
    run_test "diff: since dry-run no-tests finishes and prints dry-run JSON" test_diff_since_dry_run_no_tests_finishes
fi

# ---------------------------------------------------------------------------
# diff: additional command coverage (Phase 3b, lib/ai-diff-context/commands.sh)
# — cmd_unstaged, cmd_recent, cmd_touched, cmd_pr (cmd_since is already
# covered above).
# ---------------------------------------------------------------------------

UNSTAGED_FIX="$TMP/diff-unstaged-fixture"
make_git_fixture "$UNSTAGED_FIX"
printf 'tracked v1\n' >"$UNSTAGED_FIX/tracked.txt"
(
    cd "$UNSTAGED_FIX" && git add -A &&
        git -c user.email=t@t -c user.name=t commit -qm 'seed tracked file'
) >/dev/null 2>&1

test_cmd_unstaged_dry_run() {
    local out
    printf 'tracked v2\n' >"$UNSTAGED_FIX/tracked.txt"
    printf 'new staged\n' >"$UNSTAGED_FIX/new-staged.txt"
    (cd "$UNSTAGED_FIX" && git add new-staged.txt) >/dev/null 2>&1
    printf 'untracked\n' >"$UNSTAGED_FIX/untracked.txt"

    out="$(cd "$UNSTAGED_FIX" && AI_SESSION_DURABLE_LOG=0 "$BASH_BIN" "$SCRIPT" diff unstaged --dry-run --no-tests 2>/dev/null)"

    grep -q '"dry_run": true' <<<"$out" &&
        grep -q '"tracked.txt"' <<<"$out" &&
        grep -q '"new-staged.txt"' <<<"$out" &&
        grep -q '"untracked.txt"' <<<"$out"
}
run_test "diff unstaged: dry-run lists staged, unstaged, and untracked files" test_cmd_unstaged_dry_run

test_cmd_unstaged_unknown_option_fails() {
    ! (cd "$UNSTAGED_FIX" && AI_SESSION_DURABLE_LOG=0 "$BASH_BIN" "$SCRIPT" diff unstaged --bogus 2>/dev/null)
}
run_test "diff unstaged: unknown option fails" test_cmd_unstaged_unknown_option_fails

RECENT_FIX="$TMP/diff-recent-fixture"
make_git_fixture "$RECENT_FIX"
(
    cd "$RECENT_FIX"
    printf 'one\n' >a.txt && git add a.txt && git -c user.email=t@t -c user.name=t commit -qm 'add a'
    printf 'two\n' >b.txt && git add b.txt && git -c user.email=t@t -c user.name=t commit -qm 'add b'
    printf 'three\n' >c.txt && git add c.txt && git -c user.email=t@t -c user.name=t commit -qm 'add c'
) >/dev/null 2>&1

test_cmd_recent_dry_run_count() {
    local out
    out="$(cd "$RECENT_FIX" && AI_SESSION_DURABLE_LOG=0 "$BASH_BIN" "$SCRIPT" diff recent --count 2 --dry-run --no-tests 2>/dev/null)"

    grep -q '"dry_run": true' <<<"$out" &&
        grep -q '"b.txt"' <<<"$out" &&
        grep -q '"c.txt"' <<<"$out"
}
run_test "diff recent: --count N selects files from last N commits" test_cmd_recent_dry_run_count

test_cmd_recent_count_equals_form() {
    local out
    out="$(cd "$RECENT_FIX" && AI_SESSION_DURABLE_LOG=0 "$BASH_BIN" "$SCRIPT" diff recent --count=1 --dry-run --no-tests 2>/dev/null)"

    grep -q '"c.txt"' <<<"$out"
}
run_test "diff recent: --count=N equals-form works" test_cmd_recent_count_equals_form

TOUCHED_FIX="$TMP/diff-touched-fixture"
make_git_fixture "$TOUCHED_FIX"
mkdir -p "$TOUCHED_FIX/src"
printf 'needle-marker content\n' >"$TOUCHED_FIX/src/match.txt"
printf 'nothing interesting\n' >"$TOUCHED_FIX/src/other.txt"
(
    cd "$TOUCHED_FIX" && git add -A &&
        git -c user.email=t@t -c user.name=t commit -qm 'seed touched fixture'
) >/dev/null 2>&1

test_cmd_touched_dry_run_matches_pattern() {
    local out
    out="$(cd "$TOUCHED_FIX" && AI_SESSION_DURABLE_LOG=0 "$BASH_BIN" "$SCRIPT" diff touched needle-marker --dry-run --no-tests 2>/dev/null)"

    grep -q '"dry_run": true' <<<"$out" &&
        grep -q '"src/match.txt"' <<<"$out" &&
        ! grep -q '"src/other.txt"' <<<"$out"
}
run_test "diff touched: dry-run finds files matching content pattern via rg" test_cmd_touched_dry_run_matches_pattern

test_cmd_touched_missing_pattern_fails() {
    ! (cd "$TOUCHED_FIX" && "$BASH_BIN" "$SCRIPT" diff touched --dry-run 2>/dev/null)
}
run_test "diff touched: missing pattern fails" test_cmd_touched_missing_pattern_fails

PR_FIX="$TMP/diff-pr-fixture"
make_git_fixture "$PR_FIX"
printf '# readme\n' >"$PR_FIX/README.md"
(
    cd "$PR_FIX" && git add -A &&
        git -c user.email=t@t -c user.name=t commit -qm 'seed pr fixture'
) >/dev/null 2>&1
PR_GH_BIN="$TMP/fake-gh-bin"
make_fake_gh "$PR_GH_BIN"

test_cmd_pr_missing_number_fails() {
    ! (cd "$PR_FIX" && "$BASH_BIN" "$SCRIPT" diff pr --dry-run 2>/dev/null)
}
run_test "diff pr: missing PR number fails" test_cmd_pr_missing_number_fails

test_cmd_pr_dry_run_uses_gh_json() {
    local out
    out="$(cd "$PR_FIX" && PATH="$PR_GH_BIN:$PATH" FAKE_GH_FILES="README.md" AI_SESSION_DURABLE_LOG=0 "$BASH_BIN" "$SCRIPT" diff pr 123 --dry-run --no-tests 2>/dev/null)"

    grep -q '"dry_run": true' <<<"$out" &&
        grep -q '"label": "pr-123"' <<<"$out" &&
        grep -q '"README.md"' <<<"$out"
}
run_test "diff pr: dry-run dispatches to gh pr view and packs its files" test_cmd_pr_dry_run_uses_gh_json

# ---------------------------------------------------------------------------
# helpers: parse_common_option / stem matching / diff artifacts / pack_files_list
# (Phase 3b, lib/ai-diff-context/helpers.sh). These source the module directly
# in a subshell so the `set -euo pipefail` pulled in via lib/common.sh never
# leaks into the rest of this test script.
# ---------------------------------------------------------------------------

HELPERS_LIB="$REPO_ROOT/lib/ai-diff-context/helpers.sh"

test_parse_common_option_include_diffs() {
    (
        cd "$TMP" &&
            source "$REPO_ROOT/lib/common.sh" &&
            source "$HELPERS_LIB"
        INCLUDE_DIFFS=0
        parse_common_option --include-diffs ""
        [[ "$INCLUDE_DIFFS" == "1" && "$COMMON_OPTION_CONSUMED" == "1" ]]
    )
}
run_test "parse_common_option: --include-diffs sets INCLUDE_DIFFS=1" test_parse_common_option_include_diffs

test_parse_common_option_no_secrets_scan() {
    (
        cd "$TMP" &&
            source "$REPO_ROOT/lib/common.sh" &&
            source "$HELPERS_LIB"
        SECRETS_SCAN=1
        parse_common_option --no-secrets-scan ""
        [[ "$SECRETS_SCAN" == "0" ]]
    )
}
run_test "parse_common_option: --no-secrets-scan sets SECRETS_SCAN=0" test_parse_common_option_no_secrets_scan

test_parse_common_option_strict() {
    (
        cd "$TMP" &&
            source "$REPO_ROOT/lib/common.sh" &&
            source "$HELPERS_LIB"
        STRICT_TOKENS=0
        parse_common_option --strict ""
        [[ "$STRICT_TOKENS" == "1" ]]
    )
}
run_test "parse_common_option: --strict sets STRICT_TOKENS=1" test_parse_common_option_strict

test_parse_common_option_token_budget_two_arg() {
    (
        cd "$TMP" &&
            source "$REPO_ROOT/lib/common.sh" &&
            source "$HELPERS_LIB"
        parse_common_option --token-budget 12345
        [[ "$TOKEN_BUDGET" == "12345" && "$COMMON_OPTION_CONSUMED" == "2" ]]
    )
}
run_test "parse_common_option: --token-budget N (two-arg form)" test_parse_common_option_token_budget_two_arg

test_parse_common_option_token_budget_equals() {
    (
        cd "$TMP" &&
            source "$REPO_ROOT/lib/common.sh" &&
            source "$HELPERS_LIB"
        parse_common_option --token-budget=6789 ""
        [[ "$TOKEN_BUDGET" == "6789" && "$COMMON_OPTION_CONSUMED" == "1" ]]
    )
}
run_test "parse_common_option: --token-budget=N (equals form)" test_parse_common_option_token_budget_equals

test_parse_common_option_split_two_arg() {
    (
        cd "$TMP" &&
            source "$REPO_ROOT/lib/common.sh" &&
            source "$HELPERS_LIB"
        parse_common_option --split 500000
        [[ "$SPLIT_OUTPUT" == "500000" && "$COMMON_OPTION_CONSUMED" == "2" ]]
    )
}
run_test "parse_common_option: --split N (two-arg form)" test_parse_common_option_split_two_arg

test_parse_common_option_split_equals() {
    (
        cd "$TMP" &&
            source "$REPO_ROOT/lib/common.sh" &&
            source "$HELPERS_LIB"
        parse_common_option --split=250000 ""
        [[ "$SPLIT_OUTPUT" == "250000" && "$COMMON_OPTION_CONSUMED" == "1" ]]
    )
}
run_test "parse_common_option: --split=N (equals form)" test_parse_common_option_split_equals

test_collect_file_stems_sorted_unique() {
    (
        cd "$TMP" &&
            source "$REPO_ROOT/lib/common.sh" &&
            source "$HELPERS_LIB"
        out="$(LC_ALL=C collect_file_stems "src/Foo.php" "src/Bar.js" "other/Foo.test.js")"
        [[ "$out" == $'Bar\nFoo\nFoo.test' ]]
    )
}
run_test "collect_file_stems: dedupes and sorts basename stems" test_collect_file_stems_sorted_unique

test_build_stem_regex_sorts_and_joins() {
    (
        cd "$TMP" &&
            source "$REPO_ROOT/lib/common.sh" &&
            source "$HELPERS_LIB"
        out="$(LC_ALL=C build_stem_regex "Foo" "Bar")"
        [[ "$out" == "Bar|Foo" ]]
    )
}
run_test "build_stem_regex: sorts stems and joins with |" test_build_stem_regex_sorts_and_joins

STEM_FIX="$TMP/helpers-stem-fixture"
make_git_fixture "$STEM_FIX"
mkdir -p "$STEM_FIX/src" "$STEM_FIX/tests"
printf '<?php class Foo {}\n' >"$STEM_FIX/src/Foo.php"
printf '<?php class FooTest {}\n' >"$STEM_FIX/tests/FooTest.php"
(
    cd "$STEM_FIX" && git add -A &&
        git -c user.email=t@t -c user.name=t commit -qm 'seed stem fixture'
) >/dev/null 2>&1

test_collect_related_tests_finds_matching_test() {
    (
        cd "$STEM_FIX" &&
            source "$REPO_ROOT/lib/common.sh" &&
            source "$HELPERS_LIB"
        INCLUDE_TESTS=1
        out="$(collect_related_tests "src/Foo.php")"
        [[ "$out" == *"tests/FooTest.php"* ]]
    )
}
# fd is an optional, feature-gated tool (README's "Optional" tier, not
# "Core"), and collect_related_tests' PHP-naming-convention branch is fd-only
# by design (it soft-degrades to a no-op with a log_warn when fd is absent,
# same as this repo's own CI workflow, which never installs fd/fd-find).
if command -v fd >/dev/null 2>&1; then
    run_test "collect_related_tests: finds PHP Test naming-convention match" test_collect_related_tests_finds_matching_test
else
    skip_test "collect_related_tests: finds PHP Test naming-convention match" "fd not installed"
fi

test_collect_related_tests_skips_when_include_tests_off() {
    (
        cd "$STEM_FIX" &&
            source "$REPO_ROOT/lib/common.sh" &&
            source "$HELPERS_LIB"
        INCLUDE_TESTS=0
        out="$(collect_related_tests "src/Foo.php")"
        [[ -z "$out" ]]
    )
}
run_test "collect_related_tests: no-op when INCLUDE_TESTS != 1" test_collect_related_tests_skips_when_include_tests_off

WDA_FIX="$TMP/helpers-write-diff-artifact-fixture"
make_git_fixture "$WDA_FIX"
printf 'v1\n' >"$WDA_FIX/f.txt"
(cd "$WDA_FIX" && git add -A && git -c user.email=t@t -c user.name=t commit -qm 'seed v1') >/dev/null 2>&1
printf 'v2\n' >"$WDA_FIX/f.txt"
(cd "$WDA_FIX" && git add -A && git -c user.email=t@t -c user.name=t commit -qm 'seed v2') >/dev/null 2>&1
printf 'v3\n' >"$WDA_FIX/f.txt"
(cd "$WDA_FIX" && git add -A && git -c user.email=t@t -c user.name=t commit -qm 'seed v3') >/dev/null 2>&1

test_write_diff_artifact_since_mode() {
    (
        cd "$WDA_FIX" &&
            source "$REPO_ROOT/lib/common.sh" &&
            source "$HELPERS_LIB"
        INCLUDE_DIFFS=1
        SESSION_DIR="$WDA_FIX/.session-since"
        out="$(write_diff_artifact since-label since HEAD~1)"
        [[ -n "$out" && -f "$WDA_FIX/$out" ]] &&
            grep -q '^-v2' "$WDA_FIX/$out" && grep -q '^+v3' "$WDA_FIX/$out"
    )
}
run_test "write_diff_artifact: since mode writes a git diff file" test_write_diff_artifact_since_mode

test_write_diff_artifact_unstaged_mode() {
    (
        cd "$WDA_FIX" &&
            printf 'v4-unstaged\n' >f.txt &&
            printf 'newfile\n' >new.txt &&
            source "$REPO_ROOT/lib/common.sh" &&
            source "$HELPERS_LIB"
        INCLUDE_DIFFS=1
        SESSION_DIR="$WDA_FIX/.session-unstaged"
        out="$(write_diff_artifact unstaged-label unstaged)"
        [[ -n "$out" && -f "$WDA_FIX/$out" ]] &&
            grep -q '# git diff' "$WDA_FIX/$out" &&
            grep -q 'UNTRACKED: new.txt' "$WDA_FIX/$out"
    )
}
run_test "write_diff_artifact: unstaged mode writes staged/unstaged/untracked sections" test_write_diff_artifact_unstaged_mode

WDA_RECENT_FIX="$TMP/helpers-wda-recent-fixture"
make_git_fixture "$WDA_RECENT_FIX"
(
    cd "$WDA_RECENT_FIX"
    printf 'one\n' >a.txt && git add a.txt && git -c user.email=t@t -c user.name=t commit -qm 'add a'
    printf 'two\n' >b.txt && git add b.txt && git -c user.email=t@t -c user.name=t commit -qm 'add b'
    printf 'three\n' >c.txt && git add c.txt && git -c user.email=t@t -c user.name=t commit -qm 'add c'
) >/dev/null 2>&1

test_write_diff_artifact_recent_mode() {
    (
        cd "$WDA_RECENT_FIX" &&
            source "$REPO_ROOT/lib/common.sh" &&
            source "$HELPERS_LIB"
        INCLUDE_DIFFS=1
        SESSION_DIR="$WDA_RECENT_FIX/.session-recent"
        out="$(write_diff_artifact recent-label recent 2)"
        [[ -n "$out" && -f "$WDA_RECENT_FIX/$out" ]] &&
            grep -q '+two' "$WDA_RECENT_FIX/$out" &&
            grep -q '+three' "$WDA_RECENT_FIX/$out"
    )
}
run_test "write_diff_artifact: recent mode diffs HEAD~N..HEAD" test_write_diff_artifact_recent_mode

WDA_TOUCHED_FIX="$TMP/helpers-wda-touched-fixture"
make_git_fixture "$WDA_TOUCHED_FIX"
printf 'v1\n' >"$WDA_TOUCHED_FIX/t.txt"
(cd "$WDA_TOUCHED_FIX" && git add -A && git -c user.email=t@t -c user.name=t commit -qm seed) >/dev/null 2>&1

test_write_diff_artifact_touched_mode() {
    (
        cd "$WDA_TOUCHED_FIX" &&
            printf 'v2\n' >t.txt &&
            source "$REPO_ROOT/lib/common.sh" &&
            source "$HELPERS_LIB"
        INCLUDE_DIFFS=1
        SESSION_DIR="$WDA_TOUCHED_FIX/.session-touched"
        out="$(write_diff_artifact touched-label touched t.txt)"
        [[ -n "$out" && -f "$WDA_TOUCHED_FIX/$out" ]] &&
            grep -q '+v2' "$WDA_TOUCHED_FIX/$out"
    )
}
run_test "write_diff_artifact: touched mode diffs only the given files" test_write_diff_artifact_touched_mode

test_write_diff_artifact_pr_mode() {
    (
        cd "$PR_FIX" &&
            PATH="$PR_GH_BIN:$PATH" &&
            source "$REPO_ROOT/lib/common.sh" &&
            source "$HELPERS_LIB"
        INCLUDE_DIFFS=1
        SESSION_DIR="$PR_FIX/.session-pr"
        out="$(write_diff_artifact pr-label pr 123)"
        [[ -n "$out" && -f "$PR_FIX/$out" ]] &&
            grep -q 'README.md' "$PR_FIX/$out"
    )
}
run_test "write_diff_artifact: pr mode calls gh pr diff" test_write_diff_artifact_pr_mode

test_write_diff_artifact_unknown_mode_dies() {
    ! (
        cd "$WDA_FIX" &&
            source "$REPO_ROOT/lib/common.sh" &&
            source "$HELPERS_LIB"
        INCLUDE_DIFFS=1
        SESSION_DIR="$WDA_FIX/.session-unknown"
        write_diff_artifact bogus-label bogus
    ) 2>/dev/null
}
run_test "write_diff_artifact: unknown mode dies" test_write_diff_artifact_unknown_mode_dies

test_write_diff_artifact_disabled_short_circuits() {
    (
        cd "$WDA_FIX" &&
            source "$REPO_ROOT/lib/common.sh" &&
            source "$HELPERS_LIB"
        INCLUDE_DIFFS=0
        SESSION_DIR="$WDA_FIX/.session-disabled"
        out="$(write_diff_artifact disabled-label since HEAD~1)"
        [[ -z "$out" ]]
    )
}
run_test "write_diff_artifact: INCLUDE_DIFFS=0 short-circuits without writing" test_write_diff_artifact_disabled_short_circuits

PACK_LIST_FIX="$TMP/helpers-pack-files-list-fixture"
make_git_fixture "$PACK_LIST_FIX"
printf '# clean readme\nhello world\n' >"$PACK_LIST_FIX/README.md"
(
    cd "$PACK_LIST_FIX" && git add -A &&
        git -c user.email=t@t -c user.name=t commit -qm 'seed clean fixture'
) >/dev/null 2>&1

test_pack_files_list_secrets_scan_passes_clean_fixture() {
    (
        cd "$PACK_LIST_FIX" &&
            source "$REPO_ROOT/lib/common.sh" &&
            source "$HELPERS_LIB"
        OUTPUT_DIR="$PACK_LIST_FIX/.repomix-context/diff"
        TOKEN_BUDGET=80000
        DRY_RUN=0
        SECRETS_SCAN=1
        STRICT_TOKENS=0
        SPLIT_OUTPUT=''
        INCLUDE_TESTS=1
        INCLUDE_DIFFS=0
        out="$(pack_files_list clean-label README.md 2>/dev/null | tail -1)"
        [[ -f "$out" && -f "${out%.xml}.manifest.json" ]]
    )
}
# pack_files_list's non-dry-run path (exercised here) requires repomix or
# files-to-prompt on PATH (see its own `elif command -v files-to-prompt`
# fallback below); neither is installed by this repo's CI workflow, so
# without this guard the test fails on "no context packer available" instead
# of ever reaching the secrets-scan behavior it's meant to cover.
if command -v repomix >/dev/null 2>&1 || command -v files-to-prompt >/dev/null 2>&1; then
    run_test "pack_files_list: secrets scan passes on a clean fixture and packs" test_pack_files_list_secrets_scan_passes_clean_fixture
else
    skip_test "pack_files_list: secrets scan passes on a clean fixture and packs" "no context packer installed"
fi

test_pack_files_list_manifest_fields() {
    (
        cd "$PACK_LIST_FIX" &&
            source "$REPO_ROOT/lib/common.sh" &&
            source "$HELPERS_LIB"
        OUTPUT_DIR="$PACK_LIST_FIX/.repomix-context/diff-manifest"
        TOKEN_BUDGET=80000
        DRY_RUN=0
        SECRETS_SCAN=0
        STRICT_TOKENS=0
        SPLIT_OUTPUT=''
        INCLUDE_TESTS=0
        INCLUDE_DIFFS=1
        out="$(pack_files_list manifest-label README.md 2>/dev/null | tail -1)"
        manifest="${out%.xml}.manifest.json"
        [[ "$(jq -r '.label' "$manifest")" == "manifest-label" ]] &&
            [[ "$(jq -r '.include_tests' "$manifest")" == "false" ]] &&
            [[ "$(jq -r '.include_diffs' "$manifest")" == "true" ]] &&
            [[ "$(jq -r '.token_budget' "$manifest")" == "80000" ]]
    )
}
# Same packer dependency as the secrets-scan test above.
if command -v repomix >/dev/null 2>&1 || command -v files-to-prompt >/dev/null 2>&1; then
    run_test "pack_files_list: manifest.json records label/token_budget/include flags" test_pack_files_list_manifest_fields
else
    skip_test "pack_files_list: manifest.json records label/token_budget/include flags" "no context packer installed"
fi

SECRET_FIX="$TMP/helpers-pack-files-list-secret-fixture"
make_git_fixture "$SECRET_FIX"
# Banner built from two halves at runtime, rather than as one literal string in
# this source file, so the fixture still trips gitleaks' real private-key rule
# without also tripping check-publishable.sh's own secret-pattern grep over
# tracked *source* files.
rsa_begin_marker='-----BEGIN'
rsa_begin_marker+=' RSA PRIVATE KEY-----'
rsa_end_marker='-----END'
rsa_end_marker+=' RSA PRIVATE KEY-----'
{
    printf 'synthetic test fixture only, not a real credential\n'
    printf '%s\n' "$rsa_begin_marker"
    printf 'MIIBOgIBAAJBAKj34GkxFhD90vcNLYLInFEr8cvCsGoBiHmYUqmb9dSj7lYyoNSb\n'
    printf '%s\n' "$rsa_end_marker"
} >"$SECRET_FIX/secret.txt"
(
    cd "$SECRET_FIX" && git add -A &&
        git -c user.email=t@t -c user.name=t commit -qm 'seed synthetic secret fixture'
) >/dev/null 2>&1

if command -v gitleaks >/dev/null 2>&1; then
    test_pack_files_list_secrets_scan_fails_on_committed_secret() {
        ! (
            cd "$SECRET_FIX" &&
                source "$REPO_ROOT/lib/common.sh" &&
                source "$HELPERS_LIB"
            OUTPUT_DIR="$SECRET_FIX/.repomix-context/diff"
            TOKEN_BUDGET=80000
            DRY_RUN=0
            SECRETS_SCAN=1
            STRICT_TOKENS=0
            SPLIT_OUTPUT=''
            INCLUDE_TESTS=0
            INCLUDE_DIFFS=0
            pack_files_list secret-label secret.txt
        ) 2>/dev/null
    }
    run_test "pack_files_list: secrets scan dies on a committed secret-looking file" test_pack_files_list_secrets_scan_fails_on_committed_secret
else
    skip_test "pack_files_list: secrets scan dies on a committed secret-looking file" "gitleaks not installed"
fi

if command -v files-to-prompt >/dev/null 2>&1; then
    FTP_BIN_DIR="$TMP/pack-files-to-prompt-only-bin"
    make_bin_dir_without_packers "$FTP_BIN_DIR"
    ln -sf "$(command -v files-to-prompt)" "$FTP_BIN_DIR/files-to-prompt"

    test_pack_files_list_falls_back_to_files_to_prompt() {
        (
            cd "$PACK_LIST_FIX" &&
                PATH="$FTP_BIN_DIR" &&
                source "$REPO_ROOT/lib/common.sh" &&
                source "$HELPERS_LIB"
            OUTPUT_DIR="$PACK_LIST_FIX/.repomix-context/diff-ftp"
            TOKEN_BUDGET=80000
            DRY_RUN=0
            SECRETS_SCAN=0
            STRICT_TOKENS=0
            SPLIT_OUTPUT=''
            INCLUDE_TESTS=0
            INCLUDE_DIFFS=0
            out="$(pack_files_list ftp-label README.md 2>/dev/null | tail -1)"
            [[ -s "$out" ]]
        )
    }
    run_test "pack_files_list: falls back to files-to-prompt when repomix is absent" test_pack_files_list_falls_back_to_files_to_prompt
else
    skip_test "pack_files_list: falls back to files-to-prompt when repomix is absent" "files-to-prompt not installed"
fi

NO_PACKER_BIN_DIR="$TMP/pack-no-packer-bin"
make_bin_dir_without_packers "$NO_PACKER_BIN_DIR"

test_pack_files_list_no_packer_dies() {
    ! (
        cd "$PACK_LIST_FIX" &&
            PATH="$NO_PACKER_BIN_DIR" &&
            source "$REPO_ROOT/lib/common.sh" &&
            source "$HELPERS_LIB"
        OUTPUT_DIR="$PACK_LIST_FIX/.repomix-context/diff-nopacker"
        TOKEN_BUDGET=80000
        DRY_RUN=0
        SECRETS_SCAN=0
        STRICT_TOKENS=0
        SPLIT_OUTPUT=''
        INCLUDE_TESTS=0
        INCLUDE_DIFFS=0
        pack_files_list nopacker-label README.md
    ) 2>/dev/null
}
run_test "pack_files_list: dies when no context packer is available" test_pack_files_list_no_packer_dies

if command -v repomix >/dev/null 2>&1; then
    test_pack_files_list_strict_tokens_dies_when_over_budget() {
        ! (
            cd "$PACK_LIST_FIX" &&
                source "$REPO_ROOT/lib/common.sh" &&
                source "$HELPERS_LIB"
            OUTPUT_DIR="$PACK_LIST_FIX/.repomix-context/diff-strict"
            TOKEN_BUDGET=1
            DRY_RUN=0
            SECRETS_SCAN=0
            STRICT_TOKENS=1
            SPLIT_OUTPUT=''
            INCLUDE_TESTS=0
            INCLUDE_DIFFS=0
            pack_files_list strict-label README.md >/dev/null
        ) 2>/dev/null
    }
    run_test "pack_files_list: --strict dies when output exceeds token budget" test_pack_files_list_strict_tokens_dies_when_over_budget

    test_pack_files_list_warns_when_over_budget_not_strict() {
        (
            cd "$PACK_LIST_FIX" &&
                source "$REPO_ROOT/lib/common.sh" &&
                source "$HELPERS_LIB"
            OUTPUT_DIR="$PACK_LIST_FIX/.repomix-context/diff-warn"
            TOKEN_BUDGET=1
            DRY_RUN=0
            SECRETS_SCAN=0
            STRICT_TOKENS=0
            SPLIT_OUTPUT=''
            INCLUDE_TESTS=0
            INCLUDE_DIFFS=0
            out="$(pack_files_list warn-label README.md 2>"$TMP/warn-stderr.log" | tail -1)"
            [[ -f "$out" ]] && grep -q 'exceeding budget' "$TMP/warn-stderr.log"
        )
    }
    run_test "pack_files_list: warns (not dies) when over budget without --strict" test_pack_files_list_warns_when_over_budget_not_strict
else
    skip_test "pack_files_list: --strict dies when output exceeds token budget" "repomix not installed"
    skip_test "pack_files_list: warns (not dies) when over budget without --strict" "repomix not installed"
fi

# ===========================================================================
# estimate (formerly test-query-usage.sh)
# ===========================================================================

test_estimate_help() { "$BASH_BIN" "$SCRIPT" estimate --help 2>&1 | grep -q 'Usage'; }
run_test "estimate: help flag works" test_estimate_help

test_estimate_file_usage() {
    echo "hello world" >"$TMP/test.txt"
    local out
    out="$("$BASH_BIN" "$SCRIPT" estimate "$TMP/test.txt")"
    [[ "$out" == *"query_usage:"* ]]
    [[ "$out" == *"bytes:"* ]]
    [[ "$out" == *"raw_estimated_tokens:"* ]]
}
run_test "estimate: file usage prints YAML output" test_estimate_file_usage

test_estimate_file_tokens() {
    printf 'A%.0s' {1..400} >"$TMP/exact.txt"
    local out
    out="$("$BASH_BIN" "$SCRIPT" estimate "$TMP/exact.txt")"
    echo "$out" | grep -q "raw_estimated_tokens: 100"
}
run_test "estimate: 400 bytes → 100 tokens" test_estimate_file_tokens

test_estimate_dir_usage() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" estimate "$REPO_ROOT/libexec" 2>/dev/null || true)"
    [[ "$out" == *"query_usage:"* ]]
}
run_test "estimate: directory usage works" test_estimate_dir_usage

test_estimate_multiplier() {
    printf 'A%.0s' {1..100} >"$TMP/mult.txt"
    local out
    out="$("$BASH_BIN" "$SCRIPT" estimate "$TMP/mult.txt" --multiplier 2 --multiplier-label 2x)"
    echo "$out" | grep -q "multiplier: 2"
    echo "$out" | grep -q "multiplier_label: 2x"
    echo "$out" | grep -q "weighted_usage: 50.00"
}
run_test "estimate: multiplier affects weighted_usage" test_estimate_multiplier

test_estimate_reserved_output() {
    echo "x" >"$TMP/res.txt"
    local out
    out="$("$BASH_BIN" "$SCRIPT" estimate "$TMP/res.txt" --reserved-output 8000)"
    echo "$out" | grep -q "reserved_output_tokens: 8000"
}
run_test "estimate: reserved-output option works" test_estimate_reserved_output

test_estimate_missing_path() {
    ! "$BASH_BIN" "$SCRIPT" estimate "$TMP/nonexistent" 2>/dev/null
}
run_test "estimate: missing path exits with error" test_estimate_missing_path

test_estimate_unknown_option() {
    ! "$BASH_BIN" "$SCRIPT" estimate "$TMP" --bogus 2>/dev/null
}
run_test "estimate: unknown option fails" test_estimate_unknown_option

# Regression: a directory that is NOT inside a git repo must still produce a
# byte/token estimate instead of silently crashing (git ls-files exits 128
# outside a repo; pipefail + set -e used to abort before any output).
test_estimate_non_git_dir() {
    local non_git_dir out rc=0
    non_git_dir="$(mktemp -d "${TMPDIR:-/tmp}/ai-context-nongit.XXXXXX")"
    printf 'hello\n' >"$non_git_dir/f.txt"
    out="$("$BASH_BIN" "$SCRIPT" estimate "$non_git_dir")" || rc=$?
    rm -rf "$non_git_dir"
    ((rc == 0)) && [[ "$out" == *"query_usage:"* && "$out" == *"bytes:"* ]]
}
run_test "estimate: non-git directory still produces an estimate" test_estimate_non_git_dir

# Regression: an empty directory INSIDE a git repo must report bytes:0 via the
# rg --files fallback (rg exits 1 on no files; pipefail + set -e used to abort).
test_estimate_empty_dir_in_git_repo() {
    local empty_dir out rc=0
    empty_dir="$REPO_ROOT/.tmp-probe-empty-$$"
    mkdir -p "$empty_dir"
    out="$("$BASH_BIN" "$SCRIPT" estimate "$empty_dir")" || rc=$?
    rmdir "$empty_dir" 2>/dev/null || rm -rf "$empty_dir"
    ((rc == 0)) && [[ "$out" == *"bytes: 0"* ]]
}
run_test "estimate: empty dir inside git repo reports bytes:0" test_estimate_empty_dir_in_git_repo

# estimate: AI_OUTPUT=json emits a parseable ai.context-estimate/v1 envelope
# (opt-in; default text output is covered by the query_usage tests above).
test_estimate_json_envelope() {
    local tmp out
    tmp="$(mktemp -d)"
    printf 'abcd%.0s' {1..100} >"$tmp/j.txt" # 400 bytes -> 100 tokens
    out="$(AI_OUTPUT=json "$BASH_BIN" "$SCRIPT" estimate "$tmp/j.txt")"
    rm -rf "$tmp"
    printf '%s' "$out" | jq -e '.schema == "ai.context-estimate/v1" and .status == "ok" and .raw_estimated_tokens == 100 and .bytes == 400' >/dev/null
}
run_test "estimate: AI_OUTPUT=json emits ai.context-estimate/v1 envelope" test_estimate_json_envelope

# estimate: JSON error path for a missing PATH still yields a valid envelope
# with status:"error" and exit 1.
test_estimate_json_missing_path() {
    local out rc=0
    out="$(AI_OUTPUT=json "$BASH_BIN" "$SCRIPT" estimate "$TMP/definitely-missing-$$" 2>&1)" || rc=$?
    ((rc == 1)) && printf '%s' "$out" | jq -e '.schema == "ai.context-estimate/v1" and .status == "error"' >/dev/null
}
run_test "estimate: AI_OUTPUT=json missing path emits error envelope, exit 1" test_estimate_json_missing_path

# tree: a mistyped subcommand is rejected with a targeted message + exit 2
# before the engine's secrets scan runs (no misleading 'secrets detected').
test_tree_unknown_subcommand() {
    local out rc=0
    out="$("$BASH_BIN" "$SCRIPT" tree badsubcommand 2>&1)" || rc=$?
    ((rc == 2)) &&
        grep -q 'unknown tree subcommand: badsubcommand' <<<"$out" &&
        ! grep -qi 'secrets detected' <<<"$out"
}
run_test "tree: unknown subcommand rejected with exit 2 (no secrets message)" test_tree_unknown_subcommand

# diff: a bare `context diff` with no subcommand emits an explicit stderr
# diagnostic (in addition to the usage block) and exits 1.
test_diff_missing_subcommand() {
    local err rc=0
    err="$("$BASH_BIN" "$SCRIPT" diff 2>&1 1>/dev/null)" || rc=$?
    ((rc == 1)) && grep -q 'a diff subcommand is required' <<<"$err"
}
run_test "diff: missing subcommand emits stderr diagnostic, exit 1" test_diff_missing_subcommand

# ===========================================================================
# status / ensure (formerly test-repomix-freshness.sh, which also covered
# repomix-ensure-fresh)
# ===========================================================================

test_status_help() { "$BASH_BIN" "$SCRIPT" status --help 2>&1 | grep -q 'Usage'; }
run_test "status: help flag works" test_status_help

test_ensure_help() { "$BASH_BIN" "$SCRIPT" ensure --help 2>&1 | grep -q 'Usage'; }
run_test "ensure: help flag works" test_ensure_help

# Run against an empty temp dir (no manifest). Exit code may be non-zero
# (missing manifest) but the script must terminate and emit something.
FRESH_TMP="$(mktemp -d)"

test_status_runs() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" status "$FRESH_TMP" 2>&1 || true)"
    [[ -n "$out" ]]
}
run_test "status: reports on missing manifest" test_status_runs

test_status_json() {
    local out
    out="$(AI_OUTPUT=json "$BASH_BIN" "$SCRIPT" status "$FRESH_TMP" 2>/dev/null || true)"
    printf '%s' "$out" | jq -e '.tool == "repomix-freshness"' >/dev/null
}
run_test "status: JSON envelope is valid" test_status_json

# ensure in --no-regen mode must never regenerate (read-only) and must
# terminate even when context is missing.
test_ensure_no_regen() {
    "$BASH_BIN" "$SCRIPT" ensure "$FRESH_TMP" --no-regen >/dev/null 2>&1 || true
    return 0
}
run_test "ensure: --no-regen terminates without regen" test_ensure_no_regen

# ---------------------------------------------------------------------------
# status: additional coverage (Phase 3b, lib/ai-context/status.sh) — fresh,
# stale, expired, unparseable ts, and missing ts field states.
# ---------------------------------------------------------------------------

make_status_manifest() {
    local root="$1" ts="$2"
    mkdir -p "$root/.repomix-context/tree-context"
    if [[ -n "$ts" ]]; then
        jq -n --arg ts "$ts" '{ts:$ts}' >"$root/.repomix-context/tree-context/run-manifest.json"
    else
        printf '{}\n' >"$root/.repomix-context/tree-context/run-manifest.json"
    fi
}

STATUS_FRESH_ROOT="$TMP/status-fresh"
mkdir -p "$STATUS_FRESH_ROOT"
make_status_manifest "$STATUS_FRESH_ROOT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

test_status_fresh_state() {
    local out rc=0
    out="$(AI_OUTPUT=json REPOMIX_WARN_DAYS=1 REPOMIX_MAX_DAYS=3 "$BASH_BIN" "$SCRIPT" status "$STATUS_FRESH_ROOT" 2>/dev/null)" || rc=$?
    ((rc == 0)) && printf '%s' "$out" | jq -e '.status == "fresh"' >/dev/null
}
run_test "status: fresh manifest (age < warn) reports fresh, exit 0" test_status_fresh_state

STATUS_STALE_ROOT="$TMP/status-stale"
mkdir -p "$STATUS_STALE_ROOT"
make_status_manifest "$STATUS_STALE_ROOT" "$(date -u -d '2 days ago' +%Y-%m-%dT%H:%M:%SZ)"

test_status_stale_state() {
    local out rc=0
    out="$(AI_OUTPUT=json REPOMIX_WARN_DAYS=1 REPOMIX_MAX_DAYS=3 "$BASH_BIN" "$SCRIPT" status "$STATUS_STALE_ROOT" 2>/dev/null)" || rc=$?
    ((rc == 0)) && printf '%s' "$out" | jq -e '.status == "stale"' >/dev/null
}
run_test "status: stale manifest (warn <= age < max) reports stale, exit 0" test_status_stale_state

STATUS_EXPIRED_ROOT="$TMP/status-expired"
mkdir -p "$STATUS_EXPIRED_ROOT"
make_status_manifest "$STATUS_EXPIRED_ROOT" "$(date -u -d '5 days ago' +%Y-%m-%dT%H:%M:%SZ)"

test_status_expired_state() {
    local out rc=0
    out="$(AI_OUTPUT=json REPOMIX_WARN_DAYS=1 REPOMIX_MAX_DAYS=3 "$BASH_BIN" "$SCRIPT" status "$STATUS_EXPIRED_ROOT" 2>/dev/null)" || rc=$?
    ((rc == 3)) && printf '%s' "$out" | jq -e '.status == "expired"' >/dev/null
}
run_test "status: expired manifest (age > max) reports expired, exit 3" test_status_expired_state

STATUS_UNPARSEABLE_ROOT="$TMP/status-unparseable"
mkdir -p "$STATUS_UNPARSEABLE_ROOT"
make_status_manifest "$STATUS_UNPARSEABLE_ROOT" "not-a-real-timestamp"

test_status_unparseable_ts() {
    local out rc=0
    out="$(AI_OUTPUT=json "$BASH_BIN" "$SCRIPT" status "$STATUS_UNPARSEABLE_ROOT" 2>/dev/null)" || rc=$?
    ((rc == 4)) && printf '%s' "$out" | jq -e '.status == "missing"' >/dev/null
}
run_test "status: unparseable ts field is treated as missing, exit 4" test_status_unparseable_ts

STATUS_NO_TS_ROOT="$TMP/status-no-ts"
mkdir -p "$STATUS_NO_TS_ROOT"
make_status_manifest "$STATUS_NO_TS_ROOT" ""

test_status_missing_ts_field() {
    local out rc=0
    out="$(AI_OUTPUT=json "$BASH_BIN" "$SCRIPT" status "$STATUS_NO_TS_ROOT" 2>/dev/null)" || rc=$?
    ((rc == 4)) && printf '%s' "$out" | jq -e '.status == "missing"' >/dev/null
}
run_test "status: manifest with no ts field is treated as missing, exit 4" test_status_missing_ts_field

# Regression: a nonexistent root must emit a clean missing message and the
# documented exit 4, not leak a raw bash `cd: ... No such file` trace / exit 1.
test_status_nonexistent_root() {
    local out rc=0
    out="$("$BASH_BIN" "$SCRIPT" status "$TMP/definitely/not/here" 2>&1)" || rc=$?
    ((rc == 4)) &&
        grep -q '^missing:' <<<"$out" &&
        ! grep -qi 'No such file or directory' <<<"$out"
}
run_test "status: nonexistent root emits clean missing message, exit 4" test_status_nonexistent_root

# ---------------------------------------------------------------------------
# ensure: additional coverage (Phase 3b, lib/ai-context/ensure.sh) — fresh
# short-circuit, stale+--regen (stubbed generator), unmapped-status fallback.
# ---------------------------------------------------------------------------

ENSURE_LIB="$REPO_ROOT/lib/ai-context/ensure.sh"
STATUS_LIB="$REPO_ROOT/lib/ai-context/status.sh"

test_ensure_fresh_short_circuits_without_regen() {
    local out rc=0
    out="$(cd "$TMP" && AI_OUTPUT=text REPOMIX_WARN_DAYS=1 REPOMIX_MAX_DAYS=3 "$BASH_BIN" "$SCRIPT" ensure "$STATUS_FRESH_ROOT" --regen 2>&1)" || rc=$?
    ((rc == 0)) && [[ "$out" != *"Regenerating"* ]]
}
run_test "ensure: fresh state short-circuits (exit 0, no regen attempted)" test_ensure_fresh_short_circuits_without_regen

test_ensure_stale_regen_accepted_calls_generate() {
    (
        cd "$TMP" &&
            source "$REPO_ROOT/lib/common.sh" &&
            source "$STATUS_LIB" &&
            source "$ENSURE_LIB"
        ai_context_generate_main() {
            printf 'FAKE_GENERATE_CALLED\n'
            return 0
        }
        REPOMIX_WARN_DAYS=1
        REPOMIX_MAX_DAYS=3
        out="$(ai_context_ensure_main "$STATUS_STALE_ROOT" --regen)"
        [[ "$out" == *"FAKE_GENERATE_CALLED"* && "$out" == *"OK: Repomix context regenerated"* ]]
    )
}
run_test "ensure: stale + --regen calls the (stubbed) generator" test_ensure_stale_regen_accepted_calls_generate

test_ensure_unknown_state_fallback() {
    (
        cd "$TMP" &&
            source "$REPO_ROOT/lib/common.sh" &&
            source "$ENSURE_LIB"
        ai_context_status_main() {
            printf 'unmapped status\n'
            return 99
        }
        rc=0
        out="$(ai_context_ensure_main "$TMP" 2>&1)" || rc=$?
        [[ "$rc" == "1" && "$out" == *"recommend:"* ]]
    )
}
run_test "ensure: unmapped status exit code falls back to unknown-state branch" test_ensure_unknown_state_fallback

rm -rf "$FRESH_TMP"

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d  Skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
((FAIL == 0)) && printf '\033[0;32mPASSED\033[0m\n' || {
    printf '\033[0;31mFAILED\033[0m\n'
    exit 1
}
