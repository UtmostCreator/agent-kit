# shellcheck shell=bash
# ai-context/status.sh — check freshness of the generated Repomix context bundle.
#
# Sourced by libexec/ai-context (thin loader). Not an entrypoint. Behavior is
# byte-for-byte identical to the previous standalone libexec/repomix-freshness,
# just wrapped in ai_context_status_main() with module-local helper names.

ai_context_status_usage() {
    cat <<'EOF'
Usage:
  restsift context status [root]

Options (env):
  REPOMIX_WARN_DAYS   warn threshold in days (default 2)
  REPOMIX_MAX_DAYS    block threshold in days (default 7)
  AI_OUTPUT=json      emit a JSON envelope instead of text

Exit codes:
  0  fresh or warn (usable)
  3  expired (older than REPOMIX_MAX_DAYS) — regenerate before use
  4  missing manifest — generate context first

Regenerate with:
  restsift context generate .
EOF
}

# emit STATUS AGE_SECONDS MESSAGE
# Reads WARN_DAYS/MAX_DAYS/OUTPUT/manifest/regen_cmd from the calling
# ai_context_status_main frame via bash's dynamic scoping.
ai_context_status_emit() {
    local status="$1" age_seconds="$2" message="$3"
    if [[ "$OUTPUT" == "json" ]]; then
        jq -n \
            --arg schema "1" \
            --arg tool "repomix-freshness" \
            --arg status "$status" \
            --arg manifest "$manifest" \
            --argjson age_seconds "${age_seconds:-0}" \
            --argjson warn_days "$WARN_DAYS" \
            --argjson max_days "$MAX_DAYS" \
            --arg regenerate "$regen_cmd" \
            --arg message "$message" \
            '{schema:$schema, tool:$tool, status:$status, manifest:$manifest, age_seconds:$age_seconds, warn_days:$warn_days, max_days:$max_days, regenerate:$regenerate, message:$message}'
    else
        printf '%s: %s\n' "$status" "$message"
        if [[ "$status" != "fresh" ]]; then
            printf 'regenerate: %s\n' "$regen_cmd"
        fi
    fi
}

ai_context_status_main() {
    local WARN_DAYS="${REPOMIX_WARN_DAYS:-2}"
    local MAX_DAYS="${REPOMIX_MAX_DAYS:-7}"
    local OUTPUT="${AI_OUTPUT:-text}"
    local ROOT="."

    case "${1:-}" in
        --help | -h)
            ai_context_status_usage
            return 0
            ;;
        "") ;;
        *)
            ROOT="$1"
            ;;
    esac

    local context_dir="${AI_CONTEXT_DIR:-.repomix-context}"
    local regen_cmd="restsift context generate ."
    local manifest

    # A nonexistent root has no manifest; emit the same clean missing-manifest
    # message (exit 4) instead of leaking a raw bash `cd: ... No such file` trace.
    local root_abs
    if ! root_abs="$(cd "$ROOT" 2>/dev/null && pwd)"; then
        manifest="$context_dir/tree-context/run-manifest.json"
        ai_context_status_emit "missing" 0 "root path not found: $ROOT"
        return 4
    fi
    manifest="$root_abs/$context_dir/tree-context/run-manifest.json"

    if [[ ! -f "$manifest" ]]; then
        ai_context_status_emit "missing" 0 "no Repomix context manifest at $context_dir/tree-context/run-manifest.json"
        return 4
    fi

    local ts
    ts="$(jq -r '.ts // empty' "$manifest" 2>/dev/null || true)"
    if [[ -z "$ts" ]]; then
        ai_context_status_emit "missing" 0 "Repomix manifest has no ts field; treat as stale"
        return 4
    fi

    # Parse the manifest timestamp (UTC ISO8601) to epoch seconds, portably.
    local gen_epoch
    if gen_epoch="$(date -u -d "$ts" +%s 2>/dev/null)"; then
        :
    elif gen_epoch="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null)"; then
        :
    else
        ai_context_status_emit "missing" 0 "could not parse manifest ts '$ts'; treat as stale"
        return 4
    fi

    local now_epoch age_seconds
    now_epoch="$(date -u +%s)"
    age_seconds=$((now_epoch - gen_epoch))
    [[ "$age_seconds" -lt 0 ]] && age_seconds=0

    local warn_seconds=$((WARN_DAYS * 86400))
    local max_seconds=$((MAX_DAYS * 86400))
    local age_days=$((age_seconds / 86400))

    if [[ "$age_seconds" -gt "$max_seconds" ]]; then
        ai_context_status_emit "expired" "$age_seconds" "Repomix context is ${age_days}d old (> ${MAX_DAYS}d); do not use — regenerate first"
        return 3
    fi

    if [[ "$age_seconds" -ge "$warn_seconds" ]]; then
        ai_context_status_emit "stale" "$age_seconds" "Repomix context is ${age_days}d old (>= ${WARN_DAYS}d); consider regenerating"
        return 0
    fi

    ai_context_status_emit "fresh" "$age_seconds" "Repomix context is ${age_days}d old (< ${WARN_DAYS}d); OK to use"
    return 0
}
