#!/usr/bin/env bash
# Tests for libexec/ai-doctor (the installation/environment doctor).
set -euo pipefail
BASH_BIN="${BASH_BIN:-$(command -v bash)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCTOR="$REPO_ROOT/libexec/ai-doctor"
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

printf 'libexec/ai-doctor\n'

# Text mode prints a health summary and reports the version.
test_text() {
    local out
    out="$("$BASH_BIN" "$DOCTOR" 2>/dev/null)" || return 1
    printf '%s' "$out" | grep -q 'agent-kit doctor' &&
        printf '%s' "$out" | grep -q 'status:'
}
run_test "text mode prints a health summary" test_text

# JSON mode emits a valid ai.doctor/v1 envelope with the required top-level keys.
test_json_envelope() {
    local out
    out="$("$BASH_BIN" "$DOCTOR" --json 2>/dev/null)" || return 1
    printf '%s' "$out" | jq -e '
        .schema=="ai.doctor/v1"
        and (.status|type=="string")
        and .tool=="agent-kit"
        and (.bash.ok|type=="boolean")
        and (.install.on_path|type=="boolean")
        and (.tools.required|type=="array")
        and (.tools.optional|type=="array")
    ' >/dev/null 2>&1
}
run_test "--json emits a valid ai.doctor/v1 envelope" test_json_envelope

# AI_OUTPUT=json is an alias for --json.
test_env_json() {
    local out
    out="$(AI_OUTPUT=json "$BASH_BIN" "$DOCTOR" 2>/dev/null)" || return 1
    printf '%s' "$out" | jq -e '.schema=="ai.doctor/v1"' >/dev/null 2>&1
}
run_test "AI_OUTPUT=json emits the JSON envelope" test_env_json

# The reported version matches the VERSION file.
test_version_match() {
    local out want
    out="$("$BASH_BIN" "$DOCTOR" --json 2>/dev/null)" || return 1
    want="$(tr -d '[:space:]' <"$REPO_ROOT/VERSION")"
    printf '%s' "$out" | jq -e --arg v "$want" '.version==$v' >/dev/null 2>&1
}
run_test "reports the VERSION file value" test_version_match

# Every required tool present -> status is not "error". (git/jq/rg are needed to
# run this suite at all, so they are guaranteed present here.)
test_required_present() {
    local out status
    out="$("$BASH_BIN" "$DOCTOR" --json 2>/dev/null)" || return 1
    status="$(printf '%s' "$out" | jq -r '.status')"
    [[ "$status" != "error" ]]
}
run_test "status is not error when required tools are present" test_required_present

# --help and --introspect resolve through the universal introspection surface.
test_help() {
    "$BASH_BIN" "$DOCTOR" --help 2>/dev/null | grep -q 'installation and environment health'
}
run_test "--help prints the contract" test_help

test_introspect() {
    "$BASH_BIN" "$DOCTOR" --introspect 2>/dev/null | jq -e '.name=="ai-doctor"' >/dev/null 2>&1
}
run_test "--introspect emits the JSON contract" test_introspect

# A required tool missing (PATH holds only what the doctor's JSON path needs,
# minus jq and rg) -> status "error", exit 1.
test_missing_required_errors() {
    local dir out rc=0 t p
    # Symlink exactly the runtime deps the doctor uses on its --json path
    # (bash + coreutils dirname/tr + git) into a scratch bin, leaving jq and rg
    # absent. If any of these can't be located, skip (pass) rather than flake.
    dir="$(mktemp -d)"
    for t in bash dirname tr git; do
        p="$(command -v "$t" 2>/dev/null || true)"
        [[ -n "$p" ]] || {
            rm -rf "$dir"
            return 0
        }
        ln -s "$p" "$dir/$t"
    done
    out="$(PATH="$dir" "$BASH_BIN" "$DOCTOR" --json 2>/dev/null)" || rc=$?
    rm -rf "$dir"
    # jq is gone, so parse with grep instead of jq.
    printf '%s' "$out" | grep -q '"status":"error"' && ((rc == 1))
}
run_test "missing required tool -> error status, exit 1" test_missing_required_errors

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d\n' "$PASS" "$FAIL"
((FAIL == 0)) && printf '\033[0;32mPASSED\033[0m\n' || {
    printf '\033[0;31mFAILED\033[0m\n'
    exit 1
}
