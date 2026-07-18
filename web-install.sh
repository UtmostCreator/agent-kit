#!/usr/bin/env bash
# web-install.sh — one-line network installer for RestSift.
#
# Designed to be piped from the web:
#   curl -fsSL https://raw.githubusercontent.com/UtmostCreator/restsift/main/web-install.sh | bash
#
# It clones (or updates) the toolkit into a local cache, then runs the repo's
# own atomic install.sh. Everything is overridable by environment variable:
#   RESTSIFT_REPO    git URL      (default: https://github.com/UtmostCreator/restsift.git)
#   RESTSIFT_REF     git ref/tag  (default: newest v*.*.* release tag;
#                                  falls back to main if no release exists)
#   RESTSIFT_SRC     clone dir    (default: ${XDG_CACHE_HOME:-$HOME/.cache}/restsift/src)
#   RESTSIFT_PREFIX  install dir  (passed to install.sh --prefix)
#   RESTSIFT_BINDIR  bin dir      (passed to install.sh --bindir)
#
# Example:
#   curl -fsSL .../web-install.sh | RESTSIFT_REF=v0.1.0 bash   # pin a released tag

set -euo pipefail

# Backward-compat shim for the renamed env-var namespace (agent-kit → RestSift):
# honor a legacy AGENTKIT_* value as a deprecated default when its RESTSIFT_*
# replacement is unset, and warn once on stderr so callers migrate.
for _legacy in REPO REF SRC PREFIX BINDIR; do
    _old="AGENTKIT_${_legacy}"
    _new="RESTSIFT_${_legacy}"
    if [[ -n "${!_old:-}" && -z "${!_new:-}" ]]; then
        printf 'warning: %s is deprecated; use %s instead.\n' "$_old" "$_new" >&2
        printf -v "$_new" '%s' "${!_old}"
    fi
done
unset _legacy _old _new

repo=${RESTSIFT_REPO:-https://github.com/UtmostCreator/restsift.git}
src=${RESTSIFT_SRC:-${XDG_CACHE_HOME:-$HOME/.cache}/restsift/src}

for command in git bash rg jq; do
    command -v "$command" >/dev/null 2>&1 || {
        printf 'error: required command not found: %s\n' "$command" >&2
        exit 1
    }
done

# The toolkit needs Bash >= 4.4 (install.sh enforces it too, but this bootstrap
# runs first, so fail early with a clear message).
if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
    printf 'error: Bash 4.4 or newer is required (found %s)\n' "${BASH_VERSION:-unknown}" >&2
    exit 1
fi

# Stable-by-default: resolve the newest published v* release tag so a bare
# `curl … | bash` installs an immutable release, never mutable `main`. Override
# with RESTSIFT_REF (a tag, branch, or commit); RESTSIFT_REF=main is the
# explicit development path. Falls back to `main` only if no release exists yet.
if [[ -n "${RESTSIFT_REF:-}" ]]; then
    ref="$RESTSIFT_REF"
    ref_channel="requested"
else
    ref="$(git ls-remote --tags --refs --sort=-v:refname "$repo" 'v*.*.*' 2>/dev/null \
        | head -n1 | sed 's#.*refs/tags/##')"
    if [[ -n "$ref" ]]; then
        ref_channel="latest release"
    else
        ref="main"
        ref_channel="development (no release tag found)"
    fi
fi
printf 'RestSift installer: resolving %s -> %s\n' "$ref_channel" "$ref"

if [[ -d "$src/.git" ]]; then
    # Reuse the cache only if it points at the requested repo; otherwise re-clone
    # so a changed RESTSIFT_REPO is honored instead of silently ignored.
    existing_remote="$(git -C "$src" remote get-url origin 2>/dev/null || true)"
    if [[ "$existing_remote" != "$repo" ]]; then
        printf 'error: RESTSIFT_SRC already contains a checkout for a different remote.\n' >&2
        printf '       path: %s\n' "$src" >&2
        printf '       existing remote: %s\n' "${existing_remote:-none}" >&2
        printf '       requested remote: %s\n' "$repo" >&2
        printf '       Move that directory aside or choose another RESTSIFT_SRC.\n' >&2
        exit 1
    fi
fi

if [[ -d "$src/.git" ]]; then
    printf 'Updating existing checkout in %s\n' "$src"
    git -C "$src" fetch --depth=1 origin "$ref"
    git -C "$src" checkout --detach FETCH_HEAD
else
    mkdir -p -- "$(dirname -- "$src")"
    printf 'Cloning %s (%s) into %s\n' "$repo" "$ref" "$src"
    # Try the requested ref as a branch/tag first; if that fails, clone the repo
    # and resolve the ref explicitly. Never silently fall back to the default
    # branch — a requested pin that cannot be resolved must be a hard error.
    if ! git clone --depth=1 --branch "$ref" "$repo" "$src" 2>/dev/null; then
        git clone "$repo" "$src"
        git -C "$src" checkout --detach "$ref" 2>/dev/null || {
            printf 'error: could not resolve requested ref: %s\n' "$ref" >&2
            exit 1
        }
    fi
fi

printf 'RestSift installer: installing %s at commit %s\n' \
    "$ref" "$(git -C "$src" rev-parse --short HEAD 2>/dev/null || echo unknown)"

install_args=()
[[ -n "${RESTSIFT_PREFIX:-}" ]] && install_args+=(--prefix "$RESTSIFT_PREFIX")
[[ -n "${RESTSIFT_BINDIR:-}" ]] && install_args+=(--bindir "$RESTSIFT_BINDIR")

exec bash "$src/install.sh" "${install_args[@]}"
