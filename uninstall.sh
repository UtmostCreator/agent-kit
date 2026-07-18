#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./uninstall.sh [--prefix PATH] [--bindir PATH]
EOF
}

default_prefix=${XDG_DATA_HOME:-$HOME/.local/share}/restsift
default_bindir=$HOME/.local/bin
prefix=$default_prefix
bindir=$default_bindir

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

# Accept the current `.restsift-install` marker OR the legacy
# `.agent-kit-install` one (content `agent-kit`) so a pre-rename install can
# still be cleanly removed.
marker="$prefix/.restsift-install"
legacy_marker="$prefix/.agent-kit-install"
if { [[ ! -f "$marker" ]] || [[ $(<"$marker") != 'restsift' ]]; } &&
    { [[ ! -f "$legacy_marker" ]] || [[ $(<"$legacy_marker") != 'agent-kit' ]]; }; then
    printf 'error: refusing to remove unmarked path: %s\n' "$prefix" >&2
    exit 1
fi

# Remove the canonical `restsift` wrapper, its short alias `res`, and the
# deprecated `agent-kit`/`ak` aliases. Identify our wrappers by their stable
# marker (current or legacy), not by the exec path: install.sh writes that path
# `printf %q`-escaped, so a literal path match fails whenever the prefix
# contains spaces or shell metacharacters.
for wrapper_name in restsift res agent-kit ak; do
    wrapper="$bindir/$wrapper_name"
    if [[ -f "$wrapper" ]] && grep -Fq -e '# restsift-wrapper' -e '# agent-kit-wrapper' "$wrapper"; then
        rm -f -- "$wrapper"
    fi
done
rm -rf -- "$prefix"

# install.sh only auto-drops Fish/Bash completions for the standard global
# install (never for --project, which always uses a different prefix/bindir
# pair). Mirror that exact condition here via the same signal -- prefix and
# bindir still at their un-overridden defaults -- so a project-local
# uninstall (explicit --prefix/--bindir) never touches these shared,
# possibly-unrelated files.
if [[ "$prefix" == "$default_prefix" && "$bindir" == "$default_bindir" ]]; then
    fish_completions_dir="${XDG_CONFIG_HOME:-$HOME/.config}/fish/completions"
    rm -f -- "$fish_completions_dir/restsift.fish" "$fish_completions_dir/res.fish" \
        "$fish_completions_dir/agent-kit.fish" "$fish_completions_dir/ak.fish"
    bash_completions_dir="${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion/completions"
    rm -f -- "$bash_completions_dir/restsift" "$bash_completions_dir/res" \
        "$bash_completions_dir/agent-kit" "$bash_completions_dir/ak"
fi

# A project-local install (install.sh --project) nests both prefix and bindir
# as siblings under one dedicated folder (<project>/.restsift/{toolkit,bin}).
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

printf 'Removed RestSift from %s\n' "$prefix"
