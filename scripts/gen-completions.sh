#!/usr/bin/env bash
# Generate the committed shell-completion files under completions/ from the
# live command surface (libexec/internal/completion-spec, built from
# `sh-introspect --format=json` — never from parsing `--help` text).
#
# Usage:
#   bash scripts/gen-completions.sh
#
# Requires: jq
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cd -- "$repo_root"

output_dir="$repo_root/completions"
spec_file="$(mktemp)"
trap 'rm -f -- "$spec_file"' EXIT

mkdir -p -- "$output_dir"

bash "$repo_root/libexec/internal/completion-spec" >"$spec_file"

jq -e '
    .schema_version == 1 and
    (.commands | type == "array") and
    all(.commands[]; (.name | type == "string") and (.modes | type == "array") and (.flags | type == "array"))
' "$spec_file" >/dev/null

bash "$repo_root/scripts/completions/render-bash.sh" "$spec_file" >"$output_dir/agent-kit.bash"
bash "$repo_root/scripts/completions/render-zsh.sh" "$spec_file" >"$output_dir/_agent-kit"
bash "$repo_root/scripts/completions/render-fish.sh" "$spec_file" >"$output_dir/agent-kit.fish"

printf 'Generated Bash, Zsh and Fish completions in %s/\n' "$output_dir"
