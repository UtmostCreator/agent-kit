# shellcheck shell=bash
# shellcheck disable=SC2034  # COMMON_OPTION_CONSUMED is read via dynamic scope by lib/ai-diff-context/helpers.sh's parse_common_option(), matching the pre-existing baseline warning in libexec/ai-diff-context
# ai-context/diff.sh — packs changed/targeted files into diff-scoped context bundles.
#
# Sourced by libexec/ai-context (thin loader). Not an entrypoint.
#
# This module re-sources the EXISTING lib/ai-diff-context/{helpers,commands,main}.sh
# modules unchanged (they already share a process with lib/common.sh's real
# die()/log()/estimate_tokens(), unlike the repomix-context-tree/repomix-scc-router
# engines, so they are collision-safe to fuse here) rather than hand-duplicating
# their ~395 lines of file-collection/packing logic.
#
# lib/ai-diff-context/main.sh's ai_diff_context_main() calls a bare `usage`
# function (resolved dynamically, not statically) for its own --help/error
# paths. Because multiple ai-context modules each need their own `usage`-style
# help text, ai_context_diff_main() below (re)binds the global `usage` name to
# this mode's help text immediately before delegating, rather than defining a
# permanent top-level `usage()` here that could be silently overwritten by
# whichever ai-context module happens to be sourced last.

AI_CONTEXT_DIFF_DIR="${AI_CONTEXT_LIBEXEC_DIR}/../lib/ai-diff-context"

# shellcheck source=lib/ai-diff-context/helpers.sh
source "$AI_CONTEXT_DIFF_DIR/helpers.sh"
# shellcheck source=lib/ai-diff-context/commands.sh
source "$AI_CONTEXT_DIFF_DIR/commands.sh"
# shellcheck source=lib/ai-diff-context/main.sh
source "$AI_CONTEXT_DIFF_DIR/main.sh"

ai_context_diff_usage() {
    cat <<'EOF'
Usage:
  restsift context diff since <ref> [options]
  restsift context diff unstaged [options]
  restsift context diff pr <number> [options]
  restsift context diff recent [--count N] [options]
  restsift context diff touched <pattern> [options]

Options:
  --include-diffs         Include git diff / PR diff as context artifact
  --no-tests              Do not include related tests
  --no-secrets-scan       Disable gitleaks scan
  --dry-run               Show selected files and estimated tokens only
  --strict                Fail when output exceeds token budget
  --token-budget N        Override TOKEN_BUDGET
  --split SIZE            Pass --split-output SIZE to repomix when available
  --help                  Show help

Environment:
  TOKEN_BUDGET=80000
  INCLUDE_TESTS=1
  INCLUDE_DIFFS=0
  DRY_RUN=0
  STRICT_TOKENS=0
  SPLIT_OUTPUT=
  TOKEN_ESTIMATOR_CMD=custom-token-counter

Exit codes:
  0  ok — bundle written (or help shown)
  1  usage error (missing/unknown subcommand) or packing failure
EOF
}

ai_context_diff_main() {
    local TOKEN_BUDGET="${TOKEN_BUDGET:-80000}"
    local OUTPUT_DIR="${OUTPUT_DIR:-${AI_CONTEXT_DIR}/diff}"
    local INCLUDE_TESTS="${INCLUDE_TESTS:-1}"
    local SECRETS_SCAN="${SECRETS_SCAN:-1}"
    local INCLUDE_DIFFS="${INCLUDE_DIFFS:-0}"
    local DRY_RUN="${DRY_RUN:-0}"
    local STRICT_TOKENS="${STRICT_TOKENS:-0}"
    local SPLIT_OUTPUT="${SPLIT_OUTPUT:-}"
    local COMMON_OPTION_CONSUMED=0

    # Bind the bare `usage` name lib/ai-diff-context/main.sh's dispatch relies
    # on to this mode's help text for the duration of this call only.
    usage() { ai_context_diff_usage; }

    # The shared dispatch prints usage + exit 1 for a missing subcommand but
    # emits no diagnostic; surface an explicit stderr line first so a bare
    # `context diff` says what was wrong. (Unknown subcommands already get a
    # `[ERROR] unknown command: X` line from the shared dispatch's die.) The
    # delegation below is left intact so session-init and the exit-1 path run
    # exactly as before.
    if (($# == 0)); then
        printf 'error: a diff subcommand is required (expected since|unstaged|pr|recent|touched)\n' >&2
    fi

    ai_diff_context_main "$@"
}
