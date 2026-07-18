# shellcheck shell=bash
# ai-test/run-all.sh — run the repository's existing test suites with
# parallel-first defaults (the HEAVY, whole-suite runner).
#
# Sourced by libexec/ai-test (thin loader). Not an entrypoint. Behavior is
# functionally identical to the previous standalone libexec/run-repo-tests,
# wrapped in ai_test_all_main() with a module-local prefixed helper name
# (run_job -> ai_test_all_run_job) to avoid collisions when sourced into the
# shared ai-test process. Requires AI_TEST_LIBEXEC_DIR (set by the loader) to
# resolve the sibling sh-introspect tool and the repo root, since BASH_SOURCE
# inside a sourced function points at this module file, not the libexec/
# entrypoint.
#
# Usage:
#   restsift test all             run every discovered suite (heavy)
#
# Example:
#   restsift test all --help           # see options and defaults before running (safe)
#   PARATEST_PROCS=8 restsift test all # run the full suite with 8 parallel workers
#
# Requires: git

ai_test_all_usage() {
    sed -n '2,19p' "${AI_TEST_LIBEXEC_DIR:?AI_TEST_LIBEXEC_DIR must be set by the loader}/../lib/ai-test/run-all.sh" | sed 's/^# \{0,1\}//'
}

# Relies on Bash's dynamic scoping: JOBS/NAMES/LOGS/TMP_DIR/TIMEOUT_BIN/
# SUITE_TIMEOUT are `local` to ai_test_all_main() (the only caller) and stay
# visible here since this function is always invoked from within that scope.
ai_test_all_run_job() {
    local name="$1"
    shift
    local log="$TMP_DIR/${name//[^A-Za-z0-9_.-]/_}.log"

    echo "==> start: $name"
    if [[ -n "$TIMEOUT_BIN" ]]; then
        ("$TIMEOUT_BIN" --kill-after=10s "$SUITE_TIMEOUT" "$@") >"$log" 2>&1 &
    else
        echo "==> warn: no timeout/gtimeout binary; running '$name' WITHOUT a time limit" >&2
        ("$@") >"$log" 2>&1 &
    fi
    JOBS+=("$!")
    NAMES+=("$name")
    LOGS+=("$log")
}

ai_test_all_main() {
    # Early --help/-h and --introspect guards: answer statically via the
    # pure-Bash sh-introspect sibling and return/exit BEFORE running any test
    # suites. The target module is parsed as text, never executed.
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        local _tool="$AI_TEST_LIBEXEC_DIR/sh-introspect"
        local _target="$AI_TEST_LIBEXEC_DIR/../lib/ai-test/run-all.sh"
        if [[ -x "$_tool" ]]; then
            exec bash "$_tool" --format=help "$_target"
        fi
        ai_test_all_usage
        exit 0
    fi
    if [[ "${1:-}" == "--introspect" ]]; then
        exec env AI_OUTPUT=json bash "$AI_TEST_LIBEXEC_DIR/sh-introspect" "$AI_TEST_LIBEXEC_DIR/../lib/ai-test/run-all.sh"
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

    local PARATEST_PROCS="${PARATEST_PROCS:-16}"
    local MAX_PARATEST_PROCS="${MAX_PARATEST_PROCS:-20}"
    local SUITE_TIMEOUT="${SUITE_TIMEOUT:-360}"
    local PHP_BIN="${PHP_BIN:-}"

    if ! [[ "$PARATEST_PROCS" =~ ^[0-9]+$ ]]; then
        echo "ERROR: PARATEST_PROCS must be numeric" >&2
        exit 2
    fi

    if ((PARATEST_PROCS > MAX_PARATEST_PROCS)); then
        PARATEST_PROCS="$MAX_PARATEST_PROCS"
    fi

    if [[ -z "$PHP_BIN" ]]; then
        # Prefer a native (Unix) php. Under WSL the Windows php.exe is on PATH but
        # cannot resolve the \\wsl.localhost\ UNC working directory, so CMD.EXE
        # rejects it and paratest workers crash. Only fall back to php.exe when no
        # native php exists (e.g. Git Bash on real Windows).
        if command -v php >/dev/null 2>&1; then
            PHP_BIN="php"
        elif command -v php.exe >/dev/null 2>&1; then
            PHP_BIN="php.exe"
        else
            PHP_BIN="php"
        fi
    fi

    local TMP_DIR
    TMP_DIR="$(mktemp -d)"
    # Bake the path into the trap at set time: TMP_DIR is `local` to this
    # function and is out of scope when the EXIT trap fires (after the function
    # returns), so a deferred `$TMP_DIR` reference would trip `set -u` with an
    # unbound-variable error. Single-quoting the expansion here captures the
    # concrete path now.
    # shellcheck disable=SC2064 # intentional early expansion of $TMP_DIR
    trap "rm -rf '$TMP_DIR'" EXIT

    local JOBS=()
    local NAMES=()
    local LOGS=()

    # Resolve a hard-timeout launcher once. Each job is bounded by SUITE_TIMEOUT so a
    # hung suite is killed and reported as failed instead of blocking the run forever.
    # Falls back to running unbounded only when no timeout binary is available.
    local TIMEOUT_BIN=""
    if command -v timeout >/dev/null 2>&1; then
        TIMEOUT_BIN="timeout"
    elif command -v gtimeout >/dev/null 2>&1; then
        TIMEOUT_BIN="gtimeout"
    fi

    # Inner $1/$2/$PHP_BIN are expanded by the inner `bash -lc`, not the outer shell.
    # shellcheck disable=SC2016
    ai_test_all_run_job "php-root-tests" \
        bash -lc '
if [[ -x vendor/bin/paratest ]]; then
    exec "$1" vendor/bin/paratest --configuration phpunit.xml.dist --processes="$2" --runner=WrapperRunner
fi

if [[ -x vendor/bin/phpunit ]]; then
    exec "$1" vendor/bin/phpunit --configuration phpunit.xml.dist
fi

echo "ERROR: neither vendor/bin/paratest nor vendor/bin/phpunit is available" >&2
exit 1
' _ "$PHP_BIN" "$PARATEST_PROCS"

    ai_test_all_run_job "script-tests" \
        bash tests/scripts/ai/run-all-tests.sh

    local bats_path
    bats_path="$(command -v bats 2>/dev/null || true)"
    if [[ -n "$bats_path" ]] && [[ -d tests/shell ]]; then
        if file tests/shell/*.bats 2>/dev/null | grep -q 'CRLF'; then
            echo "==> skip: bats-shell-tests (CRLF checkout; normalize *.bats to LF to run under Bash/Bats)"
        elif [[ "$bats_path" == /mnt/c/* || "$bats_path" == *.exe ]]; then
            # A Windows-hosted bats on PATH (common under WSL) has a CRLF shebang
            # and cannot run Linux test files; skip instead of failing the suite.
            echo "==> skip: bats-shell-tests (Windows bats at $bats_path is unusable under WSL; install a native bats)"
        elif ! bats --version >/dev/null 2>&1; then
            echo "==> skip: bats-shell-tests (bats smoke check failed; install a native bats)"
        else
            ai_test_all_run_job "bats-shell-tests" bats tests/shell
        fi
    else
        echo "==> skip: bats-shell-tests (bats not installed or tests/shell missing)"
    fi

    if [[ -f packages/ai-kit-tests/phpunit.xml.dist ]] && [[ -d packages/ai-kit-tests/tests ]]; then
        if find packages/ai-kit-tests/tests -type f -name '*Test.php' -print -quit | grep -q .; then
            ai_test_all_run_job "php-paratest-package" \
                "$PHP_BIN" packages/ai-kit-tests/vendor/bin/paratest \
                --configuration packages/ai-kit-tests/phpunit.xml.dist \
                --processes="$PARATEST_PROCS" \
                --runner=WrapperRunner
        else
            echo "==> skip: php-paratest-package (no package Test.php files yet)"
        fi
    fi

    local failures=0
    local i pid name log rc
    for i in "${!JOBS[@]}"; do
        pid="${JOBS[$i]}"
        name="${NAMES[$i]}"
        log="${LOGS[$i]}"
        set +e
        wait "$pid"
        rc=$?
        set -e

        if ((rc == 0)); then
            echo "==> pass: $name"
        else
            echo "==> fail: $name (exit $rc)" >&2
            failures=$((failures + 1))
        fi

        echo "--- $name log ---"
        cat "$log"
        echo "--- end $name log ---"
    done

    echo "==> validators"
    "$PHP_BIN" tools/ai/validate-ai-config.php
    "$PHP_BIN" tools/ai/validate-ai-catalog.php
    "$PHP_BIN" tools/ai/validate-generated-artifacts.php
    "$PHP_BIN" tools/ai/validate-install-surface.php --strict

    if ((failures > 0)); then
        echo "ERROR: $failures parallel test job(s) failed" >&2
        exit 1
    fi

    echo "==> all repo tests passed"
}
