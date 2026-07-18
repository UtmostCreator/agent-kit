#!/usr/bin/env bash
# Tests for libexec/ai-structured
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/libexec/ai-structured"
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

printf 'ai-structured\n'

# Missing mode shows usage
test_no_mode() { ! "$BASH_BIN" "$SCRIPT" 2>/dev/null; }
run_test "missing mode exits with error" test_no_mode

# json mode on a repo JSON file
test_json() {
    local out
    printf '{"name":"restsift"}\n' >"$TMP/probe.json"
    out="$("$BASH_BIN" "$SCRIPT" json "$TMP/probe.json" '.name' 2>/dev/null)"
    [[ -n "$out" ]]
}
run_test "json mode queries a JSON file" test_json

# validate-json on valid file
test_validate_json_valid() {
    echo '{"key":"value"}' >"$TMP/valid.json"
    "$BASH_BIN" "$SCRIPT" validate-json "$TMP/valid.json" 2>/dev/null
}
run_test "validate-json passes for valid JSON" test_validate_json_valid

# validate-json under AI_OUTPUT=json emits the ai.ai-structured/v1 envelope on
# stdout with the expected schema/status/mode/valid/root_type keys.
test_validate_json_envelope() {
    printf '{"key":"value"}\n' >"$TMP/env.json"
    local out
    out="$(AI_OUTPUT=json "$BASH_BIN" "$SCRIPT" validate-json "$TMP/env.json" 2>/dev/null)"
    [[ "$(jq -r '.schema' <<<"$out")" == "ai.ai-structured/v1" ]] &&
        [[ "$(jq -r '.status' <<<"$out")" == "ok" ]] &&
        [[ "$(jq -r '.tool' <<<"$out")" == "ai-structured" ]] &&
        [[ "$(jq -r '.mode' <<<"$out")" == "validate-json" ]] &&
        [[ "$(jq -r '.valid' <<<"$out")" == "true" ]] &&
        [[ "$(jq -r '.root_type' <<<"$out")" == "object" ]]
}
run_test "validate-json AI_OUTPUT=json emits ai.ai-structured/v1 envelope" test_validate_json_envelope

# Backward compat: the default (no AI_OUTPUT) validate-json path prints nothing
# to stdout; the human [OK] line stays on stderr.
test_validate_json_default_stdout_empty() {
    printf '{"key":"value"}\n' >"$TMP/def.json"
    local out
    out="$("$BASH_BIN" "$SCRIPT" validate-json "$TMP/def.json" 2>/dev/null)"
    [[ -z "$out" ]]
}
run_test "validate-json default mode keeps stdout empty" test_validate_json_default_stdout_empty

# validate-json on invalid file
test_validate_json_invalid() {
    echo '{invalid' >"$TMP/invalid.json"
    ! "$BASH_BIN" "$SCRIPT" validate-json "$TMP/invalid.json" 2>/dev/null
}
run_test "validate-json fails for invalid JSON" test_validate_json_invalid

# validate-json rejects an empty or whitespace-only file (no JSON value is not
# valid JSON; regression: empty file used to report "[OK] valid JSON").
test_validate_json_empty() {
    : >"$TMP/empty.json"
    ! "$BASH_BIN" "$SCRIPT" validate-json "$TMP/empty.json" 2>/dev/null
}
run_test "validate-json fails for empty file" test_validate_json_empty

test_validate_json_whitespace() {
    printf '   \n' >"$TMP/ws.json"
    ! "$BASH_BIN" "$SCRIPT" validate-json "$TMP/ws.json" 2>/dev/null
}
run_test "validate-json fails for whitespace-only file" test_validate_json_whitespace

# yaml mode
if command -v yq >/dev/null 2>&1; then
    test_yaml() {
        echo -e "key: value\nlist:\n  - a\n  - b" >"$TMP/test.yaml"
        local out
        out="$("$BASH_BIN" "$SCRIPT" yaml "$TMP/test.yaml" '.key' 2>/dev/null)"
        [[ "$out" == *"value"* ]]
    }
    run_test "yaml mode queries YAML files" test_yaml

    test_validate_yaml_valid() {
        echo "key: value" >"$TMP/valid.yaml"
        "$BASH_BIN" "$SCRIPT" validate-yaml "$TMP/valid.yaml" 2>/dev/null
    }
    run_test "validate-yaml passes for valid YAML" test_validate_yaml_valid

    # validate-yaml under AI_OUTPUT=json emits the ai.ai-structured/v1 envelope.
    test_validate_yaml_envelope() {
        echo "key: value" >"$TMP/env.yaml"
        local out
        out="$(AI_OUTPUT=json "$BASH_BIN" "$SCRIPT" validate-yaml "$TMP/env.yaml" 2>/dev/null)"
        [[ "$(jq -r '.schema' <<<"$out")" == "ai.ai-structured/v1" ]] &&
            [[ "$(jq -r '.status' <<<"$out")" == "ok" ]] &&
            [[ "$(jq -r '.mode' <<<"$out")" == "validate-yaml" ]] &&
            [[ "$(jq -r '.valid' <<<"$out")" == "true" ]] &&
            [[ "$(jq -r '.root_type' <<<"$out")" == "object" ]]
    }
    run_test "validate-yaml AI_OUTPUT=json emits ai.ai-structured/v1 envelope" test_validate_yaml_envelope
else
    skip_test "yaml mode queries YAML files" "yq not installed"
    skip_test "validate-yaml passes for valid YAML" "yq not installed"
    skip_test "validate-yaml AI_OUTPUT=json emits ai.ai-structured/v1 envelope" "yq not installed"
fi

# csv mode
test_csv() {
    printf 'name,age\nAlice,30\nBob,25\n' >"$TMP/test.csv"
    local out
    out="$("$BASH_BIN" "$SCRIPT" csv "$TMP/test.csv" 2>/dev/null)"
    [[ "$out" == *"Alice"* ]]
}
run_test "csv mode shows CSV content" test_csv

# csv --head N
test_csv_head() {
    printf 'name,age\nAlice,30\nBob,25\nCharlie,35\n' >"$TMP/head.csv"
    local out
    out="$("$BASH_BIN" "$SCRIPT" csv "$TMP/head.csv" --head 2 2>/dev/null)"
    [[ "$out" == *"Alice"* ]]
}
run_test "csv --head limits output" test_csv_head

# Missing file fails
test_missing_file() {
    ! "$BASH_BIN" "$SCRIPT" json "$TMP/nonexistent.json" '.key' 2>/dev/null
}
run_test "missing file fails" test_missing_file

# --help / -h
test_help() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" --help 2>&1)"
    [[ "$out" == *"Usage:"* ]]
}
run_test "--help prints usage" test_help

test_help_short() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" -h 2>&1)"
    [[ "$out" == *"Usage:"* ]]
}
run_test "-h prints usage" test_help_short

# Unknown mode fails via the case default arm (distinct from the earlier
# "missing mode" early-exit check).
test_unknown_mode() {
    local out _rc=0
    out="$("$BASH_BIN" "$SCRIPT" bogus-mode 2>&1)" || _rc=$?
    [[ "$_rc" -ne 0 && "$out" == *"unknown mode: bogus-mode"* ]]
}
run_test "unknown mode fails with usage + error" test_unknown_mode

# json mode with a missing query argument hits the ":?jq query required" guard.
test_json_missing_query() {
    printf '{"a":1}\n' >"$TMP/probe2.json"
    ! "$BASH_BIN" "$SCRIPT" json "$TMP/probe2.json" 2>/dev/null
}
run_test "json mode without query fails" test_json_missing_query

# json mode with a missing file argument emits the script's own [ERROR]
# format via die(), not a raw bash parameter-expansion trace (regression:
# ${1:?file required} leaked "line NN: 1: file required").
test_json_missing_file_arg_format() {
    local out _rc=0
    out="$("$BASH_BIN" "$SCRIPT" json 2>&1)" || _rc=$?
    [[ "$_rc" -ne 0 && "$out" == *"[ERROR]"* && "$out" == *"file required"* \
        && "$out" != *"line "* ]]
}
run_test "json without file arg fails via die() format" test_json_missing_file_arg_format

# validate-json on a missing file hits "file not found".
test_validate_json_missing_file() {
    local out _rc=0
    out="$("$BASH_BIN" "$SCRIPT" validate-json "$TMP/no-such.json" 2>&1)" || _rc=$?
    [[ "$_rc" -ne 0 && "$out" == *"file not found"* ]]
}
run_test "validate-json on missing file fails with message" test_validate_json_missing_file

if command -v yq >/dev/null 2>&1; then
    # yml is an alias for yaml.
    test_yml_alias() {
        echo "key: value" >"$TMP/alias.yaml"
        local out
        out="$("$BASH_BIN" "$SCRIPT" yml "$TMP/alias.yaml" '.key' 2>/dev/null)"
        [[ "$out" == *"value"* ]]
    }
    run_test "yml is an alias for yaml" test_yml_alias

    # validate-yml is an alias for validate-yaml.
    test_validate_yml_alias() {
        echo "key: value" >"$TMP/alias-validate.yaml"
        "$BASH_BIN" "$SCRIPT" validate-yml "$TMP/alias-validate.yaml" 2>/dev/null
    }
    run_test "validate-yml is an alias for validate-yaml" test_validate_yml_alias

    # validate-yaml on invalid YAML fails.
    test_validate_yaml_invalid() {
        printf 'key: [unterminated\n' >"$TMP/invalid.yaml"
        ! "$BASH_BIN" "$SCRIPT" validate-yaml "$TMP/invalid.yaml" 2>/dev/null
    }
    run_test "validate-yaml fails for invalid YAML" test_validate_yaml_invalid
else
    skip_test "yml is an alias for yaml" "yq not installed"
    skip_test "validate-yml is an alias for validate-yaml" "yq not installed"
    skip_test "validate-yaml fails for invalid YAML" "yq not installed"
fi

# csv --head=N (equals form)
test_csv_head_equals() {
    printf 'name,age\nAlice,30\nBob,25\nCharlie,35\n' >"$TMP/head-eq.csv"
    local out
    out="$("$BASH_BIN" "$SCRIPT" csv "$TMP/head-eq.csv" --head=2 2>/dev/null)"
    [[ "$out" == *"name,age"* && "$out" == *"Alice"* && "$out" != *"Bob"* ]]
}
run_test "csv --head=N (equals form) limits output" test_csv_head_equals

# csv with an unrecognized option dies.
test_csv_unknown_option() {
    printf 'a,b\n1,2\n' >"$TMP/unk.csv"
    local out _rc=0
    out="$("$BASH_BIN" "$SCRIPT" csv "$TMP/unk.csv" --bogus 2>&1)" || _rc=$?
    [[ "$_rc" -ne 0 && "$out" == *"unknown option: --bogus"* ]]
}
run_test "csv with unknown option fails" test_csv_unknown_option

# csv --head with no following value hits the ":?head count required" guard.
test_csv_head_missing_value() {
    printf 'a,b\n1,2\n' >"$TMP/noval.csv"
    ! "$BASH_BIN" "$SCRIPT" csv "$TMP/noval.csv" --head 2>/dev/null
}
run_test "csv --head without a value fails" test_csv_head_missing_value

# csv --head with a non-numeric value is rejected by the script's own die()
# validation, not left to leak a raw coreutils "head: invalid number" error
# (regression: --head abc fell through to `head -n abc`).
test_csv_head_non_numeric() {
    printf 'a,b\n1,2\n' >"$TMP/nonnum.csv"
    local out _rc=0
    out="$("$BASH_BIN" "$SCRIPT" csv "$TMP/nonnum.csv" --head abc 2>&1)" || _rc=$?
    [[ "$_rc" -ne 0 && "$out" == *"[ERROR]"* && "$out" == *"--head requires a numeric value"* \
        && "$out" != *"invalid number of lines"* ]]
}
run_test "csv --head with non-numeric value fails" test_csv_head_non_numeric

# csv on a missing file hits "file not found".
test_csv_missing_file() {
    local out _rc=0
    out="$("$BASH_BIN" "$SCRIPT" csv "$TMP/nope.csv" 2>&1)" || _rc=$?
    [[ "$_rc" -ne 0 && "$out" == *"file not found"* ]]
}
run_test "csv on missing file fails with message" test_csv_missing_file

# xml mode without xmllint installed dies with a clear message.
if ! command -v xmllint >/dev/null 2>&1; then
    test_xml_no_xmllint() {
        printf '<a><b>1</b></a>\n' >"$TMP/probe.xml"
        local out _rc=0
        out="$("$BASH_BIN" "$SCRIPT" xml "$TMP/probe.xml" 2>&1)" || _rc=$?
        [[ "$_rc" -ne 0 && "$out" == *"xmllint not installed"* ]]
    }
    run_test "xml mode without xmllint dies with a clear message" test_xml_no_xmllint
else
    skip_test "xml mode without xmllint dies with a clear message" "xmllint is installed"
fi

# xml mode with a fake xmllint on PATH: exercises both the --format
# (no xpath) and --xpath (xpath given) branches.
FAKE_XMLLINT_DIR="$TMP/fake-xmllint"
mkdir -p "$FAKE_XMLLINT_DIR"
cat >"$FAKE_XMLLINT_DIR/xmllint" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$FAKE_XMLLINT_ARGS_FILE"
exit 0
FAKE
chmod +x "$FAKE_XMLLINT_DIR/xmllint"

test_xml_format_branch() {
    printf '<a><b>1</b></a>\n' >"$TMP/fmt.xml"
    local args_file="$TMP/xmllint-format-args.txt"
    PATH="$FAKE_XMLLINT_DIR:$PATH" FAKE_XMLLINT_ARGS_FILE="$args_file" \
        "$BASH_BIN" "$SCRIPT" xml "$TMP/fmt.xml" >/dev/null 2>&1 || return 1
    grep -q -- "--format" "$args_file"
}
run_test "xml mode without xpath uses --format" test_xml_format_branch

test_xml_xpath_branch() {
    printf '<a><b>1</b></a>\n' >"$TMP/xp.xml"
    local args_file="$TMP/xmllint-xpath-args.txt"
    PATH="$FAKE_XMLLINT_DIR:$PATH" FAKE_XMLLINT_ARGS_FILE="$args_file" \
        "$BASH_BIN" "$SCRIPT" xml "$TMP/xp.xml" '//b' >/dev/null 2>&1 || return 1
    grep -q -- "--xpath" "$args_file" && grep -q -- "//b" "$args_file"
}
run_test "xml mode with xpath uses --xpath" test_xml_xpath_branch

# xml mode on a missing file hits "file not found" (before xmllint even runs).
test_xml_missing_file() {
    local out _rc=0
    out="$("$BASH_BIN" "$SCRIPT" xml "$TMP/nope.xml" 2>&1)" || _rc=$?
    [[ "$_rc" -ne 0 && "$out" == *"file not found"* ]]
}
run_test "xml mode on missing file fails with message" test_xml_missing_file

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d  Skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
((FAIL == 0)) && printf '\033[0;32mPASSED\033[0m\n' || {
    printf '\033[0;31mFAILED\033[0m\n'
    exit 1
}
