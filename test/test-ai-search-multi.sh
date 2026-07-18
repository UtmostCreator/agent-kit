#!/usr/bin/env bash
set -euo pipefail

# Regression suite for libexec/ai-search-multi.
#
# Focused on the 'files' mode dispatch contract:
#
#   'files' is a file-list mode (no query, optional root only), not a query
#   mode. Before the fix it was routed through the query family, so `files ROOT`
#   errored "does not accept a query" and `files` alone demanded a QUERY -- the
#   mode was completely non-functional.
#
# Robust to CWD: resolves the command via an absolute path from this file's
# location, so it can be invoked directly or via a test runner.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
BASH_BIN="${BASH_BIN:-$(command -v bash)}"
MULTI_SCRIPT="$REPO_ROOT/libexec/ai-search-multi"

LAST_OUT=""
LAST_RC=0

run_multi_plain() {
    set +e
    LAST_OUT="$("$BASH_BIN" "$MULTI_SCRIPT" "$@" 2>&1)"
    LAST_RC=$?
    set -e
}

# Capture stdout only (stderr discarded) under AI_OUTPUT=json, so we assert on
# the JSON envelope emitted to stdout, not on any incidental stderr text.
run_multi_json() {
    set +e
    LAST_OUT="$(AI_OUTPUT=json "$BASH_BIN" "$MULTI_SCRIPT" "$@" 2>/dev/null)"
    LAST_RC=$?
    set -e
}

fail() {
    printf '  FAIL %s\n' "$1" >&2
    printf '       rc=%s\n       output: %s\n' "$LAST_RC" "$LAST_OUT" >&2
    exit 1
}

# --- fixture ------------------------------------------------------------------
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

printf 'workflowNeedle lives here\n' >"$fixture/hit.txt"
printf 'anotherNeedle nearby\n' >"$fixture/other.txt"

# =============================================================================
# 'files' is a file-list mode (no query, optional root only), not a query mode.
# Before the fix it was routed through the query family, so `files ROOT` errored
# "does not accept a query" and `files` alone demanded a QUERY -- the mode was
# completely non-functional.
# =============================================================================
printf '[regression] files mode lists files with only an optional root\n'

run_multi_plain files "$fixture"
if [[ "$LAST_RC" -ne 0 ]]; then
    fail "files ROOT should succeed (file-list mode, optional root only)"
fi
if [[ "$LAST_OUT" != *"hit.txt"* ]]; then
    fail "files ROOT did not list fixture files"
fi
printf '  PASS files ROOT listed files (rc=%s)\n' "$LAST_RC"

# 'files' takes no query: extra positionals must be rejected, not swallowed.
run_multi_plain files needleA needleB "$fixture"
if [[ "$LAST_RC" -eq 0 ]]; then
    fail "files mode with queries should error (does not accept queries)"
fi
if [[ "$LAST_OUT" != *"does not accept queries"* ]]; then
    fail "files-with-queries error did not name the no-query contract"
fi
printf '  PASS files mode rejected extra query positionals (rc=%s)\n' "$LAST_RC"

# --- positive control: a query mode with a trailing root still works ----------
printf '[regression] query mode with existing trailing root still works\n'

run_multi_plain text workflowNeedle "$fixture"
if [[ "$LAST_RC" -ne 0 || "$LAST_OUT" != *"workflowNeedle"* ]]; then
    fail "valid single-query batch with existing root should succeed with a match"
fi
printf '  PASS query mode with existing trailing root honoured (rc=%s)\n' "$LAST_RC"

# =============================================================================
# Under AI_OUTPUT=json, wrapper-level validation errors are emitted as a single
# JSON error envelope on stdout (schema/status/tool + errors[]), not [ERROR]
# stderr text, so an agent parsing JSON never has to scrape stderr.
# =============================================================================
if command -v jq >/dev/null 2>&1; then
    printf '[regression] AI_OUTPUT=json wrapper errors emit a JSON error envelope\n'

    # unknown mode
    run_multi_json bogusmode foo "$fixture"
    if [[ "$LAST_RC" -eq 0 ]]; then
        fail "unknown mode under AI_OUTPUT=json should exit nonzero"
    fi
    if ! jq -e '.schema=="1" and .status=="error" and .tool=="ai-search-multi" and (.errors|length>0)' <<<"$LAST_OUT" >/dev/null 2>&1; then
        fail "unknown mode did not emit a well-formed JSON error envelope"
    fi
    printf '  PASS unknown mode -> JSON error envelope (rc=%s)\n' "$LAST_RC"

    # unsafe-all rejection
    run_multi_json unsafe-all
    if [[ "$LAST_RC" -eq 0 ]]; then
        fail "unsafe-all under AI_OUTPUT=json should exit nonzero"
    fi
    if ! jq -e '.status=="error" and .tool=="ai-search-multi"' <<<"$LAST_OUT" >/dev/null 2>&1; then
        fail "unsafe-all did not emit a JSON error envelope"
    fi
    printf '  PASS unsafe-all -> JSON error envelope (rc=%s)\n' "$LAST_RC"

    # file-list mode given queries
    run_multi_json files needleA needleB "$fixture"
    if [[ "$LAST_RC" -eq 0 ]]; then
        fail "files-with-queries under AI_OUTPUT=json should exit nonzero"
    fi
    if ! jq -e '.status=="error" and (.errors[0]|test("does not accept queries"))' <<<"$LAST_OUT" >/dev/null 2>&1; then
        fail "files-with-queries JSON envelope did not carry the no-query contract error"
    fi
    printf '  PASS files-with-queries -> JSON error envelope (rc=%s)\n' "$LAST_RC"
else
    printf '[skip] jq not available; skipping JSON error-envelope assertions\n'
fi

echo "ai-search-multi tests passed"
