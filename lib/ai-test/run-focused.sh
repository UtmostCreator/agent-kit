# shellcheck shell=bash
# ai-test/run-focused.sh — run a FOCUSED PHPUnit selection (a --filter pattern
# or a single test file).
#
# Sourced by libexec/ai-test (thin loader). Not an entrypoint. Behavior is
# functionally identical to the previous standalone libexec/run-test-focused,
# wrapped in ai_test_run_main(). Requires AI_TEST_LIBEXEC_DIR (set by the
# loader) to resolve the sibling sh-introspect tool and the repo root, since
# BASH_SOURCE inside a sourced function points at this module file, not the
# libexec/ entrypoint.
#
# Usage:
#   restsift test run --filter <Pattern>
#   restsift test run <path/to/SomeTest.php>
#   restsift test run <path/to/SomeTest.php> --filter <method>
#
# Example:
#   restsift test run --help                 # see accepted forms before running (safe)
#   restsift test run --filter MyThingTest   # run only tests matching MyThingTest

ai_test_run_usage() {
    sed -n '2,19p' "${AI_TEST_LIBEXEC_DIR:?AI_TEST_LIBEXEC_DIR must be set by the loader}/../lib/ai-test/run-focused.sh" | sed 's/^# \{0,1\}//'
}

ai_test_run_main() {
    # Early --help/-h and --introspect guards: answer statically via the
    # pure-Bash sh-introspect sibling and return/exit BEFORE running phpunit.
    # The target module is parsed as text, never executed.
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        local _tool="$AI_TEST_LIBEXEC_DIR/sh-introspect"
        local _target="$AI_TEST_LIBEXEC_DIR/../lib/ai-test/run-focused.sh"
        if [[ -x "$_tool" ]]; then
            exec bash "$_tool" --format=help "$_target"
        fi
        ai_test_run_usage
        exit 0
    fi
    if [[ "${1:-}" == "--introspect" ]]; then
        exec env AI_OUTPUT=json bash "$AI_TEST_LIBEXEC_DIR/sh-introspect" "$AI_TEST_LIBEXEC_DIR/../lib/ai-test/run-focused.sh"
    fi

    # Resolve the CALLER's repository root (where the user invoked the command),
    # NOT the toolkit's own install dir. Prefer the canonical repo_root() helper
    # from lib/paths.sh (loaded via common.sh on the CLI path); fall back to the
    # same git logic when this module is sourced bare (e.g. focused unit tests).
    local ROOT
    if declare -F repo_root >/dev/null 2>&1; then
        ROOT="$(repo_root)"
    else
        ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    fi
    cd "$ROOT" || exit 1

    local TEST_TIMEOUT="${TEST_TIMEOUT:-120}"
    local PHP_BIN="${PHP_BIN:-}"

    if [[ "$#" -eq 0 ]]; then
        echo "ERROR: restsift test run requires a --filter <pattern> or a test file path" >&2
        echo "       e.g. restsift test run --filter ToolGatewayTest" >&2
        exit 2
    fi

    if [[ -z "$PHP_BIN" ]]; then
        if command -v php >/dev/null 2>&1; then
            PHP_BIN="php"
        elif command -v php.exe >/dev/null 2>&1; then
            PHP_BIN="php.exe"
        else
            PHP_BIN="php"
        fi
    fi

    if [[ ! -x vendor/bin/phpunit ]]; then
        echo "ERROR: vendor/bin/phpunit not found; run composer install first" >&2
        exit 1
    fi

    # Resolve a hard-timeout launcher so a hung/focused run is killed, not hung forever.
    local TIMEOUT_BIN=""
    if command -v timeout >/dev/null 2>&1; then
        TIMEOUT_BIN="timeout"
    elif command -v gtimeout >/dev/null 2>&1; then
        TIMEOUT_BIN="gtimeout"
    fi

    # Pass all caller args straight through to phpunit (a --filter pattern, a single
    # file path, or both). phpunit itself validates them, keeping this wrapper thin.
    set -- --configuration phpunit.xml.dist "$@"

    echo "==> focused tests: phpunit $* (timeout ${TEST_TIMEOUT}s)"
    if [[ -n "$TIMEOUT_BIN" ]]; then
        exec "$TIMEOUT_BIN" --kill-after=10s "$TEST_TIMEOUT" "$PHP_BIN" vendor/bin/phpunit "$@"
    fi

    echo "==> warn: no timeout/gtimeout binary; running WITHOUT a time limit" >&2
    exec "$PHP_BIN" vendor/bin/phpunit "$@"
}
