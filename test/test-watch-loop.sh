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
    # Regression (defect 2): debounce value must carry an explicit time unit
    # (watchexec 2.x deprecates bare/unitless spans). Pre-fix this was bare "777".
    grep -q -- "777ms" "$args_file" || return 1
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
    # Regression (defect 1): entr must be invoked with -n so the fallback works
    # in non-TTY (agent/CI/subshell) contexts. Pre-fix -n was never passed.
    grep -qx -- "-n" "$args_file" || return 1
    local log_file="$TMP/logs-entr/watch-loop.jsonl"
    [[ -f "$log_file" ]] || return 1
    jq -e '.event == "watch.start.entr"' "$log_file" >/dev/null
}
run_test "entr branch runs command and logs event (watchexec absent)" test_entr_branch

# Missing command emits a friendly, tool-namespaced usage hint (not a raw
# `${1:?}` file:line message) and exits 1.
test_missing_command_message() {
    local out rc=0
    out="$(AI_LOG_DIR="$TMP/logs-nocmd" "$BASH_BIN" "$SCRIPT" 2>&1)" && rc=0 || rc=$?
    [[ "$rc" == 1 ]] || return 1
    [[ "$out" == *"watch-loop: command required"* ]] || return 1
    [[ "$out" == *"Usage: watch-loop"* ]] || return 1
    # Must NOT leak the internal parameter-expansion file:line reference.
    [[ "$out" != *"line "* ]]
}
run_test "missing command prints friendly usage hint" test_missing_command_message

# --json (opt-in) prints a one-line ai.watch-loop/v1 start envelope on stdout
# BEFORE the watcher runs; the log side effect is preserved.
test_json_envelope_watchexec() {
    local marker="$TMP/wx-json-ran"
    local args_file="$TMP/wx-json-args.txt"
    local out
    rm -f "$marker" "$args_file"
    out="$(PATH="$FAKE_WATCHEXEC_DIR:$BINBASE" \
        AI_LOG_DIR="$TMP/logs-json" \
        WATCH_DEBOUNCE_MS=321 \
        FAKE_WATCHEXEC_ARGS_FILE="$args_file" \
        "$BASH_BIN" "$SCRIPT" --json "touch '$marker'" "sh,md" 2>/dev/null)" || return 1
    [[ -f "$marker" ]] || return 1
    local envelope
    envelope="$(printf '%s\n' "$out" | head -n1)"
    printf '%s' "$envelope" | jq -e '
        .schema == "ai.watch-loop/v1"
        and .status == "ok"
        and .tool == "watch-loop"
        and .backend == "watchexec"
        and .debounceMs == 321
        and (.extensions == ["sh","md"])
        and (.logFile | endswith("watch-loop.jsonl"))' >/dev/null
}
run_test "--json emits ai.watch-loop/v1 start envelope" test_json_envelope_watchexec

# AI_OUTPUT=json is an equivalent opt-in path to the --json flag.
test_ai_output_json_envelope() {
    local marker="$TMP/wx-aiout-ran"
    local out
    rm -f "$marker"
    out="$(PATH="$FAKE_WATCHEXEC_DIR:$BINBASE" \
        AI_LOG_DIR="$TMP/logs-aiout" \
        AI_OUTPUT=json \
        FAKE_WATCHEXEC_ARGS_FILE="$TMP/wx-aiout-args.txt" \
        "$BASH_BIN" "$SCRIPT" "touch '$marker'" 2>/dev/null)" || return 1
    printf '%s\n' "$out" | head -n1 | jq -e '.schema == "ai.watch-loop/v1" and .status == "ok"' >/dev/null
}
run_test "AI_OUTPUT=json emits start envelope" test_ai_output_json_envelope

# Backward compat: default (human) mode prints NO JSON envelope on stdout.
test_default_no_envelope() {
    local marker="$TMP/wx-human-ran"
    local out
    rm -f "$marker"
    out="$(PATH="$FAKE_WATCHEXEC_DIR:$BINBASE" \
        AI_LOG_DIR="$TMP/logs-human" \
        FAKE_WATCHEXEC_ARGS_FILE="$TMP/wx-human-args.txt" \
        "$BASH_BIN" "$SCRIPT" "touch '$marker'" 2>/dev/null)" || return 1
    [[ -f "$marker" ]] || return 1
    [[ "$out" != *"ai.watch-loop/v1"* ]]
}
run_test "default mode prints no JSON envelope" test_default_no_envelope

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
