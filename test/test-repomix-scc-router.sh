#!/usr/bin/env bash
# Tests for libexec/internal/repomix-scc-router
set -euo pipefail
BASH_BIN="${BASH_BIN:-$(command -v bash)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/libexec/internal/repomix-scc-router"
# The scope/ignore/collection helpers live in a load-ordered module (the root
# script is a thin loader); the sed-extraction tests below read function bodies
# from this module rather than the root file.
HELPERS="$REPO_ROOT/lib/repomix-scc-router/helpers.sh"
cd "$REPO_ROOT"

PASS=0 FAIL=0 SKIP=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A clean fixture repo to pack. Do NOT run the packer against this toolkit's own
# tree: lib/secrets.sh contains secret-pattern definitions that (correctly) trip
# the packer's secret guard, which would make these functional tests fail.
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

printf 'repomix-scc-router\n'

# Missing command fails
test_no_command() { ! "$BASH_BIN" "$SCRIPT" 2>/dev/null; }
run_test "missing command fails" test_no_command

# --help
test_help() { "$BASH_BIN" "$SCRIPT" --help 2>&1 | grep -qi 'usage'; }
run_test "help flag works" test_help

# stats command requires scc
if command -v scc >/dev/null 2>&1; then
    test_stats() {
        "$BASH_BIN" "$SCRIPT" stats "$FIX" --output-dir "$TMP/scc-out" 2>/dev/null
        [[ -d "$TMP/scc-out" ]]
    }
    run_test "stats command produces output" test_stats
else
    skip_test "stats command produces output" "scc not installed"
fi

# clean/purge require confirmation — skip interactive tests
# Just verify they parse args correctly
test_unknown_cmd() {
    ! "$BASH_BIN" "$SCRIPT" nonexistent 2>/dev/null
}
run_test "unknown command fails" test_unknown_cmd

# path_is_ignored matcher: trailing-slash dir patterns must match nested files
# (P0) and known glob forms must keep working. Source only the matcher into a
# clean subshell so we exercise the real function logic.
matcher_check() {
    "$BASH_BIN" -c '
        shopt -s extglob
        ((BASH_VERSINFO[0] >= 4)) && shopt -s globstar
        source <(sed -n "/^path_is_ignored() {/,/^}/p" "$1")
        check() { IGNORE_PATTERNS=("$2"); path_is_ignored "$3"; }
        check x ".ai-backups/" ".ai-backups/install-x/files/y.md" || exit 1
        check x ".ai-logs/" ".ai-logs/run.jsonl" || exit 1
        check x "vendor/" "vendor/pkg/file.php" || exit 1
        check x "node_modules/" "node_modules/pkg/index.js" || exit 1
        check x "generated/**" "generated/cache.json" || exit 1
        # a non-matching path must NOT be ignored
        if check x "src/" "other/app.js"; then exit 1; fi
    ' _ "$HELPERS"
}
run_test "path_is_ignored matches nested files under trailing-slash dirs" matcher_check

# --include-ignored: collect_files must skip a .gitignore'd file by default and
# include it when INCLUDE_IGNORED=1. Source only collect_files + path_is_ignored
# into a clean subshell and run them against a throwaway git repo.
collect_ignored_check() {
    local want="$1" # "default" (exclude) or "ignored" (include)
    local repo
    repo="$(mktemp -d)"
    (
        cd "$repo"
        git init -q
        printf 'storage/\n' >.gitignore
        printf 'tracked\n' >tracked.txt
        mkdir -p storage/tmp
        printf '{"a":1}\n' >storage/tmp/data.json
    )

    # shellcheck disable=SC2016
    "$BASH_BIN" -c '
        set -euo pipefail
        shopt -s extglob
        ((BASH_VERSINFO[0] >= 4)) && shopt -s globstar
        source <(sed -n "/^path_is_ignored() {/,/^}/p;/^collect_files() {/,/^}/p" "$1")
        ROOT="$2"
        IGNORE_PATTERNS=(".git")
        INCLUDE_IGNORED="$3"
        collect_files
        printf "%s\n" "${COLLECTED_FILES[@]}"
    ' _ "$HELPERS" "$repo" "$([[ "$want" == "ignored" ]] && echo 1 || echo 0)" >"$repo/.out"

    local rc=0
    if [[ "$want" == "ignored" ]]; then
        grep -q 'storage/tmp/data.json' "$repo/.out" || rc=1
    else
        grep -q 'storage/tmp/data.json' "$repo/.out" && rc=1
        grep -q 'tracked.txt' "$repo/.out" || rc=1
    fi
    rm -rf "$repo"
    return "$rc"
}
if command -v git >/dev/null 2>&1; then
    run_test "collect_files excludes git-ignored files by default" collect_ignored_check default
    run_test "collect_files includes git-ignored files with --include-ignored" collect_ignored_check ignored
else
    skip_test "collect_files include-ignored behavior" "git not installed"
fi

# --no-ignore / --include-repomixignored: load_ignore_patterns must DROP the
# .repomixignore patterns under full bypass so a folder listed there is still
# collectable, while .git and the output dir stay excluded. Source only
# load_ignore_patterns + path_is_ignored + collect_files into a clean subshell.
repomixignore_bypass_check() {
    local want="$1" # "default" (exclude) or "bypass" (include)
    local repo
    repo="$(mktemp -d)"
    (
        cd "$repo"
        git init -q
        printf 'generated/\n' >.repomixignore
        printf 'tracked\n' >tracked.txt
        mkdir -p generated
        printf '{"a":1}\n' >generated/out.json
    )

    # shellcheck disable=SC2016
    "$BASH_BIN" -c '
        set -euo pipefail
        shopt -s extglob
        ((BASH_VERSINFO[0] >= 4)) && shopt -s globstar
        source <(sed -n "/^path_is_ignored() {/,/^}/p;/^load_ignore_patterns() {/,/^}/p;/^collect_files() {/,/^}/p" "$1")
        ROOT="$2"
        OUTPUT_DIR_REL=".repomix-context/tree-context"
        AI_CONTEXT_HARD_EXCLUDES=(".git" ".repomix-context")
        INCLUDE_IGNORED="$3"
        INCLUDE_REPOMIXIGNORED="$3"
        load_ignore_patterns
        collect_files
        printf "%s\n" "${COLLECTED_FILES[@]}"
    ' _ "$HELPERS" "$repo" "$([[ "$want" == "bypass" ]] && echo 1 || echo 0)" >"$repo/.out"

    local rc=0
    if [[ "$want" == "bypass" ]]; then
        grep -q 'generated/out.json' "$repo/.out" || rc=1
    else
        grep -q 'generated/out.json' "$repo/.out" && rc=1
        grep -q 'tracked.txt' "$repo/.out" || rc=1
    fi
    rm -rf "$repo"
    return "$rc"
}
if command -v git >/dev/null 2>&1; then
    run_test "load_ignore_patterns honors .repomixignore by default" repomixignore_bypass_check default
    run_test "full bypass (--no-ignore) packs .repomixignore'd folder" repomixignore_bypass_check bypass
else
    skip_test "repomixignore bypass behavior" "git not installed"
fi

# Bigger fixture: the tiny FIX above (2 small files) never reaches MIN_CODE=25,
# so the current `stats` test only ever exercises run_scc_analysis/
# write_file_metrics/write_folder_metrics on near-empty input. Build several
# folders (including root-level files, to reach pack_group's "_root" branch)
# with real code lines, tracked across two commits so --changed-since has
# something to diff, to reach write_bundle_plan/pack_group/run_pack/run_clean/
# run_purge, which never run today.
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
for i in 1 2; do gen_code_file "$BIGFIX/root_file$i.sh" 20; done
( cd "$BIGFIX" && git init -q && git add -A \
    && git -c user.email=t@t -c user.name=t commit -qm init ) >/dev/null 2>&1 || true
BIGFIX_FIRST_COMMIT="$(cd "$BIGFIX" && git rev-list --max-parents=0 HEAD 2>/dev/null)"
printf 'echo "extra"\n' >>"$BIGFIX/src/moduleA/file1.sh"
( cd "$BIGFIX" && git add -A \
    && git -c user.email=t@t -c user.name=t commit -qm update ) >/dev/null 2>&1 || true

if command -v scc >/dev/null 2>&1; then
    test_write_bundle_plan_ranks_routes() {
        "$BASH_BIN" "$SCRIPT" plan "$BIGFIX" --output-dir "$TMP/wb-default" 2>/dev/null
        awk -F'\t' '$2 == "src/moduleA"' "$TMP/wb-default/bundle-plan.tsv" | grep -q . \
            && awk -F'\t' '$2 == "_root"' "$TMP/wb-default/bundle-plan.tsv" | grep -q .
    }
    run_test "write_bundle_plan ranks qualifying routes, including a real _root group" test_write_bundle_plan_ranks_routes

    test_write_bundle_plan_top_form() {
        "$BASH_BIN" "$SCRIPT" plan "$BIGFIX" --output-dir "$TMP/wb-top" --top=1 2>/dev/null
        [[ "$(wc -l <"$TMP/wb-top/bundle-plan.tsv")" -eq 2 ]]
    }
    run_test "write_bundle_plan --top= limits the ranked plan to N routes" test_write_bundle_plan_top_form

    test_write_bundle_plan_min_files_form() {
        "$BASH_BIN" "$SCRIPT" plan "$BIGFIX" --output-dir "$TMP/wb-minfiles" --min-files=2 2>/dev/null
        ! awk -F'\t' '$2 == "src/moduleC"' "$TMP/wb-minfiles/bundle-plan.tsv" | grep -q .
    }
    run_test "write_bundle_plan --min-files= excludes a single-file group" test_write_bundle_plan_min_files_form

    test_write_bundle_plan_min_score_form() {
        "$BASH_BIN" "$SCRIPT" plan "$BIGFIX" --output-dir "$TMP/wb-minscore" --min-score=20 2>/dev/null
        awk -F'\t' '$2 == "src/moduleA"' "$TMP/wb-minscore/bundle-plan.tsv" | grep -q . \
            && ! awk -F'\t' '$2 == "_root"' "$TMP/wb-minscore/bundle-plan.tsv" | grep -q .
    }
    run_test "write_bundle_plan --min-score= filters out lower-ranked groups" test_write_bundle_plan_min_score_form

    test_write_bundle_plan_empty_after_filter_dies() {
        local out
        out="$("$BASH_BIN" "$SCRIPT" plan "$BIGFIX" --output-dir "$TMP/wb-empty" --min-complexity=1000 2>&1)"
        local rc=$?
        [[ $rc -ne 0 ]] && [[ "$out" == *"bundle plan is empty after filtering"* ]]
    }
    run_test "write_bundle_plan dies when every route is filtered out" test_write_bundle_plan_empty_after_filter_dies

    test_depth_flag_changes_grouping() {
        "$BASH_BIN" "$SCRIPT" plan "$BIGFIX" --output-dir "$TMP/wb-depth1" --depth 1 2>/dev/null
        awk -F'\t' '$2 == "src"' "$TMP/wb-depth1/bundle-plan.tsv" | grep -q .
    }
    run_test "--depth 1 groups moduleA/moduleB/moduleC under a single 'src' route" test_depth_flag_changes_grouping

    test_equals_form_flags_smoke() {
        "$BASH_BIN" "$SCRIPT" plan "$BIGFIX" --output-dir "$TMP/wb-eqform" \
            --churn-count=3 --style=plain --split-size=5mb --top=0 --include-logs-count=2 2>/dev/null
        [[ -f "$TMP/wb-eqform/bundle-plan.tsv" ]]
    }
    run_test "= form common options (--churn-count=, --style=, --split-size=, --top=, --include-logs-count=) parse" test_equals_form_flags_smoke

    test_changed_since_flag() {
        "$BASH_BIN" "$SCRIPT" stats "$BIGFIX" --output-dir "$TMP/wb-changed" --changed-since "$BIGFIX_FIRST_COMMIT" 2>/dev/null
        [[ -s "$TMP/wb-changed/file-metrics.tsv" ]]
    }
    run_test "--changed-since scopes stats to files changed since a ref" test_changed_since_flag
else
    skip_test "write_bundle_plan ranks qualifying routes, including a real _root group" "scc not installed"
    skip_test "write_bundle_plan --top= limits the ranked plan to N routes" "scc not installed"
    skip_test "write_bundle_plan --min-files= excludes a single-file group" "scc not installed"
    skip_test "write_bundle_plan --min-score= filters out lower-ranked groups" "scc not installed"
    skip_test "write_bundle_plan dies when every route is filtered out" "scc not installed"
    skip_test "--depth 1 groups moduleA/moduleB/moduleC under a single 'src' route" "scc not installed"
    skip_test "= form common options (--churn-count=, --style=, --split-size=, --top=, --include-logs-count=) parse" "scc not installed"
    skip_test "--changed-since scopes stats to files changed since a ref" "scc not installed"
fi

# clean/purge on a missing output dir are plain no-ops (no scc/repomix needed).
test_clean_missing_bundles_dir_is_noop() {
    "$BASH_BIN" "$SCRIPT" clean "$BIGFIX" --output-dir "$TMP/wb-nobundles" 2>&1 | grep -qi 'no bundles directory'
}
run_test "run_clean on a missing bundles directory logs and returns" test_clean_missing_bundles_dir_is_noop

test_purge_missing_output_dir_is_noop() {
    "$BASH_BIN" "$SCRIPT" purge "$BIGFIX" --output-dir "$TMP/wb-nopurge" 2>&1 | grep -qi 'no output directory'
}
run_test "run_purge on a missing output directory logs and returns" test_purge_missing_output_dir_is_noop

if command -v scc >/dev/null 2>&1 && command -v repomix >/dev/null 2>&1; then
    test_run_pack_dies_without_plan() {
        local out
        out="$("$BASH_BIN" "$SCRIPT" pack "$BIGFIX" --output-dir "$TMP/wb-nopack" 2>&1)"
        local rc=$?
        [[ $rc -ne 0 ]] && [[ "$out" == *"missing bundle plan"* ]]
    }
    run_test "run_pack dies when no bundle plan exists yet" test_run_pack_dies_without_plan

    test_pack_group_produces_root_and_folder_bundles() {
        "$BASH_BIN" "$SCRIPT" plan "$BIGFIX" --output-dir "$TMP/wb-pack" >/dev/null 2>&1
        "$BASH_BIN" "$SCRIPT" pack "$BIGFIX" --output-dir "$TMP/wb-pack" >/dev/null 2>&1
        [[ -f "$TMP/wb-pack/bundles/_root.xml" ]] && [[ -f "$TMP/wb-pack/bundles/src__moduleA.xml" ]]
    }
    run_test "pack_group packs both the _root group (stdin list) and folder groups (--include)" test_pack_group_produces_root_and_folder_bundles

    test_all_command_runs_stats_plan_pack() {
        "$BASH_BIN" "$SCRIPT" all "$BIGFIX" --output-dir "$TMP/wb-all" >/dev/null 2>&1
        [[ -f "$TMP/wb-all/bundle-plan.tsv" ]] && find "$TMP/wb-all/bundles" -type f 2>/dev/null | grep -q .
    }
    run_test "all command runs stats, plan, and pack" test_all_command_runs_stats_plan_pack

    test_clean_requires_approval() {
        "$BASH_BIN" "$SCRIPT" all "$BIGFIX" --output-dir "$TMP/wb-cleanguard" >/dev/null 2>&1
        ! CI=true "$BASH_BIN" "$SCRIPT" clean "$BIGFIX" --output-dir "$TMP/wb-cleanguard" </dev/null >/dev/null 2>&1
    }
    run_test "run_clean without approval fails outside a tty" test_clean_requires_approval

    test_clean_removes_bundles_keeps_metrics() {
        "$BASH_BIN" "$SCRIPT" all "$BIGFIX" --output-dir "$TMP/wb-clean" >/dev/null 2>&1
        APPROVE_CONTEXT_DELETE=1 "$BASH_BIN" "$SCRIPT" clean "$BIGFIX" --output-dir "$TMP/wb-clean" >/dev/null 2>&1
        [[ ! -d "$TMP/wb-clean/bundles" ]] && [[ -f "$TMP/wb-clean/bundle-plan.tsv" ]]
    }
    run_test "run_clean with approval removes bundles but keeps metrics/plan files" test_clean_removes_bundles_keeps_metrics

    test_purge_removes_output_dir() {
        "$BASH_BIN" "$SCRIPT" stats "$BIGFIX" --output-dir "$TMP/wb-purge" >/dev/null 2>&1
        APPROVE_CONTEXT_DELETE=1 "$BASH_BIN" "$SCRIPT" purge "$BIGFIX" --output-dir "$TMP/wb-purge" >/dev/null 2>&1
        [[ ! -d "$TMP/wb-purge" ]]
    }
    run_test "run_purge with approval removes the entire output directory" test_purge_removes_output_dir
else
    skip_test "run_pack dies when no bundle plan exists yet" "scc or repomix not installed"
    skip_test "pack_group packs both the _root group (stdin list) and folder groups (--include)" "scc or repomix not installed"
    skip_test "all command runs stats, plan, and pack" "scc or repomix not installed"
    skip_test "run_clean without approval fails outside a tty" "scc or repomix not installed"
    skip_test "run_clean with approval removes bundles but keeps metrics/plan files" "scc or repomix not installed"
    skip_test "run_purge with approval removes the entire output directory" "scc or repomix not installed"
fi

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d  Skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
((FAIL == 0)) && printf '\033[0;32mPASSED\033[0m\n' || { printf '\033[0;31mFAILED\033[0m\n'; exit 1; }
