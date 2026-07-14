#!/usr/bin/env bash
set -euo pipefail

BASH_BIN="${BASH_BIN:-$(command -v bash)}"
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/libexec/preview-file"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/app" "$tmp/node_modules/pkg" "$tmp/.git"

cat > "$tmp/app/UserService.php" <<'PHP'
<?php
class UserService {
    public function login() {
        return true;
    }

    public function logout() {
        return true;
    }
}
PHP

# Help must work without a file.
"$BASH_BIN" "$script" --help >/dev/null

# Default/plain preview.
"$BASH_BIN" "$script" "$tmp/app/UserService.php" --lines 3 | grep -q 'UserService'

# Range preview.
"$BASH_BIN" "$script" "$tmp/app/UserService.php" --range 3:5 | grep -q 'login'

# Around preview.
"$BASH_BIN" "$script" "$tmp/app/UserService.php" --around 7 --context 1 | grep -q 'logout'

# JSON envelope.
AI_OUTPUT=json "$BASH_BIN" "$script" "$tmp/app/UserService.php" --lines 4 \
    | jq -e '
        .schema == "1"
        and .status == "ok"
        and .tool == "preview-file"
        and .path != ""
        and (.content | contains("UserService"))
        and (.warnings | type == "array")
        and (.errors | type == "array")
    ' >/dev/null

# JSON range/total_lines/limits/meta contract.
AI_OUTPUT=json "$BASH_BIN" "$script" "$tmp/app/UserService.php" --range 3:5 \
    | jq -e '
        .range.start == 3
        and .range.end == 5
        and .total_lines == 10
        and .truncated == false
        and (.limits.max_bytes | type == "number")
        and (.limits.max_columns | type == "number")
        and (.meta.size_bytes | type == "number")
        and (.meta.size_bytes > 0)
        and (.content | contains("login"))
    ' >/dev/null

# Dry run.
AI_OUTPUT=json "$BASH_BIN" "$script" "$tmp/app/UserService.php" --around 4 --dry-run \
    | jq -e '.status == "dry_run" and .content == ""' >/dev/null

# Invalid line count must fail.
if "$BASH_BIN" "$script" "$tmp/app/UserService.php" --lines abc >/dev/null 2>&1; then
    echo "expected invalid --lines to fail" >&2
    exit 1
fi

# Invalid range must fail.
if "$BASH_BIN" "$script" "$tmp/app/UserService.php" --range 10:2 >/dev/null 2>&1; then
    echo "expected invalid --range to fail" >&2
    exit 1
fi

# Missing file must produce JSON error envelope.
missing_json="$(AI_OUTPUT=json "$BASH_BIN" "$script" "$tmp/app/Missing.php" 2>/dev/null || true)"
printf '%s' "$missing_json" | jq -e '.status == "error" and (.errors | length == 1)' >/dev/null

# Binary-looking file blocked by default.
printf '\000\001\002' > "$tmp/app/blob.bin"

if "$BASH_BIN" "$script" "$tmp/app/blob.bin" >/dev/null 2>&1; then
    echo "expected binary file to be blocked" >&2
    exit 1
fi

binary_json="$(AI_OUTPUT=json "$BASH_BIN" "$script" "$tmp/app/blob.bin" 2>/dev/null || true)"
printf '%s' "$binary_json" | jq -e '.status == "error" and (.errors[0] | contains("binary"))' >/dev/null

# Max bytes should block oversized files.
python3 - "$tmp/app/large.txt" <<'PY'
import sys
with open(sys.argv[1], "w", encoding="utf-8") as f:
    f.write("A" * 5000)
PY

if "$BASH_BIN" "$script" "$tmp/app/large.txt" --max-bytes 100 >/dev/null 2>&1; then
    echo "expected max-bytes block" >&2
    exit 1
fi

# Long line truncation.
"$BASH_BIN" "$script" "$tmp/app/large.txt" --force --max-bytes 10K --max-columns 20 --lines 1 \
    | grep -q 'truncated'

# JSON mode must honor --max-columns (content bounded + truncated flag set).
AI_OUTPUT=json "$BASH_BIN" "$script" "$tmp/app/large.txt" --force --max-bytes 10K --max-columns 20 --lines 1 \
    | jq -e '
        .status == "ok"
        and .truncated == true
        and (.limits.max_columns == 20)
        and (.content | contains("truncated"))
        and (.content | length < 100)
    ' >/dev/null

# Generated/vendor path warning.
AI_OUTPUT=json "$BASH_BIN" "$script" "$tmp/node_modules/pkg/index.js" --force 2>/dev/null \
    | jq -e '.status == "error" or (.warnings | type == "array")' >/dev/null || true

# .git internals blocked unless forced.
echo "secretish" > "$tmp/.git/config"

if "$BASH_BIN" "$script" "$tmp/.git/config" >/dev/null 2>&1; then
    echo "expected .git internals to be blocked" >&2
    exit 1
fi

# --force bypasses the .git/ block, the max-bytes gate, and the binary gate
# together (each checked individually).
forced_git="$("$BASH_BIN" "$script" "$tmp/.git/config" --force)"
printf '%s' "$forced_git" | grep -q 'secretish'

"$BASH_BIN" "$script" "$tmp/app/large.txt" --max-bytes 10 --force >/dev/null

"$BASH_BIN" "$script" "$tmp/app/blob.bin" --force >/dev/null

# --around/--context invalid-value error branches (non-numeric and negative).
if "$BASH_BIN" "$script" "$tmp/app/UserService.php" --around abc >/dev/null 2>&1; then
    echo "expected non-numeric --around to fail" >&2
    exit 1
fi

if "$BASH_BIN" "$script" "$tmp/app/UserService.php" --around -5 >/dev/null 2>&1; then
    echo "expected negative --around to fail" >&2
    exit 1
fi

if "$BASH_BIN" "$script" "$tmp/app/UserService.php" --around 5 --context abc >/dev/null 2>&1; then
    echo "expected non-numeric --context to fail" >&2
    exit 1
fi

if "$BASH_BIN" "$script" "$tmp/app/UserService.php" --around 5 --context -2 >/dev/null 2>&1; then
    echo "expected negative --context to fail" >&2
    exit 1
fi

# Same invalid --around/--context values must also produce a JSON error
# envelope under AI_OUTPUT=json (previously these branches ignored json_mode).
around_json="$(AI_OUTPUT=json "$BASH_BIN" "$script" "$tmp/app/UserService.php" --around abc 2>/dev/null || true)"
printf '%s' "$around_json" | jq -e '.status == "error" and (.errors[0] | contains("--around"))' >/dev/null

context_json="$(AI_OUTPUT=json "$BASH_BIN" "$script" "$tmp/app/UserService.php" --around 5 --context abc 2>/dev/null || true)"
printf '%s' "$context_json" | jq -e '.status == "error" and (.errors[0] | contains("--context"))' >/dev/null

# --max-columns default (200) truncates a long line on a non-forced file.
# Use --plain so the exact-length assertion below is not affected by bat's
# ANSI styling.
python3 - "$tmp/app/longline.txt" <<'PY'
import sys
with open(sys.argv[1], "w", encoding="utf-8") as f:
    f.write("Y" * 250 + "\n")
PY

default_trunc="$("$BASH_BIN" "$script" "$tmp/app/longline.txt" --plain)"
printf '%s' "$default_trunc" | grep -q '\.\.\.truncated'
prefix="${default_trunc%% ...truncated*}"
if [[ "${#prefix}" -ne 200 ]]; then
    echo "expected default --max-columns 200 to truncate at 200 chars, got ${#prefix}" >&2
    exit 1
fi

# bat-present rendering path: default output (no --plain, non-JSON) pipes
# through bat --color=always, so it must contain ANSI escape codes; --plain
# must not.
if command -v bat >/dev/null 2>&1; then
    bat_out="$("$BASH_BIN" "$script" "$tmp/app/UserService.php" --lines 2)"
    if ! printf '%s' "$bat_out" | LC_ALL=C grep -qF $'\033['; then
        echo "expected bat-rendered output (no --plain) to contain ANSI escape codes" >&2
        exit 1
    fi

    plain_out="$("$BASH_BIN" "$script" "$tmp/app/UserService.php" --lines 2 --plain)"
    if printf '%s' "$plain_out" | LC_ALL=C grep -qF $'\033['; then
        echo "expected --plain output to have no ANSI escape codes" >&2
        exit 1
    fi
else
    echo "bat not installed; skipping bat-rendering path check" >&2
fi

# Unknown-flag error branch in both plain and JSON output modes.
if "$BASH_BIN" "$script" "$tmp/app/UserService.php" --bogus-flag >/dev/null 2>&1; then
    echo "expected unknown flag to fail in plain mode" >&2
    exit 1
fi

unknown_json="$(AI_OUTPUT=json "$BASH_BIN" "$script" "$tmp/app/UserService.php" --bogus-flag 2>/dev/null || true)"
printf '%s' "$unknown_json" | jq -e '.status == "error" and (.errors[0] | contains("unknown option"))' >/dev/null

# --lines=N / --range=A:B equals-form flags.
"$BASH_BIN" "$script" "$tmp/app/UserService.php" --lines=3 | grep -q 'UserService'
"$BASH_BIN" "$script" "$tmp/app/UserService.php" --range=3:5 | grep -q 'login'

echo "preview-file tests passed"
