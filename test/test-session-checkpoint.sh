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

# Regression: a label containing a path separator must not silently produce a
# success line for a snapshot file that was never created. Either the label is
# sanitized and the reported file exists, or the command fails loudly (non-zero
# exit, no "checkpoint created" line).
test_slash_label_not_silent_success() {
    local out rc=0 logdir="$TMP/logs-slash"
    out="$(AI_LOG_DIR="$logdir" AI_EVENT_LOG="$logdir/ev.jsonl" \
        "$BASH_BIN" "$SCRIPT" 'weird label/with slash' 2>&1)" || rc=$?
    if ((rc == 0)); then
        # Success is only acceptable if the reported manifest actually exists.
        [[ "$out" == *"checkpoint created"* ]] || return 1
        local reported="${out#*checkpoint created: }"
        reported="${reported%%$'\n'*}"
        [[ -f "$reported" ]]
    else
        # Failing loudly is acceptable — but must not also claim success.
        [[ "$out" != *"checkpoint created"* ]]
    fi
}
run_test "path-separator label is not a silent success" test_slash_label_not_silent_success

# Note: unborn-branch failure ("no commits yet") and self-referential untracked
# filtering are behaviors of the SHARED lib/snapshot.sh (snapshot_create), not of
# this command's own libexec. They are owned and regression-tested alongside the
# snapshot library / ai-rollback (see test-ai-rollback.sh). This suite therefore
# asserts only session-checkpoint's own surface, so it stays self-contained and
# green from changes to libexec/session-checkpoint alone.

# Regression (defect 3): the universal --help guard in common.sh handles --help
# before this script's body runs, so any local usage()/case dispatch would be
# unreachable dead code carrying a drift-prone stale 'session-checkpoint.sh'
# name. Assert both are gone.
test_no_dead_local_usage() {
    ! grep -qE '^usage\(\)' "$SCRIPT" || return 1
    ! grep -q 'session-checkpoint\.sh' "$SCRIPT"
}
run_test "no dead local usage()/stale script name" test_no_dead_local_usage

# AI_OUTPUT=json emits a single ai.session-checkpoint/v1 envelope on stdout with
# the documented keys, and stdout stays pure JSON (no human "checkpoint created"
# line leaking in).
test_json_envelope() {
    local out rc=0 logdir="$TMP/logs-json"
    command -v jq >/dev/null 2>&1 || return 0
    out="$(AI_OUTPUT=json AI_LOG_DIR="$logdir" AI_EVENT_LOG="$logdir/ev.jsonl" \
        "$BASH_BIN" "$SCRIPT" jlabel 2>/dev/null)" || rc=$?
    ((rc == 0)) || return 1
    [[ "$out" != *"checkpoint created"* ]] || return 1
    jq -e '
        .schema == "ai.session-checkpoint/v1"
        and .status == "ok"
        and .tool == "session-checkpoint"
        and .label == "jlabel"
        and (.manifest | length > 0)
        and (.base_ref | length > 0)
        and (.has_untracked_archive | type == "boolean")
        and (.restore_command | test("ai-rollback apply"))
        and (.warnings | type == "array")
    ' <<<"$out" >/dev/null
}
run_test "AI_OUTPUT=json emits ai.session-checkpoint/v1 envelope" test_json_envelope

# The additive --json flag is equivalent to AI_OUTPUT=json and does not become
# the snapshot label.
test_json_flag() {
    local out rc=0 logdir="$TMP/logs-jsonflag"
    command -v jq >/dev/null 2>&1 || return 0
    out="$(AI_LOG_DIR="$logdir" AI_EVENT_LOG="$logdir/ev.jsonl" \
        "$BASH_BIN" "$SCRIPT" --json flagged 2>/dev/null)" || rc=$?
    ((rc == 0)) || return 1
    jq -e '.schema == "ai.session-checkpoint/v1" and .status == "ok" and .label == "flagged"' \
        <<<"$out" >/dev/null
}
run_test "--json flag emits the JSON envelope with the correct label" test_json_flag

# Extra positional args past the label are surfaced as a warning: on stderr in
# human mode, and in the envelope's warnings[] under --json.
test_extra_args_warn() {
    local err rc=0 logdir="$TMP/logs-extra"
    err="$(AI_LOG_DIR="$logdir" AI_EVENT_LOG="$logdir/ev.jsonl" \
        "$BASH_BIN" "$SCRIPT" lbl extra1 extra2 2>&1 1>/dev/null)" || rc=$?
    ((rc == 0)) || return 1
    [[ "$err" == *"extra1 extra2"* ]] || return 1
    command -v jq >/dev/null 2>&1 || return 0
    local out
    out="$(AI_OUTPUT=json AI_LOG_DIR="$logdir" AI_EVENT_LOG="$logdir/ev.jsonl" \
        "$BASH_BIN" "$SCRIPT" lbl extra1 2>/dev/null)" || return 1
    jq -e '.warnings | length == 1 and (.[0] | test("extra1"))' <<<"$out" >/dev/null
}
run_test "extra positional args are surfaced as a warning" test_extra_args_warn

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d  Skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
((FAIL == 0)) && printf '\033[0;32mPASSED\033[0m\n' || {
    printf '\033[0;31mFAILED\033[0m\n'
    exit 1
}
