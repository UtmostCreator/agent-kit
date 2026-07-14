# shellcheck shell=bash
# ai-context/generate.sh — routes `context generate` to the isolated
# run-repomix-context engine.
#
# Sourced by libexec/ai-context (thin loader). Not an entrypoint.
#
# run-repomix-context and the repomix-context-tree/repomix-scc-router engines it
# calls stay process-isolated on purpose (see libexec/internal/README-equivalent
# note in libexec/ai-context's own header): repomix-context-tree's and
# repomix-scc-router's lib/*/helpers.sh each locally redefine die()/log()/
# estimate_tokens(), shadowing lib/common.sh's real versions for their OWN
# process only. Fusing their internals into this shared ai-context process would
# make whichever module's helpers.sh sourced last silently corrupt the other
# modes' die()/log()/estimate_tokens() for the rest of the invocation. So this
# function execs into the relocated (but otherwise byte-for-byte unchanged)
# libexec/internal/run-repomix-context script instead of calling a fused
# function, preserving its own secrets-scan/manifest-writing wrapper logic
# exactly as before.

ai_context_generate_main() {
    exec "${BASH:-bash}" "$AI_CONTEXT_LIBEXEC_DIR/internal/run-repomix-context" "$@"
}
