#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./install.sh [--prefix PATH] [--bindir PATH] [--project [DIR]]

Global install (default):
  --prefix  ${XDG_DATA_HOME:-$HOME/.local/share}/restsift
  --bindir  $HOME/.local/bin

Project-local install (vendor the toolkit inside a repo):
  --project [DIR]   Install into <DIR>/<name>/{toolkit,bin}. DIR defaults to the
                    git top-level (else the current dir). The folder <name> is
                    configurable via RESTSIFT_DIR_NAME (default: .restsift), so a
                    repo can wire tools to one stable, renamable location.
                    Equivalent to:
                      --prefix <DIR>/.restsift/toolkit --bindir <DIR>/.restsift/bin
  Env: RESTSIFT_PROJECT_DIR=<DIR> also enables project mode; RESTSIFT_DIR_NAME
       overrides the folder name. An explicit --prefix always wins.
EOF
}

source_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

# Backward-compat shim for the renamed env-var namespace (agent-kit → RestSift):
# honor a legacy AGENTKIT_* value as a deprecated default when its RESTSIFT_*
# replacement is unset, and warn once on stderr so callers migrate.
for _legacy in DIR_NAME PROJECT_DIR FORCE; do
    _old="AGENTKIT_${_legacy}"
    _new="RESTSIFT_${_legacy}"
    if [[ -n "${!_old:-}" && -z "${!_new:-}" ]]; then
        printf 'warning: %s is deprecated; use %s instead.\n' "$_old" "$_new" >&2
        printf -v "$_new" '%s' "${!_old}"
    fi
done
unset _legacy _old _new

prefix=${XDG_DATA_HOME:-$HOME/.local/share}/restsift
bindir=$HOME/.local/bin
# Project-local install target. project_dir non-empty (via env or --project) routes
# the install into <project_dir>/<dir_name>/{toolkit,bin}. dir_name is configurable so
# consuming repos can rename the vendored folder without touching this installer.
project_dir=${RESTSIFT_PROJECT_DIR:-}
dir_name=${RESTSIFT_DIR_NAME:-.restsift}
prefix_explicit=0

while (($# > 0)); do
    case "$1" in
        --prefix)
            (($# >= 2)) || {
                printf 'error: --prefix requires a path\n' >&2
                exit 2
            }
            prefix=$2
            prefix_explicit=1
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
        --project)
            # Optional DIR value; a bare --project resolves to the git top-level / cwd.
            if (($# >= 2)) && [[ "$2" != -* ]]; then
                project_dir=$2
                shift 2
            else
                project_dir=${project_dir:-.}
                shift
            fi
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            printf 'error: unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

# Resolve a project-local install target into <project_dir>/<dir_name>/{toolkit,bin}.
# An explicit --prefix always overrides project mode.
if [[ -n "$project_dir" && "$prefix_explicit" == 0 ]]; then
    if [[ "$project_dir" == "." ]]; then
        project_dir=$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)
    fi
    [[ -d "$project_dir" ]] || {
        printf 'error: --project dir not found: %s\n' "$project_dir" >&2
        exit 2
    }
    project_dir=$(cd -- "$project_dir" && pwd -P)
    prefix="$project_dir/$dir_name/toolkit"
    bindir="$project_dir/$dir_name/bin"
    project_mode=1
fi

for command in bash git rg jq; do
    command -v "$command" >/dev/null 2>&1 || {
        printf 'error: required command not found: %s\n' "$command" >&2
        exit 1
    }
done

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
    printf 'error: Bash 4.4 or newer is required\n' >&2
    exit 1
fi

for required in bin/restsift lib libexec share; do
    [[ -e "$source_root/$required" ]] || {
        printf 'error: installer source is incomplete: missing %s\n' "$required" >&2
        exit 1
    }
done

prefix_parent=$(dirname -- "$prefix")
mkdir -p -- "$prefix_parent" "$bindir"
stage=$(mktemp -d "$prefix_parent/.restsift.install.XXXXXX")
backup=''
installed=0
wrapper_tmp=''
cleanup() {
    local rc=$?
    if ((rc != 0)) && ((installed == 1)); then
        rm -rf -- "$prefix"
        if [[ -n "$backup" && -e "$backup" ]]; then
            mv -- "$backup" "$prefix"
        fi
    fi
    rm -rf -- "$stage"
    [[ -n "$wrapper_tmp" ]] && rm -f -- "$wrapper_tmp"
}
trap cleanup EXIT

copy_paths=(bin lib libexec share completions hooks docs README.md INSTALL.md AGENTS.md CLAUDE.md LICENSE NOTICE SECURITY.md SUPPORT.md CONTRIBUTING.md CHANGELOG.md VERSION uninstall.sh)
for path in "${copy_paths[@]}"; do
    [[ -e "$source_root/$path" ]] || continue
    cp -R -- "$source_root/$path" "$stage/"
done
printf '%s\n' 'restsift' >"$stage/.restsift-install"

# Refuse to clobber a foreign command already installed as `$bindir/restsift` (the
# name is generic). Only overwrite our own wrapper unless RESTSIFT_FORCE=1. Do this
# before replacing the prefix so a rejected wrapper leaves the existing install intact.
wrapper_marker='# restsift-wrapper'
# The canonical `restsift`, its short alias `res`, and the deprecated
# `agent-kit`/`ak` compatibility aliases are all installed as wrappers; guard
# each generic name against clobbering a foreign command.
wrapper_names=(restsift res agent-kit ak)
for wrapper_name in "${wrapper_names[@]}"; do
    if [[ -e "$bindir/$wrapper_name" && "${RESTSIFT_FORCE:-0}" != "1" ]]; then
        # Accept our current marker OR the legacy `# agent-kit-wrapper` one so a
        # re-install over a pre-rename install migrates instead of refusing.
        if ! grep -Fq -e "$wrapper_marker" -e '# agent-kit-wrapper' "$bindir/$wrapper_name" 2>/dev/null; then
            printf 'error: %s already exists and is not a restsift wrapper.\n' "$bindir/$wrapper_name" >&2
            printf '       Remove it, choose another --bindir, or re-run with RESTSIFT_FORCE=1 to overwrite.\n' >&2
            exit 1
        fi
    fi
done

if [[ -e "$prefix" ]]; then
    backup="${prefix}.backup.$(date +%Y%m%d%H%M%S).$$"
    mv -- "$prefix" "$backup"
fi

if ! mv -- "$stage" "$prefix"; then
    [[ -n "$backup" && -e "$backup" ]] && mv -- "$backup" "$prefix"
    printf 'error: installation failed; previous installation restored when available\n' >&2
    exit 1
fi
installed=1

# Pin the wrappers to the Bash that ran this installer. We already verified it is
# >= 4.4 above, so the installed commands always launch the dispatcher under a
# capable interpreter (bin/restsift then propagates it to subcommands via "$BASH").
# This avoids macOS silently running everything under its 3.2 /bin/bash. The
# canonical `restsift` and its short alias `res` point straight at the
# dispatcher; the deprecated `agent-kit`/`ak` aliases point at their own
# warn-then-exec shim so they emit a deprecation notice on stderr.
for wrapper_name in "${wrapper_names[@]}"; do
    case "$wrapper_name" in
        agent-kit | ak) wrapper_target="bin/$wrapper_name" ;;
        *) wrapper_target="bin/restsift" ;;
    esac
    wrapper_tmp=$(mktemp "$bindir/.restsift.XXXXXX")
    cat >"$wrapper_tmp" <<EOF
#!/bin/sh
$wrapper_marker
exec $(printf '%q' "$BASH") $(printf '%q' "$prefix/$wrapper_target") "\$@"
EOF
    chmod 0755 "$wrapper_tmp"
    mv -f -- "$wrapper_tmp" "$bindir/$wrapper_name"
done

if [[ -n "$backup" && -e "$backup" ]]; then
    rm -rf -- "$backup"
fi
installed=0
trap - EXIT
cleanup

# Auto-wire generated completions into safe, standard drop-in directories (no
# rc-file edits): Fish auto-loads *.fish files from its completions dir, and
# the bash-completion package (if present) auto-sources files dropped into
# its XDG user directory. Zsh has no equivalent rc-free location, so it stays
# the documented manual `source <(restsift completion zsh)` step. Skipped for
# project-local installs -- vendoring a tool into one repo should not touch
# the user's global shell config.
if [[ "${project_mode:-0}" != 1 && -f "$prefix/completions/restsift.fish" ]]; then
    if command -v fish >/dev/null 2>&1 || [[ -d "${XDG_CONFIG_HOME:-$HOME/.config}/fish" ]]; then
        fish_completions_dir="${XDG_CONFIG_HOME:-$HOME/.config}/fish/completions"
        mkdir -p -- "$fish_completions_dir"
        cp -f -- "$prefix/completions/restsift.fish" "$fish_completions_dir/restsift.fish"
        # Fish's autoloader keys completion files off the COMMAND being
        # completed, one file per name (restsift.fish only ever loads for
        # `restsift <TAB>`). restsift.fish itself registers completions for
        # every name once loaded, but a session whose first tab-press is
        # against an alias never triggers it -- so drop a tiny stub per alias
        # (the new `res`, plus the deprecated `agent-kit`/`ak`) that sources
        # the real file, making `<alias> <TAB>` autoload it too.
        for _alias in res agent-kit ak; do
            printf 'source (dirname (status --current-filename))/restsift.fish\n' \
                >"$fish_completions_dir/$_alias.fish"
        done
        printf 'Installed Fish completion: %s/{restsift,res,agent-kit,ak}.fish\n' "$fish_completions_dir"
    fi
    if [[ -f "$prefix/completions/restsift.bash" ]]; then
        bash_completions_dir="${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion/completions"
        mkdir -p -- "$bash_completions_dir"
        cp -f -- "$prefix/completions/restsift.bash" "$bash_completions_dir/restsift"
        # Same per-command-filename autoload convention as Fish's: the
        # bash-completion package's dynamic loader looks up a file named after
        # the command being completed, so each alias needs its own file even
        # though restsift.bash registers every name once loaded.
        for _alias in res agent-kit ak; do
            cp -f -- "$prefix/completions/restsift.bash" "$bash_completions_dir/$_alias"
        done
        printf 'Installed Bash completion: %s/{restsift,res,agent-kit,ak} (auto-loads if bash-completion is set up)\n' "$bash_completions_dir"
    fi
fi

printf 'Installed RestSift to %s\n' "$prefix"
printf 'Commands: %s/restsift (short alias %s/res; deprecated: agent-kit, ak)\n' "$bindir" "$bindir"
if [[ "${project_mode:-0}" == 1 ]]; then
    printf 'Project-local install (%s). Invoke via %s/restsift, or wire your repo to %s.\n' \
        "$dir_name" "$bindir" "$prefix"
else
    case ":$PATH:" in
        *":$bindir:"*) ;;
        *) printf 'Add %s to PATH.\n' "$bindir" ;;
    esac
fi
