#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cd -- "$repo_root"

tag=${1:-}
if [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
    printf 'usage: %s vX.Y.Z\n' "$0" >&2
    exit 2
fi

version=${tag#v}
if [[ $(<VERSION) != "$version" ]]; then
    printf 'error: VERSION (%s) does not match tag (%s)\n' "$(<VERSION)" "$tag" >&2
    exit 1
fi

npm_version=$(jq -r '.version' package.json)
if [[ "$npm_version" != "$version" ]]; then
    printf 'error: package.json version (%s) does not match tag (%s)\n' "$npm_version" "$tag" >&2
    exit 1
fi

./scripts/check-publishable.sh

name="agent-kit-${version}"
dist="$repo_root/dist"
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
mkdir -p -- "$dist" "$stage/$name"
rm -f -- "$dist"/*

include=(
    bin lib libexec hooks integrations share docs
    README.md INSTALL.md AGENTS.md CLAUDE.md
    LICENSE NOTICE SECURITY.md SUPPORT.md CONTRIBUTING.md CHANGELOG.md VERSION
    install.sh uninstall.sh
)

for path in "${include[@]}"; do
    [[ -e "$path" ]] || continue
    cp -R -- "$path" "$stage/$name/"
done

find "$stage/$name" -type d -exec chmod 0755 {} +
find "$stage/$name" -type f -exec chmod 0644 {} +
find "$stage/$name/bin" "$stage/$name/libexec" "$stage/$name/hooks" -type f -exec chmod 0755 {} + 2>/dev/null || true
chmod 0755 "$stage/$name/install.sh" "$stage/$name/uninstall.sh"

# Deterministic tarball: fixed order, epoch mtimes, numeric 0 owner, and gzip
# without an embedded name/timestamp, so the archive (and its checksum) is
# reproducible across rebuilds of the same tag. Requires GNU tar (CI is Linux).
tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
    -C "$stage" -cf - "$name" | gzip -n > "$dist/$name.tar.gz"
(
    cd -- "$stage"
    zip -qr "$dist/$name.zip" "$name"
)
(
    cd -- "$dist"
    sha256sum "$name.tar.gz" "$name.zip" > SHA256SUMS
)

printf 'Created release files in %s\n' "$dist"
