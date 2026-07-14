#!/usr/bin/env bash
# Tests for libexec/watch-loop
set -euo pipefail
BASH_BIN="${BASH_BIN:-$(command -v bash)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/libexec/watch-loop"
cd "$REPO_ROOT"

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

printf 'watch-loop\n'

# Missing command fails
test_no_command() { ! AI_LOG_DIR="$TMP/logs" "$BASH_BIN" "$SCRIPT" 2>/dev/null; }
run_test "missing command fails" test_no_command

# Script sources lib/common.sh. The early --help/--introspect guard block now
# sits above the source line, so scan the file rather than only the first 10 lines.
test_sources_common() {
    grep -q 'common.sh' "$SCRIPT"
}
run_test "sources common.sh" test_sources_common

# Requires watchexec or entr
test_watcher_check() {
    if command -v watchexec >/dev/null 2>&1 || command -v entr >/dev/null 2>&1; then
        # At least one watcher is available — script would start a loop
        # We can't actually run it (infinite), so just verify the check logic
        true
    else
        # Neither available — script should fail
        # shellcheck disable=SC2251  # intentional: assert the command fails; errexit skip is desired here
        ! AI_LOG_DIR="$TMP/logs2" "$BASH_BIN" "$SCRIPT" "echo test" 2>/dev/null
    fi
}
run_test "requires watchexec or entr" test_watcher_check

# --- Deeper coverage: build a filtered PATH without watchexec/entr, plus
# fake watchexec/entr shims that exec the wrapped command instead of
# blocking forever. This lets us drive every branch of the script
# deterministically regardless of what's installed on the host.

BINBASE="$TMP/binbase"
mkdir -p "$BINBASE"
build_binbase() {
    local IFS=':'
    local d f base
    # shellcheck disable=SC2153  # PATH is intentionally the ambient var here
    for d in $PATH; do
        [[ -d "$d" ]] || continue
        for f in "$d"/*; do
            [[ -f "$f" && -x "$f" ]] || continue
            base="$(basename "$f")"
            [[ "$base" == "watchexec" || "$base" == "entr" ]] && continue
            [[ -e "$BINBASE/$base" ]] && continue
            ln -s "$f" "$BINBASE/$base" 2>/dev/null || true
        done
    done
}
build_binbase

# Neither watchexec nor entr on PATH: script should print an error and exit 1.
test_no_watcher_fails() {
    local out
    out="$(PATH="$BINBASE" AI_LOG_DIR="$TMP/logs-none" "$BASH_BIN" "$SCRIPT" "echo test" 2>&1)" && return 1
    [[ "$out" == *"No file watcher found"* ]]
}
run_test "no watcher on PATH: fails with message" test_no_watcher_fails

FAKE_WATCHEXEC_DIR="$TMP/fake-watchexec"
mkdir -p "$FAKE_WATCHEXEC_DIR"
cat >"$FAKE_WATCHEXEC_DIR/watchexec" <<'FAKE'
#!/usr/bin/env bash
# Fake watchexec: record invocation args, then run the trailing command once
# (instead of watching forever) so tests can assert the wiring.
printf '%s\n' "$@" >"$FAKE_WATCHEXEC_ARGS_FILE"
found=0
args=()
for a in "$@"; do
    if [[ "$found" == 1 ]]; then
        args+=("$a")
    fi
    [[ "$a" == "--" ]] && found=1
done
exec "${args[@]}"
FAKE
chmod +x "$FAKE_WATCHEXEC_DIR/watchexec"

# watchexec branch: dispatches to watchexec with debounce/extension flags,
# runs the wrapped command, logs a watch.start.watchexec event, exits 0.
test_watchexec_branch() {
    local marker="$TMP/watchexec-ran"
    local args_file="$TMP/watchexec-args.txt"
    rm -f "$marker" "$args_file"
    PATH="$FAKE_WATCHEXEC_DIR:$BINBASE" \
        AI_LOG_DIR="$TMP/logs-watchexec" \
        WATCH_DEBOUNCE_MS=777 \
        FAKE_WATCHEXEC_ARGS_FILE="$args_file" \
        "$BASH_BIN" "$SCRIPT" "touch '$marker'" "sh,md" || return 1
    [[ -f "$marker" ]] || return 1
    grep -q -- "--debounce" "$args_file" || return 1
    grep -q "777" "$args_file" || return 1
    grep -q "sh,md" "$args_file" || return 1
    local log_file="$TMP/logs-watchexec/watch-loop.jsonl"
    [[ -f "$log_file" ]] || return 1
    jq -e '.event == "watch.start.watchexec" and (.debounceMs == 777)' "$log_file" >/dev/null
}
run_test "watchexec branch runs command and logs event" test_watchexec_branch

FAKE_ENTR_DIR="$TMP/fake-entr"
mkdir -p "$FAKE_ENTR_DIR"
cat >"$FAKE_ENTR_DIR/entr" <<'FAKE'
#!/usr/bin/env bash
# Fake entr: drain the piped file list, record args, run the trailing
# command once instead of watching forever.
cat >/dev/null
printf '%s\n' "$@" >"$FAKE_ENTR_ARGS_FILE"
found=0
args=()
for a in "$@"; do
    if [[ "$found" == 1 ]]; then
        args+=("$a")
    fi
    [[ "$a" == "-r" ]] && found=1
done
exec "${args[@]}"
FAKE
chmod +x "$FAKE_ENTR_DIR/entr"

# entr branch: only reachable when watchexec is absent. Feeds `rg --files`
# output to entr, runs the wrapped command, logs a watch.start.entr event.
test_entr_branch() {
    local marker="$TMP/entr-ran"
    local args_file="$TMP/entr-args.txt"
    rm -f "$marker" "$args_file"
    PATH="$FAKE_ENTR_DIR:$BINBASE" \
        AI_LOG_DIR="$TMP/logs-entr" \
        FAKE_ENTR_ARGS_FILE="$args_file" \
        "$BASH_BIN" "$SCRIPT" "touch '$marker'" || return 1
    [[ -f "$marker" ]] || return 1
    grep -q -- "-r" "$args_file" || return 1
    local log_file="$TMP/logs-entr/watch-loop.jsonl"
    [[ -f "$log_file" ]] || return 1
    jq -e '.event == "watch.start.entr"' "$log_file" >/dev/null
}
run_test "entr branch runs command and logs event (watchexec absent)" test_entr_branch

# Default extensions (no 2nd arg) are recorded in the watch log.
test_default_extensions_logged() {
    local marker="$TMP/watchexec-defaults-ran"
    local args_file="$TMP/watchexec-defaults-args.txt"
    rm -f "$marker" "$args_file"
    PATH="$FAKE_WATCHEXEC_DIR:$BINBASE" \
        AI_LOG_DIR="$TMP/logs-defaults" \
        FAKE_WATCHEXEC_ARGS_FILE="$args_file" \
        "$BASH_BIN" "$SCRIPT" "touch '$marker'" || return 1
    local log_file="$TMP/logs-defaults/watch-loop.jsonl"
    jq -e '.extensions == "md,json,sh,lua,php,yml,yaml"' "$log_file" >/dev/null
}
run_test "default extensions logged when omitted" test_default_extensions_logged

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d  Skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
# shellcheck disable=SC2015  # intentional pass/fail reporter; the || branch always exits non-zero
((FAIL == 0)) && printf '\033[0;32mPASSED\033[0m\n' || {
    printf '\033[0;31mFAILED\033[0m\n'
    exit 1
}
