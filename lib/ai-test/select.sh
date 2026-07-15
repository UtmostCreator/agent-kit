# shellcheck shell=bash
# ai-test/select.sh — select focused tests for AI-driven changes (lists tests;
# never runs them).
#
# Sourced by libexec/ai-test (thin loader). Not an entrypoint. Behavior is
# byte-for-byte identical to the previous standalone libexec/ai-test-select,
# just wrapped in ai_test_select_main() with module-local prefixed helper
# names (repo_files -> ai_test_select_repo_files, etc.) to avoid collisions
# when sourced into the shared ai-test process alongside the run-focused and
# run-all modules.

ai_test_select_usage() {
    cat <<'EOF'
Usage:
  agent-kit test select changed
  agent-kit test select file PATH
  agent-kit test select symbol SYMBOL
  agent-kit test select json

Purpose:
  Select focused tests before running broad verification.
EOF
}

ai_test_select_repo_files() {
    git ls-files
}

ai_test_select_changed_files() {
    {
        git diff --name-only --diff-filter=ACMRT
        git diff --cached --name-only --diff-filter=ACMRT
        git ls-files --others --exclude-standard
    } | sort -u | ai_test_select_existing_files_only
}

ai_test_select_existing_files_only() {
    while IFS= read -r file; do
        [[ -n "$file" && -f "$file" ]] || continue
        printf '%s\n' "$file"
    done
}

ai_test_select_lines_to_json_array() {
    sed '/^$/d' | jq -R . | jq -s .
}

ai_test_select_stem_for_file() {
    local file="$1"
    local base
    base="$(basename "$file")"
    printf '%s\n' "${base%.*}"
}

ai_test_select_find_tests_for_stem() {
    local stem="${1:-}"

    [[ -n "$stem" ]] || return 0

    {
        ai_test_select_repo_files | grep -E "(^|/)(tests?|spec|__tests__)/.*${stem}.*\.(php|js|ts|jsx|tsx|vue)$" || true
        ai_test_select_repo_files | grep -E "(^|/)${stem}(Test|Spec)?\.(php|js|ts|jsx|tsx)$" || true
        ai_test_select_repo_files | grep -E "(^|/)${stem}\.(test|spec)\.(js|ts|jsx|tsx)$" || true
    } | sort -u
}

ai_test_select_find_tests_for_symbol() {
    local symbol="${1:?symbol required}"

    if command -v rg >/dev/null 2>&1; then
        rg -l --hidden \
            -g 'tests/**' \
            -g 'test/**' \
            -g 'spec/**' \
            -g '__tests__/**' \
            -g '*.{php,js,ts,jsx,tsx,vue}' \
            "$symbol" . 2>/dev/null | sed 's#^\./##' | sort -u
    fi
}

ai_test_select_command_for_test() {
    local test_file="$1"

    case "$test_file" in
        *.php)
            if [[ -f artisan ]]; then
                printf 'php artisan test %s\n' "$test_file"
            elif [[ -x vendor/bin/pest ]]; then
                printf 'vendor/bin/pest %s\n' "$test_file"
            elif [[ -x vendor/bin/phpunit ]]; then
                printf 'vendor/bin/phpunit %s\n' "$test_file"
            fi
            ;;
        *.js | *.ts | *.jsx | *.tsx | *.vue)
            if [[ -f pnpm-lock.yaml ]]; then
                printf 'pnpm test -- %s\n' "$test_file"
            elif [[ -f package.json ]]; then
                printf 'npm test -- %s\n' "$test_file"
            fi
            ;;
    esac
}

ai_test_select_emit_json() {
    local files_json="$1"
    local tests_json="$2"
    local commands_json="$3"

    jq -n \
        --argjson files "$files_json" \
        --argjson tests "$tests_json" \
        --argjson commands "$commands_json" \
        '{
          input_files: $files,
          candidate_tests: $tests,
          recommended_commands: $commands
        }'
}

ai_test_select_for_files() {
    local input_files=("$@")
    local tests=()
    local commands=()
    local file
    local stem
    local test_file

    for file in "${input_files[@]+${input_files[@]}}"; do
        [[ -n "$file" ]] || continue
        stem="$(ai_test_select_stem_for_file "$file")"

        while IFS= read -r test_file; do
            [[ -n "$test_file" ]] || continue
            tests+=("$test_file")
        done < <(ai_test_select_find_tests_for_stem "$stem")
    done

    mapfile -t tests < <(printf '%s\n' "${tests[@]+${tests[@]}}" | sed '/^$/d' | sort -u)

    for test_file in "${tests[@]+${tests[@]}}"; do
        while IFS= read -r command; do
            [[ -n "$command" ]] || continue
            commands+=("$command")
        done < <(ai_test_select_command_for_test "$test_file")
    done

    mapfile -t commands < <(printf '%s\n' "${commands[@]+${commands[@]}}" | sed '/^$/d' | sort -u)

    ai_test_select_emit_json \
        "$(printf '%s\n' "${input_files[@]+${input_files[@]}}" | ai_test_select_lines_to_json_array)" \
        "$(printf '%s\n' "${tests[@]+${tests[@]}}" | ai_test_select_lines_to_json_array)" \
        "$(printf '%s\n' "${commands[@]+${commands[@]}}" | ai_test_select_lines_to_json_array)"
}

ai_test_select_main() {
    local mode="${1:-}"
    [[ -n "$mode" ]] || {
        ai_test_select_usage
        exit 2
    }
    shift || true

    agent_session_init "ai-test-select"
    require_bins jq git

    local files=()
    local tests=()
    local commands=()
    local file
    local symbol
    local test_file
    local command

    case "$mode" in
        changed)
            mapfile -t files < <(ai_test_select_changed_files)
            ai_test_select_for_files "${files[@]+${files[@]}}"
            ;;

        file)
            file="${1:?file required}"
            ai_test_select_for_files "$file"
            ;;

        symbol)
            symbol="${1:?symbol required}"
            mapfile -t tests < <(ai_test_select_find_tests_for_symbol "$symbol")
            commands=()

            for test_file in "${tests[@]+${tests[@]}}"; do
                while IFS= read -r command; do
                    [[ -n "$command" ]] || continue
                    commands+=("$command")
                done < <(ai_test_select_command_for_test "$test_file")
            done

            mapfile -t commands < <(printf '%s\n' "${commands[@]+${commands[@]}}" | sed '/^$/d' | sort -u)

            ai_test_select_emit_json \
                "$(jq -n --arg symbol "$symbol" '[$symbol]')" \
                "$(printf '%s\n' "${tests[@]+${tests[@]}}" | ai_test_select_lines_to_json_array)" \
                "$(printf '%s\n' "${commands[@]+${commands[@]}}" | ai_test_select_lines_to_json_array)"
            ;;

        json)
            mapfile -t files < <(ai_test_select_changed_files)
            ai_test_select_for_files "${files[@]+${files[@]}}"
            ;;

        --help | -h)
            ai_test_select_usage
            ;;

        *)
            ai_test_select_usage
            die "unknown mode: $mode"
            ;;
    esac

    log_json "test-select.query" "$(jq -cn --arg mode "$mode" '{mode:$mode}')"
}
