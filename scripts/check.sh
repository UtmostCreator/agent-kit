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
        shellcheck --severity=warning -- "${shell_files[@]}"
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
