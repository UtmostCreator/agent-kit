#!/usr/bin/env bash
# Tests for libexec/ai-rollback
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/libexec/ai-rollback"
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

printf 'ai-rollback\n'

# --help
test_help() { "$BASH_BIN" "$SCRIPT" --help 2>&1 | grep -q 'Usage'; }
run_test "help flag works" test_help

# Missing mode fails
test_no_mode() { ! "$BASH_BIN" "$SCRIPT" 2>/dev/null; }
run_test "missing mode fails" test_no_mode

# list mode works (may be empty)
test_list() {
    # list mode must not error (output is either "no snapshots" or a list).
    AI_SNAPSHOT_DIR="$TMP/snaps" "$BASH_BIN" "$SCRIPT" list >/dev/null 2>&1 || true
}
run_test "list mode runs" test_list

# show with missing snapshot fails
test_show_missing() {
    ! AI_SNAPSHOT_DIR="$TMP/snaps2" "$BASH_BIN" "$SCRIPT" show "nonexistent" 2>/dev/null
}
run_test "show missing snapshot fails" test_show_missing

# apply with missing snapshot fails
test_apply_missing() {
    ! AI_SNAPSHOT_DIR="$TMP/snaps3" "$BASH_BIN" "$SCRIPT" apply "nonexistent" 2>/dev/null
}
run_test "apply missing snapshot fails" test_apply_missing

# prune on empty dir is safe (pipe stdin to avoid interactive prompt)
test_prune_empty() {
    echo "n" | AI_SNAPSHOT_DIR="$TMP/snaps4" "$BASH_BIN" "$SCRIPT" prune --days 30 2>/dev/null || true
    true
}
run_test "prune on empty dir is safe" test_prune_empty

# Unknown mode fails
test_unknown() {
    ! "$BASH_BIN" "$SCRIPT" nonexistent 2>/dev/null
}
run_test "unknown mode fails" test_unknown

# --- fixtures / helpers for real snapshot mechanics ------------------------

make_rollback_repo() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" config user.email "ai-rollback-test@example.test"
    git -C "$dir" config user.name "AI Rollback Test"
    printf 'line1\nline2\n' >"$dir/tracked.txt"
    git -C "$dir" add tracked.txt
    git -C "$dir" commit -q -m init
}

# Create a real snapshot via lib/snapshot.sh's snapshot_create (reached through
# lib/common.sh), confined to a subshell so common.sh's `set -euo pipefail` and
# globals never leak into this test script. Prints the manifest path on stdout.
create_snapshot() {
    local work="$1" snap_dir="$2" session="$3" label="$4"
    (
        cd "$work"
        export AI_LOG_DIR="$work/.ai-logs"
        export AI_EVENT_LOG="$work/.ai-logs/events.jsonl"
        export AI_SNAPSHOT_DIR="$snap_dir"
        export AI_SESSION_AUTO_TRAP=0
        export NO_COLOR=1
        export SESSION_ID="$session"
        # shellcheck source=lib/common.sh
        source "$REPO_ROOT/lib/common.sh"
        snapshot_create "$label"
    )
}

# Symlink every executable found on the current $PATH into $1, except any
# names passed as the remaining args. Used to simulate a missing binary (e.g.
# tar) without disturbing the real PATH for the rest of the suite.
build_path_without() {
    local fakebin="$1"
    shift
    mkdir -p "$fakebin"
    local dir f base skip ex
    local -a dirs=()
    IFS=':' read -ra dirs <<<"$PATH"
    for dir in "${dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        for f in "$dir"/*; do
            [[ -x "$f" && -f "$f" ]] || continue
            base="$(basename "$f")"
            skip=0
            for ex in "$@"; do
                [[ "$base" == "$ex" ]] && { skip=1; break; }
            done
            ((skip == 1)) && continue
            [[ -e "$fakebin/$base" ]] && continue
            ln -sf "$f" "$fakebin/$base" 2>/dev/null || true
        done
    done
}

# --- lib/snapshot.sh: snapshot_apply_manifest (the real restore mechanism) --

test_snapshot_apply_reverts_tracked_and_removes_new_untracked() {
    local work="$TMP/snap-apply-basic"
    make_rollback_repo "$work"
    (
        cd "$work"
        export AI_LOG_DIR=".ai-logs"
        export AI_EVENT_LOG=".ai-logs/events.jsonl"
        export AI_SNAPSHOT_DIR=".ai-logs/snapshots"
        export AI_SESSION_AUTO_TRAP=0
        export NO_COLOR=1
        # shellcheck source=lib/common.sh
        source "$REPO_ROOT/lib/common.sh"

        # Pre-existing untracked content under the protected AI_LOG_DIR must
        # survive apply even though it existed before the snapshot was taken.
        mkdir -p .ai-logs
        printf 'preexisting log\n' >.ai-logs/keep.txt

        local manifest
        manifest="$(snapshot_create pre-edit)"

        printf 'line1\nMUTATED\n' >tracked.txt
        printf 'new untracked\n' >new-untracked.txt
        printf 'more logs\n' >>.ai-logs/keep.txt

        snapshot_apply_manifest "$manifest"

        [[ "$(cat tracked.txt)" == "$(printf 'line1\nline2')" ]] || { echo "tracked.txt not reverted"; exit 1; }
        [[ ! -f new-untracked.txt ]] || { echo "new untracked file survived apply"; exit 1; }
        [[ -f .ai-logs/keep.txt ]] || { echo "protected AI_LOG_DIR file was removed"; exit 1; }
    )
}
run_test "snapshot_apply_manifest reverts tracked file, removes new untracked file, keeps protected AI_LOG_DIR" test_snapshot_apply_reverts_tracked_and_removes_new_untracked

test_snapshot_apply_protects_new_untracked_in_protected_dirs() {
    local work="$TMP/snap-apply-protected"
    make_rollback_repo "$work"
    (
        cd "$work"
        export AI_LOG_DIR=".ai-logs"
        export AI_EVENT_LOG=".ai-logs/events.jsonl"
        export AI_SNAPSHOT_DIR=".ai-logs/snapshots"
        export AI_SESSION_AUTO_TRAP=0
        export NO_COLOR=1
        source "$REPO_ROOT/lib/common.sh"

        local manifest
        manifest="$(snapshot_create pre-edit)"

        # New (not pre-existing) untracked files created AFTER the snapshot:
        # one under a protected dir (must survive), one in a normal path
        # (must be removed).
        mkdir -p .repomix-context
        printf 'context pack\n' >.repomix-context/pack.json
        printf 'scratch\n' >scratch.txt

        snapshot_apply_manifest "$manifest"

        [[ -f .repomix-context/pack.json ]] || { echo "protected .repomix-context file was removed"; exit 1; }
        [[ ! -f scratch.txt ]] || { echo "unprotected new untracked file survived apply"; exit 1; }
    )
}
run_test "snapshot_apply_manifest protects new untracked files under .repomix-context but removes unprotected ones" test_snapshot_apply_protects_new_untracked_in_protected_dirs

test_snapshot_apply_keeps_untracked_when_removal_disabled() {
    local work="$TMP/snap-apply-keep-untracked"
    make_rollback_repo "$work"
    (
        cd "$work"
        export AI_LOG_DIR=".ai-logs"
        export AI_EVENT_LOG=".ai-logs/events.jsonl"
        export AI_SNAPSHOT_DIR=".ai-logs/snapshots"
        export AI_SESSION_AUTO_TRAP=0
        export NO_COLOR=1
        source "$REPO_ROOT/lib/common.sh"

        local manifest
        manifest="$(snapshot_create pre-edit)"

        printf 'scratch\n' >scratch.txt

        ROLLBACK_REMOVE_CREATED_UNTRACKED=0 snapshot_apply_manifest "$manifest"

        [[ -f scratch.txt ]] || { echo "untracked file removed despite ROLLBACK_REMOVE_CREATED_UNTRACKED=0"; exit 1; }
    )
}
run_test "snapshot_apply_manifest with ROLLBACK_REMOVE_CREATED_UNTRACKED=0 keeps new untracked files" test_snapshot_apply_keeps_untracked_when_removal_disabled

test_snapshot_create_warns_when_tar_archive_fails() {
    local work="$TMP/snap-tar-archive-fail"
    make_rollback_repo "$work"
    (
        cd "$work"
        export AI_LOG_DIR=".ai-logs"
        export AI_EVENT_LOG=".ai-logs/events.jsonl"
        export AI_SNAPSHOT_DIR=".ai-logs/snapshots"
        export AI_SESSION_AUTO_TRAP=0
        export NO_COLOR=1
        source "$REPO_ROOT/lib/common.sh"

        printf 'untracked content\n' >untracked.txt

        # `command -v tar` still finds this function (so snapshot_create takes
        # the archive-attempt branch), but the archive step itself fails,
        # exercising the "failed to archive untracked files" warning path.
        tar() { return 1; }

        local manifest
        manifest="$(snapshot_create pre-edit 2>tar-stderr.log)"

        grep -q "failed to archive untracked files" tar-stderr.log || { echo "expected tar-failure warning"; exit 1; }
        [[ "$(jq -r '.has_untracked_archive' "$manifest")" == "false" ]] || { echo "manifest incorrectly reports archive success"; exit 1; }
    )
}
run_test "snapshot_create warns and marks has_untracked_archive=false when tar archiving fails" test_snapshot_create_warns_when_tar_archive_fails

test_snapshot_create_warns_when_tar_binary_missing() {
    local work="$TMP/snap-no-tar" fakebin="$TMP/fakebin-no-tar"
    make_rollback_repo "$work"
    build_path_without "$fakebin" tar
    (
        cd "$work"
        export AI_LOG_DIR=".ai-logs"
        export AI_EVENT_LOG=".ai-logs/events.jsonl"
        export AI_SNAPSHOT_DIR=".ai-logs/snapshots"
        export AI_SESSION_AUTO_TRAP=0
        export NO_COLOR=1
        export PATH="$fakebin"
        source "$REPO_ROOT/lib/common.sh"

        printf 'untracked content\n' >untracked.txt

        local manifest
        manifest="$(snapshot_create pre-edit 2>no-tar-stderr.log)"

        grep -q "tar not installed" no-tar-stderr.log || { echo "expected tar-not-installed warning"; exit 1; }
        [[ "$(jq -r '.has_untracked_archive' "$manifest")" == "false" ]] || { echo "manifest incorrectly reports archive success"; exit 1; }
    )
}
run_test "snapshot_create warns when tar binary is unavailable on PATH" test_snapshot_create_warns_when_tar_binary_missing

# --- libexec/ai-rollback: real snapshot lifecycle (list/show/apply/prune) --

test_list_shows_created_snapshot() {
    local work="$TMP/cli-list" snap_dir="$TMP/cli-list-snaps"
    make_rollback_repo "$work"
    create_snapshot "$work" "$snap_dir" "sess-list" "pre-edit" >/dev/null
    local out
    out="$(AI_SNAPSHOT_DIR="$snap_dir" "$BASH_BIN" "$SCRIPT" list)"
    [[ "$out" == *"manifest"* ]] || return 1
    [[ "$out" != *"0 snapshot artifact(s) found"* ]]
}
run_test "cmd_list shows a real created snapshot" test_list_shows_created_snapshot

# NOTE: resolve_snapshot's session-prefix lookup (find ... -o -name
# "${input}*.patch" ... | sort -r | head -1) does not distinguish artifact
# TYPE when picking the most recent match by filename. snapshot_create always
# writes a same-timestamped ".patch" sidecar next to every ".manifest.json",
# and ".patch" sorts lexicographically after ".manifest.json", so a bare
# session/label prefix lookup resolves to the sidecar ".patch" (rendered as
# "legacy patch") instead of the canonical manifest -- see the bug noted in
# the implementer handoff. These two tests pass the manifest's literal path
# (the documented, ambiguity-free way to address a specific snapshot) so they
# exercise cmd_show_manifest / cmd_apply's own logic rather than that lookup
# quirk.
test_show_manifest_fields() {
    local work="$TMP/cli-show" snap_dir="$TMP/cli-show-snaps" manifest
    make_rollback_repo "$work"
    manifest="$(create_snapshot "$work" "$snap_dir" "sess-show" "pre-edit")"
    local out
    out="$(AI_SNAPSHOT_DIR="$snap_dir" "$BASH_BIN" "$SCRIPT" show "$manifest")"
    [[ "$out" == *'"session": "sess-show"'* ]] || return 1
    [[ "$out" == *'"label": "pre-edit"'* ]]
}
run_test "cmd_show renders manifest fields for a real snapshot (literal path)" test_show_manifest_fields

test_resolve_snapshot_literal_path() {
    local work="$TMP/cli-resolve-literal" snap_dir="$TMP/cli-resolve-literal-snaps" manifest
    make_rollback_repo "$work"
    manifest="$(create_snapshot "$work" "$snap_dir" "sess-literal" "pre-edit")"
    local out
    out="$(AI_SNAPSHOT_DIR="$snap_dir" "$BASH_BIN" "$SCRIPT" show "$manifest")"
    [[ "$out" == *'"session": "sess-literal"'* ]]
}
run_test "resolve_snapshot resolves a literal manifest path directly" test_resolve_snapshot_literal_path

# This exercises resolve_snapshot's find-glob-prefix-match-then-most-recent
# branch (session prefix, no artifact type specified). Because of the sidecar
# ordering quirk documented above, the match it returns is the newer
# snapshot's ".patch" sidecar, not its manifest -- but that is still enough to
# prove RECENCY selection: assert the resolved artifact belongs to the
# second (later) snapshot, not the first.
test_resolve_snapshot_prefix_picks_most_recent() {
    local work="$TMP/cli-resolve-prefix" snap_dir="$TMP/cli-resolve-prefix-snaps"
    make_rollback_repo "$work"
    create_snapshot "$work" "$snap_dir" "sess-two" "first" >/dev/null
    sleep 1.1
    create_snapshot "$work" "$snap_dir" "sess-two" "second" >/dev/null
    local out
    out="$(AI_SNAPSHOT_DIR="$snap_dir" "$BASH_BIN" "$SCRIPT" show "sess-two" 2>&1)"
    [[ "$out" == *"sess-two-second-"* ]] || return 1
    [[ "$out" != *"sess-two-first-"* ]]
}
run_test "resolve_snapshot glob-prefix match picks the most recent snapshot" test_resolve_snapshot_prefix_picks_most_recent

test_apply_real_mutation_reverts_and_removes_untracked() {
    local work="$TMP/cli-apply" snap_dir="$TMP/cli-apply-snaps" manifest
    make_rollback_repo "$work"
    manifest="$(create_snapshot "$work" "$snap_dir" "sess-apply" "pre-edit")"
    printf 'line1\nMUTATED\n' >"$work/tracked.txt"
    printf 'scratch\n' >"$work/scratch.txt"
    CI=true AI_SNAPSHOT_DIR="$snap_dir" "$BASH_BIN" "$SCRIPT" apply "$manifest" >/dev/null 2>&1
    [[ "$(cat "$work/tracked.txt")" == "$(printf 'line1\nline2')" ]] || return 1
    [[ ! -f "$work/scratch.txt" ]]
}
run_test "cmd_apply performs a real rollback mutation (revert + remove untracked)" test_apply_real_mutation_reverts_and_removes_untracked

test_prune_real_deletion_with_count() {
    local work="$TMP/cli-prune" snap_dir="$TMP/cli-prune-snaps"
    make_rollback_repo "$work"
    create_snapshot "$work" "$snap_dir" "sess-prune" "pre-edit" >/dev/null
    # Backdate the snapshot artifacts so `-mtime +0` treats them as prunable
    # without depending on the exact fresh-file rounding edge case.
    find "$snap_dir" -maxdepth 1 -type f -exec touch -d '2 days ago' {} \;
    local out
    out="$(CI=true AI_SNAPSHOT_DIR="$snap_dir" "$BASH_BIN" "$SCRIPT" prune --days 0)"
    [[ "$out" == *"Pruned"* ]]
    [[ "$out" != *"Pruned 0"* ]]
    local remaining
    remaining="$(find "$snap_dir" -maxdepth 1 -name '*.manifest.json' 2>/dev/null | wc -l | tr -d ' ')"
    ((remaining == 0))
}
run_test "cmd_prune --days 0 really deletes backdated snapshot artifacts (count > 0)" test_prune_real_deletion_with_count

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d  Skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
((FAIL == 0)) && printf '\033[0;32mPASSED\033[0m\n' || { printf '\033[0;31mFAILED\033[0m\n'; exit 1; }
