#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./uninstall.sh [--prefix PATH] [--bindir PATH]
EOF
}

prefix=${XDG_DATA_HOME:-$HOME/.local/share}/agent-kit
bindir=$HOME/.local/bin

while (($# > 0)); do
    case "$1" in
        --prefix)
            (($# >= 2)) || {
                printf 'error: --prefix requires a path\n' >&2
                exit 2
            }
            prefix=$2
            shift 2
            ;;
        --bindir)
            (($# >= 2)) || {
                printf 'error: --bindir requires a path\n' >&2
                exit 2
            }
            bindir=$2
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            printf 'error: unknown argument: %s\n' "$1" >&2
            exit 2
            ;;
    esac
done

marker="$prefix/.agent-kit-install"
if [[ ! -f "$marker" ]] || [[ $(<"$marker") != 'agent-kit' ]]; then
    printf 'error: refusing to remove unmarked path: %s\n' "$prefix" >&2
    exit 1
fi

# Remove both the canonical `agent-kit` wrapper and the short `ak` alias.
# Identify our wrappers by their stable marker, not by the exec path: install.sh
# writes that path `printf %q`-escaped, so a literal path match fails whenever
# the prefix contains spaces or shell metacharacters.
for wrapper_name in agent-kit ak; do
    wrapper="$bindir/$wrapper_name"
    if [[ -f "$wrapper" ]] && grep -Fq -- '# agent-kit-wrapper' "$wrapper"; then
        rm -f -- "$wrapper"
    fi
done
rm -rf -- "$prefix"

# A project-local install (install.sh --project) nests both prefix and bindir
# as siblings under one dedicated folder (<project>/.agent-kit/{toolkit,bin}).
# rmdir only succeeds on a truly empty directory, so this is a no-op (not an
# error, thanks to the || true) for a global install, where bindir is a
# shared location (e.g. ~/.local/bin) that must never be removed, and for a
# project-local install where the user left other files alongside ours.
rmdir -- "$bindir" 2>/dev/null || true
prefix_parent=$(dirname -- "$prefix")
bindir_parent=$(dirname -- "$bindir")
if [[ "$prefix_parent" == "$bindir_parent" ]]; then
    rmdir -- "$prefix_parent" 2>/dev/null || true
fi

printf 'Removed AgentKit from %s\n' "$prefix"
