#!/usr/bin/env bash
# Tests for libexec/ai-inspect (the read-only inspection router).
#
# Focus: the `inspect data ...` route must surface missing-argument errors
# through the file's own die() convention ([ERROR] ... + exit 1), never a raw
# bash parameter-expansion trace, and must honor AI_OUTPUT=json the same way
# every other error path in ai-structured does.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/libexec/ai-inspect"
cd "$REPO_ROOT"
BASH_BIN="${BASH_BIN:-$(command -v bash)}"

PASS=0 FAIL=0 SKIP=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

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

printf 'ai-inspect\n'

# --help prints the router usage banner.
test_help() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" --help 2>&1)"
    [[ "$out" == *"restsift inspect"* ]]
}
run_test "--help prints usage" test_help

# Unknown mode exits non-zero with a clear message.
test_unknown_mode() {
    local out _rc=0
    out="$("$BASH_BIN" "$SCRIPT" bogus 2>&1)" || _rc=$?
    [[ "$_rc" -ne 0 && "$out" == *"unknown mode"* ]]
}
run_test "unknown mode fails with message" test_unknown_mode

# REGRESSION (defect: no machine-readable contract): `--introspect` as the first
# argument must emit this router's own ai.sh-introspect/v1 JSON envelope and exit
# 0, matching every peer command, not fall through to the unknown-mode branch.
test_introspect_contract() {
    local out _rc=0
    out="$("$BASH_BIN" "$SCRIPT" --introspect 2>&1)" || _rc=$?
    [[ "$_rc" -eq 0 && "$out" == *'"ai.sh-introspect/v1"'* \
        && "$out" == *'"name":"ai-inspect"'* && "$out" != *"unknown mode"* ]]
}
run_test "--introspect emits the JSON contract" test_introspect_contract

# Unknown mode prints an actionable next-step hint on the default error path,
# while keeping the pre-existing "unknown mode" message and exit code 2.
test_unknown_mode_hint() {
    local out _rc=0
    out="$("$BASH_BIN" "$SCRIPT" bogus 2>&1)" || _rc=$?
    [[ "$_rc" -eq 2 && "$out" == *"unknown mode"* && "$out" == *"inspect --help"* ]]
}
run_test "unknown mode prints a --help hint" test_unknown_mode_hint

# Under AI_OUTPUT=json the unknown-mode failure emits a parseable ai.inspect/v1
# error envelope (schema + status=error + tool) and still exits 2.
test_unknown_mode_json_envelope() {
    if ! command -v jq >/dev/null 2>&1; then return 0; fi
    local out _rc=0
    out="$(AI_OUTPUT=json "$BASH_BIN" "$SCRIPT" bogus 2>&1)" || _rc=$?
    [[ "$_rc" -eq 2 ]] || return 1
    printf '%s' "$out" | jq -e \
        '.schema == "ai.inspect/v1" and .status == "error" and .tool == "inspect" and (.error | test("bogus"))' \
        >/dev/null
}
run_test "unknown mode emits ai.inspect/v1 error envelope under AI_OUTPUT=json" test_unknown_mode_json_envelope

# data mode routes a well-formed json query through to the engine.
test_data_json() {
    printf '{"name":"restsift"}\n' >"$TMP/probe.json"
    local out
    out="$("$BASH_BIN" "$SCRIPT" data json "$TMP/probe.json" '.name' 2>/dev/null)"
    [[ "$out" == *"restsift"* ]]
}
run_test "data json routes to the engine" test_data_json

# REGRESSION (defect 1): `inspect data json FILE` with the jq QUERY omitted must
# die() with the file's own [ERROR] format, not leak a raw bash trace such as
# "ai-structured: line 54: 2: jq query required".
test_data_json_missing_query_format() {
    printf '{"a":1}\n' >"$TMP/probe2.json"
    local out _rc=0
    out="$("$BASH_BIN" "$SCRIPT" data json "$TMP/probe2.json" 2>&1)" || _rc=$?
    [[ "$_rc" -ne 0 && "$out" == *"[ERROR]"* && "$out" == *"jq query required"* \
        && "$out" != *"line "* ]]
}
run_test "data json without query fails via die() format" test_data_json_missing_query_format

# REGRESSION (defect 1): missing-query error must stay clean under AI_OUTPUT=json
# (no raw bash parameter-expansion trace leaking the file path / line number).
test_data_json_missing_query_json_output() {
    printf '{"a":1}\n' >"$TMP/probe3.json"
    local out _rc=0
    out="$(AI_OUTPUT=json "$BASH_BIN" "$SCRIPT" data json "$TMP/probe3.json" 2>&1)" || _rc=$?
    [[ "$_rc" -ne 0 && "$out" == *"jq query required"* \
        && "$out" != *"line "* && "$out" != *"ai-structured:"* ]]
}
run_test "data json without query is clean under AI_OUTPUT=json" test_data_json_missing_query_json_output

# REGRESSION (defect 1): `inspect data json` with FILE itself omitted must die()
# with the [ERROR] format, not the raw "line 53: 1: file required" trace.
test_data_json_missing_file_format() {
    local out _rc=0
    out="$("$BASH_BIN" "$SCRIPT" data json 2>&1)" || _rc=$?
    [[ "$_rc" -ne 0 && "$out" == *"[ERROR]"* && "$out" == *"file required"* \
        && "$out" != *"line "* ]]
}
run_test "data json without file fails via die() format" test_data_json_missing_file_format

# REGRESSION (defect 1): validate-json with FILE omitted uses the die() format.
test_data_validate_json_missing_file_format() {
    local out _rc=0
    out="$("$BASH_BIN" "$SCRIPT" data validate-json 2>&1)" || _rc=$?
    [[ "$_rc" -ne 0 && "$out" == *"[ERROR]"* && "$out" == *"file required"* \
        && "$out" != *"line "* ]]
}
run_test "data validate-json without file fails via die() format" test_data_validate_json_missing_file_format

# REGRESSION (defect 1): csv with FILE omitted uses the die() format.
test_data_csv_missing_file_format() {
    local out _rc=0
    out="$("$BASH_BIN" "$SCRIPT" data csv 2>&1)" || _rc=$?
    [[ "$_rc" -ne 0 && "$out" == *"[ERROR]"* && "$out" == *"file required"* \
        && "$out" != *"line "* ]]
}
run_test "data csv without file fails via die() format" test_data_csv_missing_file_format

# REGRESSION (defect 1): xml with FILE omitted uses the die() format.
test_data_xml_missing_file_format() {
    local out _rc=0
    out="$("$BASH_BIN" "$SCRIPT" data xml 2>&1)" || _rc=$?
    [[ "$_rc" -ne 0 && "$out" == *"[ERROR]"* && "$out" == *"file required"* \
        && "$out" != *"line "* ]]
}
run_test "data xml without file fails via die() format" test_data_xml_missing_file_format

# REGRESSION (defect 1): yaml with QUERY omitted uses the die() format.
if command -v yq >/dev/null 2>&1; then
    test_data_yaml_missing_query_format() {
        printf 'key: value\n' >"$TMP/probe.yaml"
        local out _rc=0
        out="$("$BASH_BIN" "$SCRIPT" data yaml "$TMP/probe.yaml" 2>&1)" || _rc=$?
        [[ "$_rc" -ne 0 && "$out" == *"[ERROR]"* && "$out" == *"yq query required"* \
            && "$out" != *"line "* ]]
    }
    run_test "data yaml without query fails via die() format" test_data_yaml_missing_query_format
else
    skip_test "data yaml without query fails via die() format" "yq not installed"
fi

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d  Skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
((FAIL == 0)) && printf '\033[0;32mPASSED\033[0m\n' || {
    printf '\033[0;31mFAILED\033[0m\n'
    exit 1
}
