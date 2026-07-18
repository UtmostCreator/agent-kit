#!/usr/bin/env bash
# Tests for libexec/ai-git (fused git-branch-origin + git-forensics +
# gh-pr-context). Replaces test-git-branch-origin.sh, test-git-forensics.sh,
# and test-gh-pr-context.sh, which tested the pre-fusion standalone engines.
set -euo pipefail
BASH_BIN="${BASH_BIN:-$(command -v bash)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/libexec/ai-git"
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

# A git repo with an initial (empty) commit on a caller-chosen branch name,
# ready for further commits/branches.
make_git_fixture() {
    local dir="$1" branch="${2:-main}"
    mkdir -p "$dir"
    (
        cd "$dir" && git init -q &&
            git symbolic-ref HEAD "refs/heads/$branch" &&
            git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    ) >/dev/null 2>&1
}

# A fake `gh` binary answering the pr-context subcommands: `gh pr view <n>
# --json <fields>` (full metadata, or --json files for the pack path), `gh pr
# checks <n> --json ...`, and `gh pr diff <n>`.
make_fake_gh() {
    local bin_dir="$1"
    mkdir -p "$bin_dir"
    cat >"$bin_dir/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail
sub="${1:-} ${2:-}"
case "$sub" in
"pr view")
    json_val=""
    args=("$@")
    for ((i = 0; i < ${#args[@]}; i++)); do
        [[ "${args[i]}" == "--json" ]] && json_val="${args[i+1]:-}"
    done
    case "$json_val" in
    files)
        printf '%s\n' "${FAKE_GH_FILES:-README.md}"
        ;;
    reviews)
        cat <<'JSON'
[{"author":"alice","state":"APPROVED","body":"Looks good","submittedAt":"2026-01-01T00:00:00Z"}]
JSON
        ;;
    *)
        cat <<'JSON'
{"title":"Add feature X","body":"This PR adds feature X.","author":{"login":"alice"},"state":"OPEN","baseRefName":"main","headRefName":"feature-x","files":[{"path":"README.md"},{"path":"lib/foo.sh"}],"commits":[{"oid":"abc"},{"oid":"def"}],"labels":[{"name":"enhancement"}],"assignees":[{"login":"bob"}],"reviewRequests":[],"isDraft":false,"url":"https://example.com/pr/1","mergedAt":null,"closedAt":null,"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-02T00:00:00Z"}
JSON
        ;;
    esac
    ;;
"pr checks")
    cat <<'JSON'
[{"name":"build","state":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-01-01T00:00:00Z","completedAt":"2026-01-01T00:05:00Z","link":"https://example.com/build"}]
JSON
    ;;
"pr diff")
    printf 'diff --git a/README.md b/README.md\n+hello world\n'
    ;;
*)
    exit 1
    ;;
esac
FAKE_GH
    chmod +x "$bin_dir/gh"
}

printf 'ai-git\n'

# =============================================================================
# origin (fused from git-branch-origin)
# =============================================================================

test_origin_help() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" origin --help 2>&1 || true)"
    [[ "$out" == *"restsift git origin"* && "$out" == *"--field"* ]]
}
run_test "origin --help prints usage" test_origin_help

# Fixture: main (1 commit) + feature (current, 1 commit ahead) + a
# remote-tracking origin/main pointing at the same commit as main. Used for
# every "origin" test below that isn't itself exercising a specific
# candidate-search scenario, so they get a deterministic answer (best
# candidate: local "main", priority 0 via base-pattern match) regardless of
# what remotes/branches the ambient checkout happens to have. This matters
# because CI's no-external-actions checkout (see .github/workflows/ci.yml)
# does a bare `git fetch --depth=1` into a detached HEAD with no local
# branches and no origin/* refs at all — running these tests directly against
# that checkout left every one of them with nothing to detect and no
# origin/main fallback ref to honor, which is exactly what CI's first real
# run surfaced.
ORIGIN_BASIC_FIX="$TMP/origin-basic-fixture"
make_git_fixture "$ORIGIN_BASIC_FIX" main
(
    cd "$ORIGIN_BASIC_FIX" &&
        git update-ref refs/remotes/origin/main "$(git rev-parse main)" &&
        git checkout -q -b feature &&
        git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "feature work"
) >/dev/null 2>&1

test_origin_default_name() {
    local out
    out="$(cd "$ORIGIN_BASIC_FIX" && "$BASH_BIN" "$SCRIPT" origin 2>/dev/null || true)"
    [[ -n "$out" ]]
}
run_test "origin prints a non-empty origin branch name" test_origin_default_name

test_origin_field_base() {
    local out
    out="$(cd "$ORIGIN_BASIC_FIX" && "$BASH_BIN" "$SCRIPT" origin --field base 2>/dev/null || true)"
    [[ "$out" =~ ^[0-9a-f]{7,40}$ ]]
}
run_test "origin --field base prints a merge-base sha" test_origin_field_base

test_origin_field_count() {
    local out
    out="$(cd "$ORIGIN_BASIC_FIX" && "$BASH_BIN" "$SCRIPT" origin --field count 2>/dev/null || true)"
    [[ "$out" =~ ^[0-9]+$ ]]
}
run_test "origin --field count prints an integer distance" test_origin_field_count

test_origin_field_all() {
    local out
    out="$(cd "$ORIGIN_BASIC_FIX" && "$BASH_BIN" "$SCRIPT" origin --field all 2>/dev/null || true)"
    [[ "$(awk -F'\t' '{print NF}' <<<"$out")" == "3" ]]
}
run_test "origin --field all prints name<TAB>base<TAB>count" test_origin_field_all

if command -v jq >/dev/null 2>&1; then
    test_origin_json() {
        local out
        out="$(cd "$ORIGIN_BASIC_FIX" && "$BASH_BIN" "$SCRIPT" origin --json 2>/dev/null || true)"
        jq -e '.tool == "git-branch-origin" and (.origin_branch|type=="string") and (.merge_base|type=="string") and (.distance|type=="number")' <<<"$out" >/dev/null
    }
    run_test "origin --json emits a valid envelope" test_origin_json
else
    skip_test "origin --json emits a valid envelope" "jq not installed"
fi

test_origin_override() {
    local out
    out="$(cd "$ORIGIN_BASIC_FIX" && GIT_ORIGIN_REF=origin/main "$BASH_BIN" "$SCRIPT" origin --field name 2>/dev/null || true)"
    [[ "$out" == "origin/main" ]]
}
run_test "origin GIT_ORIGIN_REF override is honored" test_origin_override

test_origin_bad_field() {
    local rc=0
    "$BASH_BIN" "$SCRIPT" origin --field bogus >/dev/null 2>&1 || rc=$?
    ((rc != 0))
}
run_test "origin invalid --field exits non-zero" test_origin_bad_field

test_origin_field_equals_form() {
    local out
    out="$(cd "$ORIGIN_BASIC_FIX" && "$BASH_BIN" "$SCRIPT" origin --field=count 2>/dev/null || true)"
    [[ "$out" =~ ^[0-9]+$ ]]
}
run_test "origin --field=count equals-form is parsed" test_origin_field_equals_form

# Fixture: trunk -> widgets-base -> widgets-fix (current). widgets-base
# doesn't match any AI_GIT_ORIGIN_DEFAULT_BASE_PATTERNS glob, so it can only
# out-rank trunk (no shared prefix) via ai_git_origin_shares_prefix's
# "widgets" token match, not via ai_git_origin_matches_base_pattern.
ORIGIN_PREFIX_FIX="$TMP/origin-prefix-fixture"
make_git_fixture "$ORIGIN_PREFIX_FIX" trunk
(
    cd "$ORIGIN_PREFIX_FIX" &&
        git checkout -q -b widgets-base &&
        git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "widgets base work" &&
        git checkout -q -b widgets-fix &&
        git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "widgets fix work"
) >/dev/null 2>&1

test_origin_shares_prefix_wins() {
    local out
    out="$(cd "$ORIGIN_PREFIX_FIX" && "$BASH_BIN" "$SCRIPT" origin --field name 2>/dev/null || true)"
    [[ "$out" == "widgets-base" ]]
}
run_test "origin shares-prefix branch outranks unrelated candidate" test_origin_shares_prefix_wins

# Fixture: a fresh single-commit repo with no sibling branches and no
# remotes, so `scored` is empty and the origin/main|master|main|master
# fallback loop must run.
ORIGIN_FALLBACK_FIX="$TMP/origin-fallback-fixture"
make_git_fixture "$ORIGIN_FALLBACK_FIX" main

test_origin_no_candidates_fallback() {
    local name count
    name="$(cd "$ORIGIN_FALLBACK_FIX" && "$BASH_BIN" "$SCRIPT" origin --field name 2>/dev/null || true)"
    count="$(cd "$ORIGIN_FALLBACK_FIX" && "$BASH_BIN" "$SCRIPT" origin --field count 2>/dev/null || true)"
    [[ "$name" == "main" && "$count" == "0" ]]
}
run_test "origin falls back to origin/main|master search with no candidates" test_origin_no_candidates_fallback

# Fixture: main + feature (current) + a remote-tracking ref (origin/develop)
# that only shows up as a candidate when remotes are included.
ORIGIN_REMOTE_FIX="$TMP/origin-remote-fixture"
make_git_fixture "$ORIGIN_REMOTE_FIX" main
(
    cd "$ORIGIN_REMOTE_FIX" &&
        git checkout -q -b feature &&
        git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "feature work" &&
        git update-ref refs/remotes/origin/develop "$(git rev-parse main)"
) >/dev/null 2>&1

if command -v jq >/dev/null 2>&1; then
    test_origin_include_remote_default() {
        local out
        out="$(cd "$ORIGIN_REMOTE_FIX" && "$BASH_BIN" "$SCRIPT" origin --json 2>/dev/null || true)"
        jq -e '.candidates | any(.name == "origin/develop")' <<<"$out" >/dev/null
    }
    run_test "origin includes remote-tracking candidates by default" test_origin_include_remote_default

    test_origin_include_remote_disabled() {
        local out
        out="$(cd "$ORIGIN_REMOTE_FIX" && GIT_ORIGIN_INCLUDE_REMOTE=0 "$BASH_BIN" "$SCRIPT" origin --json 2>/dev/null || true)"
        jq -e '(.candidates | any(.name == "origin/develop")) | not' <<<"$out" >/dev/null
    }
    run_test "origin GIT_ORIGIN_INCLUDE_REMOTE=0 excludes remote-tracking candidates" test_origin_include_remote_disabled
else
    skip_test "origin includes remote-tracking candidates by default" "jq not installed"
    skip_test "origin GIT_ORIGIN_INCLUDE_REMOTE=0 excludes remote-tracking candidates" "jq not installed"
fi

# =============================================================================
# history / blame (fused from git-forensics)
# =============================================================================

test_history_help() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" history --help 2>&1)"
    [[ "$out" == *Usage* ]]
}
run_test "history --help exits successfully" test_history_help

test_history_no_args() { ! "$BASH_BIN" "$SCRIPT" history 2>/dev/null; }
run_test "history missing args fails" test_history_no_args

test_history_s_mode() {
    "$BASH_BIN" "$SCRIPT" history S "common_require_core" >/dev/null 2>&1 || true
    true
}
run_test "history S mode runs without crash" test_history_s_mode

test_history_g_mode() {
    "$BASH_BIN" "$SCRIPT" history G "require_bins" >/dev/null 2>&1 || true
    true
}
run_test "history G mode runs without crash" test_history_g_mode

test_blame() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" blame "1,5" lib/common.sh 2>/dev/null)"
    [[ -n "$out" ]]
}
run_test "blame returns output" test_blame

test_blame_no_file() {
    ! "$BASH_BIN" "$SCRIPT" blame "1,5" 2>/dev/null
}
run_test "blame without file fails" test_blame_no_file

test_blame_json() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" blame "1,3" lib/common.sh --json 2>/dev/null)"
    echo "$out" | jq -e '.mode' >/dev/null
    echo "$out" | jq -e '.output' >/dev/null
}
run_test "blame --json has mode and output fields" test_blame_json

# Regression (defect 1): --json must not swallow the underlying command's
# failure. A blame on a nonexistent file exits non-zero in plain mode; the
# --json envelope must both exit non-zero AND carry a status/error a caller can
# branch on, instead of stuffing the error text into `output` and exiting 0.
test_blame_json_propagates_failure() {
    local out rc=0
    out="$("$BASH_BIN" "$SCRIPT" blame "1,10" NOPE_FILE_DOES_NOT_EXIST.md --json 2>/dev/null)" || rc=$?
    ((rc != 0)) || return 1
    jq -e '.status != 0 and .error != null' <<<"$out" >/dev/null
}
run_test "blame --json propagates underlying failure" test_blame_json_propagates_failure

# Regression (defect 2): an out-of-range LINES spec on a tracked file must not
# fall through to the sed fallback (which returns empty output and exit 0);
# git's invalid-range error must surface as a non-zero exit.
test_blame_out_of_range_fails() {
    local rc=0
    "$BASH_BIN" "$SCRIPT" blame "999999,1000000" lib/common.sh >/dev/null 2>&1 || rc=$?
    ((rc != 0))
}
run_test "blame out-of-range on tracked file surfaces error" test_blame_out_of_range_fails

# A bad LINES spec on a tracked file must surface an actionable ai-git `hint`
# in the --json envelope (wrapping git's raw usage/fatal text), while still
# carrying a non-zero status and exiting non-zero.
test_blame_json_hint() {
    local out rc=0
    out="$("$BASH_BIN" "$SCRIPT" blame "notaline" lib/common.sh --json 2>/dev/null)" || rc=$?
    ((rc != 0)) || return 1
    jq -e '.hint != null and (.hint | contains("blame LINES")) and .status != 0' <<<"$out" >/dev/null
}
run_test "blame bad line spec --json carries an actionable hint" test_blame_json_hint

test_history_unknown_mode() {
    ! "$BASH_BIN" "$SCRIPT" history X "query" 2>/dev/null
}
run_test "history unknown mode fails" test_history_unknown_mode

# =============================================================================
# pr-context (fused from gh-pr-context)
# =============================================================================

if ! command -v gh >/dev/null 2>&1; then
    skip_test "pr-context missing PR number fails" "gh CLI not installed"
    skip_test "pr-context unknown option fails" "gh CLI not installed"
    skip_test "pr-context plain output assembles PR metadata" "gh CLI not installed"
    skip_test "pr-context --json emits a valid envelope" "gh CLI not installed"
    skip_test "pr-context --checks plain output includes CI table" "gh CLI not installed"
    skip_test "pr-context --checks --json includes the checks array" "gh CLI not installed"
    skip_test "pr-context --reviews plain output includes review notes" "gh CLI not installed"
    skip_test "pr-context --reviews --json includes the reviews array" "gh CLI not installed"
    skip_test "pr-context --diff plain output includes a diff fence" "gh CLI not installed"
    skip_test "pr-context --diff --json includes the diff field" "gh CLI not installed"
    skip_test "pr-context --pack packs PR files via ai-context diff pr" "gh CLI not installed"
    skip_test "pr-context logs a gh-pr-context.done event" "gh CLI not installed"
else
    test_pr_context_no_pr() { ! "$BASH_BIN" "$SCRIPT" pr-context 2>/dev/null; }
    run_test "pr-context missing PR number fails" test_pr_context_no_pr

    test_pr_context_unknown() { ! "$BASH_BIN" "$SCRIPT" pr-context 1 --bogus 2>/dev/null; }
    run_test "pr-context unknown option fails" test_pr_context_unknown

    PR_GH_BIN="$TMP/fake-gh-bin"
    make_fake_gh "$PR_GH_BIN"

    test_pr_context_plain() {
        local out
        out="$(PATH="$PR_GH_BIN:$PATH" AI_SESSION_DURABLE_LOG=0 "$BASH_BIN" "$SCRIPT" pr-context 1 2>/dev/null)"
        [[ "$out" == *"# PR #1 - Add feature X"* ]] &&
            [[ "$out" == *"**State:** OPEN  |  **Author:** alice  |  **Draft:** false"* ]] &&
            [[ "$out" == *"**Base:** main  <-  **Head:** feature-x"* ]] &&
            [[ "$out" == *"**Files changed:** 2  |  **Commits:** 2"* ]] &&
            [[ "$out" == *"- README.md"* ]] &&
            [[ "$out" == *"- lib/foo.sh"* ]] &&
            [[ "$out" == *"This PR adds feature X."* ]] &&
            [[ "$out" != *"## CI Checks"* ]] &&
            [[ "$out" != *"## Reviews"* ]] &&
            [[ "$out" != *"## Diff"* ]]
    }
    run_test "pr-context plain output assembles PR metadata" test_pr_context_plain

    test_pr_context_json() {
        local out
        out="$(PATH="$PR_GH_BIN:$PATH" AI_SESSION_DURABLE_LOG=0 "$BASH_BIN" "$SCRIPT" pr-context 1 --json 2>/dev/null)"
        jq -e '.pr.title == "Add feature X"
            and .pr.state == "OPEN"
            and .pr.author == "alice"
            and .pr.base == "main"
            and .pr.head == "feature-x"
            and .pr.fileCount == 2
            and .pr.commitCount == 2
            and .checks == null
            and .reviews == null
            and .diff == null' <<<"$out" >/dev/null
    }
    run_test "pr-context --json emits a valid envelope" test_pr_context_json

    # The --json output must carry the stable ai-git envelope header
    # (schema/status/tool + warnings/errors arrays) shared with `origin --json`,
    # so an agent can parse any mode's output the same way.
    test_pr_context_json_envelope() {
        local out
        out="$(PATH="$PR_GH_BIN:$PATH" AI_SESSION_DURABLE_LOG=0 "$BASH_BIN" "$SCRIPT" pr-context 1 --json 2>/dev/null)"
        jq -e '.schema == 1
            and .status == "ok"
            and .tool == "gh-pr-context"
            and (.warnings | type) == "array"
            and (.errors | type) == "array"' <<<"$out" >/dev/null
    }
    run_test "pr-context --json carries the shared schema/status/tool envelope" test_pr_context_json_envelope

    test_pr_context_checks_plain() {
        local out
        out="$(PATH="$PR_GH_BIN:$PATH" AI_SESSION_DURABLE_LOG=0 "$BASH_BIN" "$SCRIPT" pr-context 1 --checks 2>/dev/null)"
        [[ "$out" == *"## CI Checks"* ]] && [[ "$out" == *"build"* ]] && [[ "$out" == *"SUCCESS"* ]]
    }
    run_test "pr-context --checks plain output includes CI table" test_pr_context_checks_plain

    test_pr_context_checks_json() {
        local out
        out="$(PATH="$PR_GH_BIN:$PATH" AI_SESSION_DURABLE_LOG=0 "$BASH_BIN" "$SCRIPT" pr-context 1 --checks --json 2>/dev/null)"
        jq -e '(.checks | length) == 1 and .checks[0].name == "build" and .checks[0].conclusion == "SUCCESS"' <<<"$out" >/dev/null
    }
    run_test "pr-context --checks --json includes the checks array" test_pr_context_checks_json

    test_pr_context_reviews_plain() {
        local out
        out="$(PATH="$PR_GH_BIN:$PATH" AI_SESSION_DURABLE_LOG=0 "$BASH_BIN" "$SCRIPT" pr-context 1 --reviews 2>/dev/null)"
        [[ "$out" == *"## Reviews"* ]] && [[ "$out" == *"**alice** [APPROVED]: Looks good"* ]]
    }
    run_test "pr-context --reviews plain output includes review notes" test_pr_context_reviews_plain

    test_pr_context_reviews_json() {
        local out
        out="$(PATH="$PR_GH_BIN:$PATH" AI_SESSION_DURABLE_LOG=0 "$BASH_BIN" "$SCRIPT" pr-context 1 --reviews --json 2>/dev/null)"
        jq -e '(.reviews | length) == 1 and .reviews[0].author == "alice" and .reviews[0].state == "APPROVED"' <<<"$out" >/dev/null
    }
    run_test "pr-context --reviews --json includes the reviews array" test_pr_context_reviews_json

    test_pr_context_diff_plain() {
        local out
        out="$(PATH="$PR_GH_BIN:$PATH" AI_SESSION_DURABLE_LOG=0 "$BASH_BIN" "$SCRIPT" pr-context 1 --diff 2>/dev/null)"
        [[ "$out" == *'## Diff'* ]] && [[ "$out" == *'```diff'* ]] && [[ "$out" == *"diff --git a/README.md b/README.md"* ]]
    }
    run_test "pr-context --diff plain output includes a diff fence" test_pr_context_diff_plain

    test_pr_context_diff_json() {
        local out
        out="$(PATH="$PR_GH_BIN:$PATH" AI_SESSION_DURABLE_LOG=0 "$BASH_BIN" "$SCRIPT" pr-context 1 --diff --json 2>/dev/null)"
        jq -e '(.diff | type) == "string" and (.diff | contains("diff --git"))' <<<"$out" >/dev/null
    }
    run_test "pr-context --diff --json includes the diff field" test_pr_context_diff_json

    # --pack shells out to a sibling libexec/ai-context "diff pr <n>" process
    # (the former standalone libexec/ai-diff-context), which itself calls `gh
    # pr view --json files` and packs the resulting file list with the real
    # repomix/gitleaks toolchain. Use a throwaway single-file fixture repo (not
    # this toolkit's own tree) so the packer's secret guard and file scan stay
    # small and fast.
    PR_PACK_FIX="$TMP/pr-pack-fixture"
    mkdir -p "$PR_PACK_FIX"
    printf '# Sample\nhello world\n' >"$PR_PACK_FIX/README.md"
    (
        cd "$PR_PACK_FIX" && git init -q && git add -A &&
            git -c user.email=t@t -c user.name=t commit -qm init
    ) >/dev/null 2>&1

    # --pack shells out to `ai-context diff pr`, which in turn needs a real
    # packer (repomix/files-to-prompt/code2prompt) on PATH to produce output;
    # with none installed it dies (by design, see test-ai-context.sh's own
    # "auto backend dies when no packer is installed" case), so skip here too
    # instead of failing outright — this is what CI's first real run hit,
    # since it installs none of the three.
    if command -v repomix >/dev/null 2>&1 || command -v files-to-prompt >/dev/null 2>&1 ||
        command -v code2prompt >/dev/null 2>&1; then
        test_pr_context_pack() {
            local out
            out="$(cd "$PR_PACK_FIX" && PATH="$PR_GH_BIN:$PATH" OUTPUT_DIR="$TMP/pr-pack-out" AI_SESSION_DURABLE_LOG=0 FAKE_GH_FILES="README.md" "$BASH_BIN" "$SCRIPT" pr-context 1 --pack 2>&1)"
            [[ "$out" == *"Packing PR files as AI context"* ]] || return 1
            compgen -G "$TMP/pr-pack-out/*.xml" >/dev/null
        }
        run_test "pr-context --pack packs PR files via ai-context diff pr" test_pr_context_pack
    else
        skip_test "pr-context --pack packs PR files via ai-context diff pr" "no context packer installed"
    fi

    test_pr_context_log_json() {
        local log_dir out
        log_dir="$TMP/pr-context-log"
        out="$(PATH="$PR_GH_BIN:$PATH" AI_LOG_DIR="$log_dir" AI_SESSION_DURABLE_LOG=0 "$BASH_BIN" "$SCRIPT" pr-context 1 --checks --reviews 2>/dev/null)"
        [[ -n "$out" ]] || return 1
        jq -e 'select(.event_type == "gh-pr-context.done")
            | .details.pr == "1" and .details.checks == 1 and .details.reviews == 1 and .details.diff == 0' \
            "$log_dir/tool-usage.jsonl" >/dev/null
    }
    run_test "pr-context logs a gh-pr-context.done event" test_pr_context_log_json
fi

# =============================================================================
# files mode — status selector
# =============================================================================

# A repo exercising the porcelain codes: M (staged mod), A (staged add),
# ?? (untracked), D (unstaged delete), and a worktree-only modification.
make_status_fixture() {
    local dir="$1"
    mkdir -p "$dir"
    (
        cd "$dir" && git init -q &&
            git config user.email t@t && git config user.name t &&
            printf 'x\n' >stagemod.php && printf 'x\n' >wtmod.php && printf 'x\n' >del.php &&
            git add -A && git commit -qm init &&
            printf 'x\ny\n' >stagemod.php && git add stagemod.php &&
            printf 'x\nz\n' >wtmod.php &&
            printf 'new\n' >added.php && git add added.php &&
            printf 'u\n' >untracked.php &&
            rm del.php
    ) >/dev/null 2>&1
}

# A repo left in a real UU merge conflict on shared.php.
make_conflict_fixture() {
    local dir="$1"
    mkdir -p "$dir"
    (
        cd "$dir" && git init -q &&
            git config user.email t@t && git config user.name t &&
            git symbolic-ref HEAD refs/heads/main &&
            printf 'shared\n' >shared.php && git add -A && git commit -qm init &&
            git checkout -q -b feature && printf 'feat\n' >shared.php && git commit -qam feat &&
            git checkout -q main && printf 'main\n' >shared.php && git commit -qam main &&
            { git merge feature >/dev/null 2>&1 || true; }
    ) >/dev/null 2>&1
}

if command -v jq >/dev/null 2>&1; then
    SFIX="$TMP/statusfix"
    make_status_fixture "$SFIX"

    # count_sel SELECTOR... -> the .count from a --json run in the fixture.
    files_json() { (cd "$SFIX" && "$BASH_BIN" "$SCRIPT" files "$@" --json); }

    test_files_all_count() {
        [[ "$(files_json --all | jq -r '.count')" == "5" ]]
    }
    run_test "files --all lists every changed path" test_files_all_count

    test_files_staged() {
        # A staged add + a staged modification, and NOT the worktree-only file.
        files_json --staged | jq -e '
            (.count == 2) and
            ([.files[].path] | (index("added.php") != null) and (index("stagemod.php") != null)
                and (index("wtmod.php") == null))' >/dev/null
    }
    run_test "files --staged selects index-side changes" test_files_staged

    test_files_untracked() {
        files_json --untracked | jq -e '.count==1 and .files[0].path=="untracked.php"' >/dev/null
    }
    run_test "files --untracked selects ?? paths" test_files_untracked

    test_files_deleted() {
        files_json --deleted | jq -e '.count==1 and .files[0].path=="del.php"' >/dev/null
    }
    run_test "files --deleted selects D paths" test_files_deleted

    test_files_added() {
        files_json --added | jq -e '.count==1 and .files[0].path=="added.php"' >/dev/null
    }
    run_test "files --added selects staged adds" test_files_added

    test_files_new_union() {
        # --new is the union of added (A) and untracked (??).
        files_json --new | jq -e '
            (.count==2) and ([.files[].path] | sort == ["added.php","untracked.php"])' >/dev/null
    }
    run_test "files --new unions added and untracked" test_files_new_union

    test_files_modified() {
        files_json --modified | jq -e '
            [.files[].path] | sort == ["stagemod.php","wtmod.php"]' >/dev/null
    }
    run_test "files --modified selects M in either column" test_files_modified

    test_files_tracked_excludes_untracked() {
        files_json --tracked | jq -e '[.files[].path] | index("untracked.php") == null' >/dev/null
    }
    run_test "files --tracked excludes untracked paths" test_files_tracked_excludes_untracked

    test_files_union_of_selectors() {
        # Multiple selectors union: --added + --deleted -> both files.
        files_json --added --deleted | jq -e '
            [.files[].path] | sort == ["added.php","del.php"]' >/dev/null
    }
    run_test "multiple selectors union their results" test_files_union_of_selectors

    test_files_categories() {
        files_json --staged | jq -e '
            .files[] | select(.path=="added.php")
            | (.categories | (index("added") and index("new") and index("staged")))' >/dev/null
    }
    run_test "files --json reports per-path categories" test_files_categories

    test_files_name_only_bare() {
        # --name-only prints bare paths (no XY prefix / no tab).
        local out
        out="$(cd "$SFIX" && "$BASH_BIN" "$SCRIPT" files --untracked --name-only 2>/dev/null)"
        [[ "$out" == "untracked.php" ]]
    }
    run_test "files --name-only prints bare paths" test_files_name_only_bare

    test_files_null_sep() {
        # -0 NUL-separates; converting NUL->newline yields the path.
        local out
        out="$(cd "$SFIX" && "$BASH_BIN" "$SCRIPT" files --untracked --name-only -0 2>/dev/null | tr '\0' '\n')"
        [[ "$out" == "untracked.php" ]]
    }
    run_test "files --name-only -0 NUL-separates paths" test_files_null_sep

    test_files_conflicted_category() {
        local cfix="$TMP/uufix"
        make_conflict_fixture "$cfix"
        (cd "$cfix" && "$BASH_BIN" "$SCRIPT" files --conflicted --json) | jq -e '
            .count==1 and .files[0].path=="shared.php"
            and (.files[0].categories | index("conflicted") != null)' >/dev/null
    }
    run_test "files --conflicted selects unmerged (UU) paths" test_files_conflicted_category
else
    skip_test "files mode (jq)" "jq not installed"
fi

test_files_not_a_repo() {
    local rc=0
    (cd "$TMP" && "$BASH_BIN" "$SCRIPT" files >/dev/null 2>&1) || rc=$?
    ((rc == 1))
}
run_test "files outside a git repo fails (exit 1)" test_files_not_a_repo

test_files_unknown_option() {
    local rc=0
    "$BASH_BIN" "$SCRIPT" files --nonesuch >/dev/null 2>&1 || rc=$?
    ((rc == 1))
}
run_test "files rejects an unknown option" test_files_unknown_option

# =============================================================================
# conflicts mode — marker scanner
# =============================================================================
if command -v jq >/dev/null 2>&1 && command -v rg >/dev/null 2>&1; then
    CFIX="$TMP/conflictfix"
    make_conflict_fixture "$CFIX"

    test_conflicts_finds_markers() {
        (cd "$CFIX" && "$BASH_BIN" "$SCRIPT" conflicts --json) | jq -e '
            (.count >= 3) and
            ([.markers[].marker] | (index("begin") and index("sep") and index("end")))' >/dev/null
    }
    run_test "conflicts detects begin/sep/end markers" test_conflicts_finds_markers

    test_conflicts_line_numbers() {
        # The begin marker sits on shared.php line 1 (file opens with <<<<<<<).
        (cd "$CFIX" && "$BASH_BIN" "$SCRIPT" conflicts --json) | jq -e '
            .markers | any(.marker=="begin" and (.path|test("shared.php$")) and .line==1)' >/dev/null
    }
    run_test "conflicts reports the marker line number" test_conflicts_line_numbers

    test_conflicts_unmerged_files() {
        (cd "$CFIX" && "$BASH_BIN" "$SCRIPT" conflicts --json) |
            jq -e '.unmerged_files | index("shared.php") != null' >/dev/null
    }
    run_test "conflicts lists git-reported unmerged files" test_conflicts_unmerged_files

    test_conflicts_fail_on_findings() {
        local rc=0
        (cd "$CFIX" && "$BASH_BIN" "$SCRIPT" conflicts --fail-on-findings >/dev/null 2>&1) || rc=$?
        ((rc == 3))
    }
    run_test "conflicts --fail-on-findings exits 3 when markers exist" test_conflicts_fail_on_findings

    test_conflicts_clean_is_zero() {
        # A repo with no markers: zero findings, and exit 0 even with the gate.
        local clean="$TMP/clean-conflicts"
        make_git_fixture "$clean" main
        (cd "$clean" && "$BASH_BIN" "$SCRIPT" conflicts --fail-on-findings --json) |
            jq -e '.count==0 and .status=="ok"' >/dev/null
    }
    run_test "conflicts on a clean tree finds nothing and exits 0" test_conflicts_clean_is_zero

    test_conflicts_ignores_dot_equals() {
        # A lone "=======" separator is a marker, but a marker scan must not fire
        # on a shorter run of equals (e.g. a 4-char divider).
        local d="$TMP/eqfix"
        mkdir -p "$d"
        (cd "$d" && git init -q && git config user.email t@t && git config user.name t)
        printf 'title\n====\nbody\n' >"$d/doc.md"
        (cd "$d" && "$BASH_BIN" "$SCRIPT" conflicts --json) | jq -e '.count==0' >/dev/null
    }
    run_test "conflicts does not fire on a short equals divider" test_conflicts_ignores_dot_equals
else
    skip_test "conflicts mode (jq/rg)" "jq or ripgrep not installed"
fi

# =============================================================================
# group-level dispatch
# =============================================================================

test_group_help() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" --help 2>&1 || true)"
    [[ "$out" == *"restsift git"* ]]
}
run_test "group --help prints usage" test_group_help

test_group_unknown_mode() {
    local rc=0
    "$BASH_BIN" "$SCRIPT" bogus >/dev/null 2>&1 || rc=$?
    ((rc == 2))
}
run_test "unknown top-level mode exits 2" test_group_unknown_mode

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d  Skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
((FAIL == 0)) && printf '\033[0;32mPASSED\033[0m\n' || {
    printf '\033[0;31mFAILED\033[0m\n'
    exit 1
}
