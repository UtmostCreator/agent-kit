# scripts/lib/cov-hook.sh
# shellcheck shell=bash
#
# Native Bash line-coverage collector, sourced automatically via BASH_ENV by
# every non-interactive Bash process spawned while ./scripts/coverage.sh runs.
# No kcov/ptrace dependency: kcov's bash tracer requires PTRACE_TRACEME,
# which fails with EPERM in seccomp-restricted sandboxes/containers (verified
# on this host). This hook uses only Bash's own DEBUG trap instead.
#
# Why BASH_ENV: bin/agent-kit resolves a subcommand and `exec`s a fresh Bash
# process per libexec/* script, replacing the process image, so a DEBUG trap
# set in the parent would not survive. BASH_ENV is re-read by every new
# non-interactive Bash on startup, so exporting it re-installs this hook
# across each exec boundary. Within a single process, `set -o functrace`
# carries the DEBUG trap into `source`d lib/*.sh modules and shell functions.
#
# KNOWN LIMITATION: `functrace` (`-T`) makes Bash inherit BOTH DEBUG and
# RETURN traps into called functions -- there's no way to opt into DEBUG-only
# inheritance. A function that sets its own scoped `trap '...' RETURN` for
# cleanup (e.g. check_jscpd in lib/ai-verify/duplication.sh, which does
# `trap "rm -rf '$report_dir'" RETURN`) will have that trap ALSO fire when
# any function it calls returns (e.g. run_with_timeout), deleting the
# directory before the caller checks it. This is a tracer artifact, not a
# source bug: confirmed via direct instrumentation that the file is written
# and present, then gone by the time check_jscpd inspects it, only when this
# hook's DEBUG trap is active. `./scripts/check.sh` (the real CI gate) never
# uses this hook, so it is unaffected; only `./scripts/coverage.sh` runs can
# hit this, and only for code with this specific pattern (scoped RETURN trap
# + a nested function call). If a `warning: test exited non-zero` appears for
# a file using this pattern, verify with a plain `bash test/test-X.sh` before
# assuming a regression.
if [[ -n ${AK_COV_DIR:-} && -z ${AK_COV_HOOKED:-} ]]; then
    # Deliberately NOT exported: BASH_ENV is read once per new Bash process,
    # so each process (including ones bin/agent-kit `exec`s into) needs its
    # own fresh, unset AK_COV_HOOKED to re-install the trap. Exporting it
    # would leak "already hooked" into every child via the environment and
    # silently stop coverage collection at the first exec boundary.
    AK_COV_HOOKED=1
    exec {AK_COV_FD}>>"$AK_COV_DIR/$$.cov"
    set -o functrace
    _ak_cov_trap() {
        [[ $1 == "$AK_COV_ROOT"/* ]] || return 0
        printf '%s\t%s\n' "$1" "$2" >&"$AK_COV_FD"
    }
    # ${BASH_SOURCE:-} guards against `set -u` scripts: at the outermost
    # level of a `bash -c '...'` string (before any source/function call),
    # BASH_SOURCE is unset, and an unguarded reference here would abort any
    # instrumented script that has `nounset` on (e.g. lib/common.sh).
    trap '_ak_cov_trap "${BASH_SOURCE:-}" "$LINENO"' DEBUG
fi
