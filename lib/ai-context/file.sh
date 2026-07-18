# shellcheck shell=bash
# ai-context/file.sh — exact single-file Repomix wrapper.
#
# Sourced by libexec/ai-context (thin loader). Not an entrypoint. Behavior is
# byte-for-byte identical to the previous standalone libexec/run-repomix-file,
# just wrapped in ai_context_file_main() with a module-local usage name. The
# original file's early standalone --help/--introspect sh-introspect guards are
# dropped here (they only made sense for a directly-executed script); --help is
# still handled inline by the option loop below, matching every other fused
# ai-context mode.

ai_context_file_usage() {
    cat <<'EOF'
Usage:
  restsift context file [REPO_ROOT] FILE [options]

Arguments:
  REPO_ROOT   Repository root (optional; defaults to the current directory).
  FILE        File to pack, absolute or relative to REPO_ROOT.

Options:
  --style STYLE    Repomix output style (default: xml).
  --output PATH    Output file path (relative paths resolve under REPO_ROOT).
                   Default: .repomix-context/single-file/<sanitized-path>.<style>
  --no-compress    Disable the default --compress flag.
  --help, -h       Show this help.

Defaults:
  --compress
  --style xml

Exit codes:
  0  ok — file packed (path printed to stdout)
  1  repo root / file not found, file outside repo root, or repomix missing
  2  bad flag / unknown option / missing FILE argument
EOF
}

ai_context_file_main() {
    local style='xml'
    local output=''
    local compress=1
    local positionals=()

    while (($# > 0)); do
        case "$1" in
            --help | -h)
                ai_context_file_usage
                return 0
                ;;
            --style)
                [[ $# -ge 2 ]] || {
                    printf 'error: --style requires a value\n' >&2
                    return 2
                }
                style="$2"
                shift 2
                ;;
            --output)
                [[ $# -ge 2 ]] || {
                    printf 'error: --output requires a value\n' >&2
                    return 2
                }
                output="$2"
                shift 2
                ;;
            --no-compress)
                compress=0
                shift
                ;;
            --compress)
                compress=1
                shift
                ;;
            --)
                shift
                while (($# > 0)); do
                    positionals+=("$1")
                    shift
                done
                ;;
            -*)
                printf 'error: unknown option: %s\n' "$1" >&2
                return 2
                ;;
            *)
                positionals+=("$1")
                shift
                ;;
        esac
    done

    local repo file
    if ((${#positionals[@]} >= 2)); then
        repo="${positionals[0]}"
        file="${positionals[1]}"
    elif ((${#positionals[@]} == 1)); then
        repo='.'
        file="${positionals[0]}"
    else
        printf 'error: a FILE argument is required\n' >&2
        ai_context_file_usage >&2
        return 2
    fi

    [[ -d "$repo" ]] || {
        printf 'error: repository root not found: %s\n' "$repo" >&2
        return 1
    }
    local repo_abs
    repo_abs="$(cd "$repo" && pwd)"

    # Resolve the repository-relative path for the target file.
    local rel
    case "$file" in
        /*)
            rel="${file#"$repo_abs"/}"
            if [[ "$rel" == "$file" ]]; then
                printf 'error: file is not inside repository root: %s\n' "$file" >&2
                return 1
            fi
            ;;
        *)
            rel="${file#./}"
            ;;
    esac

    [[ -f "$repo_abs/$rel" ]] || {
        printf 'error: file not found: %s\n' "$repo_abs/$rel" >&2
        return 1
    }

    command -v repomix >/dev/null 2>&1 || {
        printf 'error: repomix not found on PATH\n' >&2
        return 1
    }

    # Determine the output path.
    local out
    if [[ -n "$output" ]]; then
        case "$output" in
            /*) out="$output" ;;
            *) out="$repo_abs/$output" ;;
        esac
    else
        local sanitized="${rel//\//__}"
        out="$repo_abs/.repomix-context/single-file/${sanitized}.${style}"
    fi

    local out_dir
    out_dir="$(dirname "$out")"
    mkdir -p "$out_dir"

    # Build the repomix argument list.
    local args=(--stdin --style "$style")
    ((compress == 1)) && args+=(--compress)
    args+=(--output "$out")

    # Pass the single repository-relative path to repomix via stdin.
    printf '%s\n' "$rel" | (cd "$repo_abs" && repomix "${args[@]}")

    # Write a small run manifest next to the output.
    local manifest="${out_dir}/run-manifest.json"
    local generated_at
    generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown')"
    printf '{\n  "file": "%s",\n  "output": "%s",\n  "style": "%s",\n  "compress": %s,\n  "generated_at": "%s"\n}\n' \
        "$rel" "$out" "$style" "$([[ "$compress" == 1 ]] && printf 'true' || printf 'false')" "$generated_at" \
        >"$manifest"

    printf 'packed %s -> %s\n' "$rel" "$out"
}
