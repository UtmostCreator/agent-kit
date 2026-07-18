#!/usr/bin/env bash
# Tests for libexec/ai-completion and the generated completions/ definitions.
set -euo pipefail
BASH_BIN="${BASH_BIN:-$(command -v bash)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPLETION="$REPO_ROOT/libexec/ai-completion"
cd "$REPO_ROOT"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0 FAIL=0 SKIP=0
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
skip_test() {
    SKIP=$((SKIP + 1))
    printf '  \033[0;33m⊘\033[0m %s (skipped: %s)\n' "$1" "$2"
}

printf 'libexec/ai-completion\n'

# --- Spec sanity: catch accidental corruption of a hand-authored `# Modes:` --
# header (e.g. a bad edit that empties or truncates the list) — nothing else
# in the suite would fail if one of these silently regressed, since the
# committed completions/ would just regenerate with fewer candidates.
if command -v jq >/dev/null 2>&1; then
    test_spec_modes_present() {
        local spec
        spec="$(bash "$REPO_ROOT/libexec/internal/completion-spec")"
        printf '%s' "$spec" | jq -e '
            (.commands[] | select(.name=="search") | .modes | index("text")) and
            (.commands[] | select(.name=="search") | .modes | index("batch")) and
            (.commands[] | select(.name=="edit") | .modes | index("sd")) and
            (.commands[] | select(.name=="context") | .modes | index("pack")) and
            (.commands[] | select(.name=="rollback") | .modes | index("apply")) and
            (.commands[] | select(.name=="test") | .modes | index("select"))
        ' >/dev/null
    }
    run_test "completion spec exposes expected modes for group commands" test_spec_modes_present
else
    skip_test "completion spec exposes expected modes for group commands" "jq not available"
fi

# --- Static generation: regenerating must reproduce the committed files ------
test_no_drift() {
    cp -R "$REPO_ROOT/completions" "$TMP/committed"
    bash "$REPO_ROOT/scripts/gen-completions.sh" >/dev/null
    diff -rq "$TMP/committed" "$REPO_ROOT/completions" >/dev/null
}
run_test "regenerating produces no drift from the committed completions/" test_no_drift

test_bash_syntax() {
    bash -n "$REPO_ROOT/completions/restsift.bash"
}
run_test "generated Bash completion has valid syntax" test_bash_syntax

if command -v fish >/dev/null 2>&1; then
    test_fish_syntax() {
        fish --no-execute "$REPO_ROOT/completions/restsift.fish"
    }
    run_test "generated Fish completion has valid syntax" test_fish_syntax
else
    skip_test "generated Fish completion has valid syntax" "fish not installed"
fi

if command -v zsh >/dev/null 2>&1; then
    test_zsh_syntax() {
        zsh -n "$REPO_ROOT/completions/_restsift"
    }
    run_test "generated Zsh completion has valid syntax" test_zsh_syntax
else
    skip_test "generated Zsh completion has valid syntax" "zsh not installed"
fi

# --- Bash: functional completion candidates ----------------------------------
test_bash_top_level_prefix() {
    local out
    out="$(
        bash -c '
            source "'"$REPO_ROOT"'/completions/restsift.bash"
            COMP_WORDS=(restsift se)
            COMP_CWORD=1
            _restsift_completion
            printf "%s\n" "${COMPREPLY[@]}"
        '
    )"
    printf '%s' "$out" | grep -qx search
}
run_test "restsift se<TAB> offers search" test_bash_top_level_prefix

test_bash_completion_offers_shells() {
    local out
    out="$(
        bash -c '
            source "'"$REPO_ROOT"'/completions/restsift.bash"
            COMP_WORDS=(restsift completion "")
            COMP_CWORD=2
            _restsift_completion
            printf "%s\n" "${COMPREPLY[@]}"
        '
    )"
    printf '%s' "$out" | grep -qx bash && printf '%s' "$out" | grep -qx zsh && printf '%s' "$out" | grep -qx fish
}
run_test "restsift completion <TAB> offers bash zsh fish" test_bash_completion_offers_shells

test_bash_search_mode_prefix() {
    local out
    out="$(
        bash -c '
            source "'"$REPO_ROOT"'/completions/restsift.bash"
            COMP_WORDS=(restsift search t)
            COMP_CWORD=2
            _restsift_completion
            printf "%s\n" "${COMPREPLY[@]}"
        '
    )"
    printf '%s' "$out" | grep -qx text && printf '%s' "$out" | grep -qx tests
}
run_test "restsift search t<TAB> offers text and tests modes" test_bash_search_mode_prefix

test_bash_search_flag_prefix() {
    local out
    out="$(
        bash -c '
            source "'"$REPO_ROOT"'/completions/restsift.bash"
            COMP_WORDS=(restsift search text foo . --)
            COMP_CWORD=5
            _restsift_completion
            printf "%s\n" "${COMPREPLY[@]}"
        '
    )"
    printf '%s' "$out" | grep -qx -- --glob && printf '%s' "$out" | grep -qx -- --max-results
}
run_test "restsift search text ... --<TAB> offers search flags" test_bash_search_flag_prefix

test_bash_no_stale_compreply() {
    # A command with no matching case branch must not leak COMPREPLY from a
    # PRIOR completion attempt in the same shell session.
    local out
    out="$(
        bash -c '
            source "'"$REPO_ROOT"'/completions/restsift.bash"
            COMP_WORDS=(restsift search text foo . --)
            COMP_CWORD=5
            _restsift_completion
            COMP_WORDS=(restsift no-such-command --)
            COMP_CWORD=3
            _restsift_completion
            printf "%s\n" "${COMPREPLY[@]}"
        '
    )"
    [[ -z "$out" ]]
}
run_test "an unmatched command does not inherit a prior COMPREPLY" test_bash_no_stale_compreply

# --- Fish: functional completion candidates ----------------------------------
if command -v fish >/dev/null 2>&1; then
    test_fish_top_level() {
        fish -c '
            source "'"$REPO_ROOT"'/completions/restsift.fish"
            complete -C "restsift se"
        ' | grep -qF search
    }
    run_test "fish: restsift se<TAB> offers search" test_fish_top_level

    test_fish_ak_alias() {
        fish -c '
            source "'"$REPO_ROOT"'/completions/restsift.fish"
            complete -C "ak se"
        ' | grep -qF search
    }
    run_test "fish: ak se<TAB> (short alias) offers search" test_fish_ak_alias
else
    skip_test "fish: restsift se<TAB> offers search" "fish not installed"
    skip_test "fish: ak se<TAB> (short alias) offers search" "fish not installed"
fi

# --- libexec/ai-completion itself --------------------------------------------
test_completion_bash_matches_file() {
    diff <("$BASH_BIN" "$COMPLETION" bash) "$REPO_ROOT/completions/restsift.bash" >/dev/null
}
run_test "restsift completion bash prints completions/restsift.bash verbatim" test_completion_bash_matches_file

test_completion_zsh_matches_file() {
    diff <("$BASH_BIN" "$COMPLETION" zsh) "$REPO_ROOT/completions/_restsift" >/dev/null
}
run_test "restsift completion zsh prints completions/_restsift verbatim" test_completion_zsh_matches_file

test_completion_fish_matches_file() {
    diff <("$BASH_BIN" "$COMPLETION" fish) "$REPO_ROOT/completions/restsift.fish" >/dev/null
}
run_test "restsift completion fish prints completions/restsift.fish verbatim" test_completion_fish_matches_file

test_completion_missing_arg() {
    local _rc=0
    "$BASH_BIN" "$COMPLETION" >/dev/null 2>&1 || _rc=$?
    [[ "$_rc" -eq 2 ]]
}
run_test "missing SHELL argument fails, exit 2" test_completion_missing_arg

test_completion_unknown_shell() {
    local _rc=0
    "$BASH_BIN" "$COMPLETION" powershell >/dev/null 2>&1 || _rc=$?
    [[ "$_rc" -eq 2 ]]
}
run_test "unsupported shell argument fails, exit 2" test_completion_unknown_shell

test_completion_empty_arg() {
    # An explicitly-passed empty string is distinguished from a missing arg:
    # exit 2, and the diagnostic names it as "empty" rather than "missing".
    local out _rc=0
    out="$("$BASH_BIN" "$COMPLETION" "" 2>&1 >/dev/null)" || _rc=$?
    [[ "$_rc" -eq 2 ]] && printf '%s' "$out" | grep -q 'empty SHELL argument'
}
run_test "empty SHELL argument fails with an 'empty' diagnostic, exit 2" test_completion_empty_arg

test_completion_error_hint() {
    # Error paths carry an actionable recovery hint (mention of --help/auto).
    local out
    out="$("$BASH_BIN" "$COMPLETION" powershell 2>&1 >/dev/null)"
    printf '%s' "$out" | grep -q -- '--help'
}
run_test "unsupported-shell error suggests a recovery path" test_completion_error_hint

test_completion_extra_args_ignored() {
    # Trailing extra positional args are ignored for stdout (byte-identical to
    # the plain invocation) but produce a warning on stderr; exit stays 0.
    local err _rc=0
    diff <("$BASH_BIN" "$COMPLETION" bash extra junk 2>/dev/null) \
        "$REPO_ROOT/completions/restsift.bash" >/dev/null || return 1
    err="$("$BASH_BIN" "$COMPLETION" bash extra junk 2>&1 >/dev/null)" || _rc=$?
    [[ "$_rc" -eq 0 ]] && printf '%s' "$err" | grep -q 'unexpected extra argument'
}
run_test "trailing extra args are ignored for stdout but warned on stderr" test_completion_extra_args_ignored

test_completion_auto_verbose() {
    # RES_COMPLETION_VERBOSE prints the detected shell to stderr in auto mode
    # without disturbing stdout.
    local err
    err="$(FISH_VERSION=1 RES_COMPLETION_VERBOSE=1 "$BASH_BIN" "$COMPLETION" auto 2>&1 >/dev/null)"
    printf '%s' "$err" | grep -q 'detected shell: fish'
}
run_test "RES_COMPLETION_VERBOSE reports the detected shell in auto mode" test_completion_auto_verbose

test_completion_auto_quiet_by_default() {
    # Without the env var, auto mode emits nothing on stderr.
    local err
    err="$(FISH_VERSION=1 "$BASH_BIN" "$COMPLETION" auto 2>&1 >/dev/null)"
    [[ -z "$err" ]]
}
run_test "auto mode is quiet on stderr by default" test_completion_auto_quiet_by_default

test_completion_auto_precedence() {
    # detect_shell() checks FISH_VERSION before ZSH_VERSION/BASH_VERSION/$SHELL,
    # regardless of the interpreter actually running it.
    diff <(FISH_VERSION=1 "$BASH_BIN" "$COMPLETION" auto) "$REPO_ROOT/completions/restsift.fish" >/dev/null
}
run_test "completion auto honors FISH_VERSION precedence" test_completion_auto_precedence

# --- Regression: `auto` must detect the *calling* shell from its parent process,
# not the bash interpreter that always runs this script. A real fish/zsh session
# does not export FISH_VERSION/ZSH_VERSION into child processes, yet BASH_VERSION
# is always set by our own `#!/usr/bin/env bash`; env-var sniffing alone would
# therefore always mis-resolve `auto` to bash. Before the fix these diffs fail
# (auto prints the bash definition); after the fix they match the caller's shell.
if command -v fish >/dev/null 2>&1; then
    test_completion_auto_detects_fish_parent() {
        # Launched from a live fish process: the bash subprocess inherits no
        # FISH_VERSION, so detection must fall back to the parent (fish).
        diff <(fish -c "$BASH_BIN '$COMPLETION' auto") "$REPO_ROOT/completions/restsift.fish" >/dev/null
    }
    run_test "completion auto detects a fish parent shell (not bash)" test_completion_auto_detects_fish_parent
else
    skip_test "completion auto detects a fish parent shell (not bash)" "fish not installed"
fi

if command -v zsh >/dev/null 2>&1; then
    test_completion_auto_detects_zsh_parent() {
        # Launched from a live zsh process: the bash subprocess inherits no
        # ZSH_VERSION, so detection must fall back to the parent (zsh).
        diff <(zsh -c "$BASH_BIN '$COMPLETION' auto") "$REPO_ROOT/completions/_restsift" >/dev/null
    }
    run_test "completion auto detects a zsh parent shell (not bash)" test_completion_auto_detects_zsh_parent
else
    skip_test "completion auto detects a zsh parent shell (not bash)" "zsh not installed"
fi

test_completion_help() {
    local out
    out="$("$BASH_BIN" "$COMPLETION" --help 2>&1)"
    [[ -n "$out" ]] && printf '%s' "$out" | grep -q 'Usage:'
}
run_test "--help works" test_completion_help

if command -v jq >/dev/null 2>&1; then
    test_completion_introspect() {
        local out
        out="$("$BASH_BIN" "$COMPLETION" --introspect 2>&1)"
        printf '%s' "$out" | jq -e '.modes == ["auto","bash","fish","zsh"]' >/dev/null
    }
    run_test "--introspect exposes its own modes" test_completion_introspect
else
    skip_test "--introspect exposes its own modes" "jq not available"
fi

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d  Skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
((FAIL == 0)) && printf '\033[0;32mPASSED\033[0m\n' || {
    printf '\033[0;31mFAILED\033[0m\n'
    exit 1
}
