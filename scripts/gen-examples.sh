#!/usr/bin/env bash
# Generate docs/EXAMPLES.md from each command's own `# Example:` block.
#
# The examples are the single source of truth (they live in each libexec/*
# script header and drive `--help`), so this file is always derivable — never
# hand-edit docs/EXAMPLES.md.
#
# Usage:
#   bash scripts/gen-examples.sh > docs/EXAMPLES.md
#
# Requires: jq
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
introspect="$repo_root/libexec/sh-introspect"

cat <<'EOF'
# Examples

One runnable example per command, generated from each command's own `# Example:`
block.

These snippets use the short **`akit`** alias. Enable it once (add to your shell
rc), then every example below works verbatim:

```bash
alias akit='agent-kit'
```

The canonical command is `agent-kit` — if you have not set the alias, replace
`akit` with `agent-kit`. The authoritative contract for any command is always
`agent-kit <command> --help` (and `--introspect` for JSON).

> Regenerate this file with: `bash scripts/gen-examples.sh > docs/EXAMPLES.md`

EOF

first=1
while IFS= read -r f; do
    name=$(basename "$f")
    json=$(bash "$introspect" --format=json "$f" 2>/dev/null || true)
    [[ -n "$json" ]] || continue
    desc=$(printf '%s' "$json" | jq -r '.description // ""')
    # One blank line BEFORE each block (except the first) — avoids a trailing
    # blank line at end-of-file that would trip `git diff --check`.
    ((first)) || printf '\n'
    first=0
    printf '### `akit %s`\n' "${name#ai-}"
    [[ -n "$desc" ]] && printf '%s\n' "$desc"
    printf '\n```bash\n'
    # Examples are authored with the canonical `agent-kit`; render the short
    # alias form here (safe: example lines contain only the command invocation).
    printf '%s' "$json" | jq -r '.examples[]?' | sed -E 's/\bagent-kit /akit /g'
    printf '```\n'
done < <(find "$repo_root/libexec" -maxdepth 1 -type f | sort)
