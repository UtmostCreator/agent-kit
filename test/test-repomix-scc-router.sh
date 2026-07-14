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
ANALYSIS_PACK="$REPO_ROOT/lib/repomix-scc-router/analysis-pack.sh"
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

# write_file_metrics direct unit test: feed crafted (including malformed)
# openmetrics-style content straight into the function so we exercise its
# path-normalization and skip-malformed-line branches deterministically,
# without depending on real scc output ever producing a Windows path, a
# double-slash, or a line scc itself would never emit. Source only
# group_for_path (a write_file_metrics dependency) + write_file_metrics into a
# clean subshell.
write_file_metrics_check() {
    local work raw
    work="$(mktemp -d)"
    raw="$work/raw.txt"
    {
        printf 'scc_lines{language="Go",file="src\\weird\\path.go"} 12\n'
        printf 'scc_code{language="Go",file="src\\weird\\path.go"} 10\n'
        printf 'scc_lines{language="Bash",file=".//dup//slash.sh"} 5\n'
        printf 'scc_code{language="Bash",file=".//dup//slash.sh"} 4\n'
        printf 'this_is_not_a_valid_metric_line garbage\n'
        printf 'scc_lines{language="Bash",file="./leading/dotslash.sh"} 3\n'
        printf 'scc_code{language="Bash",file="./leading/dotslash.sh"} 2\n'
    } >"$raw"

    # shellcheck disable=SC2016
    "$BASH_BIN" -c '
        set -euo pipefail
        source <(sed -n "/^group_for_path() {/,/^}/p" "$1")
        source <(sed -n "/^write_file_metrics() {/,/^}/p" "$2")
        DEPTH=2
        RAW_METRICS="$3"
        FILE_METRICS_RAW="$4/raw.tsv"
        FILE_METRICS="$4/file-metrics.tsv"
        write_file_metrics
        cat "$FILE_METRICS"
    ' _ "$HELPERS" "$ANALYSIS_PACK" "$raw" "$work" >"$work/out.tsv"

    local rc=0
    # Backslash Windows path normalized to forward slashes.
    grep -q 'src/weird/path.go' "$work/out.tsv" || rc=1
    # Double-slash collapsed and leading ./ stripped.
    grep -q 'dup/slash.sh' "$work/out.tsv" || rc=1
    # Leading ./ (no double slash) stripped.
    grep -q 'leading/dotslash.sh' "$work/out.tsv" || rc=1
    # A line that doesn't match the scc_<metric>{...file="..."...} pattern is
    # skipped by the awk `next` branch, not carried through into the output.
    grep -q 'garbage' "$work/out.tsv" && rc=1
    # Grouping still runs correctly against a normalized path.
    awk -F'\t' '$1=="src/weird" && $2=="src/weird/path.go"' "$work/out.tsv" | grep -q . || rc=1
    rm -rf "$work"
    return "$rc"
}
run_test "write_file_metrics normalizes backslash/double-slash/leading-./ paths and skips malformed lines" write_file_metrics_check

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

# Chunking fixture: run_scc_analysis batches scc invocations in chunks of 200
# files; every fixture above stays well under that, so the chunking while-loop
# (idx/total/chunk_output) never runs. 205 tiny one-line files (reusing
# gen_code_file) force two chunk batches (200 + 5).
CHUNKFIX="$TMP/chunkfix"
mkdir -p "$CHUNKFIX/src"
for i in $(seq -w 1 205); do gen_code_file "$CHUNKFIX/src/file$i.sh" 1; done
( cd "$CHUNKFIX" && git init -q && git add -A \
    && git -c user.email=t@t -c user.name=t commit -qm init ) >/dev/null 2>&1 || true

# Deep-nesting fixture: group_for_path's depth loop only ever collapses 3-4
# path segments down to 1-2 in the fixtures above. Nest four levels deep with
# a branch at level 3 (b/c vs b/d) so that the SAME files land in different
# candidate groups depending on --depth: one shared group at the default
# depth=2 ("src/a"), but split into distinct groups at depth=4
# ("src/a/b/c" vs "src/a/b/d").
DEEPFIX="$TMP/deepfix"
gen_code_file "$DEEPFIX/src/a/b/c/deep1.sh" 30
gen_code_file "$DEEPFIX/src/a/b/d/deep2.sh" 30
gen_code_file "$DEEPFIX/src/x/y/z/w/deep3.sh" 30
( cd "$DEEPFIX" && git init -q && git add -A \
    && git -c user.email=t@t -c user.name=t commit -qm init ) >/dev/null 2>&1 || true

if command -v scc >/dev/null 2>&1; then
    test_write_bundle_plan_ranks_routes() {
        "$BASH_BIN" "$SCRIPT" plan "$BIGFIX" --output-dir "$TMP/wb-default" 2>/dev/null
        awk -F'\t' '$2 == "src/moduleA"' "$TMP/wb-default/bundle-plan.tsv" | grep -q . \
            && awk -F'\t' '$2 == "_root"' "$TMP/wb-default/bundle-plan.tsv" | grep -q .
    }
    run_test "write_bundle_plan ranks qualifying routes, including a real _root group" test_write_bundle_plan_ranks_routes

    test_bundle_plan_json_mirrors_tsv_rows() {
        local tsv_rows json_rows first_tsv_group first_json_group
        tsv_rows="$(tail -n +2 "$TMP/wb-default/bundle-plan.tsv" | wc -l | tr -d ' ')"
        json_rows="$(jq 'length' "$TMP/wb-default/bundle-plan.json")"
        first_tsv_group="$(awk -F'\t' 'NR==2{print $2}' "$TMP/wb-default/bundle-plan.tsv")"
        first_json_group="$(jq -r '.[0].group' "$TMP/wb-default/bundle-plan.json")"
        [[ "$tsv_rows" -eq "$json_rows" ]] && [[ "$first_tsv_group" == "$first_json_group" ]]
    }
    run_test "write_bundle_plan's JSON output mirrors the TSV rows (jq -R -s pipeline)" test_bundle_plan_json_mirrors_tsv_rows

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

    # --changed-since with a ref that has NO diff against HEAD (HEAD itself):
    # collect_changed_files legitimately returns empty (no die), so files=()
    # after the CHANGED_SINCE override, hitting run_scc_analysis's early-return
    # "no files selected for analysis" branch — never reached by the flag test
    # above, which always has a real diff.
    test_changed_since_no_diff_writes_empty_metrics() {
        local out
        out="$("$BASH_BIN" "$SCRIPT" stats "$BIGFIX" --output-dir "$TMP/wb-nodiff" --changed-since HEAD 2>&1)"
        [[ "$out" == *"no files selected for analysis"* ]] \
            && [[ "$(wc -l <"$TMP/wb-nodiff/file-metrics.tsv")" -eq 1 ]]
    }
    run_test "--changed-since with no diff hits the empty-metrics early-return branch" test_changed_since_no_diff_writes_empty_metrics

    # run_scc_analysis chunks scc invocations in batches of 200 files; every
    # other fixture stays under that, so the chunking while-loop never runs.
    test_chunking_handles_over_200_files() {
        "$BASH_BIN" "$SCRIPT" stats "$CHUNKFIX" --output-dir "$TMP/wb-chunk" 2>/dev/null
        [[ "$(tail -n +2 "$TMP/wb-chunk/file-metrics.tsv" | wc -l | tr -d ' ')" -eq 205 ]]
    }
    run_test "run_scc_analysis chunks scc invocations when file count exceeds 200" test_chunking_handles_over_200_files

    # Same file set, two different --depth values: at depth=2 both branches
    # collapse into one group; at depth=4 they split into distinct groups.
    test_deep_nesting_depth2_collapses_groups() {
        "$BASH_BIN" "$SCRIPT" plan "$DEEPFIX" --output-dir "$TMP/wb-deep2" --depth 2 2>/dev/null
        awk -F'\t' '$2 == "src/a"' "$TMP/wb-deep2/bundle-plan.tsv" | grep -q . \
            && ! awk -F'\t' '$2 == "src/a/b/c"' "$TMP/wb-deep2/bundle-plan.tsv" | grep -q .
    }
    run_test "deep nesting at depth=2 collapses multiple subfolders into one group" test_deep_nesting_depth2_collapses_groups

    test_deep_nesting_depth4_separates_groups() {
        "$BASH_BIN" "$SCRIPT" plan "$DEEPFIX" --output-dir "$TMP/wb-deep4" --depth 4 2>/dev/null
        awk -F'\t' '$2 == "src/a/b/c"' "$TMP/wb-deep4/bundle-plan.tsv" | grep -q . \
            && awk -F'\t' '$2 == "src/a/b/d"' "$TMP/wb-deep4/bundle-plan.tsv" | grep -q .
    }
    run_test "deep nesting at depth=4 separates the same files into distinct groups" test_deep_nesting_depth4_separates_groups

    # --churn-count scopes write_folder_metrics' git-log churn window: with
    # --churn-count=1 only the most recent commit (which touched only
    # src/moduleA/file1.sh) counts, so moduleA's churn is 1 and moduleC's is 0
    # (moduleC was only touched by the initial commit).
    test_churn_count_scopes_recent_commits() {
        "$BASH_BIN" "$SCRIPT" stats "$BIGFIX" --output-dir "$TMP/wb-churn1" --churn-count=1 2>/dev/null
        local module_a_churn module_c_churn
        module_a_churn="$(awk -F'\t' '$1 == "src/moduleA" {print $9}' "$TMP/wb-churn1/folder-metrics.tsv")"
        module_c_churn="$(awk -F'\t' '$1 == "src/moduleC" {print $9}' "$TMP/wb-churn1/folder-metrics.tsv")"
        [[ "$module_a_churn" == "1" ]] && [[ "$module_c_churn" == "0" ]]
    }
    run_test "--churn-count= scopes churn counting to only the most recent commits" test_churn_count_scopes_recent_commits
else
    skip_test "write_bundle_plan ranks qualifying routes, including a real _root group" "scc not installed"
    skip_test "write_bundle_plan's JSON output mirrors the TSV rows (jq -R -s pipeline)" "scc not installed"
    skip_test "write_bundle_plan --top= limits the ranked plan to N routes" "scc not installed"
    skip_test "write_bundle_plan --min-files= excludes a single-file group" "scc not installed"
    skip_test "write_bundle_plan --min-score= filters out lower-ranked groups" "scc not installed"
    skip_test "write_bundle_plan dies when every route is filtered out" "scc not installed"
    skip_test "--depth 1 groups moduleA/moduleB/moduleC under a single 'src' route" "scc not installed"
    skip_test "= form common options (--churn-count=, --style=, --split-size=, --top=, --include-logs-count=) parse" "scc not installed"
    skip_test "--changed-since scopes stats to files changed since a ref" "scc not installed"
    skip_test "--changed-since with no diff hits the empty-metrics early-return branch" "scc not installed"
    skip_test "run_scc_analysis chunks scc invocations when file count exceeds 200" "scc not installed"
    skip_test "deep nesting at depth=2 collapses multiple subfolders into one group" "scc not installed"
    skip_test "deep nesting at depth=4 separates the same files into distinct groups" "scc not installed"
    skip_test "--churn-count= scopes churn counting to only the most recent commits" "scc not installed"
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

    # run_pack's SECOND guard (missing file metrics) is unreachable from a bare
    # `pack` invocation, since a bundle plan can only exist if `stats` already
    # wrote file-metrics.tsv alongside it. Reach it by running `plan` (which
    # writes both), then deleting file-metrics.tsv before `pack`.
    test_run_pack_dies_without_file_metrics() {
        "$BASH_BIN" "$SCRIPT" plan "$BIGFIX" --output-dir "$TMP/wb-nofm" >/dev/null 2>&1
        rm -f "$TMP/wb-nofm/file-metrics.tsv"
        local out
        out="$("$BASH_BIN" "$SCRIPT" pack "$BIGFIX" --output-dir "$TMP/wb-nofm" 2>&1)"
        local rc=$?
        [[ $rc -ne 0 ]] && [[ "$out" == *"missing file metrics"* ]]
    }
    run_test "run_pack dies when the bundle plan exists but file metrics is missing" test_run_pack_dies_without_file_metrics

    test_pack_group_produces_root_and_folder_bundles() {
        "$BASH_BIN" "$SCRIPT" plan "$BIGFIX" --output-dir "$TMP/wb-pack" >/dev/null 2>&1
        "$BASH_BIN" "$SCRIPT" pack "$BIGFIX" --output-dir "$TMP/wb-pack" >/dev/null 2>&1
        [[ -f "$TMP/wb-pack/bundles/_root.xml" ]] && [[ -f "$TMP/wb-pack/bundles/src__moduleA.xml" ]]
    }
    run_test "pack_group packs both the _root group (stdin list) and folder groups (--include)" test_pack_group_produces_root_and_folder_bundles

    # pack_group's optional repomix_args branches (INCLUDE_IGNORED,
    # INCLUDE_REPOMIXIGNORED, COMPRESS, SPLIT_SIZE, INCLUDE_LOGS,
    # INCLUDE_DIFFS) are only appended to repomix_args when their matching
    # flag is set; every pack test above uses bare defaults, so none of those
    # `if` bodies ever run. --no-ignore sets both INCLUDE_IGNORED and
    # INCLUDE_REPOMIXIGNORED at once (common-options.sh), so one combined
    # invocation reaches all six branches.
    test_pack_group_optional_repomix_flags_branch() {
        "$BASH_BIN" "$SCRIPT" plan "$BIGFIX" --output-dir "$TMP/wb-packflags" >/dev/null 2>&1
        "$BASH_BIN" "$SCRIPT" pack "$BIGFIX" --output-dir "$TMP/wb-packflags" \
            --no-ignore --compress --split-size=5mb --include-logs --include-diffs >/dev/null 2>&1
        # --split-size makes repomix always number its output (even a single
        # part), so the bundle is "_root.1.xml", not the bare "_root.xml"
        # every other pack test above asserts on.
        ls "$TMP/wb-packflags/bundles/"_root*.xml >/dev/null 2>&1
    }
    run_test "pack_group: --no-ignore/--compress/--split-size/--include-logs/--include-diffs all extend repomix_args" test_pack_group_optional_repomix_flags_branch

    # --style changes STYLE_EXT (main.sh), which write_bundle_plan bakes into
    # each row's bundle filename and pack_group's repomix --style arg actually
    # produces. Every other pack test above uses the xml default.
    test_style_markdown_changes_bundle_extension() {
        "$BASH_BIN" "$SCRIPT" all "$BIGFIX" --output-dir "$TMP/wb-md" --style=markdown >/dev/null 2>&1
        [[ -f "$TMP/wb-md/bundles/_root.md" ]] \
            && awk -F'\t' '$NF ~ /\.md$/' "$TMP/wb-md/bundle-plan.tsv" | grep -q .
    }
    run_test "--style=markdown changes the generated bundle file extension to .md" test_style_markdown_changes_bundle_extension

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
    skip_test "run_pack dies when the bundle plan exists but file metrics is missing" "scc or repomix not installed"
    skip_test "pack_group packs both the _root group (stdin list) and folder groups (--include)" "scc or repomix not installed"
    skip_test "pack_group: --no-ignore/--compress/--split-size/--include-logs/--include-diffs all extend repomix_args" "scc or repomix not installed"
    skip_test "--style=markdown changes the generated bundle file extension to .md" "scc or repomix not installed"
    skip_test "all command runs stats, plan, and pack" "scc or repomix not installed"
    skip_test "run_clean without approval fails outside a tty" "scc or repomix not installed"
    skip_test "run_clean with approval removes bundles but keeps metrics/plan files" "scc or repomix not installed"
    skip_test "run_purge with approval removes the entire output directory" "scc or repomix not installed"
fi

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d  Skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
((FAIL == 0)) && printf '\033[0;32mPASSED\033[0m\n' || { printf '\033[0;31mFAILED\033[0m\n'; exit 1; }
