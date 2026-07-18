#!/usr/bin/env bash
# Tests for libexec/all-f-into-one
set -euo pipefail
BASH_BIN="${BASH_BIN:-$(command -v bash)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/libexec/all-f-into-one"

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

printf 'all-f-into-one\n'

# Isolated sandbox: the command writes combined_output.txt into the CWD, so it
# must never run against the repo. Each helper builds a fresh fixture tree.
make_fixture() {
    local root
    root="$(mktemp -d)"
    mkdir -p "$root/src" "$root/node_modules/pkg" "$root/.git"
    printf 'alpha content\n' >"$root/src/keep.txt"
    printf 'beta content\n' >"$root/top.md"
    printf 'vendor noise\n' >"$root/node_modules/pkg/index.js"
    printf 'git internals\n' >"$root/.git/HEAD"
    printf '%s' "$root"
}

test_help() {
    local out _rc=0
    out="$("$BASH_BIN" "$SCRIPT" --help 2>&1)" || _rc=$?
    [[ "$_rc" -eq 0 && -n "$out" ]]
}
run_test "--help works (exit 0, non-empty)" test_help

# Combines tracked content into combined_output.txt with file markers.
test_combines() {
    local root
    root="$(make_fixture)"
    (cd "$root" && "$BASH_BIN" "$SCRIPT") >/dev/null 2>&1
    local rc=$?
    local out="$root/combined_output.txt"
    local ok=1
    [[ "$rc" -eq 0 && -f "$out" ]] || ok=0
    grep -q 'START FILE: src/keep.txt' "$out" 2>/dev/null || ok=0
    grep -q 'alpha content' "$out" 2>/dev/null || ok=0
    grep -q 'beta content' "$out" 2>/dev/null || ok=0
    rm -rf -- "$root"
    ((ok == 1))
}
run_test "combines files into combined_output.txt with markers" test_combines

# Ignored directory trees (.git, node_modules) are pruned entirely.
test_prunes_ignored() {
    local root
    root="$(make_fixture)"
    (cd "$root" && "$BASH_BIN" "$SCRIPT") >/dev/null 2>&1
    local out="$root/combined_output.txt"
    local ok=1
    grep -q 'vendor noise' "$out" 2>/dev/null && ok=0
    grep -q 'git internals' "$out" 2>/dev/null && ok=0
    rm -rf -- "$root"
    ((ok == 1))
}
run_test "prunes .git and node_modules subtrees" test_prunes_ignored

# A pre-existing output file is rotated to a timestamped .bak, not clobbered.
test_rotates_previous() {
    local root
    root="$(make_fixture)"
    printf 'previous run marker\n' >"$root/combined_output.txt"
    (cd "$root" && "$BASH_BIN" "$SCRIPT") >/dev/null 2>&1
    local ok=0
    # A backup carrying the old content must now exist alongside the fresh output.
    local bak
    for bak in "$root"/combined_output.txt.bak.*; do
        [[ -f "$bak" ]] && grep -q 'previous run marker' "$bak" && ok=1
    done
    rm -rf -- "$root"
    ((ok == 1))
}
run_test "rotates an existing output file to a .bak" test_rotates_previous

# Regression (defect: the rotated combined_output.txt.bak.<timestamp> was re-collected
# on subsequent runs, nesting the entire previous output inside the fresh one and
# causing unbounded duplication). A second run must not embed any .bak artifact.
test_excludes_bak_on_rerun() {
    local root
    root="$(make_fixture)"
    (cd "$root" && "$BASH_BIN" "$SCRIPT") >/dev/null 2>&1
    (cd "$root" && "$BASH_BIN" "$SCRIPT") >/dev/null 2>&1
    local out="$root/combined_output.txt"
    local ok=1
    grep -q 'START FILE: combined_output.txt' "$out" 2>/dev/null && ok=0
    rm -rf -- "$root"
    ((ok == 1))
}
run_test "excludes rotated .bak output on re-run" test_excludes_bak_on_rerun

# Regression (defect: unknown flags/args were silently ignored, running a full combine
# and exiting 0). An unrecognized argument must fail with a clear error and exit 2.
test_rejects_unknown_arg() {
    local root out _rc=0
    root="$(make_fixture)"
    out="$( (cd "$root" && "$BASH_BIN" "$SCRIPT" --bogus-flag) 2>&1 )" || _rc=$?
    local ok=1
    [[ "$_rc" -eq 2 ]] || ok=0
    printf '%s' "$out" | grep -qi 'unknown argument' || ok=0
    rm -rf -- "$root"
    ((ok == 1))
}
run_test "rejects unknown argument with exit 2" test_rejects_unknown_arg

# Regression (defect: --help/--introspect claimed "Requires: osascript" as a hard
# dependency, but the osascript call is `command -v`-guarded and no-ops off macOS).
# The contract must not advertise osascript as a requirement.
test_help_no_osascript_requirement() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" --help 2>&1 || true)"
    ! printf '%s' "$out" | grep -qi 'osascript'
}
run_test "--help does not claim osascript as a requirement" test_help_no_osascript_requirement

# Opt-in JSON run envelope: --json must not disturb the file it writes and must
# print a single ai.all-f-into-one/v1 object reporting the artifact and counts.
test_json_run_envelope() {
    local root out _rc=0
    root="$(make_fixture)"
    out="$( (cd "$root" && "$BASH_BIN" "$SCRIPT" --json) 2>/dev/null )" || _rc=$?
    local ok=1
    [[ "$_rc" -eq 0 && -f "$root/combined_output.txt" ]] || ok=0
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$out" | jq -e \
            '.schema == "ai.all-f-into-one/v1" and .status == "ok"
             and (.files_combined | numbers) >= 1
             and (.bytes | numbers) >= 1
             and (.output_file | endswith("combined_output.txt"))' >/dev/null || ok=0
    else
        printf '%s' "$out" | grep -q '"schema":"ai.all-f-into-one/v1"' || ok=0
        printf '%s' "$out" | grep -q '"status":"ok"' || ok=0
    fi
    rm -rf -- "$root"
    ((ok == 1))
}
run_test "--json emits an ai.all-f-into-one/v1 run envelope" test_json_run_envelope

# AI_OUTPUT=json is the env form of --json and yields the same envelope schema.
test_env_json_form() {
    local root out
    root="$(make_fixture)"
    out="$( (cd "$root" && AI_OUTPUT=json "$BASH_BIN" "$SCRIPT") 2>/dev/null )"
    local ok=1
    printf '%s' "$out" | grep -q '"schema":"ai.all-f-into-one/v1"' || ok=0
    rm -rf -- "$root"
    ((ok == 1))
}
run_test "AI_OUTPUT=json emits the run envelope" test_env_json_form

# Additive config: AIO_OUTPUT_FILE redirects the artifact and AIO_IGNORE_DIRS
# prunes an extra directory NAME, both without editing the script.
test_env_config() {
    local root out _rc=0
    root="$(mktemp -d)"
    mkdir -p "$root/keepme" "$root/skipme"
    printf 'kept\n' >"$root/keepme/a.txt"
    printf 'dropped\n' >"$root/skipme/b.txt"
    out="$( (cd "$root" && AIO_OUTPUT_FILE="$root/out.txt" AIO_IGNORE_DIRS="skipme" "$BASH_BIN" "$SCRIPT") 2>/dev/null )" || _rc=$?
    local ok=1
    [[ "$_rc" -eq 0 && -f "$root/out.txt" ]] || ok=0
    grep -q 'kept' "$root/out.txt" 2>/dev/null || ok=0
    grep -q 'dropped' "$root/out.txt" 2>/dev/null && ok=0
    rm -rf -- "$root"
    ((ok == 1))
}
run_test "AIO_OUTPUT_FILE + AIO_IGNORE_DIRS honored (additive config)" test_env_config

# Zero-file runs still succeed (exit 0) but emit a distinct stderr note so an
# empty artifact is never silent. Default stdout stays the plain Success line.
test_zero_files_note() {
    local root err_out _rc=0
    root="$(mktemp -d)"
    err_out="$( (cd "$root" && "$BASH_BIN" "$SCRIPT" 2>&1 1>/dev/null) )" || _rc=$?
    local ok=1
    [[ "$_rc" -eq 0 ]] || ok=0
    printf '%s' "$err_out" | grep -qi 'no files were combined' || ok=0
    rm -rf -- "$root"
    ((ok == 1))
}
run_test "empty directory run notes zero files on stderr (exit 0)" test_zero_files_note

# The unknown-argument error now includes an actionable hint pointing at --help.
test_unknown_arg_hint() {
    local root out _rc=0
    root="$(mktemp -d)"
    out="$( (cd "$root" && "$BASH_BIN" "$SCRIPT" --nope) 2>&1 )" || _rc=$?
    local ok=1
    [[ "$_rc" -eq 2 ]] || ok=0
    printf '%s' "$out" | grep -qi -- '--help' || ok=0
    rm -rf -- "$root"
    ((ok == 1))
}
run_test "unknown argument error prints a --help hint" test_unknown_arg_hint

if command -v jq >/dev/null 2>&1; then
    test_json() {
        local out
        out="$("$BASH_BIN" "$SCRIPT" --introspect 2>/dev/null || true)"
        printf '%s' "$out" | jq -e \
            '.status == "ok" and .name == "all-f-into-one"' >/dev/null
    }
    run_test "--introspect emits a valid JSON contract" test_json

    # The JSON flag is now an advertised part of the contract (flags[] was empty).
    test_introspect_flags_json() {
        local out
        out="$("$BASH_BIN" "$SCRIPT" --introspect 2>/dev/null || true)"
        printf '%s' "$out" | jq -e '(.flags // []) | index("--json") != null' >/dev/null
    }
    run_test "--introspect flags advertise --json" test_introspect_flags_json

    # Regression (defect: --introspect listed internal locals ROOT_DIR, OUTPUT_FILE,
    # IGNORE_DIRS, IGNORE_FILE_NAMES, IGNORE_FILE_PATHS, FIND_ARGS in its "env" array,
    # implying env-var configurability the script never honors). None of these
    # hardcoded values are read from the environment, so the contract must not
    # advertise them as environment inputs.
    test_no_false_env_inputs() {
        local out
        out="$("$BASH_BIN" "$SCRIPT" --introspect 2>/dev/null || true)"
        printf '%s' "$out" | jq -e \
            '(.env // []) | any(. as $v | ["ROOT_DIR","OUTPUT_FILE","IGNORE_DIRS","IGNORE_FILE_NAMES","IGNORE_FILE_PATHS","FIND_ARGS"] | index($v)) | not' \
            >/dev/null
    }
    run_test "--introspect env omits non-honored internal vars" test_no_false_env_inputs

    # Regression: osascript must not appear as a required command in the JSON contract.
    test_json_no_osascript_requirement() {
        local out
        out="$("$BASH_BIN" "$SCRIPT" --introspect 2>/dev/null || true)"
        printf '%s' "$out" | jq -e \
            '(.requires // []) | index("osascript") | not' >/dev/null
    }
    run_test "--introspect requires omits osascript" test_json_no_osascript_requirement
else
    skip_test "--introspect emits a valid JSON contract" "jq not available"
    skip_test "--introspect env omits non-honored internal vars" "jq not available"
    skip_test "--introspect requires omits osascript" "jq not available"
fi

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d  Skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
((FAIL == 0)) && printf '\033[0;32mPASSED\033[0m\n' || {
    printf '\033[0;31mFAILED\033[0m\n'
    exit 1
}
