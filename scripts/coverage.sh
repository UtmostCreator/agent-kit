#!/usr/bin/env bash
# Measure real line coverage of the toolkit's Bash sources (bin/, lib/,
# libexec/) by running the test suite.
#
# Default engine: a native Bash DEBUG-trap collector (scripts/lib/cov-hook.sh),
# no ptrace required. kcov's bash tracer needs PTRACE_TRACEME, which returns
# EPERM in seccomp-restricted sandboxes/containers (confirmed on this host via
# `strace -f -e trace=ptrace`) — it exits 0 but silently reports 0/0 lines
# instead of erroring, so a kcov run that "succeeds" there is not evidence.
# Set COVERAGE_ENGINE=kcov to use kcov instead, e.g. on a host where ptrace is
# permitted: `nix-shell --run 'COVERAGE_ENGINE=kcov ./scripts/coverage.sh'`.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cd -- "$repo_root"

out_dir=${COVERAGE_OUT:-coverage}
engine=${COVERAGE_ENGINE:-native}

shopt -s nullglob
tests=(test/test-*.sh)
if ((${#tests[@]} == 0)); then
    printf 'error: no test/test-*.sh files found\n' >&2
    exit 1
fi

run_kcov() {
    if ! command -v kcov >/dev/null 2>&1; then
        printf 'error: kcov is not installed\n' >&2
        printf 'hint: nix-shell --run ./scripts/coverage.sh\n' >&2
        exit 127
    fi

    rm -rf -- "$out_dir"
    mkdir -p -- "$out_dir"

    # One kcov run per test file, all merged into $out_dir. kcov follows the
    # child processes each test spawns (bin/agent-kit -> libexec/* -> lib/*),
    # so coverage accumulates across the whole toolkit.
    local i=0 test_file
    for test_file in "${tests[@]}"; do
        i=$((i + 1))
        printf '==> [%d/%d] %s\n' "$i" "${#tests[@]}" "$test_file"
        kcov \
            --include-path="$repo_root/libexec,$repo_root/lib,$repo_root/bin" \
            --exclude-pattern=/test/,/.git/ \
            "$out_dir/run-$i" \
            bash -- "$test_file" >/dev/null 2>&1 || {
            printf 'warning: test exited non-zero under kcov: %s\n' "$test_file" >&2
        }
    done

    kcov --merge "$out_dir/merged" "$out_dir"/run-* >/dev/null 2>&1

    local summary="$out_dir/merged/kcov-merged/coverage.json"
    if [[ -f "$summary" ]]; then
        local pct covered total
        pct=$(jq -r '.percent_covered' "$summary")
        covered=$(jq -r '.covered_lines' "$summary")
        total=$(jq -r '.total_lines' "$summary")
        printf '\nLine coverage: %s%% (%s/%s lines)\n' "$pct" "$covered" "$total"
        printf 'HTML report: %s/merged/index.html\n' "$out_dir"
        if [[ "$total" == "0" ]]; then
            printf 'warning: 0 total lines — kcov likely failed to attach (ptrace blocked); this is not real coverage\n' >&2
        fi
    else
        printf '\nMerged report written to %s/merged\n' "$out_dir"
    fi
}

run_native() {
    rm -rf -- "$out_dir"
    mkdir -p -- "$out_dir/hits"

    export AK_COV_ROOT="$repo_root"
    export AK_COV_DIR="$repo_root/$out_dir/hits"
    export BASH_ENV="$repo_root/scripts/lib/cov-hook.sh"
    # test-ai-search.sh has ~269 already-written Phase 3-6 assertions gated
    # behind this var (off by default; scripts/check.sh does not set it
    # either). They pass cleanly, so run them for an accurate baseline.
    export AI_SEARCH_RUN_P1_TESTS=1

    local i=0 test_file
    for test_file in "${tests[@]}"; do
        i=$((i + 1))
        printf '==> [%d/%d] %s\n' "$i" "${#tests[@]}" "$test_file"
        bash -- "$test_file" >/dev/null 2>&1 || {
            printf 'warning: test exited non-zero under the coverage tracer: %s\n' "$test_file" >&2
            printf '  (verify with a plain "bash %s" before assuming a regression -- see the\n' "$test_file" >&2
            printf '   KNOWN LIMITATION note in scripts/lib/cov-hook.sh: functrace can make a\n' >&2
            printf '   scoped RETURN trap fire early in code that sets one for cleanup)\n' >&2
        }
    done

    unset BASH_ENV AK_COV_ROOT AK_COV_DIR AI_SEARCH_RUN_P1_TESTS

    local hit_file="$out_dir/hits.txt"
    cat -- "$out_dir"/hits/*.cov 2>/dev/null | sort -u >"$hit_file" || : >"$hit_file"

    # Modules are frequently `source`d via an uncollapsed relative path (e.g.
    # libexec/ai-search sources "$libexec_dir/../lib/ai-search/x.sh"), so
    # $BASH_SOURCE in the trap records that literal, uncollapsed path. Resolve
    # every distinct recorded path to its canonical form once here, rather
    # than shelling out to readlink per executed line.
    if [[ -s "$hit_file" ]]; then
        local -A canon
        local p canon_path
        while IFS= read -r p; do
            canon_path=$(readlink -f -- "$p" 2>/dev/null) || canon_path="$p"
            canon["$p"]="$canon_path"
        done < <(cut -f1 -- "$hit_file" | sort -u)

        local tmp_hits="$hit_file.tmp"
        : >"$tmp_hits"
        local line
        while IFS=$'\t' read -r p line; do
            printf '%s\t%s\n' "${canon[$p]:-$p}" "$line"
        done <"$hit_file" >"$tmp_hits"
        sort -u -- "$tmp_hits" >"$hit_file"
        rm -f -- "$tmp_hits"
    fi

    mapfile -d '' sources < <(find bin lib libexec -type f -print0 | sort -z)

    local report="$out_dir/report.txt"
    : >"$report"

    local total_exec=0 total_hit=0 f rel exec_lines exec_count hit_lines hit_count pct
    for f in "${sources[@]}"; do
        rel="$repo_root/$f"
        exec_lines=$(awk -f "$repo_root/scripts/lib/cov-lines.awk" -- "$f")
        exec_count=$(grep -c . <<<"$exec_lines" || true)
        ((exec_count == 0)) && continue

        hit_lines=$(awk -F'\t' -v want="$rel" '$1 == want { print $2 }' "$hit_file" | sort -u)
        # comm requires its two inputs in the same (lexicographic, not
        # numeric) order — `sort -n` would desync it from `sort -u` here.
        hit_count=$(comm -12 <(sort -u <<<"$exec_lines") <(printf '%s\n' "$hit_lines") | grep -c . || true)

        total_exec=$((total_exec + exec_count))
        total_hit=$((total_hit + hit_count))

        pct=$(awk -v h="$hit_count" -v t="$exec_count" 'BEGIN { printf "%.1f", (t > 0 ? 100.0 * h / t : 0) }')
        printf '%6s%%  %4d/%-4d  %s\n' "$pct" "$hit_count" "$exec_count" "$f" >>"$report"
    done

    sort -k1,1n -- "$report" >"$report.sorted" && mv -- "$report.sorted" "$report"

    printf '\nPer-file coverage (lowest first):\n'
    cat -- "$report"

    local overall_pct
    overall_pct=$(awk -v h="$total_hit" -v t="$total_exec" 'BEGIN { printf "%.2f", (t > 0 ? 100.0 * h / t : 0) }')
    printf '\nLine coverage: %s%% (%s/%s executable lines across %s files)\n' \
        "$overall_pct" "$total_hit" "$total_exec" "${#sources[@]}"
    printf 'Per-file report: %s\n' "$report"
    printf 'Raw hits:        %s\n' "$hit_file"
}

case "$engine" in
    native) run_native ;;
    kcov) run_kcov ;;
    *)
        printf 'error: unknown COVERAGE_ENGINE=%s (expected native or kcov)\n' "$engine" >&2
        exit 2
        ;;
esac
