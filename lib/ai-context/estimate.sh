# shellcheck shell=bash
# ai-context/estimate.sh — estimate the context/token cost of a file or directory.
#
# Sourced by libexec/ai-context (thin loader). Not an entrypoint. Behavior is
# byte-for-byte identical to the previous standalone libexec/query-usage, just
# wrapped in ai_context_estimate_main() with a module-local usage name. The
# original file's early standalone --help/--introspect sh-introspect guards are
# dropped here (they only made sense for a directly-executed script); --help is
# still handled inline by the option loop below, matching every other fused
# ai-context mode. This module does not source lib/common.sh functionality
# directly (query-usage never did); it only uses plain shell builtins.

ai_context_estimate_usage() {
    cat <<'EOF'
Usage:
  agent-kit context estimate [path] [--multiplier <n>] [--multiplier-label <label>] [--reserved-output <n>]

Estimate the context/token cost of a PATH (file or directory). Prints bytes and
estimated token counts for budgeting context packs. Read-only.

[path] MUST be a real file or directory that exists on disk (defaults to ".").
This is NOT a symbol/usage/call-site search: a bare identifier like "MyClass"
will fail with "Path not found". To find where a symbol is used, run:
  bash scripts/ai/ai-search.sh text "MyClass" . --fixed
EOF
}

ai_context_estimate_main() {
    local TARGET='.'
    local MULTIPLIER='1'
    local LABEL='1x'
    local RESERVED_OUTPUT='4000'

    if (($# > 0)) && [[ "${1:-}" != --* ]]; then
        TARGET="$1"
        shift || true
    fi

    while (($# > 0)); do
        case "$1" in
        --multiplier)
            MULTIPLIER="$2"
            shift 2
            ;;
        --multiplier=*)
            MULTIPLIER="${1#*=}"
            shift
            ;;
        --multiplier-label)
            LABEL="$2"
            shift 2
            ;;
        --multiplier-label=*)
            LABEL="${1#*=}"
            shift
            ;;
        --reserved-output)
            RESERVED_OUTPUT="$2"
            shift 2
            ;;
        --reserved-output=*)
            RESERVED_OUTPUT="${1#*=}"
            shift
            ;;
        --help | -h)
            ai_context_estimate_usage
            return 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            ai_context_estimate_usage
            return 2
            ;;
        esac
    done

    [[ -e "$TARGET" ]] || {
        echo "Path not found: $TARGET" >&2
        echo "context estimate estimates the token cost of a PATH (file or directory), not a symbol." >&2
        echo "To search where a symbol is used, run: bash scripts/ai/ai-search.sh text \"$TARGET\" . --fixed" >&2
        return 1
    }

    local BYTES
    if [[ -d "$TARGET" ]]; then
        BYTES="$(git -C "$TARGET" ls-files -z 2>/dev/null | xargs -0 -I{} sh -c 'test -f "$1" && wc -c <"$1" || true' _ "$TARGET/{}" | awk '{s+=$1} END{print s+0}')"
        if [[ "$BYTES" == "0" ]]; then
            BYTES="$(rg --files "$TARGET" 2>/dev/null | xargs -I{} sh -c 'wc -c <"$1"' _ {} 2>/dev/null | awk '{s+=$1} END{print s+0}')"
        fi
    else
        BYTES="$(wc -c <"$TARGET")"
    fi

    local RAW_TOKENS WEIGHTED
    RAW_TOKENS="$(awk -v b="$BYTES" 'BEGIN { printf "%d", int((b + 3) / 4) }')"
    WEIGHTED="$(awk -v t="$RAW_TOKENS" -v m="$MULTIPLIER" 'BEGIN { printf "%.2f", t * m }')"

    cat <<EOF
query_usage:
  path: $TARGET
  bytes: $BYTES
  raw_estimated_tokens: $RAW_TOKENS
  multiplier_label: $LABEL
  multiplier: $MULTIPLIER
  weighted_usage: $WEIGHTED
  reserved_output_tokens: $RESERVED_OUTPUT
EOF
}
