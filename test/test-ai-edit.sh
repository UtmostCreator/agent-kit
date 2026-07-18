#!/usr/bin/env bash
# Tests for libexec/ai-edit
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/libexec/ai-edit"
BASH_BIN="${BASH_BIN:-$(command -v bash)}"

PASS=0
FAIL=0
SKIP=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

run_test() {
    local name="$1"
    shift
    local rc=0
    "$@" >/dev/null 2>&1 || rc=$?
    if ((rc == 0)); then
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

make_repo() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" config user.email "ai-edit-test@example.test"
    git -C "$dir" config user.name "AI Edit Test"
    printf 'OldName\nKeep\n' >"$dir/a.txt"
    git -C "$dir" add a.txt
    git -C "$dir" commit -q -m "init"
}

run_edit() {
    local work="$1"
    shift
    (
        cd "$work"
        AI_LOG_DIR="$TMP/logs" \
            AI_EVENT_LOG="$TMP/logs/events.jsonl" \
            "$BASH_BIN" "$SCRIPT" "$@"
    )
}

# sd planning (dry-run, no-match, limit, exclude) only needs rg + jq; the
# sd binary is only invoked when --apply mutates files. Gate the two layers
# independently so plan-only coverage stays green even when sd is absent.
need_sd_plan() {
    command -v rg >/dev/null 2>&1 && command -v jq >/dev/null 2>&1
}

need_sd_apply() {
    need_sd_plan && command -v sd >/dev/null 2>&1
}

printf 'ai-edit\n'

test_help() {
    "$BASH_BIN" "$SCRIPT" --help 2>&1 | grep -q 'Status values'
}
run_test "help prints AI-facing contract sections" test_help

test_format_help() {
    "$BASH_BIN" "$SCRIPT" --format=help 2>&1 | grep -q 'Machine contract'
}
run_test "--format=help works without mode" test_format_help

test_introspect() {
    # Parity with ai-search: --introspect is intercepted by lib/common.sh and
    # delegated to the static introspector, emitting ai.sh-introspect/v1 with
    # tool=sh-introspect and meta.target_executed=false. It must NOT run the
    # edit logic. The three edit modes are still parsed out statically.
    "$BASH_BIN" "$SCRIPT" --introspect |
        jq -e '.schema=="ai.sh-introspect/v1"
            and .status=="ok"
            and .tool=="sh-introspect"
            and .name=="ai-edit"
            and .meta.target_executed==false' >/dev/null
}
run_test "--introspect emits static contract (ai.sh-introspect/v1)" test_introspect

# The edit modes are documented in the human --help view (the pure-Bash
# introspector surfaces the Usage/Modes text rather than a JSON modes[] array).
test_help_lists_modes() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" --help 2>&1 || true)"
    [[ "$out" == *"ast-grep"* && "$out" == *"comby"* && "$out" == *"sd"* ]]
}
run_test "--help documents the edit modes" test_help_lists_modes

test_missing_mode() {
    ! "$BASH_BIN" "$SCRIPT" >/dev/null 2>&1
}
run_test "missing mode fails" test_missing_mode

test_unknown_mode() {
    local work="$TMP/unknown"
    make_repo "$work"
    ! run_edit "$work" nonexistent --format json >/tmp/ai-edit-unknown.json 2>/dev/null
}
run_test "unknown mode fails" test_unknown_mode

if need_sd_plan; then
    test_sd_no_matches_json() {
        local work="$TMP/no-matches" out
        make_repo "$work"
        out="$(run_edit "$work" sd Missing Replacement . --format json)"
        jq -e '.status=="no_matches" and .plannedChanges==[] and .errors==[]' <<<"$out" >/dev/null
    }
    run_test "sd no matches returns no_matches JSON" test_sd_no_matches_json

    test_sd_dry_run_json_does_not_modify() {
        local work="$TMP/dry-run" out
        make_repo "$work"
        out="$(run_edit "$work" sd OldName NewName . --format json)"
        jq -e '.status=="dry_run" and (.plannedChanges|length)==1 and .plannedChanges[0].replacements==1' <<<"$out" >/dev/null
        grep -q 'OldName' "$work/a.txt"
        ! grep -q 'NewName' "$work/a.txt"
    }
    run_test "sd dry-run plans exact change and does not modify" test_sd_dry_run_json_does_not_modify

    # Regression: a single explicit FILE as the root must plan matches. ripgrep
    # omits the filename prefix when the target is one file, which previously
    # made sd_plan parse a bare count as the path, skip it, and wrongly report
    # no_matches even though the file had matches. sd_plan forces --with-filename.
    test_sd_single_file_root_plans_matches() {
        local work="$TMP/single-file" out
        make_repo "$work"
        out="$(run_edit "$work" sd OldName NewName a.txt --format json)"
        jq -e '.status=="dry_run" and (.plannedChanges|length)==1 and .plannedChanges[0].path=="a.txt" and .plannedChanges[0].replacements==1' <<<"$out" >/dev/null
        grep -q 'OldName' "$work/a.txt"
    }
    run_test "sd single-file root plans matches (not no_matches)" test_sd_single_file_root_plans_matches

    test_sd_max_files_blocks() {
        local work="$TMP/max-files" out rc=0
        make_repo "$work"
        printf 'OldName\n' >"$work/b.txt"
        git -C "$work" add b.txt
        git -C "$work" commit -q -m "second"

        out="$(run_edit "$work" sd OldName NewName . --max-files 1 --format json 2>/dev/null)" || rc=$?
        ((rc != 0))
        jq -e '.status=="limit_exceeded" and (.errors|length)>=1' <<<"$out" >/dev/null
        grep -q 'OldName' "$work/a.txt"
        grep -q 'OldName' "$work/b.txt"
    }
    run_test "sd max-files blocks before mutation" test_sd_max_files_blocks

    test_sd_max_replacements_blocks() {
        local work="$TMP/max-replacements" out rc=0
        make_repo "$work"
        printf 'OldName OldName OldName\n' >"$work/a.txt"
        git -C "$work" add a.txt
        git -C "$work" commit -q -m "many"

        out="$(run_edit "$work" sd OldName NewName . --max-replacements 1 --format json 2>/dev/null)" || rc=$?
        ((rc != 0))
        jq -e '.status=="limit_exceeded" and (.errors|length)>=1' <<<"$out" >/dev/null
        grep -q 'OldName' "$work/a.txt"
    }
    run_test "sd max-replacements blocks before mutation" test_sd_max_replacements_blocks

    test_sd_exclude_prevents_match() {
        local work="$TMP/exclude" out
        make_repo "$work"
        out="$(run_edit "$work" sd OldName NewName . --exclude 'a.txt' --format json)"
        jq -e '.status=="no_matches" and .plannedChanges==[]' <<<"$out" >/dev/null
        grep -q 'OldName' "$work/a.txt"
    }
    run_test "sd --exclude prevents replacement planning" test_sd_exclude_prevents_match

    # build_rg_args' include_globs loop (rg_args+=(-g "$g")) is only exercised
    # when --glob is actually passed to sd mode; every other --glob test in
    # this suite targets ast-grep/patch, which reject --glob outright via
    # structural_scope_guard before build_rg_args ever runs.
    test_sd_glob_restricts_to_matching_files() {
        local work="$TMP/sd-glob-include" out
        make_repo "$work"
        printf 'OldName\n' >"$work/b.md"
        git -C "$work" add b.md
        git -C "$work" commit -q -m "second"
        out="$(run_edit "$work" sd OldName NewName . --glob '*.md' --format json)"
        jq -e '.status=="dry_run" and (.plannedChanges|length)==1' <<<"$out" >/dev/null || return 1
        [[ "$(jq -r '.plannedChanges[0].path' <<<"$out")" == *"b.md" ]]
    }
    run_test "sd --glob restricts matches to the included glob (build_rg_args include path)" test_sd_glob_restricts_to_matching_files

    # dirty_files_json()'s early-return branch ("git rev-parse
    # --is-inside-work-tree" fails, print "[]") only fires outside a git work
    # tree. sd mode needs only rg+jq (not a git repo) to plan, so it is the
    # cheapest mode to exercise this from cwd, not a make_repo fixture.
    test_dirty_files_json_outside_git_repo() {
        local work="$TMP/no-git-repo" out
        mkdir -p "$work"
        printf 'OldName\n' >"$work/a.txt"
        out="$(run_edit "$work" sd OldName NewName . --format json)"
        jq -e '.baselineDirtyFiles==[] and .changedFiles==[]' <<<"$out" >/dev/null
    }
    run_test "dirty_files_json returns [] outside a git work tree" test_dirty_files_json_outside_git_repo

    test_ai_output_json_env() {
        local work="$TMP/env-json" out
        make_repo "$work"
        out="$(
            cd "$work"
            AI_OUTPUT=json \
                AI_LOG_DIR="$TMP/logs-env" \
                AI_EVENT_LOG="$TMP/logs-env/events.jsonl" \
                "$BASH_BIN" "$SCRIPT" sd OldName NewName .
        )"
        jq -e '.schema=="ai.edit/v1" and .status=="dry_run"' <<<"$out" >/dev/null
    }
    run_test "AI_OUTPUT=json emits JSON" test_ai_output_json_env

    # emit_result_json's additive nextStep hint: a dry_run envelope must carry
    # an actionable, non-null re-run hint so an agent can self-correct without a
    # human choosing the next flag. Success statuses (see applied test below)
    # render nextStep as null.
    test_dry_run_json_carries_next_step() {
        local work="$TMP/next-step-dry-run" out
        make_repo "$work"
        out="$(run_edit "$work" sd OldName NewName . --format json)"
        jq -e '.status=="dry_run"
            and (.nextStep|type)=="string"
            and (.nextStep|test("--apply"))' <<<"$out" >/dev/null
    }
    run_test "dry_run JSON envelope carries a non-null nextStep hint" test_dry_run_json_carries_next_step

    # "restsift edit apply MODE ARGS..." is a thin routing alias: the leading
    # "apply" token is dropped and the rest flows into the same unchanged
    # mode-dispatch logic as the bare "restsift edit MODE ARGS..." form.
    # Prove the two forms plan identically (status + plannedChanges) and that
    # neither mutates the working tree in dry-run.
    test_sd_apply_prefix_matches_bare_mode() {
        local work_bare="$TMP/apply-prefix-bare" work_alias="$TMP/apply-prefix-alias"
        local out_bare out_alias status_bare status_alias changes_bare changes_alias
        make_repo "$work_bare"
        make_repo "$work_alias"

        out_bare="$(run_edit "$work_bare" sd OldName NewName . --format json)"
        out_alias="$(run_edit "$work_alias" apply sd OldName NewName . --format json)"

        status_bare="$(jq -r '.status' <<<"$out_bare")"
        status_alias="$(jq -r '.status' <<<"$out_alias")"
        changes_bare="$(jq -c '.plannedChanges' <<<"$out_bare")"
        changes_alias="$(jq -c '.plannedChanges' <<<"$out_alias")"

        [[ "$status_bare" == "dry_run" && "$status_alias" == "dry_run" ]]
        [[ "$changes_bare" == "$changes_alias" ]]
        grep -q 'OldName' "$work_alias/a.txt"
        ! grep -q 'NewName' "$work_alias/a.txt"
    }
    run_test "edit apply sd behaves identically to bare sd (dry-run)" test_sd_apply_prefix_matches_bare_mode
else
    skip_test "sd no matches returns no_matches JSON" "requires rg, jq"
    skip_test "sd dry-run plans exact change and does not modify" "requires rg, jq"
    skip_test "sd max-files blocks before mutation" "requires rg, jq"
    skip_test "sd max-replacements blocks before mutation" "requires rg, jq"
    skip_test "sd --exclude prevents replacement planning" "requires rg, jq"
    skip_test "sd --glob restricts matches to the included glob (build_rg_args include path)" "requires rg, jq"
    skip_test "dirty_files_json returns [] outside a git work tree" "requires rg, jq"
    skip_test "AI_OUTPUT=json emits JSON" "requires rg, jq"
    skip_test "edit apply sd behaves identically to bare sd (dry-run)" "requires rg, jq"
fi

# "restsift edit rollback ARGS..." execs straight into the sibling,
# unmodified libexec/ai-rollback script (routing only, never logic fusion).
# Prove the routed invocation produces byte-identical output to calling
# ai-rollback directly, using a snapshot dir that does not exist so the
# check stays read-only and side-effect-free.
test_rollback_routes_to_ai_rollback() {
    local snap_dir="$TMP/rollback-list-route"
    local out_via_edit out_direct
    out_via_edit="$(AI_SNAPSHOT_DIR="$snap_dir" "$BASH_BIN" "$SCRIPT" rollback list 2>&1)"
    out_direct="$(AI_SNAPSHOT_DIR="$snap_dir" "$BASH_BIN" "$REPO_ROOT/libexec/ai-rollback" list 2>&1)"
    [[ "$out_via_edit" == "$out_direct" ]]
}
run_test "edit rollback list routes to unchanged ai-rollback (identical output)" test_rollback_routes_to_ai_rollback

if need_sd_apply; then
    test_sd_apply_json_modifies_file() {
        local work="$TMP/apply" out
        make_repo "$work"
        out="$(run_edit "$work" sd OldName NewName . --apply --no-verify --format json)"
        jq -e '.status=="applied" and .apply==true and (.plannedChanges|length)==1' <<<"$out" >/dev/null
        grep -q 'NewName' "$work/a.txt"
    }
    run_test "sd apply modifies file and returns applied JSON" test_sd_apply_json_modifies_file

    # A terminal success status (applied) carries no next-step hint: nextStep
    # is rendered as JSON null, not a string.
    test_applied_json_next_step_null() {
        local work="$TMP/next-step-applied" out
        make_repo "$work"
        out="$(run_edit "$work" sd OldName NewName . --apply --no-verify --format json)"
        jq -e '.status=="applied" and .nextStep==null' <<<"$out" >/dev/null
    }
    run_test "applied JSON envelope reports nextStep as null" test_applied_json_next_step_null
else
    skip_test "applied JSON envelope reports nextStep as null" "requires rg, sd, jq"
    skip_test "sd apply modifies file and returns applied JSON" "requires rg, sd, jq"
fi

# sd_apply() (lib/ai-edit/plan-apply.sh) is otherwise entirely untested on any
# host without the real `sd` binary installed (this one included). Install a
# minimal `sd FROM TO FILE` stand-in (literal in-place substitution via sed)
# ahead of the real PATH so require_bins/`command -v sd` finds it, and prove
# sd_apply's read-loop actually invokes it once per planned file.
if need_sd_plan; then
    test_sd_apply_with_fake_sd_binary() {
        local work="$TMP/apply-fake-sd" fakebin="$TMP/fakebin-sd" out
        make_repo "$work"
        mkdir -p "$fakebin"
        cat >"$fakebin/sd" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
from="$1" to="$2" file="$3"
tmp="$(mktemp)"
sed "s/${from//\//\\/}/${to//\//\\/}/g" "$file" >"$tmp" && mv "$tmp" "$file"
EOF
        chmod +x "$fakebin/sd"
        out="$(
            cd "$work"
            AI_LOG_DIR="$TMP/logs-fake-sd" \
                AI_EVENT_LOG="$TMP/logs-fake-sd/events.jsonl" \
                PATH="$fakebin:$PATH" \
                "$BASH_BIN" "$SCRIPT" sd OldName NewName . --apply --no-verify --format json
        )"
        jq -e '.status=="applied" and .apply==true and (.plannedChanges|length)==1' <<<"$out" >/dev/null
        grep -q 'NewName' "$work/a.txt"
    }
    run_test "sd_apply invokes a stand-in sd binary once per planned file" test_sd_apply_with_fake_sd_binary
else
    skip_test "sd_apply invokes a stand-in sd binary once per planned file" "requires rg, jq"
fi

# sd_plan's rg-error path (rc >= 2, distinct from rc==1 no-match): an
# unbalanced character class is an invalid regex, so rg exits 2.
if need_sd_plan; then
    test_sd_plan_rg_error() {
        local work="$TMP/sd-rg-error" out rc=0
        make_repo "$work"
        out="$(run_edit "$work" sd '[' NewName . --format json 2>/dev/null)" || rc=$?
        ((rc != 0)) || return 1
        jq -e '.status=="error" and (.errors|join(" ")|test("rg failed"))' <<<"$out" >/dev/null
    }
    run_test "sd_plan surfaces a real rg error (invalid regex) distinctly from no-match" test_sd_plan_rg_error
else
    skip_test "sd_plan surfaces a real rg error (invalid regex) distinctly from no-match" "requires rg, jq"
fi

# --- patch mode -------------------------------------------------------------
# patch mode needs only git + jq (git apply ships with git), so it does not
# depend on rg/sd availability.
need_patch() {
    command -v git >/dev/null 2>&1 && command -v jq >/dev/null 2>&1
}

# Build a unified diff that turns a.txt's "OldName" line into "NewName" and
# write it to $1, relative to the repo at $2.
make_patch() {
    local out="$1" work="$2"
    cat >"$out" <<'EOF'
diff --git a/a.txt b/a.txt
index 0000000..1111111 100644
--- a/a.txt
+++ b/a.txt
@@ -1,2 +1,2 @@
-OldName
+NewName
 Keep
EOF
}

if need_patch; then
    test_patch_dry_run_plans_no_modify() {
        local work="$TMP/patch-dry" out
        make_repo "$work"
        make_patch "$work/change.patch" "$work"
        out="$(run_edit "$work" patch change.patch . --format json)"
        jq -e '.status=="dry_run"
            and (.plannedChanges|length)==1
            and .plannedChanges[0].path=="a.txt"
            and .plannedChanges[0].operation=="patch"' <<<"$out" >/dev/null
        grep -q 'OldName' "$work/a.txt"
        ! grep -q 'NewName' "$work/a.txt"
    }
    run_test "patch dry-run plans changed file and does not modify" test_patch_dry_run_plans_no_modify

    test_patch_apply_modifies_file() {
        local work="$TMP/patch-apply" out
        make_repo "$work"
        make_patch "$work/change.patch" "$work"
        out="$(run_edit "$work" patch change.patch . --apply --no-verify --format json)"
        jq -e '.status=="applied" and .apply==true and (.plannedChanges|length)==1' <<<"$out" >/dev/null
        grep -q 'NewName' "$work/a.txt"
    }
    run_test "patch apply modifies file and returns applied JSON" test_patch_apply_modifies_file

    test_patch_max_files_blocks() {
        local work="$TMP/patch-max-files" out rc=0
        make_repo "$work"
        make_patch "$work/change.patch" "$work"
        out="$(run_edit "$work" patch change.patch . --max-files 0 --format json 2>/dev/null)" || rc=$?
        ((rc != 0))
        jq -e '.status=="limit_exceeded" and (.errors|join(" ")|test("max-files exceeded"))' <<<"$out" >/dev/null
        grep -q 'OldName' "$work/a.txt"
        ! grep -q 'NewName' "$work/a.txt"
    }
    run_test "patch_plan max-files exceeded blocks before mutation" test_patch_max_files_blocks

    test_patch_stdin_apply() {
        local work="$TMP/patch-stdin" out
        make_repo "$work"
        make_patch "$work/change.patch" "$work"
        out="$(
            cd "$work"
            AI_OUTPUT=json \
                AI_LOG_DIR="$TMP/logs-patch-stdin" \
                AI_EVENT_LOG="$TMP/logs-patch-stdin/events.jsonl" \
                "$BASH_BIN" "$SCRIPT" patch - . --apply --no-verify <change.patch
        )"
        jq -e '.status=="applied"' <<<"$out" >/dev/null
        grep -q 'NewName' "$work/a.txt"
    }
    run_test "patch reads diff from stdin and applies" test_patch_stdin_apply

    test_patch_unsafe_path_blocked() {
        local work="$TMP/patch-unsafe" out rc=0
        make_repo "$work"
        cat >"$work/evil.patch" <<'EOF'
diff --git a/.git/config b/.git/config
--- a/.git/config
+++ b/.git/config
@@ -1 +1 @@
-x
+y
EOF
        out="$(run_edit "$work" patch evil.patch . --format json 2>/dev/null)" || rc=$?
        ((rc != 0))
        jq -e '.status=="blocked" and (.errors|length)>=1' <<<"$out" >/dev/null
    }
    run_test "patch with .git path is blocked" test_patch_unsafe_path_blocked

    test_patch_secret_path_blocked() {
        local work="$TMP/patch-secret" out rc=0
        make_repo "$work"
        cat >"$work/secret.patch" <<'EOF'
diff --git a/.env b/.env
new file mode 100644
--- /dev/null
+++ b/.env
@@ -0,0 +1 @@
+TOKEN=abc
EOF
        out="$(run_edit "$work" patch secret.patch . --format json 2>/dev/null)" || rc=$?
        ((rc != 0))
        jq -e '.status=="blocked"' <<<"$out" >/dev/null
        [[ ! -f "$work/.env" ]]
    }
    run_test "patch targeting .env is blocked" test_patch_secret_path_blocked

    test_patch_does_not_apply_blocked() {
        local work="$TMP/patch-conflict" out rc=0
        make_repo "$work"
        cat >"$work/bad.patch" <<'EOF'
diff --git a/a.txt b/a.txt
--- a/a.txt
+++ b/a.txt
@@ -1,2 +1,2 @@
-DoesNotExist
+Replacement
 Keep
EOF
        out="$(run_edit "$work" patch bad.patch . --format json 2>/dev/null)" || rc=$?
        ((rc != 0))
        jq -e '.status=="blocked"' <<<"$out" >/dev/null
        grep -q 'OldName' "$work/a.txt"
    }
    run_test "patch that does not apply cleanly is blocked" test_patch_does_not_apply_blocked

    test_patch_introspect_lists_mode() {
        local out
        out="$("$BASH_BIN" "$SCRIPT" --help 2>&1 || true)"
        [[ "$out" == *"patch"* ]]
    }
    run_test "--help documents patch mode" test_patch_introspect_lists_mode
else
    skip_test "patch dry-run plans changed file and does not modify" "requires git, jq"
    skip_test "patch apply modifies file and returns applied JSON" "requires git, jq"
    skip_test "patch_plan max-files exceeded blocks before mutation" "requires git, jq"
    skip_test "patch reads diff from stdin and applies" "requires git, jq"
    skip_test "patch with .git path is blocked" "requires git, jq"
    skip_test "patch targeting .env is blocked" "requires git, jq"
    skip_test "patch that does not apply cleanly is blocked" "requires git, jq"
    skip_test "--introspect lists patch mode" "requires git, jq"
fi

# --- shared helpers for the additional coverage sections below -------------

# parse_tail's dangling-value/`=`-form checks fire before rg/sd are ever
# touched; they only need git+jq (finish() always writes a JSON manifest via
# jq, and dirty_files_json always shells out to git).
need_parse_common() {
    command -v git >/dev/null 2>&1 && command -v jq >/dev/null 2>&1
}

need_ast_grep() {
    command -v ast-grep >/dev/null 2>&1
}

need_comby() {
    command -v comby >/dev/null 2>&1
}

make_js_repo() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" config user.email "ai-edit-test@example.test"
    git -C "$dir" config user.name "AI Edit Test"
    printf 'var foo = 1;\n' >"$dir/app.js"
    git -C "$dir" add app.js
    git -C "$dir" commit -q -m "init"
}

# Same as run_edit, but swaps stdout/stderr so command substitution captures
# only what the script wrote to stderr (finish()'s non-JSON limit_exceeded /
# blocked / error / verify_failed branches print there).
# shellcheck disable=SC2069  # intentional stdout/stderr swap below: capture
# only what the command wrote to stderr, not a merge of both streams.
run_edit_stderr() {
    local work="$1"
    shift
    (
        cd "$work"
        AI_LOG_DIR="$TMP/logs" \
            AI_EVENT_LOG="$TMP/logs/events.jsonl" \
            "$BASH_BIN" "$SCRIPT" "$@"
    ) 2>&1 1>/dev/null
}

# Symlink every executable found on the current $PATH into $1, except any
# names passed as the remaining args. Used to simulate a missing binary
# (ast-grep/sg) without disturbing the real PATH for the rest of the suite.
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

# --- lib/ai-edit/parse.sh: dangling-value flags, unknown flag, `=`-form ----

if need_parse_common; then
    test_parse_format_no_value() {
        local work="$TMP/parse-format-nv"
        make_repo "$work"
        ! run_edit "$work" sd OldName NewName . --format
    }
    run_test "parse_tail: --format with no value fails" test_parse_format_no_value

    test_parse_glob_no_value() {
        local work="$TMP/parse-glob-nv"
        make_repo "$work"
        ! run_edit "$work" sd OldName NewName . --glob
    }
    run_test "parse_tail: --glob with no value fails" test_parse_glob_no_value

    test_parse_exclude_no_value() {
        local work="$TMP/parse-exclude-nv"
        make_repo "$work"
        ! run_edit "$work" sd OldName NewName . --exclude
    }
    run_test "parse_tail: --exclude with no value fails" test_parse_exclude_no_value

    test_parse_max_files_no_value() {
        local work="$TMP/parse-max-files-nv"
        make_repo "$work"
        ! run_edit "$work" sd OldName NewName . --max-files
    }
    run_test "parse_tail: --max-files with no value fails" test_parse_max_files_no_value

    test_parse_max_replacements_no_value() {
        local work="$TMP/parse-max-replacements-nv"
        make_repo "$work"
        ! run_edit "$work" sd OldName NewName . --max-replacements
    }
    run_test "parse_tail: --max-replacements with no value fails" test_parse_max_replacements_no_value

    test_parse_max_bytes_no_value() {
        local work="$TMP/parse-max-bytes-nv"
        make_repo "$work"
        ! run_edit "$work" sd OldName NewName . --max-bytes
    }
    run_test "parse_tail: --max-bytes with no value fails" test_parse_max_bytes_no_value

    test_parse_unknown_flag_rejected() {
        local work="$TMP/parse-unknown-flag"
        make_repo "$work"
        ! run_edit "$work" sd OldName NewName . --nonexistent-flag
    }
    run_test "parse_tail: unknown flag is rejected" test_parse_unknown_flag_rejected

    test_parse_format_equals_json() {
        local work="$TMP/parse-format-eq" out
        make_repo "$work"
        out="$(run_edit "$work" sd OldName NewName . --format=json)"
        jq -e '.schema=="ai.edit/v1" and .status=="dry_run"' <<<"$out" >/dev/null
    }
    run_test "parse_tail: --format=json (= form) is accepted" test_parse_format_equals_json

    test_parse_max_files_equals() {
        local work="$TMP/parse-maxfiles-eq" out
        make_repo "$work"
        out="$(run_edit "$work" sd OldName NewName . --max-files=5 --format json)"
        jq -e '.limits.maxFiles==5' <<<"$out" >/dev/null
    }
    run_test "parse_tail: --max-files=5 (= form) sets the limit" test_parse_max_files_equals

    test_parse_max_replacements_equals() {
        local work="$TMP/parse-maxreplacements-eq" out
        make_repo "$work"
        out="$(run_edit "$work" sd OldName NewName . --max-replacements=10 --format json)"
        jq -e '.limits.maxReplacements==10' <<<"$out" >/dev/null
    }
    run_test "parse_tail: --max-replacements=10 (= form) sets the limit" test_parse_max_replacements_equals

    test_parse_max_bytes_equals() {
        local work="$TMP/parse-maxbytes-eq" out
        make_repo "$work"
        out="$(run_edit "$work" sd OldName NewName . --max-bytes=999 --format json)"
        jq -e '.limits.maxBytes==999' <<<"$out" >/dev/null
    }
    run_test "parse_tail: --max-bytes=999 (= form) sets the limit" test_parse_max_bytes_equals

    test_parse_dry_run_flag_explicit() {
        local work="$TMP/parse-dry-run-explicit" out
        make_repo "$work"
        out="$(run_edit "$work" sd OldName NewName . --dry-run --format json)"
        jq -e '.status=="dry_run" and .apply==false' <<<"$out" >/dev/null
    }
    run_test "parse_tail: explicit --dry-run flag sets apply=0" test_parse_dry_run_flag_explicit

    test_parse_extra_positional_rejected() {
        local work="$TMP/parse-extra-positional"
        make_repo "$work"
        ! run_edit "$work" sd OldName NewName . extra-token
    }
    run_test "parse_tail: extra positional argument after root is rejected" test_parse_extra_positional_rejected

    test_parse_format_invalid_value() {
        local work="$TMP/parse-format-invalid"
        make_repo "$work"
        ! run_edit "$work" sd OldName NewName . --format=bogus
    }
    run_test "parse_tail: unknown --format value is rejected" test_parse_format_invalid_value

    test_parse_max_files_non_numeric() {
        local work="$TMP/parse-max-files-nan"
        make_repo "$work"
        ! run_edit "$work" sd OldName NewName . --max-files notanumber
    }
    run_test "parse_tail: --max-files non-numeric value is rejected (validate_uint)" test_parse_max_files_non_numeric

    # parse_tail's own --help/--format=help handling (lines 14-17 and 110-113)
    # only fires from within a mode's tail flags (e.g. "sd ... --help"). The
    # bare top-level "ai-edit --help"/"--format=help" forms above are
    # intercepted earlier by ai_edit_main's own guard, before parse_tail ever
    # runs, so they do not exercise this code.
    test_parse_tail_help_flag() {
        local work="$TMP/parse-tail-help" out rc=0
        make_repo "$work"
        out="$(run_edit "$work" sd OldName NewName . --help)" || rc=$?
        ((rc == 0)) || return 1
        [[ "$out" == *"Status values"* ]]
    }
    run_test "parse_tail: --help within mode tail prints usage and exits 0" test_parse_tail_help_flag

    test_parse_tail_format_help() {
        local work="$TMP/parse-tail-format-help" out rc=0
        make_repo "$work"
        out="$(run_edit "$work" sd OldName NewName . --format=help)" || rc=$?
        ((rc == 0)) || return 1
        [[ "$out" == *"Machine contract"* ]]
    }
    run_test "parse_tail: --format=help within mode tail prints usage and exits 0" test_parse_tail_format_help
else
    skip_test "parse_tail: --format with no value fails" "requires git, jq"
    skip_test "parse_tail: --glob with no value fails" "requires git, jq"
    skip_test "parse_tail: --exclude with no value fails" "requires git, jq"
    skip_test "parse_tail: --max-files with no value fails" "requires git, jq"
    skip_test "parse_tail: --max-replacements with no value fails" "requires git, jq"
    skip_test "parse_tail: --max-bytes with no value fails" "requires git, jq"
    skip_test "parse_tail: unknown flag is rejected" "requires git, jq"
    skip_test "parse_tail: --format=json (= form) is accepted" "requires git, jq"
    skip_test "parse_tail: --max-files=5 (= form) sets the limit" "requires git, jq"
    skip_test "parse_tail: --max-replacements=10 (= form) sets the limit" "requires git, jq"
    skip_test "parse_tail: --max-bytes=999 (= form) sets the limit" "requires git, jq"
    skip_test "parse_tail: explicit --dry-run flag sets apply=0" "requires git, jq"
    skip_test "parse_tail: extra positional argument after root is rejected" "requires git, jq"
    skip_test "parse_tail: unknown --format value is rejected" "requires git, jq"
    skip_test "parse_tail: --max-files non-numeric value is rejected (validate_uint)" "requires git, jq"
    skip_test "parse_tail: --help within mode tail prints usage and exits 0" "requires git, jq"
    skip_test "parse_tail: --format=help within mode tail prints usage and exits 0" "requires git, jq"
fi

# --- lib/ai-edit/helpers.sh: finish() non-JSON branches --------------------

if need_sd_plan; then
    test_finish_text_dry_run() {
        local work="$TMP/finish-dry-run-text" out
        make_repo "$work"
        out="$(run_edit "$work" sd OldName NewName .)"
        [[ "$out" == *"Dry-run only. Re-run with --apply or APPLY=1 to modify files."* ]]
    }
    run_test "finish(): dry_run non-JSON text output" test_finish_text_dry_run

    test_finish_text_no_matches() {
        local work="$TMP/finish-no-matches-text" out
        make_repo "$work"
        out="$(run_edit "$work" sd Missing Replacement .)"
        [[ "$out" == *"No matches."* ]]
    }
    run_test "finish(): no_matches non-JSON text output" test_finish_text_no_matches

    test_finish_text_limit_exceeded() {
        local work="$TMP/finish-limit-text" out
        make_repo "$work"
        printf 'OldName\n' >"$work/b.txt"
        git -C "$work" add b.txt
        git -C "$work" commit -q -m second
        out="$(run_edit_stderr "$work" sd OldName NewName . --max-files 1)" || true
        [[ "$out" == *"limit_exceeded"* ]]
    }
    run_test "finish(): limit_exceeded non-JSON text output" test_finish_text_limit_exceeded

    test_finish_text_error() {
        local work="$TMP/finish-error-text" out
        make_repo "$work"
        out="$(run_edit_stderr "$work" sd OldName NewName . --format)" || true
        [[ "$out" == *"error"* ]]
    }
    run_test "finish(): error non-JSON text output" test_finish_text_error

    # finish() text-mode error branches now surface the accumulated diagnostic
    # (errors_json), not only the bare status keyword: an unknown mode prints
    # "unknown mode: <value>" alongside the "error" status word.
    test_finish_text_error_shows_diagnostic() {
        local work="$TMP/finish-error-diagnostic" out
        make_repo "$work"
        out="$(run_edit_stderr "$work" bogusmode .)" || true
        [[ "$out" == *"unknown mode: bogusmode"* && "$out" == *"error"* ]]
    }
    run_test "finish(): error text output surfaces the diagnostic message, not just the status word" test_finish_text_error_shows_diagnostic
else
    skip_test "finish(): dry_run non-JSON text output" "requires rg, jq"
    skip_test "finish(): no_matches non-JSON text output" "requires rg, jq"
    skip_test "finish(): limit_exceeded non-JSON text output" "requires rg, jq"
    skip_test "finish(): error non-JSON text output" "requires rg, jq"
fi

# The sd binary itself is NOT installed in every environment (unlike git/jq,
# which are always available), so the applied/verified/verify_failed cases
# below use `patch` mode instead of `sd --apply` -- it needs only git+jq and
# is already proven to mutate real files by the patch block above.
if need_patch; then
    test_finish_text_applied() {
        local work="$TMP/finish-applied-text" out
        make_repo "$work"
        make_patch "$work/change.patch" "$work"
        out="$(run_edit "$work" patch change.patch . --apply --no-verify)"
        [[ "$out" == *"Applied changes. Manifest:"* ]]
    }
    run_test "finish(): applied non-JSON text output" test_finish_text_applied

    test_finish_text_verified() {
        local work="$TMP/finish-verified-text" out
        make_repo "$work"
        make_patch "$work/change.patch" "$work"
        out="$(
            cd "$work"
            AI_LOG_DIR="$TMP/logs-verified-text" \
                AI_EVENT_LOG="$TMP/logs-verified-text/events.jsonl" \
                AI_VERIFY_SCOPE=changed \
                "$BASH_BIN" "$SCRIPT" patch change.patch . --apply --verify
        )"
        [[ "$out" == *"Applied and verified. Manifest:"* ]]
    }
    run_test "finish(): verified non-JSON text output" test_finish_text_verified

    test_finish_text_verify_failed() {
        local work="$TMP/finish-verify-failed-text" out
        make_repo "$work"
        make_patch "$work/change.patch" "$work"
        out="$(
            cd "$work"
            AI_LOG_DIR="$TMP/logs-vf-text" \
                AI_EVENT_LOG="$TMP/logs-vf-text/events.jsonl" \
                AI_VERIFY_SCOPE=changed \
                LINECOUNT_ERROR=1 \
                "$BASH_BIN" "$SCRIPT" patch change.patch . --apply --verify 2>&1 1>/dev/null
        )" || true
        [[ "$out" == *"verify_failed"* ]]
    }
    run_test "finish(): verify_failed non-JSON text output" test_finish_text_verify_failed
else
    skip_test "finish(): applied non-JSON text output" "requires git, jq"
    skip_test "finish(): verified non-JSON text output" "requires git, jq"
    skip_test "finish(): verify_failed non-JSON text output" "requires git, jq"
fi

if need_patch; then
    test_finish_text_blocked() {
        local work="$TMP/finish-blocked-text" out
        make_repo "$work"
        cat >"$work/evil.patch" <<'EOF'
diff --git a/.git/config b/.git/config
--- a/.git/config
+++ b/.git/config
@@ -1 +1 @@
-x
+y
EOF
        out="$(run_edit_stderr "$work" patch evil.patch .)" || true
        [[ "$out" == *"blocked"* ]]
    }
    run_test "finish(): blocked non-JSON text output" test_finish_text_blocked
else
    skip_test "finish(): blocked non-JSON text output" "requires git, jq"
fi

test_resolve_ast_grep_not_found() {
    local work="$TMP/ast-grep-missing" fakebin="$TMP/fakebin-no-astgrep" out rc=0
    make_js_repo "$work"
    build_path_without "$fakebin" ast-grep sg
    out="$(
        cd "$work"
        AI_LOG_DIR="$TMP/logs-ast-missing" \
            AI_EVENT_LOG="$TMP/logs-ast-missing/events.jsonl" \
            AI_OUTPUT=json \
            PATH="$fakebin" \
            "$BASH_BIN" "$SCRIPT" ast-grep js 'var $A = $B' 'let $A = $B' . 2>/dev/null
    )" || rc=$?
    ((rc == 127)) || return 1
    # resolve_ast_grep now sets the caller-visible `ast_bin` global and lets
    # fail_status/finish run in the parent shell (not a command-substitution
    # subshell), so the documented status:"unavailable" envelope and its exact
    # diagnostic reach the real stdout instead of being swallowed by the generic
    # on_error ERR trap ("unexpected failure"). Exit code stays 127.
    jq -e '.status=="unavailable"
        and (.errors|index("required tool not found: ast-grep or sg") != null)' <<<"$out" >/dev/null
}
run_test "resolve_ast_grep: not-found path emits status:unavailable JSON with the exact diagnostic and exits 127" test_resolve_ast_grep_not_found

# resolve_ast_grep's "ast-grep missing, sg present" fallback branch
# (`printf 'sg\n'`) is otherwise never reached: the real system `sg` binary
# on most hosts is an unrelated set-group-id wrapper, not ast-grep's `sg`
# alias, so a naive PATH-availability test would risk invoking it for real.
# Hide the real ast-grep (and any real sg) and install a harmless stub named
# "sg" so resolve_ast_grep's own `command -v sg` check succeeds safely.
test_resolve_ast_grep_sg_fallback() {
    local work="$TMP/ast-grep-sg-fallback" fakebin="$TMP/fakebin-sg-fallback" out rc=0
    make_js_repo "$work"
    build_path_without "$fakebin" ast-grep sg
    cat >"$fakebin/sg" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$fakebin/sg"
    out="$(
        cd "$work"
        AI_LOG_DIR="$TMP/logs-sg-fallback" \
            AI_EVENT_LOG="$TMP/logs-sg-fallback/events.jsonl" \
            AI_OUTPUT=json \
            PATH="$fakebin" \
            "$BASH_BIN" "$SCRIPT" ast-grep js 'var $A = $B' 'let $A = $B' . --format json
    )" || rc=$?
    ((rc == 0)) || return 1
    jq -e '.status=="dry_run"' <<<"$out" >/dev/null
}
run_test "resolve_ast_grep: falls back to sg when ast-grep is absent but sg is present" test_resolve_ast_grep_sg_fallback

# comby mode's missing-binary check must honor the AI_OUTPUT=json contract the
# same way resolve_ast_grep does: a missing comby binary emits the ai.edit/v1
# envelope with status:"unavailable" and the exact diagnostic, exiting 127 --
# NOT require_bins/die's raw non-JSON "[ERROR] required tools not found: comby"
# text with exit 1 (which an agent parsing stdout as JSON cannot branch on).
test_comby_missing_binary_json_unavailable() {
    local work="$TMP/comby-missing" fakebin="$TMP/fakebin-no-comby" out rc=0
    make_repo "$work"
    build_path_without "$fakebin" comby
    out="$(
        cd "$work"
        AI_LOG_DIR="$TMP/logs-comby-missing" \
            AI_EVENT_LOG="$TMP/logs-comby-missing/events.jsonl" \
            AI_OUTPUT=json \
            PATH="$fakebin" \
            "$BASH_BIN" "$SCRIPT" comby OldName NewName . --dry-run 2>/dev/null
    )" || rc=$?
    ((rc == 127)) || return 1
    jq -e '.schema=="ai.edit/v1"
        and .status=="unavailable"
        and (.errors|index("required tool not found: comby") != null)' <<<"$out" >/dev/null
}
run_test "comby: missing binary emits status:unavailable JSON with the exact diagnostic and exits 127" test_comby_missing_binary_json_unavailable

# --- lib/ai-edit/main.sh: ast-grep/comby modes, --verify, dirty-tree gate --

if need_ast_grep; then
    # NOTE: `trap on_error ERR` is set in ai_edit_main, but this codebase never
    # enables `set -E`/errtrace anywhere, so per Bash semantics the ERR trap is
    # NOT inherited into functions (verified directly: a chmod-read-only-file
    # failure inside patch_apply()/sd_apply(), both called as functions, never
    # reaches on_error -- it just exits the process with the failing command's
    # raw exit code and no JSON envelope at all). on_error only fires for a
    # command that fails as a BARE top-level statement inside ai_edit_main
    # itself. The ast-grep/comby dispatch's own `"$ast_bin" run ...`/`comby ...`
    # invocations are the only such bare commands in the mutation paths, so
    # this test forces one of those (an invalid --lang) to fail unexpectedly.
    # See the bug noted in the implementer handoff.
    test_on_error_trap_fires_on_unexpected_failure() {
        local work="$TMP/on-error" out rc=0
        make_js_repo "$work"
        out="$(run_edit "$work" ast-grep bogus-lang-xyz 'var $A = $B' 'let $A = $B' . --apply --no-verify --format json 2>/dev/null)" || rc=$?
        ((rc != 0)) || return 1
        jq -e '.status=="error"' <<<"$out" >/dev/null
    }
    run_test "on_error ERR trap fires on an unexpected mid-mode failure (status=error)" test_on_error_trap_fires_on_unexpected_failure
else
    skip_test "on_error ERR trap fires on an unexpected mid-mode failure (status=error)" "ast-grep/sg not installed"
fi

if need_ast_grep; then
    test_ast_grep_dry_run_does_not_modify() {
        local work="$TMP/ast-grep-dry" out
        make_js_repo "$work"
        out="$(run_edit "$work" ast-grep js 'var $A = $B' 'let $A = $B' . --format json)"
        jq -e '.status=="dry_run"' <<<"$out" >/dev/null || return 1
        grep -q 'var foo = 1' "$work/app.js" || return 1
        ! grep -q 'let foo' "$work/app.js"
    }
    run_test "ast-grep dry-run plans without modifying the file" test_ast_grep_dry_run_does_not_modify

    test_ast_grep_apply_modifies_file() {
        local work="$TMP/ast-grep-apply" out
        make_js_repo "$work"
        out="$(run_edit "$work" ast-grep js 'var $A = $B' 'let $A = $B' . --apply --no-verify --format json)"
        jq -e '.status=="applied"' <<<"$out" >/dev/null || return 1
        grep -q 'let foo' "$work/app.js"
    }
    run_test "ast-grep --apply rewrites the file and returns applied JSON" test_ast_grep_apply_modifies_file

    test_ast_grep_glob_blocked_by_structural_scope_guard() {
        local work="$TMP/ast-grep-glob" out rc=0
        make_js_repo "$work"
        out="$(run_edit "$work" ast-grep js 'var $A = $B' 'let $A = $B' . --glob '*.js' --format json 2>/dev/null)" || rc=$?
        ((rc != 0)) || return 1
        jq -e '.status=="blocked"' <<<"$out" >/dev/null
    }
    run_test "structural_scope_guard blocks ast-grep + --glob" test_ast_grep_glob_blocked_by_structural_scope_guard
else
    skip_test "ast-grep dry-run plans without modifying the file" "ast-grep/sg not installed"
    skip_test "ast-grep --apply rewrites the file and returns applied JSON" "ast-grep/sg not installed"
    skip_test "structural_scope_guard blocks ast-grep + --glob" "ast-grep/sg not installed"
fi

if need_comby; then
    test_comby_dry_run_does_not_modify() {
        local work="$TMP/comby-dry" out
        make_repo "$work"
        out="$(run_edit "$work" comby 'OldName' 'NewName' . --format json)"
        jq -e '.status=="dry_run"' <<<"$out" >/dev/null || return 1
        grep -q 'OldName' "$work/a.txt"
    }
    run_test "comby dry-run plans without modifying the file" test_comby_dry_run_does_not_modify

    test_comby_apply_modifies_file() {
        local work="$TMP/comby-apply" out
        make_repo "$work"
        out="$(run_edit "$work" comby 'OldName' 'NewName' . --apply --no-verify --format json)"
        jq -e '.status=="applied"' <<<"$out" >/dev/null || return 1
        grep -q 'NewName' "$work/a.txt"
    }
    run_test "comby --apply rewrites the file and returns applied JSON" test_comby_apply_modifies_file
else
    skip_test "comby dry-run plans without modifying the file" "comby not installed"
    skip_test "comby --apply rewrites the file and returns applied JSON" "comby not installed"
fi

# Same rg/sd-availability rationale as the block above: patch mode (git+jq
# only) exercises --verify and the dirty-tree gate without depending on sd.
if need_patch; then
    test_verify_success_json() {
        local work="$TMP/verify-success" out rc=0
        make_repo "$work"
        make_patch "$work/change.patch" "$work"
        out="$(
            cd "$work"
            AI_LOG_DIR="$TMP/logs-verify-ok" \
                AI_EVENT_LOG="$TMP/logs-verify-ok/events.jsonl" \
                AI_VERIFY_SCOPE=changed \
                "$BASH_BIN" "$SCRIPT" patch change.patch . --apply --verify --format json
        )" || rc=$?
        ((rc == 0)) || return 1
        jq -e '.status=="verified"' <<<"$out" >/dev/null
    }
    run_test "patch --verify succeeds against a clean change and returns verified status" test_verify_success_json

    test_verify_failure_json() {
        local work="$TMP/verify-fail" out rc=0
        make_repo "$work"
        make_patch "$work/change.patch" "$work"
        out="$(
            cd "$work"
            AI_LOG_DIR="$TMP/logs-verify-fail" \
                AI_EVENT_LOG="$TMP/logs-verify-fail/events.jsonl" \
                AI_VERIFY_SCOPE=changed \
                LINECOUNT_ERROR=1 \
                "$BASH_BIN" "$SCRIPT" patch change.patch . --apply --verify --format json 2>/dev/null
        )" || rc=$?
        ((rc != 0)) || return 1
        jq -e '.status=="verify_failed"' <<<"$out" >/dev/null
    }
    run_test "patch --verify fails a deliberately-broken check and returns verify_failed status" test_verify_failure_json

    test_apply_dirty_tree_blocked_by_default() {
        local work="$TMP/dirty-default" rc=0
        make_repo "$work"
        make_patch "$work/change.patch" "$work"
        printf 'dirty\n' >>"$work/a.txt"
        run_edit "$work" patch change.patch . --apply --no-verify >/dev/null 2>&1 || rc=$?
        ((rc != 0)) || return 1
        grep -q 'OldName' "$work/a.txt" || return 1
        ! grep -q 'NewName' "$work/a.txt"
    }
    run_test "apply with a dirty tree is blocked by the default require-clean-tree gate" test_apply_dirty_tree_blocked_by_default

    # Regression: a dirty-tree block under AI_OUTPUT=json must honor the
    # ai.edit/v1 contract (parseable JSON on stdout, status:"blocked", exit 4)
    # rather than the shared require_clean_tree die()'s raw text + exit 1.
    test_apply_dirty_tree_blocked_emits_json_envelope() {
        local work="$TMP/dirty-json" out rc=0
        make_repo "$work"
        make_patch "$work/change.patch" "$work"
        printf 'dirty\n' >>"$work/a.txt"
        out="$(run_edit "$work" patch change.patch . --apply --no-verify --format json 2>/dev/null)" || rc=$?
        ((rc == 4)) || return 1
        jq -e '.schema=="ai.edit/v1" and .status=="blocked"' <<<"$out" >/dev/null
    }
    run_test "apply on a dirty tree still emits a blocked ai.edit/v1 JSON envelope (exit 4)" test_apply_dirty_tree_blocked_emits_json_envelope

    test_apply_allow_dirty_tree_bypasses_gate() {
        local work="$TMP/dirty-allow" out
        make_repo "$work"
        make_patch "$work/change.patch" "$work"
        printf 'dirty\n' >>"$work/a.txt"
        out="$(run_edit "$work" patch change.patch . --apply --no-verify --allow-dirty-tree --format json)"
        jq -e '.status=="applied"' <<<"$out" >/dev/null || return 1
        grep -q 'NewName' "$work/a.txt"
    }
    run_test "--allow-dirty-tree bypasses the require-clean-tree gate" test_apply_allow_dirty_tree_bypasses_gate

    # --require-clean-tree's own case arm (require_clean_tree_flag=1) is only
    # distinct from the default when passed explicitly; every other apply
    # test above relies on the implicit default instead.
    test_apply_require_clean_tree_explicit_flag() {
        local work="$TMP/require-clean-explicit" out
        make_repo "$work"
        make_patch "$work/change.patch" "$work"
        out="$(run_edit "$work" patch change.patch . --apply --no-verify --require-clean-tree --format json)"
        jq -e '.status=="applied"' <<<"$out" >/dev/null || return 1
        grep -q 'NewName' "$work/a.txt"
    }
    run_test "parse_tail: explicit --require-clean-tree flag still allows apply on a clean tree" test_apply_require_clean_tree_explicit_flag
else
    skip_test "patch --verify succeeds against a clean change and returns verified status" "requires git, jq"
    skip_test "patch --verify fails a deliberately-broken check and returns verify_failed status" "requires git, jq"
    skip_test "apply with a dirty tree is blocked by the default require-clean-tree gate" "requires git, jq"
    skip_test "apply on a dirty tree still emits a blocked ai.edit/v1 JSON envelope (exit 4)" "requires git, jq"
    skip_test "--allow-dirty-tree bypasses the require-clean-tree gate" "requires git, jq"
    skip_test "parse_tail: explicit --require-clean-tree flag still allows apply on a clean tree" "requires git, jq"
fi

# --- lib/ai-edit/plan-apply.sh: oversized-file skip, patch denylist, guard -

if need_sd_plan; then
    test_sd_oversized_file_skipped_limit_exceeded() {
        local work="$TMP/sd-oversized" out rc=0
        make_repo "$work"
        {
            printf 'OldName\n'
            printf 'X%.0s' {1..3000}
            printf '\n'
        } >"$work/a.txt"
        git -C "$work" add a.txt
        git -C "$work" commit -q -m "oversized"
        out="$(run_edit "$work" sd OldName NewName . --max-bytes 100 --format json 2>/dev/null)" || rc=$?
        ((rc != 0)) || return 1
        jq -e '.status=="limit_exceeded" and ([.warnings[] | select(contains("oversized"))] | length) >= 1' <<<"$out" >/dev/null
    }
    run_test "sd_plan skips an oversized file (add_warning) and reports limit_exceeded when none remain" test_sd_oversized_file_skipped_limit_exceeded
else
    skip_test "sd_plan skips an oversized file (add_warning) and reports limit_exceeded when none remain" "requires rg, jq"
fi

if need_patch; then
    test_patch_pem_blocked() {
        local work="$TMP/patch-pem" out rc=0
        make_repo "$work"
        cat >"$work/pem.patch" <<'EOF'
diff --git a/server.pem b/server.pem
new file mode 100644
--- /dev/null
+++ b/server.pem
@@ -0,0 +1 @@
+FAKEPEMDATA
EOF
        out="$(run_edit "$work" patch pem.patch . --format json 2>/dev/null)" || rc=$?
        ((rc != 0)) || return 1
        jq -e '.status=="blocked"' <<<"$out" >/dev/null || return 1
        [[ ! -f "$work/server.pem" ]]
    }
    run_test "patch_guard_paths blocks *.pem beyond the .env/.git denylist" test_patch_pem_blocked

    test_patch_sqlite_blocked() {
        local work="$TMP/patch-sqlite" out rc=0
        make_repo "$work"
        cat >"$work/db.patch" <<'EOF'
diff --git a/data.sqlite b/data.sqlite
new file mode 100644
--- /dev/null
+++ b/data.sqlite
@@ -0,0 +1 @@
+FAKEDB
EOF
        out="$(run_edit "$work" patch db.patch . --format json 2>/dev/null)" || rc=$?
        ((rc != 0)) || return 1
        jq -e '.status=="blocked"' <<<"$out" >/dev/null || return 1
        [[ ! -f "$work/data.sqlite" ]]
    }
    run_test "patch_guard_paths blocks *.sqlite beyond the .env/.git denylist" test_patch_sqlite_blocked

    test_patch_glob_blocked_by_structural_scope_guard() {
        local work="$TMP/patch-glob" out rc=0
        make_repo "$work"
        make_patch "$work/change.patch" "$work"
        out="$(run_edit "$work" patch change.patch . --glob '*.txt' --format json 2>/dev/null)" || rc=$?
        ((rc != 0)) || return 1
        jq -e '.status=="blocked"' <<<"$out" >/dev/null
    }
    run_test "structural_scope_guard blocks patch + --glob" test_patch_glob_blocked_by_structural_scope_guard
else
    skip_test "patch_guard_paths blocks *.pem beyond the .env/.git denylist" "requires git, jq"
    skip_test "patch_guard_paths blocks *.sqlite beyond the .env/.git denylist" "requires git, jq"
    skip_test "structural_scope_guard blocks patch + --glob" "requires git, jq"
fi

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d  Skipped: %d\n' "$PASS" "$FAIL" "$SKIP"

if ((FAIL == 0)); then
    printf '\033[0;32mPASSED\033[0m\n'
else
    printf '\033[0;31mFAILED\033[0m\n'
    exit 1
fi
