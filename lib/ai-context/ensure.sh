# shellcheck shell=bash
# ai-context/ensure.sh — ensure the Repomix context bundle is fresh before an
# agent relies on it.
#
# Sourced by libexec/ai-context (thin loader). Not an entrypoint. Behavior is
# byte-for-byte equivalent to the previous standalone libexec/repomix-ensure-fresh,
# wrapped in ai_context_ensure_main() with module-local helper names. The two
# scripts it used to shell out to by relative path are now called in-process:
# freshness checking calls ai_context_status_main() directly (fused in this same
# module set, see status.sh) and regeneration calls ai_context_generate_main()
# (generate.sh), which itself execs the relocated, still-process-isolated
# libexec/internal/run-repomix-context engine. Both calls run inside a subshell
# so a function that calls `exit`/`exec` internally only ends that subshell, not
# the whole ai-context process — matching the previous subprocess-call semantics.

ai_context_ensure_usage() {
    cat <<'EOF'
Usage:
  agent-kit context ensure [root] [--regen] [--no-regen]

Options:
  --regen        permit regeneration of stale/expired/missing context
  --no-regen     never regenerate; only report and recommend
  (env) REPOMIX_AUTO_REGEN=1   same as --regen
  (env) REPOMIX_WARN_DAYS / REPOMIX_MAX_DAYS   thresholds (default 2 / 7)

Behaviour:
  - fresh   -> exit 0
  - stale   -> exit 0 (recommend regen; regenerate only if permitted)
  - expired -> regenerate if permitted, else exit 3
  - missing -> regenerate if permitted, else exit 4
  Non-interactive without --regen/REPOMIX_AUTO_REGEN never prompts; it exits
  with a recommended command instead.

Regeneration always runs against the repository root only:
  agent-kit context generate .
EOF
}

# Regenerates the context bundle. Reads root_abs from the calling
# ai_context_ensure_main frame via bash's dynamic scoping.
ai_context_ensure_regenerate() {
    section "Regenerating Repomix context (root: $root_abs)"
    # Subshell: ai_context_generate_main execs into the relocated engine, so it
    # must not replace this process — only the subshell that runs it.
    if (cd "$root_abs" && SECRETS_SCAN=0 ai_context_generate_main .); then
        echo "OK: Repomix context regenerated"
        return 0
    fi
    die "Repomix context regeneration failed"
}

# Reads REGEN/ASSUME_NO from the calling ai_context_ensure_main frame via
# bash's dynamic scoping.
ai_context_ensure_want_regen() {
    if [[ "$REGEN" == "1" ]]; then
        return 0
    fi
    if [[ "$ASSUME_NO" == "1" ]]; then
        return 1
    fi
    # Interactive prompt only when attached to a TTY; never silent.
    if [[ -t 0 && -t 1 ]]; then
        printf 'Regenerate Repomix context now? [y/N] '
        local reply
        read -r reply || reply=""
        case "$reply" in
            y | Y | yes | YES) return 0 ;;
            *) return 1 ;;
        esac
    fi
    # Non-interactive and not explicitly permitted: do not prompt, do not regen.
    return 1
}

ai_context_ensure_main() {
    local ROOT="."
    local REGEN="${REPOMIX_AUTO_REGEN:-0}" # 1 = allowed to regenerate without prompt
    local ASSUME_NO="0"

    local args=()
    local arg
    for arg in "$@"; do
        case "$arg" in
            --help | -h)
                ai_context_ensure_usage
                return 0
                ;;
            --regen)
                REGEN="1"
                ;;
            --no-regen)
                REGEN="0"
                ASSUME_NO="1"
                ;;
            *)
                args+=("$arg")
                ;;
        esac
    done
    if [[ ${#args[@]} -gt 0 ]]; then
        ROOT="${args[0]}"
    fi

    local root_abs
    root_abs="$(cd "$ROOT" && pwd)"
    local regen_cmd="agent-kit context generate ."

    # Determine freshness state via the dedicated checker (deterministic exit codes).
    set +e
    local freshness_out freshness_code
    freshness_out="$(AI_OUTPUT=text ai_context_status_main "$root_abs" 2>&1)"
    freshness_code=$?
    set -e

    local state="unknown"
    case "$freshness_code" in
        0)
            # fresh or stale; distinguish by message
            if printf '%s' "$freshness_out" | head -n1 | grep -qi '^stale'; then
                state="stale"
            else
                state="fresh"
            fi
            ;;
        3) state="expired" ;;
        4) state="missing" ;;
        *) state="unknown" ;;
    esac

    printf '%s\n' "$freshness_out"

    case "$state" in
        fresh)
            return 0
            ;;
        stale)
            # Usable; recommend regen but never force it.
            if ai_context_ensure_want_regen; then
                ai_context_ensure_regenerate
            else
                echo "recommend: $regen_cmd"
            fi
            return 0
            ;;
        expired | missing)
            if ai_context_ensure_want_regen; then
                ai_context_ensure_regenerate
                return 0
            fi
            echo "recommend: $regen_cmd"
            echo "Repomix context is ${state}; not regenerated (no permission). Provide --regen or run the command above."
            [[ "$state" == "expired" ]] && return 3
            return 4
            ;;
        *)
            echo "recommend: $regen_cmd"
            return 1
            ;;
    esac
}
