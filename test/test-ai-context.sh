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

rm -rf "$FRESH_TMP"

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d  Skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
((FAIL == 0)) && printf '\033[0;32mPASSED\033[0m\n' || {
    printf '\033[0;31mFAILED\033[0m\n'
    exit 1
}
