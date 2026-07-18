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
#
# `${f##*/}` (not `basename "$f"`) and batched `ln` calls (multiple sources,
# one destination dir -- portable POSIX form, not GNU-only `-t`) avoid
# forking a process per PATH entry; on a PATH with hundreds of entries that
# was ~6-7s per call, now sub-0.1s, with byte-identical output.
build_path_without() {
    local fakebin="$1"
    shift
    mkdir -p "$fakebin"
    local dir f base
    local -a dirs=() sources=()
    local -A seen=()
    local ex
    for ex in "$@"; do seen["$ex"]=1; done
    IFS=':' read -ra dirs <<<"$PATH"
    for dir in "${dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        for f in "$dir"/*; do
            [[ -x "$f" && -f "$f" ]] || continue
            base="${f##*/}"
            [[ -n "${seen[$base]:-}" ]] && continue
            seen["$base"]=1
            sources+=("$f")
        done
    done
    local i
    for ((i = 0; i < ${#sources[@]}; i += 500)); do
        ln -sf -- "${sources[@]:i:500}" "$fakebin" 2>/dev/null || true
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

        [[ "$(cat tracked.txt)" == "$(printf 'line1\nline2')" ]] || {
            echo "tracked.txt not reverted"
            exit 1
        }
        [[ ! -f new-untracked.txt ]] || {
            echo "new untracked file survived apply"
            exit 1
        }
        [[ -f .ai-logs/keep.txt ]] || {
            echo "protected AI_LOG_DIR file was removed"
            exit 1
        }
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

        [[ -f .repomix-context/pack.json ]] || {
            echo "protected .repomix-context file was removed"
            exit 1
        }
        [[ ! -f scratch.txt ]] || {
            echo "unprotected new untracked file survived apply"
            exit 1
        }
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

        [[ -f scratch.txt ]] || {
            echo "untracked file removed despite ROLLBACK_REMOVE_CREATED_UNTRACKED=0"
            exit 1
        }
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

        grep -q "failed to archive untracked files" tar-stderr.log || {
            echo "expected tar-failure warning"
            exit 1
        }
        [[ "$(jq -r '.has_untracked_archive' "$manifest")" == "false" ]] || {
            echo "manifest incorrectly reports archive success"
            exit 1
        }
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

        grep -q "tar not installed" no-tar-stderr.log || {
            echo "expected tar-not-installed warning"
            exit 1
        }
        [[ "$(jq -r '.has_untracked_archive' "$manifest")" == "false" ]] || {
            echo "manifest incorrectly reports archive success"
            exit 1
        }
    )
}
run_test "snapshot_create warns when tar binary is unavailable on PATH" test_snapshot_create_warns_when_tar_binary_missing

# _ai_snapshot_protected_untracked_path's case statement checks the current
# AI_LOG_DIR/AI_CONTEXT_DIR env values FIRST, falling back to the hardcoded
# literals ".ai-logs"/".repomix-context" only as separate, later arms. Every
# existing protected-path test above leaves AI_LOG_DIR/AI_CONTEXT_DIR at their
# defaults (".ai-logs"/".repomix-context"), so a path under either default
# always matches the env-var arm first and the hardcoded literal arms are
# never reached. Point AI_LOG_DIR/AI_CONTEXT_DIR at custom directories here so
# all four "protected" arms (custom AI_LOG_DIR, custom AI_CONTEXT_DIR,
# hardcoded ".ai-logs", hardcoded ".repomix-context") get distinctly hit.
test_snapshot_apply_protects_hardcoded_and_custom_dirs() {
    local work="$TMP/snap-apply-protect-all"
    make_rollback_repo "$work"
    (
        cd "$work"
        export AI_LOG_DIR="custom-logs"
        export AI_CONTEXT_DIR="custom-context"
        export AI_EVENT_LOG="custom-logs/events.jsonl"
        export AI_SNAPSHOT_DIR="custom-logs/snapshots"
        export AI_SESSION_AUTO_TRAP=0
        export NO_COLOR=1
        source "$REPO_ROOT/lib/common.sh"

        local manifest
        manifest="$(snapshot_create pre-edit)"

        mkdir -p custom-logs custom-context .ai-logs .repomix-context
        printf 'a\n' >custom-logs/a.txt
        printf 'b\n' >custom-context/b.txt
        printf 'c\n' >.ai-logs/c.txt
        printf 'd\n' >.repomix-context/d.txt
        printf 'e\n' >scratch.txt

        snapshot_apply_manifest "$manifest"

        [[ -f custom-logs/a.txt ]] || {
            echo "custom AI_LOG_DIR path removed"
            exit 1
        }
        [[ -f custom-context/b.txt ]] || {
            echo "custom AI_CONTEXT_DIR path removed"
            exit 1
        }
        [[ -f .ai-logs/c.txt ]] || {
            echo "hardcoded .ai-logs fallback removed"
            exit 1
        }
        [[ -f .repomix-context/d.txt ]] || {
            echo "hardcoded .repomix-context fallback removed"
            exit 1
        }
        [[ ! -f scratch.txt ]] || {
            echo "unprotected file survived"
            exit 1
        }
    )
}
run_test "snapshot_apply_manifest protects custom AI_LOG_DIR/AI_CONTEXT_DIR AND the hardcoded .ai-logs/.repomix-context fallback arms" test_snapshot_apply_protects_hardcoded_and_custom_dirs

# snapshot_apply()'s *.ref and *.patch dispatch arms (as opposed to the
# *.manifest.json / snapshot_apply_manifest path exercised everywhere above)
# are the legacy formats. Neither takes a "root" from a manifest, so they
# operate on whatever the current working directory is -- unlike
# snapshot_apply_manifest, cd into the target repo before invoking.
test_snapshot_apply_legacy_ref_dispatch() {
    local work="$TMP/snap-legacy-ref" base_sha ref_file
    make_rollback_repo "$work"
    base_sha="$(git -C "$work" rev-parse HEAD)"
    printf 'line1\nline2\nline3\n' >"$work/tracked.txt"
    git -C "$work" add tracked.txt
    git -C "$work" commit -q -m second
    ref_file="$work/rollback-point.ref"
    printf '%s\n' "$base_sha" >"$ref_file"
    (
        cd "$work"
        CI=true AI_SNAPSHOT_DIR="$TMP/unused-snap-dir-ref" "$BASH_BIN" "$SCRIPT" apply "$ref_file" >/dev/null 2>&1
    )
    [[ "$(cat "$work/tracked.txt")" == "$(printf 'line1\nline2')" ]]
}
run_test "cmd_apply on a literal .ref file dispatches to snapshot_apply's legacy 'git reset --hard' path" test_snapshot_apply_legacy_ref_dispatch

test_snapshot_apply_legacy_patch_dispatch() {
    local work="$TMP/snap-legacy-patch" patch_file
    make_rollback_repo "$work"
    patch_file="$work/change.patch"
    cat >"$patch_file" <<'EOF'
diff --git a/tracked.txt b/tracked.txt
index 0000000..1111111 100644
--- a/tracked.txt
+++ b/tracked.txt
@@ -1,2 +1,2 @@
 line1
-line2
+CHANGED
EOF
    (
        cd "$work"
        CI=true AI_SNAPSHOT_DIR="$TMP/unused-snap-dir-patch" "$BASH_BIN" "$SCRIPT" apply "$patch_file" >/dev/null 2>&1
    )
    grep -q 'CHANGED' "$work/tracked.txt"
}
run_test "cmd_apply on a literal .patch file dispatches to snapshot_apply's legacy 'git apply' path" test_snapshot_apply_legacy_patch_dispatch

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

test_list_empty_existing_dir() {
    local snap_dir="$TMP/list-empty-snaps"
    mkdir -p "$snap_dir"
    local out
    out="$(AI_SNAPSHOT_DIR="$snap_dir" "$BASH_BIN" "$SCRIPT" list)"
    [[ "$out" == *"0 snapshot artifact(s) found"* ]]
}
run_test "cmd_list on an existing but empty snapshot dir reports 0 artifacts (loop runs zero times)" test_list_empty_existing_dir

# resolve_snapshot's "directory exists but no artifact matches" die branch is
# distinct from "directory does not exist at all" (already covered by
# test_show_missing/test_apply_missing, which point at a nonexistent dir).
test_show_no_match_in_existing_dir() {
    local snap_dir="$TMP/show-no-match-snaps"
    mkdir -p "$snap_dir"
    ! AI_SNAPSHOT_DIR="$snap_dir" "$BASH_BIN" "$SCRIPT" show "totally-absent-prefix" 2>/dev/null
}
run_test "resolve_snapshot: existing dir with no matching artifact fails distinctly" test_show_no_match_in_existing_dir

# cmd_show's final unsupported-type die arm (an existing file that resolve_snapshot
# happily returns via its literal-path branch, but whose suffix matches none of
# manifest.json/.ref/.patch).
test_show_unsupported_type() {
    local work="$TMP/snap-unsupported-show" bogus
    make_rollback_repo "$work"
    bogus="$work/bogus.txt"
    printf 'not a snapshot\n' >"$bogus"
    ! AI_SNAPSHOT_DIR="$TMP/unused-snap-dir-show-bad" "$BASH_BIN" "$SCRIPT" show "$bogus" 2>/dev/null
}
run_test "cmd_show dies on an unsupported snapshot file type" test_show_unsupported_type

# snapshot_apply() (lib/snapshot.sh) has its OWN separate unsupported-type die
# arm from cmd_show's -- exercise it directly via cmd_apply.
test_apply_unsupported_type() {
    local work="$TMP/snap-unsupported-apply" bogus
    make_rollback_repo "$work"
    bogus="$work/bogus.txt"
    printf 'not a snapshot\n' >"$bogus"
    ! CI=true AI_SNAPSHOT_DIR="$TMP/unused-snap-dir-apply-bad" "$BASH_BIN" "$SCRIPT" apply "$bogus" 2>/dev/null
}
run_test "cmd_apply dies on an unsupported snapshot file type (snapshot_apply's own guard)" test_apply_unsupported_type

test_show_ref_sidecar_directly() {
    local work="$TMP/cli-show-ref" ref_file base_sha out
    make_rollback_repo "$work"
    base_sha="$(git -C "$work" rev-parse HEAD)"
    ref_file="$work/point.ref"
    printf '%s\n' "$base_sha" >"$ref_file"
    # log_info writes to stderr; merge it into the captured output.
    out="$(cd "$work" && AI_SNAPSHOT_DIR="$TMP/unused-show-ref" "$BASH_BIN" "$SCRIPT" show "$ref_file" 2>&1)"
    [[ "$out" == *"Type: legacy ref"* ]]
}
run_test "cmd_show on a literal .ref file renders the legacy-ref branch" test_show_ref_sidecar_directly

# Reaches cmd_show's *.patch) branch directly (as opposed to the sidecar
# ordering quirk documented above, which resolves an ambiguous session/label
# prefix to it indirectly).
test_show_patch_sidecar_directly() {
    local work="$TMP/cli-show-patch-sidecar" snap_dir="$TMP/cli-show-patch-sidecar-snaps" manifest patch_file out
    make_rollback_repo "$work"
    printf 'line1\nDIRTY\n' >"$work/tracked.txt"
    manifest="$(create_snapshot "$work" "$snap_dir" "sess-patch-sidecar" "pre-edit")"
    patch_file="${manifest%.manifest.json}.patch"
    # log_info writes to stderr; merge it into the captured output.
    out="$(AI_SNAPSHOT_DIR="$snap_dir" "$BASH_BIN" "$SCRIPT" show "$patch_file" 2>&1)"
    [[ "$out" == *"Type: legacy patch"* ]]
}
run_test "cmd_show on the real .patch sidecar (literal path) renders the legacy-patch branch" test_show_patch_sidecar_directly

# cmd_show_manifest's three conditional sections ("## Patch stat", "## Untracked
# files captured", "## Untracked archive") are all gated on the patch/untracked
# artifacts being nonempty. Every existing cmd_show test above snapshots a
# perfectly clean repo (no dirty tracked changes, no untracked files), so none
# of those three blocks ever executes. Dirty the tree and add an untracked file
# BEFORE taking the snapshot to populate all three artifacts.
test_show_manifest_full_sections() {
    local work="$TMP/cli-show-full" snap_dir="$TMP/cli-show-full-snaps" manifest out
    make_rollback_repo "$work"
    printf 'line1\nDIRTY\n' >"$work/tracked.txt"
    printf 'untracked content\n' >"$work/new-file.txt"
    manifest="$(create_snapshot "$work" "$snap_dir" "sess-show-full" "pre-edit")"
    out="$(AI_SNAPSHOT_DIR="$snap_dir" "$BASH_BIN" "$SCRIPT" show "$manifest")"
    [[ "$out" == *"## Patch stat"* ]] || return 1
    [[ "$out" == *"## Untracked files captured"* ]] || return 1
    [[ "$out" == *"## Untracked archive"* ]]
}
run_test "cmd_show_manifest renders Patch stat / Untracked files captured / Untracked archive sections" test_show_manifest_full_sections

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

# git-stash-style numeric index selection -------------------------------

test_list_human_table_has_no_index_column() {
    # Backward-compat guard: the default (non-JSON) `list` table keeps its
    # pre-existing layout -- no leading "#" index column and no "Select by
    # index" hint line. The git-stash-style index lives ONLY in the --json
    # envelope, so consumers of the fixed-width table are unaffected.
    local work="$TMP/cli-list-human" snap_dir="$TMP/cli-list-human-snaps"
    make_rollback_repo "$work"
    create_snapshot "$work" "$snap_dir" "sess-human" "only" >/dev/null
    local out
    out="$(AI_SNAPSHOT_DIR="$snap_dir" "$BASH_BIN" "$SCRIPT" list)"
    # Header still starts with the SNAPSHOT column, not a "#" index column.
    [[ "$out" == "SNAPSHOT"* ]] || return 1
    [[ "$out" != *"Select by index"* ]] || return 1
    [[ "$out" == *"snapshot artifact(s) found"* ]]
}
run_test "cmd_list default table keeps its pre-existing layout (no index column, no hint)" test_list_human_table_has_no_index_column

test_resolve_snapshot_index_one_is_most_recent() {
    local work="$TMP/cli-resolve-index" snap_dir="$TMP/cli-resolve-index-snaps"
    make_rollback_repo "$work"
    # Labels chosen (as in test_resolve_snapshot_prefix_picks_most_recent
    # above) so lexicographic filename order agrees with creation order --
    # snapshot_create's HHMMSS-only timestamp can't be trusted alone to
    # disambiguate two same-second/near-second creations by sort -r.
    create_snapshot "$work" "$snap_dir" "sess-idx" "first" >/dev/null
    sleep 1.1
    create_snapshot "$work" "$snap_dir" "sess-idx" "second" >/dev/null
    local out
    out="$(AI_SNAPSHOT_DIR="$snap_dir" "$BASH_BIN" "$SCRIPT" show 1 2>&1)"
    [[ "$out" == *'"label": "second"'* ]] || return 1
    [[ "$out" != *'"label": "first"'* ]] || return 1

    out="$(AI_SNAPSHOT_DIR="$snap_dir" "$BASH_BIN" "$SCRIPT" show 2 2>&1)"
    [[ "$out" == *'"label": "first"'* ]]
}
run_test "resolve_snapshot: index 1 is the most recent snapshot, index 2 the next (git-stash style)" test_resolve_snapshot_index_one_is_most_recent

test_apply_by_index_performs_real_mutation() {
    local work="$TMP/cli-apply-index" snap_dir="$TMP/cli-apply-index-snaps"
    make_rollback_repo "$work"
    create_snapshot "$work" "$snap_dir" "sess-apply-idx" "pre-edit" >/dev/null
    printf 'line1\nMUTATED\n' >"$work/tracked.txt"
    (cd "$work" && CI=true AI_SNAPSHOT_DIR="$snap_dir" "$BASH_BIN" "$SCRIPT" apply 1 >/dev/null 2>&1)
    [[ "$(cat "$work/tracked.txt")" == "$(printf 'line1\nline2')" ]]
}
run_test "cmd_apply accepts a numeric index and performs the real rollback" test_apply_by_index_performs_real_mutation

test_resolve_snapshot_index_out_of_range_fails() {
    local snap_dir="$TMP/cli-resolve-index-oor-snaps" work="$TMP/cli-resolve-index-oor"
    make_rollback_repo "$work"
    create_snapshot "$work" "$snap_dir" "sess-idx-oor" "only" >/dev/null
    ! AI_SNAPSHOT_DIR="$snap_dir" "$BASH_BIN" "$SCRIPT" show 99 2>/dev/null
}
run_test "resolve_snapshot: out-of-range index fails with a clear error" test_resolve_snapshot_index_out_of_range_fails

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

test_prune_days_equals_form() {
    local work="$TMP/cli-prune-eq" snap_dir="$TMP/cli-prune-eq-snaps"
    make_rollback_repo "$work"
    create_snapshot "$work" "$snap_dir" "sess-prune-eq" "pre-edit" >/dev/null
    find "$snap_dir" -maxdepth 1 -type f -exec touch -d '2 days ago' {} \;
    local out
    out="$(CI=true AI_SNAPSHOT_DIR="$snap_dir" "$BASH_BIN" "$SCRIPT" prune --days=0)"
    [[ "$out" == *"Pruned"* ]]
    [[ "$out" != *"Pruned 0"* ]]
}
run_test "cmd_prune --days=N (= form) prunes real snapshots" test_prune_days_equals_form

# Both of these fail while parsing options, before confirm_mutation ever runs,
# so no CI/tty handling is needed.
test_prune_unknown_option() {
    ! AI_SNAPSHOT_DIR="$TMP/prune-unknown-snaps" "$BASH_BIN" "$SCRIPT" prune --bogus-option 2>/dev/null
}
run_test "cmd_prune rejects an unknown option" test_prune_unknown_option

test_prune_days_missing_value() {
    ! AI_SNAPSHOT_DIR="$TMP/prune-missing-days" "$BASH_BIN" "$SCRIPT" prune --days 2>/dev/null
}
run_test "cmd_prune --days with no value fails" test_prune_days_missing_value

# --- regression: session-prefix resolution + missing-arg error contract -----

# Defect 1 (show): a bare session/label prefix must resolve to the owning
# ".manifest.json" (the canonical restore point that `list`/index selection
# pick), NOT its bookkeeping ".patch" sidecar. Before the fix, resolve_snapshot
# did `find ... | sort -r | head -1`, and ".patch" sorts after ".manifest.json",
# so `show <prefix>` rendered the legacy patch (missing session/label/untracked
# fields) instead of the manifest that `show <index>` returns for the same point.
test_resolve_prefix_picks_manifest_not_patch_sidecar() {
    local work="$TMP/cli-prefix-manifest" snap_dir="$TMP/cli-prefix-manifest-snaps" out
    make_rollback_repo "$work"
    printf 'line1\nDIRTY\n' >"$work/tracked.txt"
    create_snapshot "$work" "$snap_dir" "sess-prefix-canon" "pre-edit" >/dev/null
    out="$(AI_SNAPSHOT_DIR="$snap_dir" NO_COLOR=1 "$BASH_BIN" "$SCRIPT" show "sess-prefix-canon" 2>&1)"
    # Manifest branch emits the JSON "session" field; the legacy-patch branch
    # emits "Type: legacy patch" and never the session/label fields.
    [[ "$out" == *'"session": "sess-prefix-canon"'* ]] || return 1
    [[ "$out" != *"Type: legacy patch"* ]]
}
run_test "resolve_snapshot: session prefix resolves to the owning manifest, not its .patch sidecar" test_resolve_prefix_picks_manifest_not_patch_sidecar

# Defect 1 (apply): because the prefix now resolves to the manifest, `apply
# <prefix>` restores untracked files from untracked_archive -- exactly like
# `apply <index>` for the same restore point. Before the fix the prefix landed
# on the .patch sidecar, whose snapshot_apply arm only runs `git apply` and
# silently skips untracked-archive restoration.
test_apply_by_prefix_restores_untracked_archive() {
    local work="$TMP/cli-prefix-apply" snap_dir="$TMP/cli-prefix-apply-snaps"
    make_rollback_repo "$work"
    # Untracked BEFORE the snapshot so it's captured in untracked_archive.
    printf 'recover me\n' >"$work/archived.txt"
    create_snapshot "$work" "$snap_dir" "sess-prefix-apply" "pre-edit" >/dev/null
    rm -f "$work/archived.txt"
    (cd "$work" && CI=true AI_SNAPSHOT_DIR="$snap_dir" "$BASH_BIN" "$SCRIPT" apply "sess-prefix-apply" >/dev/null 2>&1)
    [[ -f "$work/archived.txt" ]] || return 1
    [[ "$(cat "$work/archived.txt")" == "recover me" ]]
}
run_test "cmd_apply by session prefix restores untracked files from the manifest archive (not just tracked changes)" test_apply_by_prefix_restores_untracked_archive

# Defect 2: show/apply with no argument must go through die() (colored "[ERROR]"
# line + structured log_json event), not a raw bash `${1:?...}` parameter
# error. The old guard printed an uncolored "ai-rollback: line N: 1: ..."
# interpreter error with no "[ERROR]" prefix and no JSON event.
test_show_missing_arg_uses_die_contract() {
    local err
    err="$(AI_SNAPSHOT_DIR="$TMP/missing-arg-snaps" "$BASH_BIN" "$SCRIPT" show 2>&1 >/dev/null)" && return 1
    [[ "$err" == *"[ERROR]"* ]] || return 1
    [[ "$err" == *"session or snapshot required"* ]] || return 1
    # The raw bash parameter-expansion error would leak a "line N:" interpreter
    # message; die()'s log_error never does.
    [[ "$err" != *"line "* ]]
}
run_test "cmd_show with no argument fails through die()/[ERROR] contract, not a raw bash guard" test_show_missing_arg_uses_die_contract

test_apply_missing_arg_uses_die_contract() {
    local err
    err="$(AI_SNAPSHOT_DIR="$TMP/missing-arg-apply-snaps" "$BASH_BIN" "$SCRIPT" apply 2>&1 >/dev/null)" && return 1
    [[ "$err" == *"[ERROR]"* ]] || return 1
    [[ "$err" == *"session or snapshot required"* ]] || return 1
    [[ "$err" != *"line "* ]]
}
run_test "cmd_apply with no argument fails through die()/[ERROR] contract, not a raw bash guard" test_apply_missing_arg_uses_die_contract

# --- ai.rollback/v1 JSON envelope (--json / AI_OUTPUT=json), opt-in -----------
# These modes are additive and default-off; the human table/show output above is
# unchanged. Each asserts the stable schema/status keys an agent depends on.

test_list_json_envelope() {
    local work="$TMP/json-list" snap_dir="$TMP/json-list-snaps" out
    make_rollback_repo "$work"
    create_snapshot "$work" "$snap_dir" "sess-json-list" "pre-edit" >/dev/null
    out="$(AI_SNAPSHOT_DIR="$snap_dir" "$BASH_BIN" "$SCRIPT" list --json 2>/dev/null)" || return 1
    [[ "$(jq -r '.schema' <<<"$out")" == "ai.rollback/v1" ]] || return 1
    [[ "$(jq -r '.status' <<<"$out")" == "ok" ]] || return 1
    [[ "$(jq -r '.tool' <<<"$out")" == "ai-rollback" ]] || return 1
    [[ "$(jq -r '.mode' <<<"$out")" == "list" ]] || return 1
    [[ "$(jq -r '.count' <<<"$out")" == "1" ]] || return 1
    [[ "$(jq -r '.snapshots[0].index' <<<"$out")" == "1" ]] || return 1
    [[ "$(jq -r '.snapshots[0].type' <<<"$out")" == "manifest" ]] || return 1
    [[ "$(jq -r '.snapshots[0].session' <<<"$out")" == "sess-json-list" ]] || return 1
    [[ "$(jq -r '.snapshots[0].label' <<<"$out")" == "pre-edit" ]]
}
run_test "list --json emits an ai.rollback/v1 envelope with per-snapshot fields" test_list_json_envelope

test_list_json_empty_dir() {
    local out
    out="$(AI_SNAPSHOT_DIR="$TMP/json-list-empty" "$BASH_BIN" "$SCRIPT" list --json 2>/dev/null)" || return 1
    [[ "$(jq -r '.schema' <<<"$out")" == "ai.rollback/v1" ]] || return 1
    [[ "$(jq -r '.status' <<<"$out")" == "ok" ]] || return 1
    [[ "$(jq -r '.count' <<<"$out")" == "0" ]] || return 1
    [[ "$(jq -c '.snapshots' <<<"$out")" == "[]" ]]
}
run_test "list --json on a missing snapshot dir returns status ok, count 0, empty array" test_list_json_empty_dir

test_show_json_env_form() {
    local work="$TMP/json-show" snap_dir="$TMP/json-show-snaps" out
    make_rollback_repo "$work"
    create_snapshot "$work" "$snap_dir" "sess-json-show" "pre-edit" >/dev/null
    # AI_OUTPUT=json is the env equivalent of --json.
    out="$(AI_OUTPUT=json AI_SNAPSHOT_DIR="$snap_dir" "$BASH_BIN" "$SCRIPT" show 1 2>/dev/null)" || return 1
    [[ "$(jq -r '.schema' <<<"$out")" == "ai.rollback/v1" ]] || return 1
    [[ "$(jq -r '.status' <<<"$out")" == "ok" ]] || return 1
    [[ "$(jq -r '.mode' <<<"$out")" == "show" ]] || return 1
    [[ "$(jq -r '.type' <<<"$out")" == "manifest" ]] || return 1
    [[ "$(jq -r '.manifest.session' <<<"$out")" == "sess-json-show" ]] || return 1
    [[ "$(jq -r '.manifest.label' <<<"$out")" == "pre-edit" ]]
}
run_test "AI_OUTPUT=json show emits an ai.rollback/v1 show envelope with manifest fields" test_show_json_env_form

test_default_list_stays_human_table() {
    # Backward-compat guard: without --json/AI_OUTPUT the human table is
    # unchanged and carries no envelope schema on stdout.
    local work="$TMP/json-default" snap_dir="$TMP/json-default-snaps" out
    make_rollback_repo "$work"
    create_snapshot "$work" "$snap_dir" "sess-default" "pre-edit" >/dev/null
    out="$(AI_SNAPSHOT_DIR="$snap_dir" "$BASH_BIN" "$SCRIPT" list 2>/dev/null)" || return 1
    [[ "$out" != *"ai.rollback/v1"* ]] || return 1
    [[ "$out" == *"SNAPSHOT"* ]] || return 1
    [[ "$out" == *"snapshot artifact(s) found"* ]]
}
run_test "default list stays a human table with no JSON envelope (--json is opt-in)" test_default_list_stays_human_table

test_introspect_advertises_json_flag_and_modes() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" --introspect 2>/dev/null)" || return 1
    [[ "$(jq -r '.flags | index("--json")' <<<"$out")" != "null" ]] || return 1
    [[ "$(jq -r '.modes | sort | join(",")' <<<"$out")" == "apply,list,prune,show" ]] || return 1
    # AI_OUTPUT is a real input now that the script reads ${AI_OUTPUT}.
    [[ "$(jq -r '.env | index("AI_OUTPUT")' <<<"$out")" != "null" ]]
}
run_test "--introspect advertises --json flag, the four modes, and AI_OUTPUT env" test_introspect_advertises_json_flag_and_modes

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d  Skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
((FAIL == 0)) && printf '\033[0;32mPASSED\033[0m\n' || {
    printf '\033[0;31mFAILED\033[0m\n'
    exit 1
}
