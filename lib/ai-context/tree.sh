# shellcheck shell=bash
# ai-context/tree.sh — routes `context tree` to the isolated repomix-context-tree
# engine.
#
# Sourced by libexec/ai-context (thin loader). Not an entrypoint.
#
# repomix-context-tree stays process-isolated on purpose: its lib/repomix-context-tree/
# helpers.sh locally redefines die()/log()/estimate_tokens(), shadowing
# lib/common.sh's real versions for its OWN process only. See generate.sh's
# header comment for the full collision rationale (repomix-scc-router has the
# same issue and stays unwired from any public subcommand entirely, per
# TODO/public-command-surface-consolidation.md section 4). This function execs
# into the relocated (but otherwise byte-for-byte unchanged)
# libexec/internal/repomix-context-tree script instead of calling a fused
# function.

ai_context_tree_main() {
    # The isolated engine runs its secrets scan BEFORE validating the
    # subcommand, so a plain typo (`context tree badsub`) surfaces an unrelated
    # "secrets detected" message. Pre-validate the subcommand here — in this
    # command's own wrapper, without touching the shared engine — so a mistyped
    # subcommand gets a targeted error. Only a non-flag first token that is not a
    # known subcommand is rejected; empty args and flags (incl. --help/-h) are
    # left to the engine so its usage/exit-0 and option handling are unchanged.
    case "${1:-}" in
        '' | -*) ;;
        analyze | plan | pack | all | clean | purge) ;;
        *)
            printf 'error: unknown tree subcommand: %s (expected analyze|plan|pack|all|clean|purge)\n' "$1" >&2
            printf 'run: restsift context tree --help\n' >&2
            return 2
            ;;
    esac
    exec "${BASH:-bash}" "$AI_CONTEXT_LIBEXEC_DIR/internal/repomix-context-tree" "$@"
}
