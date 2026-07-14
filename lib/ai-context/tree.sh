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
    exec "${BASH:-bash}" "$AI_CONTEXT_LIBEXEC_DIR/internal/repomix-context-tree" "$@"
}
