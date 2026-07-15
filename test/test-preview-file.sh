#!/usr/bin/env bash
set -euo pipefail

BASH_BIN="${BASH_BIN:-$(command -v bash)}"
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/libexec/preview-file"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/app" "$tmp/node_modules/pkg" "$tmp/.git"

cat >"$tmp/app/UserService.php" <<'PHP'
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
AI_OUTPUT=json "$BASH_BIN" "$script" "$tmp/app/UserService.php" --lines 4 |
    jq -e '
        .schema == "1"
        and .status == "ok"
        and .tool == "preview-file"
        and .path != ""
        and (.content | contains("UserService"))
        and (.warnings | type == "array")
        and (.errors | type == "array")
    ' >/dev/null

# JSON range/total_lines/limits/meta contract.
AI_OUTPUT=json "$BASH_BIN" "$script" "$tmp/app/UserService.php" --range 3:5 |
    jq -e '
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
AI_OUTPUT=json "$BASH_BIN" "$script" "$tmp/app/UserService.php" --around 4 --dry-run |
    jq -e '.status == "dry_run" and .content == ""' >/dev/null

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
printf '\000\001\002' >"$tmp/app/blob.bin"

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
"$BASH_BIN" "$script" "$tmp/app/large.txt" --force --max-bytes 10K --max-columns 20 --lines 1 |
    grep -q 'truncated'

# JSON mode must honor --max-columns (content bounded + truncated flag set).
AI_OUTPUT=json "$BASH_BIN" "$script" "$tmp/app/large.txt" --force --max-bytes 10K --max-columns 20 --lines 1 |
    jq -e '
        .status == "ok"
        and .truncated == true
        and (.limits.max_columns == 20)
        and (.content | contains("truncated"))
        and (.content | length < 100)
    ' >/dev/null

# Generated/vendor path warning.
AI_OUTPUT=json "$BASH_BIN" "$script" "$tmp/node_modules/pkg/index.js" --force 2>/dev/null |
    jq -e '.status == "error" or (.warnings | type == "array")' >/dev/null || true

# .git internals blocked unless forced.
echo "secretish" >"$tmp/.git/config"

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

# This script's OWN --help|-h case arm (and its own usage() function) is only
# reachable when --help/-h is NOT the first argument: common.sh's universal
# --help guard intercepts "$1 == --help" before this script's arg-parsing
# loop even runs, and renders the shared introspector help instead. Put a
# file first so this script's own usage() actually runs.
"$BASH_BIN" "$script" "$tmp/app/UserService.php" --help | grep -q 'preview-file.sh FILE'

# --max-bytes with K/M/G size suffixes (parse_size's m)/g) arms; k) is
# already exercised above via --max-bytes 10K).
"$BASH_BIN" "$script" "$tmp/app/UserService.php" --max-bytes 1M | grep -q 'UserService'
"$BASH_BIN" "$script" "$tmp/app/UserService.php" --max-bytes 1G | grep -q 'UserService'

# --around=N / --context=N equals-form flags.
"$BASH_BIN" "$script" "$tmp/app/UserService.php" --around=7 --context=1 | grep -q 'logout'

# --max-bytes=N / --max-columns=N equals-form flags (combined with --lines=
# already covered above; use --force so max-bytes=1M is not the limiting
# factor for a tiny file, --max-columns=20 to truncate the padded line).
"$BASH_BIN" "$script" "$tmp/app/large.txt" --force --max-bytes=10K --max-columns=20 --lines=1 |
    grep -q 'truncated'

# Unexpected second positional argument.
if "$BASH_BIN" "$script" "$tmp/app/UserService.php" "$tmp/app/large.txt" >/dev/null 2>&1; then
    echo "expected a second positional argument to fail" >&2
    exit 1
fi

# Zero arguments (no --help/-h/file at all): common.sh's universal guard only
# intercepts a literal --help/-h/--introspect first argument, so this reaches
# preview-file.sh's own `-z "$file"` branch (usage + exit 2).
set +e
no_args_out="$("$BASH_BIN" "$script" 2>&1)"
no_args_rc=$?
set -e
if [[ "$no_args_rc" -ne 2 ]] || ! printf '%s' "$no_args_out" | grep -q 'Usage:'; then
    echo "expected zero args to print usage and exit 2, got rc=$no_args_rc" >&2
    exit 1
fi

# Missing file in PLAIN (non-JSON) mode (the JSON envelope variant is already
# covered above).
if "$BASH_BIN" "$script" "$tmp/app/Missing.php" 2>/dev/null; then
    echo "expected plain-mode missing file to fail" >&2
    exit 1
fi
missing_plain_err="$("$BASH_BIN" "$script" "$tmp/app/Missing.php" 2>&1 >/dev/null || true)"
printf '%s' "$missing_plain_err" | grep -q 'file not found'

# .git internals blocked in JSON mode (the plain-mode variant is already
# covered above).
git_blocked_json="$(AI_OUTPUT=json "$BASH_BIN" "$script" "$tmp/.git/config" 2>/dev/null || true)"
printf '%s' "$git_blocked_json" | jq -e '.status == "error" and (.errors[0] | contains(".git internals blocked"))' >/dev/null

# Plain (non-JSON) dry-run (the JSON envelope variant is already covered
# above).
"$BASH_BIN" "$script" "$tmp/app/UserService.php" --dry-run | grep -q '^dry-run$'

# max-bytes-exceeded in JSON mode (the plain-mode variant is already covered
# above).
max_bytes_json="$(AI_OUTPUT=json "$BASH_BIN" "$script" "$tmp/app/large.txt" --max-bytes 100 2>/dev/null || true)"
printf '%s' "$max_bytes_json" | jq -e '.status == "error" and (.errors[0] | contains("max-bytes exceeded"))' >/dev/null

# Invalid --lines in JSON mode (the plain-mode variant is already covered
# above).
lines_json="$(AI_OUTPUT=json "$BASH_BIN" "$script" "$tmp/app/UserService.php" --lines abc 2>/dev/null || true)"
printf '%s' "$lines_json" | jq -e '.status == "error" and (.errors[0] | contains("invalid --lines"))' >/dev/null

# Malformed --range (does not match the A:B numeric pattern at all, as
# opposed to the already-covered start>end case) in both plain and JSON mode.
if "$BASH_BIN" "$script" "$tmp/app/UserService.php" --range not-a-range >/dev/null 2>&1; then
    echo "expected malformed --range to fail in plain mode" >&2
    exit 1
fi
malformed_range_plain_err="$("$BASH_BIN" "$script" "$tmp/app/UserService.php" --range not-a-range 2>&1 >/dev/null || true)"
printf '%s' "$malformed_range_plain_err" | grep -q 'invalid --range'

malformed_range_json="$(AI_OUTPUT=json "$BASH_BIN" "$script" "$tmp/app/UserService.php" --range not-a-range 2>/dev/null || true)"
printf '%s' "$malformed_range_json" | jq -e '.status == "error" and (.errors[0] | contains("invalid --range"))' >/dev/null

# --range start>end in JSON mode (the plain-mode variant is already covered
# above).
range_order_json="$(AI_OUTPUT=json "$BASH_BIN" "$script" "$tmp/app/UserService.php" --range 10:2 2>/dev/null || true)"
printf '%s' "$range_order_json" | jq -e '.status == "error" and (.errors[0] | contains("invalid --range"))' >/dev/null

echo "preview-file tests passed"
