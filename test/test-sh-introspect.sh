#!/usr/bin/env bash
# Tests for libexec/sh-introspect (pure-Bash static introspector).
set -euo pipefail
BASH_BIN="${BASH_BIN:-$(command -v bash)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/libexec/sh-introspect"
TARGET="libexec/ai-rollback"
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

printf 'sh-introspect\n'

test_runs() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" "$TARGET" 2>&1 || true)"
    [[ -n "$out" ]]
}
run_test "text report runs and is non-empty" test_runs

test_help() {
    local out _rc=0
    out="$("$BASH_BIN" "$SCRIPT" --help 2>&1)" || _rc=$?
    [[ "$_rc" -eq 0 && -n "$out" ]]
}
run_test "--help works (exit 0, non-empty)" test_help

test_help_format() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" --format=help "$TARGET" 2>&1 || true)"
    [[ -n "$out" ]]
}
run_test "--format=help renders a compact contract" test_help_format

test_list() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" --list libexec 2>/dev/null || true)"
    printf '%s' "$out" | grep -q 'ai-search'
}
run_test "--list enumerates commands with summaries" test_list

test_introspect_flag() {
    local out _rc=0
    out="$("$BASH_BIN" "$SCRIPT" --introspect 2>&1)" || _rc=$?
    [[ "$_rc" -eq 0 && "$out" == *'"schema"'* ]]
}
run_test "--introspect self-describes via JSON re-exec" test_introspect_flag

test_format_json_eq() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" --format json "$TARGET" 2>&1 || true)"
    [[ -n "$out" ]] && printf '%s' "$out" | grep -q '"schema"'
}
run_test "--format json (space form) renders JSON" test_format_json_eq

test_json_flag_shorthand() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" --json "$TARGET" 2>&1 || true)"
    [[ -n "$out" ]] && printf '%s' "$out" | grep -q '"schema"'
}
run_test "--json shorthand flag renders JSON" test_json_flag_shorthand

test_missing_file_arg_text() {
    local out _rc=0
    out="$("$BASH_BIN" "$SCRIPT" 2>&1)" || _rc=$?
    [[ "$_rc" -eq 2 && "$out" == *"missing FILE argument"* ]]
}
run_test "missing FILE argument fails with text error, exit 2" test_missing_file_arg_text

test_no_such_file_text() {
    local out _rc=0
    out="$("$BASH_BIN" "$SCRIPT" "$TMP/does-not-exist.sh" 2>&1)" || _rc=$?
    [[ "$_rc" -eq 2 && "$out" == *"no such file"* ]]
}
run_test "no such file fails with text error, exit 2" test_no_such_file_text

test_list_missing_dir() {
    local out _rc=0
    out="$("$BASH_BIN" "$SCRIPT" --list "$TMP/no-such-dir" 2>&1)" || _rc=$?
    [[ "$_rc" -eq 2 && "$out" == *"not a directory"* ]]
}
run_test "--list on a missing directory fails, exit 2" test_list_missing_dir

test_list_default_dir() {
    # `--list` with no explicit directory defaults to `.` and should still
    # exercise the shift/consume-arg logic without erroring.
    (
        cd "$TMP" || exit 1
        printf '#!/usr/bin/env bash\n# a fixture script\n' >fixture.sh
        chmod +x fixture.sh
        "$BASH_BIN" "$SCRIPT" --list >/dev/null 2>&1
    )
}
run_test "--list with no directory argument defaults to ." test_list_default_dir

# Fixture with no leading doc-comment block at all: description/usage/examples/
# flags/env/requires should all render as empty in the text report.
FIXTURE_MINIMAL="$TMP/minimal.sh"
cat >"$FIXTURE_MINIMAL" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo hi
EOF
test_minimal_fixture_text() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" "$FIXTURE_MINIMAL" 2>&1 || true)"
    [[ "$out" == *"minimal.sh"* && "$out" == *"(static introspection"* ]]
}
run_test "fixture with no doc comments still renders a minimal report" test_minimal_fixture_text

# Fixture that has no `# Usage:`/`# Example:` header block, but does have a
# `usage() { cat <<EOF ... EOF }` heredoc — exercises extract_usage_heredoc's
# fallback path.
FIXTURE_HEREDOC="$TMP/heredoc-usage.sh"
cat >"$FIXTURE_HEREDOC" <<'EOF'
#!/usr/bin/env bash
# A fixture with a heredoc-based usage function instead of a comment block.
set -euo pipefail
usage() {
    cat <<USAGE
heredoc-usage.sh [--flag]
  runs the fixture
USAGE
}
if [[ "${1:-}" == "--help" ]]; then usage; exit 0; fi
case "${1:-}" in
    --flag) shift ;;
esac
EOF
test_heredoc_usage_fallback() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" "$FIXTURE_HEREDOC" 2>&1 || true)"
    [[ "$out" == *"heredoc-usage.sh [--flag]"* ]]
}
run_test "extract_usage_heredoc fallback picks up heredoc usage() body" test_heredoc_usage_fallback

# Fixture with a `# Modes:` header — exercises the modes convention added for
# shell-completion generation (agent-kit search/edit/context/... subcommands).
FIXTURE_MODES="$TMP/modes-fixture.sh"
cat >"$FIXTURE_MODES" <<'EOF'
#!/usr/bin/env bash
# A fixture declaring modes and an explicit flags override.
#
# Usage:
#   modes-fixture.sh MODE [flags]
#
# Modes: alpha beta gamma
#
# Flags: --explicit --only
case "${1:-}" in
    --unrelated) shift ;;
esac
EOF
test_modes_header_text() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" "$FIXTURE_MODES" 2>&1 || true)"
    [[ "$out" == *"Modes:"* && "$out" == *"alpha beta gamma"* ]]
}
run_test "# Modes: header renders in the text report" test_modes_header_text

test_flags_declared_override() {
    # A declared `# Flags:` block must WIN over the inferred `--foo)` case-label
    # scan — the fixture's case label is `--unrelated`, which must NOT appear.
    local out
    out="$("$BASH_BIN" "$SCRIPT" --format=help "$FIXTURE_MODES" 2>&1 || true)"
    [[ "$out" == *"--explicit"* && "$out" == *"--only"* && "$out" != *"--unrelated"* ]]
}
run_test "declared # Flags: overrides the inferred case-label scan" test_flags_declared_override

if command -v jq >/dev/null 2>&1; then
    test_modes_json() {
        local out
        out="$("$BASH_BIN" "$SCRIPT" --format=json "$FIXTURE_MODES" 2>/dev/null || true)"
        printf '%s' "$out" | jq -e '.modes == ["alpha","beta","gamma"]' >/dev/null
    }
    run_test "JSON contract exposes declared modes" test_modes_json

    test_flags_json_declared() {
        local out
        out="$("$BASH_BIN" "$SCRIPT" --format=json "$FIXTURE_MODES" 2>/dev/null || true)"
        printf '%s' "$out" | jq -e '.flags == ["--explicit","--only"]' >/dev/null
    }
    run_test "JSON contract exposes declared flags override" test_flags_json_declared

    test_flags_sibling_lib_dir() {
        # libexec/ai-search has no case labels of its own — its real flags live
        # in the sibling lib/ai-search/*.sh modules, which extract_flags scans
        # by the repo's fixed thin-loader convention (never by executing or
        # resolving `source` statements).
        local out
        out="$("$BASH_BIN" "$SCRIPT" --format=json "$REPO_ROOT/libexec/ai-search" 2>/dev/null || true)"
        printf '%s' "$out" | jq -e '.flags | index("--max-results") != null' >/dev/null
    }
    run_test "flags scan follows the lib/<name>/ sibling module convention" test_flags_sibling_lib_dir
else
    skip_test "JSON contract exposes declared modes" "jq not available"
    skip_test "JSON contract exposes declared flags override" "jq not available"
    skip_test "flags scan follows the lib/<name>/ sibling module convention" "jq not available"
fi

if command -v jq >/dev/null 2>&1; then
    test_json_envelope() {
        local out
        out="$(AI_OUTPUT=json "$BASH_BIN" "$SCRIPT" "$TARGET" 2>/dev/null || true)"
        printf '%s' "$out" | jq -e \
            '.schema == "ai.sh-introspect/v1" and .status == "ok" and .tool == "sh-introspect" and .meta.target_executed == false and .name == "ai-rollback"' >/dev/null
    }
    run_test "JSON envelope: schema/status/tool/meta/name" test_json_envelope

    test_json_example() {
        local out
        out="$("$BASH_BIN" "$SCRIPT" --format=json "$TARGET" 2>/dev/null || true)"
        printf '%s' "$out" | jq -e '(.examples | length) >= 1 and (.usage | length) >= 1' >/dev/null
    }
    run_test "JSON contract exposes usage and examples" test_json_example

    test_missing_path_error() {
        local out _rc=0
        out="$(AI_OUTPUT=json "$BASH_BIN" "$SCRIPT" "no/such/file.sh" 2>/dev/null)" || _rc=$?
        [[ "$_rc" -eq 2 ]] && printf '%s' "$out" | jq -e '.status == "error"' >/dev/null
    }
    run_test "missing path yields status=error, exit 2 (json)" test_missing_path_error
else
    skip_test "JSON envelope: schema/status/tool/meta/name" "jq not available"
    skip_test "JSON contract exposes usage and examples" "jq not available"
    skip_test "missing path yields status=error, exit 2 (json)" "jq not available"
fi

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d  Skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
((FAIL == 0)) && printf '\033[0;32mPASSED\033[0m\n' || {
    printf '\033[0;31mFAILED\033[0m\n'
    exit 1
}
