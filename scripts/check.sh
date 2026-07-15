#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cd -- "$repo_root"

if command -v shellcheck >/dev/null 2>&1; then
    mapfile -d '' shell_files < <(
        git ls-files -z -- '*.sh' 'bin/*' 'libexec/*' 'hooks/*' |
            while IFS= read -r -d '' file; do
                [[ -f "$file" ]] || continue
                first_line=$(head -n 1 -- "$file" || true)
                case "$first_line" in
                    # ShellCheck cannot lint zsh; skip zsh scripts explicitly
                    # (this must precede the *sh* case, since "zsh" contains "sh").
                    *zsh*) ;;
                    *bash*|*sh*) printf '%s\0' "$file" ;;
                esac
            done
    )

    if ((${#shell_files[@]} > 0)); then
        # Sharded across parallel shellcheck processes instead of one process
        # given all files: a single invocation over this many files measured
        # at ~93s, dominating the whole suite's wall time, vs ~42s sharded
        # (still ~2.2x faster; small shards, not "1 shard per core", because
        # bigger batches were measured to blow up super-linearly past ~20
        # files per shard rather than just amortizing better).
        #
        # -x (--external-sources) is required for correctness once files are
        # split into separate invocations: by default shellcheck refuses to
        # follow a `source` statement to a path outside the current
        # invocation's FILES list, so many lib/*.sh files that set a
        # variable consumed only by a sourced sibling (e.g. $REPO_ROOT,
        # $failures -- both real, deliberate cross-module conventions in
        # this codebase, not bugs) would otherwise show up as false-positive
        # "appears unused" warnings the instant those siblings land in a
        # different shard. Confirmed empirically: without -x, splitting into
        # per-file shards surfaced 5 such false positives that vanished the
        # moment -x was added, matching the single-invocation baseline
        # (0 warnings) exactly.
        printf '%s\0' "${shell_files[@]}" |
            xargs -0 -P"$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)" -n5 \
                shellcheck -x --severity=warning --
    fi
else
    printf 'warning: shellcheck is not installed; lint skipped\n' >&2
fi

shopt -s nullglob
tests=(test/test-*.sh)
if ((${#tests[@]} == 0)); then
    printf 'error: no test/test-*.sh files found\n' >&2
    exit 1
fi

for test_file in "${tests[@]}"; do
    printf '==> %s\n' "$test_file"
    bash -- "$test_file"
done

printf 'All checks passed.\n'
