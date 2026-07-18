# shellcheck shell=bash
# ai-git/forensics.sh — history search (log -S/-G/-L) and blame.
#
# Sourced by libexec/ai-git (thin loader). Not an entrypoint. Behavior is
# byte-for-byte identical to the previous standalone libexec/git-forensics,
# just wrapped in ai_git_forensics_main() with a module-local helper name.

ai_git_forensics_usage() {
    cat <<'EOF'
Usage:
  restsift git history MODE TARGET [file] [--json]
  restsift git blame LINES FILE [--json]

Modes (history):
  S      search by added/removed string via git log -S
  G      search by regex via git log -G
  L      line history via git log -L

blame annotates a line range (LINES, e.g. "1,20") in a file.

Exit codes:
  0    success
  1    usage/validation error (missing mode/target/file, unknown option)
  128  git passthrough failure (e.g. blame LINES out of range)
  129  git usage error (e.g. malformed blame LINES spec)
EOF
}

ai_git_forensics_run_and_capture() {
    local mode="$1" search_target="$2" file="$3" output_json="$4"
    shift 4
    local cmd=("$@")
    # blame_hint is set by ai_git_forensics_main (dynamic scope) when the caller
    # knows the invocation will fail with a git usage/fatal error, so we can wrap
    # git's raw "usage: git blame ..." (129) / "fatal: ... only N lines" (128)
    # text in an actionable ai-git remediation line.
    local hint="${blame_hint:-}"
    if [[ "$output_json" == "1" ]]; then
        local output rc=0
        output="$("${cmd[@]}" 2>&1)" || rc=$?
        jq -n --arg mode "$mode" --arg target "$search_target" --arg file "$file" \
            --arg output "$output" --argjson status "$rc" --arg hint "$hint" \
            '{mode:$mode, target:$target, file:(if $file == "" then null else $file end), status:$status, error:(if $status == 0 then null else $output end), output:$output}
             + (if $hint != "" then {hint:$hint} else {} end)'
        return "$rc"
    else
        if [[ -n "$hint" ]]; then
            log_error "$hint"
        fi
        "${cmd[@]}"
    fi
}

ai_git_forensics_main() {
    require_bins git

    # Scan every argument for --help/-h before consuming positionals, so
    # `git blame --help` (and `git log -S x --help`) reach usage instead of
    # binding "--help" as the LINES/target positional.
    local _arg
    for _arg in "$@"; do
        case "$_arg" in
            --help | -h)
                ai_git_forensics_usage
                exit 0
                ;;
        esac
    done

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
    local blame_hint=""
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
            elif git ls-files --error-unmatch -- "$file" >/dev/null 2>&1; then
                # File is tracked but git blame failed (e.g. an out-of-range LINES
                # spec): surface git's real error instead of masking it with the
                # sed fallback, which would succeed with empty/no-op output. Wrap
                # git's raw usage/fatal text in an actionable ai-git hint.
                blame_hint="blame LINES must be START,END within the file (got: $search_target)"
                ai_git_forensics_run_and_capture "$mode" "$search_target" "$file" "$output_json" git blame -L "$search_target" -- "$file"
            elif [[ -e "$file" ]]; then
                # Fallback for existing files not yet in HEAD/history in
                # fixture-heavy worktrees.
                ai_git_forensics_run_and_capture "$mode" "$search_target" "$file" "$output_json" sed -n "${search_target}p" "$file"
            else
                # File does not exist on disk and is not tracked: report a clean
                # "file not found" instead of leaking the sed fallback's
                # "sed: can't read" message. Stay JSON-aware so consumers still
                # get an envelope with a non-zero status and error.
                if [[ "$output_json" == "1" ]]; then
                    jq -n --arg mode "$mode" --arg target "$search_target" --arg file "$file" \
                        '{mode:$mode, target:$target, file:$file, status:2, error:("file not found: "+$file), output:""}'
                    return 2
                fi
                die "file not found: $file"
            fi
            ;;
        *) die "unknown mode: $mode" ;;
    esac
}
