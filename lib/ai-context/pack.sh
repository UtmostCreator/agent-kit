# shellcheck shell=bash
# shellcheck disable=SC2164  # cd calls are inside ( ) subshells under set -e; a failed cd aborts only the subshell — behavior preserved verbatim from the previous standalone script
# ai-context/pack.sh — safe context packer wrapper (repomix / files-to-prompt / code2prompt).
#
# Sourced by libexec/ai-context (thin loader). Not an entrypoint. Behavior is
# byte-for-byte identical to the previous standalone libexec/pack-context, just
# wrapped in ai_context_pack_main() with module-local helper names so it can
# share a process with the other ai-context modules.

ai_context_pack_usage() {
    cat <<'EOF'
Usage:
  agent-kit context pack [auto|repomix|files-to-prompt|code2prompt] [tool args...]

Environment:
  OUTPUT_DIR=.repomix-context/manual
  OUTPUT_FILE=<path>
  OUTPUT_STYLE=xml
  SECRETS_SCAN=1
  TOKEN_BUDGET=80000

Examples:
  agent-kit context pack auto --include "docs/ai/**/*.md,tools/**/*.php"
  OUTPUT_FILE=.repomix-context/manual/docs.xml agent-kit context pack repomix --include "docs/**/*.md"
  agent-kit context pack files-to-prompt docs/ai/cli-tools.md docs/ai/tools/tool-map.md
EOF
}

ai_context_pack_args_contain_output() {
    local arg
    for arg in "$@"; do
        case "$arg" in
        --output | --output=*)
            return 0
            ;;
        esac
    done
    return 1
}

ai_context_pack_select_backend() {
    local backend="$1"
    case "$backend" in
    auto)
        if command -v repomix >/dev/null 2>&1; then
            printf 'repomix\n'
        elif command -v files-to-prompt >/dev/null 2>&1; then
            printf 'files-to-prompt\n'
        elif command -v code2prompt >/dev/null 2>&1; then
            printf 'code2prompt\n'
        else
            die "no supported context packer found; install repomix, files-to-prompt, or code2prompt"
        fi
        ;;
    repomix)
        require_bins repomix
        printf 'repomix\n'
        ;;
    files-to-prompt)
        require_bins files-to-prompt
        printf 'files-to-prompt\n'
        ;;
    code2prompt)
        require_bins code2prompt
        printf 'code2prompt\n'
        ;;
    *)
        die "unknown backend: $backend"
        ;;
    esac
}

ai_context_pack_main() {
    local backend="${1:-auto}"

    case "$backend" in
    auto | repomix | files-to-prompt | code2prompt)
        shift || true
        ;;
    --help | -h)
        ai_context_pack_usage
        exit 0
        ;;
    *)
        # Backward-compatible behaviour: first arg is probably a tool arg; use auto backend.
        backend="auto"
        ;;
    esac

    agent_session_init "pack-context"
    require_bins jq

    local root
    root="$(git_root)"
    local OUTPUT_DIR="${OUTPUT_DIR:-${AI_CONTEXT_DIR}/manual}"
    local OUTPUT_STYLE="${OUTPUT_STYLE:-xml}"
    local TOKEN_BUDGET="${TOKEN_BUDGET:-80000}"
    local timestamp
    timestamp="$(date +%Y%m%d-%H%M%S)"
    local OUTPUT_FILE="${OUTPUT_FILE:-${OUTPUT_DIR}/context-${timestamp}.${OUTPUT_STYLE}}"

    mkdir -p "$OUTPUT_DIR"

    local selected_backend
    selected_backend="$(ai_context_pack_select_backend "$backend")"

    section "Secrets scan"
    require_clean_secret_scan "$root"

    section "Pack context"
    log_info "Backend: $selected_backend"
    log_info "Output: $OUTPUT_FILE"

    case "$selected_backend" in
    repomix)
        local repomix_args=("$@")

        if ! ai_context_pack_args_contain_output "${repomix_args[@]+${repomix_args[@]}}"; then
            repomix_args+=(--output "$OUTPUT_FILE")
        fi

        if [[ "$OUTPUT_STYLE" != "" ]]; then
            repomix_args+=(--style "$OUTPUT_STYLE")
        fi

        (
            cd "$root"
            repomix "${repomix_args[@]}"
        )
        ;;
    files-to-prompt)
        (
            cd "$root"
            files-to-prompt "$@"
        ) >"$OUTPUT_FILE"
        ;;
    code2prompt)
        (
            cd "$root"
            code2prompt "$@"
        ) >"$OUTPUT_FILE"
        ;;
    *)
        die "unsupported selected backend: $selected_backend"
        ;;
    esac

    [[ -f "$OUTPUT_FILE" ]] || die "expected output file was not created: $OUTPUT_FILE"

    local tokens
    tokens="$(estimate_tokens "$OUTPUT_FILE")"

    if ! within_token_budget "$OUTPUT_FILE" "$TOKEN_BUDGET"; then
        log_warn "Context is ~${tokens} tokens, exceeding budget ${TOKEN_BUDGET}"
    else
        log_ok "Context packed: ~${tokens} tokens"
    fi

    local manifest="${OUTPUT_FILE%.*}.manifest.json"

    jq -n \
        --arg backend "$selected_backend" \
        --arg output "$OUTPUT_FILE" \
        --arg root "$root" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson tokens "$tokens" \
        --argjson token_budget "$TOKEN_BUDGET" \
        --argjson args "$(printf '%s\n' "$@" | jq -R . | jq -s .)" \
        '{
          backend: $backend,
          output: $output,
          root: $root,
          ts: $ts,
          estimated_tokens: $tokens,
          token_budget: $token_budget,
          args: $args
        }' >"$manifest"

    log_json "context.pack.manual" "$(cat "$manifest")"
    printf '%s\n' "$OUTPUT_FILE"
}
