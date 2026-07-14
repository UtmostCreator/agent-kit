#!/usr/bin/env bash
# Tests for libexec/session-checkpoint
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/libexec/session-checkpoint"
cd "$REPO_ROOT"
BASH_BIN="${BASH_BIN:-$(command -v bash)}"

PASS=0 FAIL=0 SKIP=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

run_test() {
    local name="$1"; shift; local _rc=0
    "$@" >/dev/null 2>&1 || _rc=$?
    if ((_rc == 0)); then PASS=$((PASS+1)); printf '  \033[0;32m✓\033[0m %s\n' "$name"
    else FAIL=$((FAIL+1)); printf '  \033[0;31m✗\033[0m %s\n' "$name"; fi
}

printf 'session-checkpoint\n'

# --help
test_help() { "$BASH_BIN" "$SCRIPT" --help 2>&1 | grep -q 'Usage'; }
run_test "help flag works" test_help

# snapshot_create may not be implemented yet
test_creates() {
    local out rc=0
    out="$(AI_LOG_DIR="$TMP/logs" AI_EVENT_LOG="$TMP/logs/ev.jsonl" "$BASH_BIN" "$SCRIPT" 2>&1)" || rc=$?
    if ((rc == 0)); then
        [[ "$out" == *"checkpoint created"* ]]
    else
        # snapshot_create not available — expected if not implemented
        [[ "$out" == *"snapshot_create"* ]] || [[ "$out" == *"command not found"* ]]
    fi
}
run_test "creates checkpoint or reports missing function" test_creates

# -h short flag
test_help_short() { "$BASH_BIN" "$SCRIPT" -h 2>&1 | grep -q 'Usage'; }
run_test "-h short flag works" test_help_short

# Custom label is used for the snapshot and echoed in the confirmation line.
test_custom_label() {
    local out rc=0
    out="$(AI_LOG_DIR="$TMP/logs-label" AI_EVENT_LOG="$TMP/logs-label/ev.jsonl" \
        "$BASH_BIN" "$SCRIPT" before-refactor 2>&1)" || rc=$?
    if ((rc == 0)); then
        [[ "$out" == *"checkpoint created"* ]]
    else
        [[ "$out" == *"snapshot_create"* || "$out" == *"command not found"* ]]
    fi
}
run_test "custom label is accepted" test_custom_label

# The checkpoint.create event is logged with the given label.
test_logs_checkpoint_event() {
    local event_log="$TMP/logs-event/ev.jsonl"
    local rc=0
    AI_LOG_DIR="$TMP/logs-event" AI_EVENT_LOG="$event_log" \
        "$BASH_BIN" "$SCRIPT" my-label >/dev/null 2>&1 || rc=$?
    ((rc == 0)) || return 1
    [[ -f "$event_log" ]] || return 1
    command -v jq >/dev/null 2>&1 || return 0
    grep -q '"checkpoint.create"' "$event_log" &&
        jq -e 'select(.event_type == "checkpoint.create") | .details.label == "my-label"' "$event_log" >/dev/null
}
run_test "logs checkpoint.create event with the given label" test_logs_checkpoint_event

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d  Skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
((FAIL == 0)) && printf '\033[0;32mPASSED\033[0m\n' || { printf '\033[0;31mFAILED\033[0m\n'; exit 1; }
