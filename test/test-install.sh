#!/usr/bin/env bash
# Round-trip tests for install.sh and uninstall.sh (the primary install surface).
set -euo pipefail
BASH_BIN="${BASH_BIN:-$(command -v bash)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

PASS=0 FAIL=0
run_test() {
    local name="$1"; shift; local _rc=0
    "$@" >/dev/null 2>&1 || _rc=$?
    if ((_rc == 0)); then PASS=$((PASS+1)); printf '  \033[0;32m✓\033[0m %s\n' "$name"
    else FAIL=$((FAIL+1)); printf '  \033[0;31m✗\033[0m %s\n' "$name"; fi
}

printf 'install/uninstall\n'

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
# Deliberately use paths WITH SPACES to guard the install/uninstall path handling.
PREFIX="$STAGE/opt/agent kit"
BINDIR="$STAGE/bin dir"

# Install to an isolated prefix.
test_install_succeeds() {
    "$BASH_BIN" "$REPO_ROOT/install.sh" --prefix "$PREFIX" --bindir "$BINDIR" >/dev/null 2>&1
}
run_test "install.sh installs to a custom prefix" test_install_succeeds

test_marker_written() {
    [[ -f "$PREFIX/.agent-kit-install" ]] && \
        [[ "$(<"$PREFIX/.agent-kit-install")" == "agent-kit" ]]
}
run_test "install writes the identity marker" test_marker_written

test_foreign_wrapper_refusal_preserves_existing_install() {
    local existing_marker="$PREFIX/existing-marker"
    printf 'keep\n' > "$existing_marker"
    printf '#!/bin/sh\nexit 0\n' > "$BINDIR/agent-kit"
    chmod 0755 "$BINDIR/agent-kit"

    local _rc=0
    "$BASH_BIN" "$REPO_ROOT/install.sh" --prefix "$PREFIX" --bindir "$BINDIR" >/dev/null 2>&1 || _rc=$?
    [[ "$_rc" -ne 0 ]] && [[ -f "$existing_marker" ]] && ! grep -Fq '# agent-kit-wrapper' "$BINDIR/agent-kit"
}
run_test "install refuses foreign wrapper before replacing prefix" test_foreign_wrapper_refusal_preserves_existing_install

test_reinstall_succeeds_after_wrapper_removed() {
    rm -f -- "$BINDIR/agent-kit"
    "$BASH_BIN" "$REPO_ROOT/install.sh" --prefix "$PREFIX" --bindir "$BINDIR" >/dev/null 2>&1
}
run_test "install.sh reinstalls after foreign wrapper is removed" test_reinstall_succeeds_after_wrapper_removed

test_web_install_refuses_remote_mismatch_without_deleting_cache() {
    local cache_src="$STAGE/cache/src"
    mkdir -p "$cache_src"
    git -C "$cache_src" init >/dev/null 2>&1
    git -C "$cache_src" remote add origin https://example.invalid/other.git
    printf 'keep\n' > "$cache_src/sentinel"

    local _rc=0
    AGENTKIT_REF=main \
        AGENTKIT_SRC="$cache_src" \
        AGENTKIT_REPO=https://example.invalid/agent-kit.git \
        "$BASH_BIN" "$REPO_ROOT/web-install.sh" >/dev/null 2>&1 || _rc=$?
    [[ "$_rc" -ne 0 ]] && [[ -f "$cache_src/sentinel" ]] && [[ -d "$cache_src/.git" ]]
}
run_test "web installer refuses remote mismatch without deleting cache" test_web_install_refuses_remote_mismatch_without_deleting_cache

test_wrapper_runs() {
    [[ -x "$BINDIR/agent-kit" ]] || return 1
    local out
    out="$("$BINDIR/agent-kit" --list 2>/dev/null || true)"
    printf '%s' "$out" | grep -q 'ai-search'
}
run_test "installed 'ai' wrapper resolves commands" test_wrapper_runs

# The installed payload must not carry dev/CI/private material.
test_payload_minimal() {
    ! find "$PREFIX" \( -name '.claude' -o -name 'release-plan' -o -name 'test' \
        -o -path '*/.github/*' -o -name 'node_modules' -o -name '.ai-logs' \) \
        -print 2>/dev/null | grep -q .
}
run_test "installed payload excludes dev/CI/private files" test_payload_minimal

# Uninstall must refuse an unmarked directory.
test_uninstall_refuses_unmarked() {
    local unmarked _rc=0
    unmarked="$STAGE/unmarked"
    mkdir -p "$unmarked"
    "$BASH_BIN" "$REPO_ROOT/uninstall.sh" --prefix "$unmarked" --bindir "$BINDIR" >/dev/null 2>&1 || _rc=$?
    [[ -d "$unmarked" && "$_rc" -ne 0 ]]
}
run_test "uninstall refuses an unmarked path" test_uninstall_refuses_unmarked

# Uninstall removes the marked prefix and the wrapper.
test_uninstall_removes() {
    "$BASH_BIN" "$REPO_ROOT/uninstall.sh" --prefix "$PREFIX" --bindir "$BINDIR" >/dev/null 2>&1
    [[ ! -e "$PREFIX" && ! -e "$BINDIR/agent-kit" ]]
}
run_test "uninstall removes prefix and wrapper" test_uninstall_removes

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d\n' "$PASS" "$FAIL"
((FAIL == 0)) && printf '\033[0;32mPASSED\033[0m\n' || { printf '\033[0;31mFAILED\033[0m\n'; exit 1; }
