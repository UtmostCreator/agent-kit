#!/usr/bin/env bash
# Round-trip tests for install.sh and uninstall.sh (the primary install surface).
set -euo pipefail
BASH_BIN="${BASH_BIN:-$(command -v bash)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

PASS=0 FAIL=0
run_test() {
    local name="$1"
    shift
    local _rc=0
    "$@" >/dev/null 2>&1 || _rc=$?
    if ((_rc == 0)); then
        PASS=$((PASS + 1))
        printf '  \033[0;32m✓\033[0m %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        printf '  \033[0;31m✗\033[0m %s\n' "$name"
    fi
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
    [[ -f "$PREFIX/.agent-kit-install" ]] &&
        [[ "$(<"$PREFIX/.agent-kit-install")" == "agent-kit" ]]
}
run_test "install writes the identity marker" test_marker_written

test_foreign_wrapper_refusal_preserves_existing_install() {
    local existing_marker="$PREFIX/existing-marker"
    printf 'keep\n' >"$existing_marker"
    printf '#!/bin/sh\nexit 0\n' >"$BINDIR/agent-kit"
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
    printf 'keep\n' >"$cache_src/sentinel"

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

# The short `ak` alias is installed alongside agent-kit and routes to the same
# dispatcher (exercised here through the new `s` shorthand).
test_ak_alias_runs() {
    [[ -x "$BINDIR/ak" ]] || return 1
    grep -Fq -- '# agent-kit-wrapper' "$BINDIR/ak" || return 1
    local out
    out="$(AI_OUTPUT=json "$BINDIR/ak" s emit_json libexec 2>/dev/null || true)"
    printf '%s' "$out" | grep -q '"status":"ok"'
}
run_test "installed 'ak' alias routes to the dispatcher" test_ak_alias_runs

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
    [[ ! -e "$PREFIX" && ! -e "$BINDIR/agent-kit" && ! -e "$BINDIR/ak" ]]
}
run_test "uninstall removes prefix and both wrappers" test_uninstall_removes

# ── Project-local install (install.sh --project) ────────────────────────────
# A fresh throwaway git repo per test, so branch_scoped_files-style git
# assumptions elsewhere in the toolkit never confuse this repo's own tree
# with the fixture being installed into.
make_fixture_repo() {
    local dir="$1"
    mkdir -p "$dir"
    (cd "$dir" && git init -q && git config user.email t@t.t && git config user.name t)
}

test_project_install_creates_layout() {
    local proj="$STAGE/proj1"
    make_fixture_repo "$proj"
    "$BASH_BIN" "$REPO_ROOT/install.sh" --project "$proj" >/dev/null 2>&1
    [[ -f "$proj/.agent-kit/toolkit/.agent-kit-install" ]] &&
        [[ -x "$proj/.agent-kit/bin/agent-kit" ]]
}
run_test "install.sh --project creates <dir>/.agent-kit/{toolkit,bin}" test_project_install_creates_layout

test_project_install_wrapper_runs() {
    local proj="$STAGE/proj1"
    [[ "$("$proj/.agent-kit/bin/agent-kit" --version)" == *"agent-kit"* ]]
}
run_test "project-local wrapper actually runs (agent-kit --version)" test_project_install_wrapper_runs

test_project_install_not_git_tracked() {
    local proj="$STAGE/proj1"
    [[ "$(cd "$proj" && git status --short -- .agent-kit)" == "?? .agent-kit/" ]]
}
run_test "project-local install lands untracked in the fixture repo" test_project_install_not_git_tracked

test_project_uninstall_removes_everything() {
    local proj="$STAGE/proj1"
    "$BASH_BIN" "$REPO_ROOT/uninstall.sh" --prefix "$proj/.agent-kit/toolkit" --bindir "$proj/.agent-kit/bin" >/dev/null 2>&1
    # Not just the toolkit and wrapper -- the whole now-empty .agent-kit
    # folder too, matching INSTALL.md's "self-contained, cleanly removable"
    # promise for project-local installs. (Regression: uninstall.sh used to
    # leave an empty .agent-kit/bin/ and .agent-kit/ behind.)
    [[ ! -e "$proj/.agent-kit" ]]
}
run_test "project-local uninstall leaves no trace (no leftover .agent-kit/)" test_project_uninstall_removes_everything

test_project_install_custom_dir_name() {
    local proj="$STAGE/proj2"
    make_fixture_repo "$proj"
    AGENTKIT_DIR_NAME=.tools "$BASH_BIN" "$REPO_ROOT/install.sh" --project "$proj" >/dev/null 2>&1
    [[ -x "$proj/.tools/bin/agent-kit" && ! -e "$proj/.agent-kit" ]]
}
run_test "AGENTKIT_DIR_NAME renames the vendored folder" test_project_install_custom_dir_name

test_project_env_var_form() {
    local proj="$STAGE/proj3"
    make_fixture_repo "$proj"
    AGENTKIT_PROJECT_DIR="$proj" "$BASH_BIN" "$REPO_ROOT/install.sh" >/dev/null 2>&1
    [[ -x "$proj/.agent-kit/bin/agent-kit" ]]
}
run_test "AGENTKIT_PROJECT_DIR env var enables project mode" test_project_env_var_form

test_project_explicit_prefix_overrides_project_flag() {
    local proj="$STAGE/proj4" explicit="$STAGE/proj4-explicit"
    make_fixture_repo "$proj"
    "$BASH_BIN" "$REPO_ROOT/install.sh" --project "$proj" --prefix "$explicit/opt" --bindir "$explicit/bin" >/dev/null 2>&1
    # --project is ignored entirely: nothing lands inside the project dir,
    # everything lands at the explicit prefix/bindir instead.
    [[ ! -e "$proj/.agent-kit" ]] && [[ -x "$explicit/bin/agent-kit" ]]
}
run_test "explicit --prefix overrides --project" test_project_explicit_prefix_overrides_project_flag

test_tarball_is_reproducible() {
    local out1 out2
    (cd "$REPO_ROOT" && ./scripts/package-release.sh "v$(cat VERSION)" >/dev/null 2>&1)
    out1=$(sha256sum "$REPO_ROOT/dist/agent-kit-$(cat "$REPO_ROOT/VERSION").tar.gz" | cut -d' ' -f1)
    (cd "$REPO_ROOT" && ./scripts/package-release.sh "v$(cat VERSION)" >/dev/null 2>&1)
    out2=$(sha256sum "$REPO_ROOT/dist/agent-kit-$(cat "$REPO_ROOT/VERSION").tar.gz" | cut -d' ' -f1)
    [[ "$out1" == "$out2" ]]
}
run_test "tarball build is reproducible (byte-identical across two builds)" test_tarball_is_reproducible

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d\n' "$PASS" "$FAIL"
((FAIL == 0)) && printf '\033[0;32mPASSED\033[0m\n' || {
    printf '\033[0;31mFAILED\033[0m\n'
    exit 1
}
