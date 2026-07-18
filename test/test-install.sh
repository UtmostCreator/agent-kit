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

# install.sh auto-drops Fish/Bash completions into
# ${XDG_CONFIG_HOME:-$HOME/.config}/fish and ${XDG_DATA_HOME:-$HOME/.local/share}
# for non-project installs. Point those at the isolated stage so this test
# suite's install.sh calls never touch the real developer's dotfiles.
export XDG_CONFIG_HOME="$STAGE/xdg-config"
export XDG_DATA_HOME="$STAGE/xdg-data"

# Install to an isolated prefix.
test_install_succeeds() {
    "$BASH_BIN" "$REPO_ROOT/install.sh" --prefix "$PREFIX" --bindir "$BINDIR" >/dev/null 2>&1
}
run_test "install.sh installs to a custom prefix" test_install_succeeds

test_marker_written() {
    [[ -f "$PREFIX/.restsift-install" ]] &&
        [[ "$(<"$PREFIX/.restsift-install")" == "restsift" ]]
}
run_test "install writes the identity marker" test_marker_written

test_foreign_wrapper_refusal_preserves_existing_install() {
    local existing_marker="$PREFIX/existing-marker"
    printf 'keep\n' >"$existing_marker"
    printf '#!/bin/sh\nexit 0\n' >"$BINDIR/restsift"
    chmod 0755 "$BINDIR/restsift"

    local _rc=0
    "$BASH_BIN" "$REPO_ROOT/install.sh" --prefix "$PREFIX" --bindir "$BINDIR" >/dev/null 2>&1 || _rc=$?
    [[ "$_rc" -ne 0 ]] && [[ -f "$existing_marker" ]] && ! grep -Fq '# restsift-wrapper' "$BINDIR/restsift"
}
run_test "install refuses foreign wrapper before replacing prefix" test_foreign_wrapper_refusal_preserves_existing_install

test_reinstall_succeeds_after_wrapper_removed() {
    rm -f -- "$BINDIR/restsift"
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
    RESTSIFT_REF=main \
        RESTSIFT_SRC="$cache_src" \
        RESTSIFT_REPO=https://example.invalid/restsift.git \
        "$BASH_BIN" "$REPO_ROOT/web-install.sh" >/dev/null 2>&1 || _rc=$?
    [[ "$_rc" -ne 0 ]] && [[ -f "$cache_src/sentinel" ]] && [[ -d "$cache_src/.git" ]]
}
run_test "web installer refuses remote mismatch without deleting cache" test_web_install_refuses_remote_mismatch_without_deleting_cache

test_wrapper_runs() {
    [[ -x "$BINDIR/restsift" ]] || return 1
    local out
    out="$("$BINDIR/restsift" --list 2>/dev/null || true)"
    printf '%s' "$out" | grep -q 'ai-search'
}
run_test "installed 'ai' wrapper resolves commands" test_wrapper_runs

# The short `ak` alias is installed alongside restsift and routes to the same
# dispatcher (exercised here through the new `s` shorthand).
test_ak_alias_runs() {
    [[ -x "$BINDIR/ak" ]] || return 1
    grep -Fq -- '# restsift-wrapper' "$BINDIR/ak" || return 1
    local out
    out="$(AI_OUTPUT=json "$BINDIR/ak" s emit_json libexec 2>/dev/null || true)"
    printf '%s' "$out" | grep -q '"status":"ok"'
}
run_test "installed 'ak' alias routes to the dispatcher" test_ak_alias_runs

# Fish's completion autoloader keys off the FILENAME matching the command
# being completed, one file per name -- restsift.fish alone only ever
# autoloads for `restsift <TAB>`, never `ak <TAB>`. install.sh must also drop
# an ak.fish stub that sources it so both names autoload independently.
test_fish_completion_installed_for_both_names() {
    local fish_dir="$XDG_CONFIG_HOME/fish/completions"
    [[ -f "$fish_dir/restsift.fish" ]] || return 1
    [[ -f "$fish_dir/ak.fish" ]] || return 1
    grep -q 'restsift.fish' "$fish_dir/ak.fish"
}
run_test "install.sh drops a Fish completion file for BOTH restsift and ak" test_fish_completion_installed_for_both_names

# Same per-command-filename autoload convention applies to the bash-completion
# package's dynamic loader.
test_bash_completion_installed_for_both_names() {
    local bash_dir="$XDG_DATA_HOME/bash-completion/completions"
    [[ -f "$bash_dir/restsift" ]] || return 1
    [[ -f "$bash_dir/ak" ]] || return 1
    diff -q "$bash_dir/restsift" "$bash_dir/ak" >/dev/null
}
run_test "install.sh drops a Bash completion file for BOTH restsift and ak" test_bash_completion_installed_for_both_names

# uninstall.sh must remove the completions it (via install.sh) wired up --
# but ONLY for a true default-location global install/uninstall pair, never
# when --prefix/--bindir are overridden (that's how --project installs always
# invoke it, and they must never touch this shared, possibly-unrelated
# location). Fully isolated via a private HOME so this never touches the
# real developer's dotfiles or actual restsift install.
test_default_global_install_uninstall_wires_and_removes_completions() {
    local home="$STAGE/default-home"
    mkdir -p "$home"
    (
        export HOME="$home"
        export XDG_CONFIG_HOME="$home/.config"
        export XDG_DATA_HOME="$home/.local/share"
        "$BASH_BIN" "$REPO_ROOT/install.sh" >/dev/null 2>&1 || exit 1
        [[ -f "$home/.config/fish/completions/restsift.fish" ]] || exit 1
        [[ -f "$home/.config/fish/completions/ak.fish" ]] || exit 1
        [[ -f "$home/.local/share/bash-completion/completions/restsift" ]] || exit 1
        [[ -f "$home/.local/share/bash-completion/completions/ak" ]] || exit 1
        "$BASH_BIN" "$REPO_ROOT/uninstall.sh" >/dev/null 2>&1 || exit 1
        [[ ! -f "$home/.config/fish/completions/restsift.fish" ]] || exit 1
        [[ ! -f "$home/.config/fish/completions/ak.fish" ]] || exit 1
        [[ ! -f "$home/.local/share/bash-completion/completions/restsift" ]] || exit 1
        [[ ! -f "$home/.local/share/bash-completion/completions/ak" ]] || exit 1
    )
}
run_test "default global install/uninstall wires and later removes Fish+Bash completions" test_default_global_install_uninstall_wires_and_removes_completions

# Snapshot the sentinel now (left by test_install_succeeds/reinstall above,
# which use a custom --prefix/--bindir but still write into the SHARED
# $XDG_CONFIG_HOME, matching real non-project usage) so the assertion after
# test_uninstall_removes below can prove it. Not consumed by an uninstall
# call here -- that would prematurely tear down $PREFIX/$BINDIR that later
# tests (payload check, the real uninstall test) still depend on.
COMPLETION_SENTINEL="$XDG_CONFIG_HOME/fish/completions/restsift.fish"
test_completion_sentinel_present_before_custom_prefix_uninstall() {
    [[ -f "$COMPLETION_SENTINEL" ]]
}
run_test "sanity: custom-prefix install still wired the shared Fish completion" test_completion_sentinel_present_before_custom_prefix_uninstall

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
    [[ ! -e "$PREFIX" && ! -e "$BINDIR/restsift" && ! -e "$BINDIR/ak" ]]
}
run_test "uninstall removes prefix and both wrappers" test_uninstall_removes

# uninstall.sh only cleans up the shared Fish/Bash completion dirs when
# prefix/bindir are still at their un-overridden defaults (see uninstall.sh).
# The uninstall just above used an explicit --prefix/--bindir, so it must NOT
# have touched the sentinel captured before it ran.
test_custom_prefix_uninstall_did_not_touch_completions() {
    [[ -f "$COMPLETION_SENTINEL" ]]
}
run_test "uninstall with an explicit --prefix/--bindir never touches the completions dirs" test_custom_prefix_uninstall_did_not_touch_completions

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
    [[ -f "$proj/.restsift/toolkit/.restsift-install" ]] &&
        [[ -x "$proj/.restsift/bin/restsift" ]]
}
run_test "install.sh --project creates <dir>/.restsift/{toolkit,bin}" test_project_install_creates_layout

test_project_install_wrapper_runs() {
    local proj="$STAGE/proj1"
    [[ "$("$proj/.restsift/bin/restsift" --version)" == *"restsift"* ]]
}
run_test "project-local wrapper actually runs (restsift --version)" test_project_install_wrapper_runs

test_project_install_not_git_tracked() {
    local proj="$STAGE/proj1"
    [[ "$(cd "$proj" && git status --short -- .restsift)" == "?? .restsift/" ]]
}
run_test "project-local install lands untracked in the fixture repo" test_project_install_not_git_tracked

test_project_uninstall_removes_everything() {
    local proj="$STAGE/proj1"
    "$BASH_BIN" "$REPO_ROOT/uninstall.sh" --prefix "$proj/.restsift/toolkit" --bindir "$proj/.restsift/bin" >/dev/null 2>&1
    # Not just the toolkit and wrapper -- the whole now-empty .restsift
    # folder too, matching INSTALL.md's "self-contained, cleanly removable"
    # promise for project-local installs. (Regression: uninstall.sh used to
    # leave an empty .restsift/bin/ and .restsift/ behind.)
    [[ ! -e "$proj/.restsift" ]]
}
run_test "project-local uninstall leaves no trace (no leftover .restsift/)" test_project_uninstall_removes_everything

test_project_install_custom_dir_name() {
    local proj="$STAGE/proj2"
    make_fixture_repo "$proj"
    RESTSIFT_DIR_NAME=.tools "$BASH_BIN" "$REPO_ROOT/install.sh" --project "$proj" >/dev/null 2>&1
    [[ -x "$proj/.tools/bin/restsift" && ! -e "$proj/.restsift" ]]
}
run_test "RESTSIFT_DIR_NAME renames the vendored folder" test_project_install_custom_dir_name

test_project_env_var_form() {
    local proj="$STAGE/proj3"
    make_fixture_repo "$proj"
    RESTSIFT_PROJECT_DIR="$proj" "$BASH_BIN" "$REPO_ROOT/install.sh" >/dev/null 2>&1
    [[ -x "$proj/.restsift/bin/restsift" ]]
}
run_test "RESTSIFT_PROJECT_DIR env var enables project mode" test_project_env_var_form

test_project_explicit_prefix_overrides_project_flag() {
    local proj="$STAGE/proj4" explicit="$STAGE/proj4-explicit"
    make_fixture_repo "$proj"
    "$BASH_BIN" "$REPO_ROOT/install.sh" --project "$proj" --prefix "$explicit/opt" --bindir "$explicit/bin" >/dev/null 2>&1
    # --project is ignored entirely: nothing lands inside the project dir,
    # everything lands at the explicit prefix/bindir instead.
    [[ ! -e "$proj/.restsift" ]] && [[ -x "$explicit/bin/restsift" ]]
}
run_test "explicit --prefix overrides --project" test_project_explicit_prefix_overrides_project_flag

test_tarball_is_reproducible() {
    local out1 out2
    (cd "$REPO_ROOT" && ./scripts/package-release.sh "v$(cat VERSION)" >/dev/null 2>&1)
    out1=$(sha256sum "$REPO_ROOT/dist/restsift-$(cat "$REPO_ROOT/VERSION").tar.gz" | cut -d' ' -f1)
    (cd "$REPO_ROOT" && ./scripts/package-release.sh "v$(cat VERSION)" >/dev/null 2>&1)
    out2=$(sha256sum "$REPO_ROOT/dist/restsift-$(cat "$REPO_ROOT/VERSION").tar.gz" | cut -d' ' -f1)
    [[ "$out1" == "$out2" ]]
}
run_test "tarball build is reproducible (byte-identical across two builds)" test_tarball_is_reproducible

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d\n' "$PASS" "$FAIL"
((FAIL == 0)) && printf '\033[0;32mPASSED\033[0m\n' || {
    printf '\033[0;31mFAILED\033[0m\n'
    exit 1
}
