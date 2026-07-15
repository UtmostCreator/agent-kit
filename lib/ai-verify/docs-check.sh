# shellcheck shell=bash
# Documentation quality checks (lint, links, drift) folded into the AI
# verification gate as `agent-kit verify docs`.
#
# This module is sourced by scripts/ai/ai-verify.sh's `verify docs` subcommand
# dispatch, near the top of that file, BEFORE the main --language pipeline is
# loaded; it is NOT an entrypoint and must not be executed directly. It relies
# on lib/common.sh already being sourced by the root loader before this file
# is sourced.
#
# Fused from the former standalone libexec/ai-doc-check (verify-cluster
# consolidation): behavior is byte-for-byte identical to that script, only the
# invocation surface changed (`agent-kit doc-check ...` ->
# `agent-kit verify docs ...`). Requires: lychee (for the links mode).
#
# Every helper here is prefixed ai_verify_docs_ (and AI_VERIFY_DOCS_ for the
# one process-global list variable) so sourcing this module into ai-verify's
# shared process can never silently override an unrelated same-named
# function/variable already defined by another lib/ai-verify/*.sh module --
# e.g. run_step already exists with a different implementation in
# lib/ai-verify/step-runner.sh, so ai-doc-check's own run_step is renamed here
# rather than reused bare.

ai_verify_docs_usage() {
    cat <<'EOF'
Usage:
  agent-kit verify docs [all|markdownlint|links|drift] [paths...]
  agent-kit verify docs --check [paths...]

Environment:
  DOC_PATHS="README.md docs/**/*.md"
  Link checks always run lychee with --offline.
EOF
}

# Generated/aggregated docs are gitignored build artifacts, not authored documentation.
# Their concatenated relative links resolve against the wrong base and produce false
# broken-link errors, so they are excluded from doc checks.
ai_verify_docs_is_excluded_path() {
    case "$1" in
        docs/ai/generated/* | ./docs/ai/generated/*)
            return 0
            ;;
    esac
    return 1
}

ai_verify_docs_resolve_paths() {
    local -a resolved=()

    if (($# > 0)); then
        local candidate
        for candidate in "$@"; do
            [[ -e "$candidate" ]] || continue
            ai_verify_docs_is_excluded_path "$candidate" && continue
            resolved+=("$candidate")
        done
    else
        local pattern
        for pattern in $DOC_PATHS; do
            if [[ -e "$pattern" ]]; then
                ai_verify_docs_is_excluded_path "$pattern" && continue
                resolved+=("$pattern")
                continue
            fi
            case "$pattern" in
                *[*?[]*) ;;
                *)
                    continue
                    ;;
            esac
            # Intentional glob expansion (globstar + nullglob enabled by the caller).
            # shellcheck disable=SC2206
            local -a matches=($pattern)
            if ((${#matches[@]} == 0)); then
                continue
            fi
            local match
            for match in "${matches[@]}"; do
                ai_verify_docs_is_excluded_path "$match" && continue
                resolved+=("$match")
            done
        done
    fi

    if ((${#resolved[@]} == 0)); then
        log_warn "no documentation paths found; skipping"
        return 0
    fi

    printf '%s\n' "${resolved[@]}"
}

# Renamed from the original script's bare `run_step` to avoid silently
# overriding lib/ai-verify/step-runner.sh's own run_step (different
# implementation: that one runs under the anti-freeze watchdog) once both are
# sourced into the same ai-verify process.
ai_verify_docs_run_step() {
    local label="$1"
    shift

    echo "==> $label"

    if ! "$@"; then
        echo "FAIL: $label" >&2
        failures=$((failures + 1))
    fi
}

ai_verify_docs_run_markdownlint() {
    if ((${#AI_VERIFY_DOCS_PATH_LIST[@]} == 0)); then
        return 0
    fi
    if command -v markdownlint >/dev/null 2>&1; then
        ai_verify_docs_run_step "markdownlint" markdownlint "${AI_VERIFY_DOCS_PATH_LIST[@]}"
    else
        log_warn "markdownlint not installed; skipping"
    fi
}

ai_verify_docs_run_links() {
    if ((${#AI_VERIFY_DOCS_PATH_LIST[@]} == 0)); then
        return 0
    fi
    if command -v lychee >/dev/null 2>&1; then
        # Accept 403/429: these mean the resource exists but blocks automated checks
        # (anti-bot / rate limiting), which must not be treated as a broken link.
        ai_verify_docs_run_step "lychee --offline" lychee --offline --accept "200..=299,403,429" "${AI_VERIFY_DOCS_PATH_LIST[@]}"
    else
        log_warn "lychee not installed; skipping"
    fi
}

ai_verify_docs_run_drift() {
    if [[ -f scripts/ai/repo-tool-inventory.sh ]]; then
        ai_verify_docs_run_step "repo-tool-inventory --check" bash scripts/ai/repo-tool-inventory.sh --check
    fi

    if [[ -f tools/ai/validate-generated-artifacts.php ]]; then
        ai_verify_docs_run_step "validate-generated-artifacts" php tools/ai/validate-generated-artifacts.php
    fi

    if [[ -f tools/ai/generate-agent-snippets.php ]]; then
        ai_verify_docs_run_step "agent-snippets --check" php tools/ai/generate-agent-snippets.php --check
    fi

    if [[ -f tools/ai/validate-context-budgets.php ]]; then
        ai_verify_docs_run_step "validate-context-budgets" php tools/ai/validate-context-budgets.php
    fi

    if [[ -f tools/ai/validate-agent-spec.php ]]; then
        ai_verify_docs_run_step "validate-agent-spec --self-test" php tools/ai/validate-agent-spec.php --self-test
    fi

    if [[ -f tools/ai/validate-stub-surfaces.php ]]; then
        ai_verify_docs_run_step "validate-stub-surfaces" php tools/ai/validate-stub-surfaces.php --root=.
    fi

    if [[ -f tools/ai/validate-catalog-drift.php ]]; then
        ai_verify_docs_run_step "validate-catalog-drift" php tools/ai/validate-catalog-drift.php --root=.
    fi

    if [[ -f tools/ai/validate-schemas.php ]]; then
        ai_verify_docs_run_step "validate-schemas" php tools/ai/validate-schemas.php --root=.
    fi

    if [[ -f tools/ai/validate-agent-assessment.php ]]; then
        ai_verify_docs_run_step "validate-agent-assessment" php tools/ai/validate-agent-assessment.php --root=.
    fi

    if [[ -f tools/ai/validate-agent-assessment-values.php && -f docs/ai/agent-scores.yaml ]]; then
        ai_verify_docs_run_step "validate-agent-assessment-values" php tools/ai/validate-agent-assessment-values.php --root=.
    fi

    if [[ -f tools/ai/validate-mentor-parity.php ]]; then
        ai_verify_docs_run_step "validate-mentor-parity" php tools/ai/validate-mentor-parity.php
    fi

    if [[ -f tools/ai/validate-script-access.php ]]; then
        ai_verify_docs_run_step "validate-script-access" php tools/ai/validate-script-access.php
    fi
}

# Entry point called by libexec/ai-verify's `verify docs` subcommand dispatch.
# Renamed from the original script's bare `main`. Preserves the original's
# exact control flow, including its direct `exit 1`/`exit 0`-free fallthrough
# on success (the caller wraps this with its own `exit $?`).
ai_verify_docs_main() {
    local mode="all"
    local DOC_PATHS="${DOC_PATHS:-README.md docs/**/*.md}"
    local failures=0
    # AI_VERIFY_DOCS_PATH_LIST is intentionally NOT local: it mirrors the
    # original script's process-global DOC_PATH_LIST, which
    # ai_verify_docs_run_markdownlint/ai_verify_docs_run_links (separate
    # top-level functions) read after this function populates it. The
    # AI_VERIFY_DOCS_ prefix keeps it out of the way of every other
    # lib/ai-verify/*.sh module's own globals.
    AI_VERIFY_DOCS_PATH_LIST=()

    if (($# > 0)); then
        case "$1" in
            all | markdownlint | links | drift)
                mode="$1"
                shift
                ;;
            --check)
                shift
                ;;
            --help | -h)
                ai_verify_docs_usage
                return 0
                ;;
            *)
                # A first argument that is neither a known mode/flag nor an existing
                # path is an unknown mode. Existing paths fall through as [paths...].
                if [[ ! -e "$1" ]]; then
                    ai_verify_docs_usage >&2
                    die "unknown mode: $1"
                fi
                ;;
        esac
    fi

    shopt -s nullglob globstar

    mapfile -t AI_VERIFY_DOCS_PATH_LIST < <(ai_verify_docs_resolve_paths "$@")

    agent_session_init "ai-doc-check"

    case "$mode" in
        all)
            ai_verify_docs_run_markdownlint
            ai_verify_docs_run_links
            ai_verify_docs_run_drift
            ;;
        markdownlint)
            ai_verify_docs_run_markdownlint
            ;;
        links)
            ai_verify_docs_run_links
            ;;
        drift)
            ai_verify_docs_run_drift
            ;;
        --help | -h)
            ai_verify_docs_usage
            ;;
        *)
            ai_verify_docs_usage
            die "unknown mode: $mode"
            ;;
    esac

    if ((failures > 0)); then
        log_json "doc-check.failed" "$(jq -cn --argjson failures "$failures" '{failures:$failures}')"
        exit 1
    fi

    log_json "doc-check.passed" "$(jq -cn --arg mode "$mode" '{mode:$mode}')"
    echo "==> docs ok"
}
