#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./install.sh [--prefix PATH] [--bindir PATH] [--project [DIR]]

Global install (default):
  --prefix  ${XDG_DATA_HOME:-$HOME/.local/share}/agent-kit
  --bindir  $HOME/.local/bin

Project-local install (vendor the toolkit inside a repo):
  --project [DIR]   Install into <DIR>/<name>/{toolkit,bin}. DIR defaults to the
                    git top-level (else the current dir). The folder <name> is
                    configurable via AGENTKIT_DIR_NAME (default: .agent-kit), so a
                    repo can wire tools to one stable, renamable location.
                    Equivalent to:
                      --prefix <DIR>/.agent-kit/toolkit --bindir <DIR>/.agent-kit/bin
  Env: AGENTKIT_PROJECT_DIR=<DIR> also enables project mode; AGENTKIT_DIR_NAME
       overrides the folder name. An explicit --prefix always wins.
EOF
}

source_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
prefix=${XDG_DATA_HOME:-$HOME/.local/share}/agent-kit
bindir=$HOME/.local/bin
# Project-local install target. project_dir non-empty (via env or --project) routes
# the install into <project_dir>/<dir_name>/{toolkit,bin}. dir_name is configurable so
# consuming repos can rename the vendored folder without touching this installer.
project_dir=${AGENTKIT_PROJECT_DIR:-}
dir_name=${AGENTKIT_DIR_NAME:-.agent-kit}
prefix_explicit=0

while (($# > 0)); do
    case "$1" in
        --prefix)
            (($# >= 2)) || { printf 'error: --prefix requires a path\n' >&2; exit 2; }
            prefix=$2
            prefix_explicit=1
            shift 2
            ;;
        --bindir)
            (($# >= 2)) || { printf 'error: --bindir requires a path\n' >&2; exit 2; }
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
        -h|--help)
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
    [[ -d "$project_dir" ]] || { printf 'error: --project dir not found: %s\n' "$project_dir" >&2; exit 2; }
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

for required in bin/agent-kit lib libexec share; do
    [[ -e "$source_root/$required" ]] || {
        printf 'error: installer source is incomplete: missing %s\n' "$required" >&2
        exit 1
    }
done

prefix_parent=$(dirname -- "$prefix")
mkdir -p -- "$prefix_parent" "$bindir"
stage=$(mktemp -d "$prefix_parent/.agent-kit.install.XXXXXX")
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

copy_paths=(bin lib libexec share hooks integrations docs README.md INSTALL.md AGENTS.md CLAUDE.md LICENSE NOTICE SECURITY.md SUPPORT.md CONTRIBUTING.md CHANGELOG.md VERSION uninstall.sh)
for path in "${copy_paths[@]}"; do
    [[ -e "$source_root/$path" ]] || continue
    cp -R -- "$source_root/$path" "$stage/"
done
printf '%s\n' 'agent-kit' > "$stage/.agent-kit-install"

# Refuse to clobber a foreign command already installed as `$bindir/agent-kit` (the
# name is generic). Only overwrite our own wrapper unless AGENTKIT_FORCE=1. Do this
# before replacing the prefix so a rejected wrapper leaves the existing install intact.
wrapper_marker='# agent-kit-wrapper'
if [[ -e "$bindir/agent-kit" && "${AGENTKIT_FORCE:-0}" != "1" ]]; then
    if ! grep -Fq -- "$wrapper_marker" "$bindir/agent-kit" 2>/dev/null; then
        printf 'error: %s already exists and is not an agent-kit wrapper.\n' "$bindir/agent-kit" >&2
        printf '       Remove it, choose another --bindir, or re-run with AGENTKIT_FORCE=1 to overwrite.\n' >&2
        exit 1
    fi
fi

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

wrapper_tmp=$(mktemp "$bindir/.agent-kit.XXXXXX")
# Pin the wrapper to the Bash that ran this installer. We already verified it is
# >= 4.4 above, so the installed `agent-kit` always launches the dispatcher under a
# capable interpreter (bin/agent-kit then propagates it to subcommands via "$BASH").
# This avoids macOS silently running everything under its 3.2 /bin/bash.
cat > "$wrapper_tmp" <<EOF
#!/bin/sh
$wrapper_marker
exec $(printf '%q' "$BASH") $(printf '%q' "$prefix/bin/agent-kit") "\$@"
EOF
chmod 0755 "$wrapper_tmp"
mv -f -- "$wrapper_tmp" "$bindir/agent-kit"

if [[ -n "$backup" && -e "$backup" ]]; then
    rm -rf -- "$backup"
fi
installed=0
trap - EXIT
cleanup

printf 'Installed AgentKit to %s\n' "$prefix"
printf 'Command: %s/agent-kit\n' "$bindir"
if [[ "${project_mode:-0}" == 1 ]]; then
    printf 'Project-local install (%s). Invoke via %s/agent-kit, or wire your repo to %s.\n' \
        "$dir_name" "$bindir" "$prefix"
else
    case ":$PATH:" in
        *":$bindir:"*) ;;
        *) printf 'Add %s to PATH.\n' "$bindir" ;;
    esac
fi
