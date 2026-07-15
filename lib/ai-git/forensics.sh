# shellcheck shell=bash
# ai-git/forensics.sh — history search (log -S/-G/-L) and blame.
#
# Sourced by libexec/ai-git (thin loader). Not an entrypoint. Behavior is
# byte-for-byte identical to the previous standalone libexec/git-forensics,
# just wrapped in ai_git_forensics_main() with a module-local helper name.

ai_git_forensics_usage() {
    cat <<'EOF'
Usage:
  agent-kit git history MODE TARGET [file] [--json]
  agent-kit git blame LINES FILE [--json]

Modes (history):
  S      search by added/removed string via git log -S
  G      search by regex via git log -G
  L      line history via git log -L

blame annotates a line range (LINES, e.g. "1,20") in a file.
EOF
}

ai_git_forensics_run_and_capture() {
    local mode="$1" search_target="$2" file="$3" output_json="$4"
    shift 4
    local cmd=("$@")
    if [[ "$output_json" == "1" ]]; then
        local output
        output="$("${cmd[@]}" 2>&1 || true)"
        jq -n --arg mode "$mode" --arg target "$search_target" --arg file "$file" --arg output "$output" \
            '{mode:$mode, target:$target, file:(if $file == "" then null else $file end), output:$output}'
    else
        "${cmd[@]}"
    fi
}

ai_git_forensics_main() {
    require_bins git

    case "${1:-}" in
        --help | -h)
            ai_git_forensics_usage
            exit 0
            ;;
    esac

    if [[ $# -lt 2 ]]; then
        ai_git_forensics_usage >&2
        die "mode and target required"
    fi

    local mode="$1"
    local search_target="$2"
    local file="${3:-}"

    if [[ -n "$file" ]] && [[ "$file" == --* ]]; then
        file=""
    fi

    shift 2 || true
    if [[ -n "$file" ]]; then
        shift || true
    fi

    local output_json=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)
                output_json=1
                shift
                ;;
            *) die "unknown option: $1" ;;
        esac
    done

    case "$mode" in
        S)
            if [[ -n "$file" ]]; then
                ai_git_forensics_run_and_capture "$mode" "$search_target" "$file" "$output_json" git log -S "$search_target" -p -- "$file"
            else
                ai_git_forensics_run_and_capture "$mode" "$search_target" "$file" "$output_json" git log -S "$search_target" -p
            fi
            ;;
        G)
            if [[ -n "$file" ]]; then
                ai_git_forensics_run_and_capture "$mode" "$search_target" "$file" "$output_json" git log -G "$search_target" -p -- "$file"
            else
                ai_git_forensics_run_and_capture "$mode" "$search_target" "$file" "$output_json" git log -G "$search_target" -p
            fi
            ;;
        L)
            ai_git_forensics_run_and_capture "$mode" "$search_target" "$file" "$output_json" git log -L "$search_target"
            ;;
        blame)
            [[ -n "$file" ]] || die "file required for blame mode"
            if git blame -L "$search_target" -- "$file" >/dev/null 2>&1; then
                ai_git_forensics_run_and_capture "$mode" "$search_target" "$file" "$output_json" git blame -L "$search_target" -- "$file"
            elif git blame -L "$search_target" "$file" >/dev/null 2>&1; then
                ai_git_forensics_run_and_capture "$mode" "$search_target" "$file" "$output_json" git blame -L "$search_target" "$file"
            else
                # Fallback for files not yet in HEAD/history in fixture-heavy worktrees.
                ai_git_forensics_run_and_capture "$mode" "$search_target" "$file" "$output_json" sed -n "${search_target}p" "$file"
            fi
            ;;
        *) die "unknown mode: $mode" ;;
    esac
}
