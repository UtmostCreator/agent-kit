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

# Bigger fixture: the tiny FIX above (2 small files) never reaches MIN_CODE=25,
# so it only ever exercises the analyze fallback-route path (see
# TODO/coverage-todo.md Phase 3). Build several folders with real code lines,
# tracked across two commits so --changed-since has something to diff, to
# reach build_plan's real threshold branches and run_pack/run_all/run_clean/
# run_purge/generate_child_index, which never run today.
BIGFIX="$TMP/bigfix"
gen_code_file() {
    local path="$1" n="$2" i
    mkdir -p "$(dirname "$path")"
    {
        printf '#!/usr/bin/env bash\n'
        for ((i = 0; i < n; i++)); do
            printf 'echo "line %d in %s"\n' "$i" "$(basename "$path")"
        done
    } >"$path"
}
mkdir -p "$BIGFIX/src/moduleA" "$BIGFIX/src/moduleC" "$BIGFIX/src/moduleB"
for i in 1 2 3 4 5; do gen_code_file "$BIGFIX/src/moduleA/file$i.sh" 40; done
gen_code_file "$BIGFIX/src/moduleC/only.sh" 40
for i in 1 2; do gen_code_file "$BIGFIX/src/moduleB/file$i.sh" 5; done
printf '# root\n' >"$BIGFIX/README.md"
( cd "$BIGFIX" && git init -q && git add -A \
    && git -c user.email=t@t -c user.name=t commit -qm init ) >/dev/null 2>&1 || true
BIGFIX_FIRST_COMMIT="$(cd "$BIGFIX" && git rev-list --max-parents=0 HEAD 2>/dev/null)"
printf 'echo "extra"\n' >>"$BIGFIX/src/moduleA/file1.sh"
( cd "$BIGFIX" && git add -A \
    && git -c user.email=t@t -c user.name=t commit -qm update ) >/dev/null 2>&1 || true

if command -v scc >/dev/null 2>&1; then
    test_build_plan_real_pack_route() {
        "$BASH_BIN" "$SCRIPT" analyze "$BIGFIX" --output-dir "$TMP/bp-default" 2>/dev/null
        awk -F'\t' '$1 == "src/moduleA" && $3 == "pack"' "$TMP/bp-default/tree-context/tree-plan.tsv" | grep -q .
    }
    run_test "analyze selects a real pack route once code/files/complexity/score thresholds are met" test_build_plan_real_pack_route

    test_build_plan_top_limit() {
        "$BASH_BIN" "$SCRIPT" analyze "$BIGFIX" --output-dir "$TMP/bp-top" --top 1 2>/dev/null
        grep -q 'exceeds top limit' "$TMP/bp-top/tree-context/tree-plan.tsv"
    }
    run_test "analyze --top limits selected routes and marks the rest skip" test_build_plan_top_limit

    test_build_plan_min_files() {
        "$BASH_BIN" "$SCRIPT" analyze "$BIGFIX" --output-dir "$TMP/bp-minfiles" --min-files 2 2>/dev/null
        grep -q 'below min-files threshold' "$TMP/bp-minfiles/tree-context/tree-plan.tsv"
    }
    run_test "analyze --min-files skips a route with too few files" test_build_plan_min_files

    test_build_plan_min_complexity() {
        "$BASH_BIN" "$SCRIPT" analyze "$BIGFIX" --output-dir "$TMP/bp-mincomplex" --min-complexity 1000 2>/dev/null
        grep -q 'below min-complexity threshold' "$TMP/bp-mincomplex/tree-context/tree-plan.tsv"
    }
    run_test "analyze --min-complexity skips a route below the complexity floor" test_build_plan_min_complexity

    test_build_plan_min_score() {
        "$BASH_BIN" "$SCRIPT" analyze "$BIGFIX" --output-dir "$TMP/bp-minscore" --min-score 1000 2>/dev/null
        grep -q 'below min-score threshold' "$TMP/bp-minscore/tree-context/tree-plan.tsv"
    }
    run_test "analyze --min-score skips a route below the score floor" test_build_plan_min_score

    test_generate_child_index() {
        "$BASH_BIN" "$SCRIPT" analyze "$BIGFIX" --output-dir "$TMP/bp-split" --safety-factor 0 2>/dev/null
        [[ -f "$TMP/bp-split/tree-context/indexes/src__moduleA.md" ]] \
            && grep -q 'Child Context Index' "$TMP/bp-split/tree-context/indexes/src__moduleA.md"
    }
    run_test "generate_child_index writes a child index when a route splits (--safety-factor 0)" test_generate_child_index

    test_changed_since_flag() {
        "$BASH_BIN" "$SCRIPT" analyze "$BIGFIX" --output-dir "$TMP/bp-changed" --changed-since "$BIGFIX_FIRST_COMMIT" 2>/dev/null
        [[ -s "$TMP/bp-changed/tree-context/tree-plan.tsv" ]]
    }
    run_test "--changed-since scopes stats to files changed since a ref" test_changed_since_flag

    test_equals_form_flags() {
        "$BASH_BIN" "$SCRIPT" analyze "$BIGFIX" --output-dir="$TMP/bp-eqform" --depth=1 --min-code=5 --style=json 2>/dev/null
        [[ -f "$TMP/bp-eqform/tree-context/tree-plan.tsv" ]]
    }
    run_test "= form common options (--output-dir=, --depth=, --min-code=, --style=) parse" test_equals_form_flags

    test_include_ignored_flags_parse() {
        "$BASH_BIN" "$SCRIPT" analyze "$BIGFIX" --output-dir "$TMP/bp-inc1" --include-ignored 2>/dev/null \
            && "$BASH_BIN" "$SCRIPT" analyze "$BIGFIX" --output-dir "$TMP/bp-inc2" --no-ignore 2>/dev/null
    }
    run_test "--include-ignored and --no-ignore top-level flags parse" test_include_ignored_flags_parse
else
    skip_test "analyze selects a real pack route once code/files/complexity/score thresholds are met" "scc not installed"
    skip_test "analyze --top limits selected routes and marks the rest skip" "scc not installed"
    skip_test "analyze --min-files skips a route with too few files" "scc not installed"
    skip_test "analyze --min-complexity skips a route below the complexity floor" "scc not installed"
    skip_test "analyze --min-score skips a route below the score floor" "scc not installed"
    skip_test "generate_child_index writes a child index when a route splits (--safety-factor 0)" "scc not installed"
    skip_test "--changed-since scopes stats to files changed since a ref" "scc not installed"
    skip_test "= form common options (--output-dir=, --depth=, --min-code=, --style=) parse" "scc not installed"
    skip_test "--include-ignored and --no-ignore top-level flags parse" "scc not installed"
fi

# purge on a missing tree-context directory is a plain no-op (no scc/repomix needed).
test_purge_missing_dir_is_noop() {
    "$BASH_BIN" "$SCRIPT" purge "$BIGFIX" --output-dir "$TMP/bp-nopurge" 2>&1 | grep -qi 'no tree-context directory'
}
run_test "purge on a missing tree-context directory logs and returns" test_purge_missing_dir_is_noop

if command -v scc >/dev/null 2>&1 && command -v repomix >/dev/null 2>&1; then
    test_pack_command_produces_bundles() {
        "$BASH_BIN" "$SCRIPT" pack "$BIGFIX" --output-dir "$TMP/bp-pack" >/dev/null 2>&1
        find "$TMP/bp-pack/tree-context/bundles" -type f 2>/dev/null | grep -q .
    }
    run_test "pack command packs qualifying routes into bundles" test_pack_command_produces_bundles

    test_all_command_runs_analyze_then_pack() {
        "$BASH_BIN" "$SCRIPT" all "$BIGFIX" --output-dir "$TMP/bp-all" >/dev/null 2>&1
        [[ -f "$TMP/bp-all/tree-context/tree-plan.tsv" ]] \
            && find "$TMP/bp-all/tree-context/bundles" -type f 2>/dev/null | grep -q .
    }
    run_test "all command runs analyze then pack" test_all_command_runs_analyze_then_pack

    test_clean_requires_approval() {
        "$BASH_BIN" "$SCRIPT" all "$BIGFIX" --output-dir "$TMP/bp-cleanguard" >/dev/null 2>&1
        ! CI=true "$BASH_BIN" "$SCRIPT" clean "$BIGFIX" --output-dir "$TMP/bp-cleanguard" </dev/null >/dev/null 2>&1
    }
    run_test "clean without approval fails outside a tty" test_clean_requires_approval

    test_clean_removes_bundles_keeps_plan() {
        "$BASH_BIN" "$SCRIPT" all "$BIGFIX" --output-dir "$TMP/bp-clean" >/dev/null 2>&1
        APPROVE_CONTEXT_DELETE=1 "$BASH_BIN" "$SCRIPT" clean "$BIGFIX" --output-dir "$TMP/bp-clean" >/dev/null 2>&1
        [[ ! -d "$TMP/bp-clean/tree-context/bundles" ]] && [[ -f "$TMP/bp-clean/tree-context/tree-plan.tsv" ]]
    }
    run_test "clean with approval removes bundles but keeps the plan" test_clean_removes_bundles_keeps_plan

    test_purge_removes_tree_context() {
        "$BASH_BIN" "$SCRIPT" analyze "$BIGFIX" --output-dir "$TMP/bp-purge" >/dev/null 2>&1
        APPROVE_CONTEXT_DELETE=1 "$BASH_BIN" "$SCRIPT" purge "$BIGFIX" --output-dir "$TMP/bp-purge" >/dev/null 2>&1
        [[ ! -d "$TMP/bp-purge/tree-context" ]]
    }
    run_test "purge with approval removes the entire tree-context directory" test_purge_removes_tree_context

    test_split_size_flag() {
        "$BASH_BIN" "$SCRIPT" pack "$BIGFIX" --output-dir "$TMP/bp-split-size" --split-size 10mb >/dev/null 2>&1
        find "$TMP/bp-split-size/tree-context/bundles" -maxdepth 1 -type f -name '*.1.xml' 2>/dev/null | grep -q .
    }
    run_test "--split-size splits pack output into numbered chunks" test_split_size_flag

    test_combined_flags_pack() {
        "$BASH_BIN" "$SCRIPT" pack "$BIGFIX" --output-dir "$TMP/bp-flags" \
            --depth 1 --churn-count 5 --style markdown --compress \
            --include-logs --include-logs-count 3 --include-diffs >/dev/null 2>&1
        find "$TMP/bp-flags/tree-context/bundles" -type f 2>/dev/null | grep -q .
    }
    run_test "combined depth/churn-count/style/compress/include-logs/include-diffs flags pack successfully" test_combined_flags_pack
else
    skip_test "pack command packs qualifying routes into bundles" "scc or repomix not installed"
    skip_test "all command runs analyze then pack" "scc or repomix not installed"
    skip_test "clean without approval fails outside a tty" "scc or repomix not installed"
    skip_test "clean with approval removes bundles but keeps the plan" "scc or repomix not installed"
    skip_test "purge with approval removes the entire tree-context directory" "scc or repomix not installed"
    skip_test "--split-size splits pack output into numbered chunks" "scc or repomix not installed"
    skip_test "combined depth/churn-count/style/compress/include-logs/include-diffs flags pack successfully" "scc or repomix not installed"
fi

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d  Skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
((FAIL == 0)) && printf '\033[0;32mPASSED\033[0m\n' || { printf '\033[0;31mFAILED\033[0m\n'; exit 1; }
