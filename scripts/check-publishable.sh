#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cd -- "$repo_root"

fail=0

reject_tracked() {
    local pattern=$1
    local description=$2
    local matches
    matches=$(git ls-files | grep -E -- "$pattern" || true)
    if [[ -n "$matches" ]]; then
        printf 'error: tracked %s:\n%s\n' "$description" "$matches" >&2
        fail=1
    fi
}

reject_tracked '(^|/)\.ai-logs(/|$)' 'agent/session logs'
reject_tracked '(^|/)\.env($|\.)' 'environment files'
reject_tracked '\.(pem|p12|pfx|key)$' 'private-key material'
reject_tracked '(^|/)(tmp|\.tmp|\.cache|artifacts|coverage)(/|$)' 'generated output directories'
reject_tracked '(session\.jsonl|edit-session\.json|repomix-output\.)' 'generated context/session artifacts'

required=(README.md LICENSE SECURITY.md CONTRIBUTING.md AGENTS.md VERSION install.sh uninstall.sh)
for file in "${required[@]}"; do
    if [[ ! -s "$file" ]]; then
        printf 'error: required publication file is missing or empty: %s\n' "$file" >&2
        fail=1
    fi
done

while IFS= read -r -d '' file; do
    if grep -Iq . -- "$file" && grep -nE -- '(-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16})' "$file"; then
        printf 'error: possible credential in tracked file: %s\n' "$file" >&2
        fail=1
    fi
done < <(git ls-files -z)

if ((fail != 0)); then
    exit 1
fi

printf 'Publication boundary checks passed.\n'
