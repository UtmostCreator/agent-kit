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
    local name="$1"; shift; local _rc=0
    "$@" >/dev/null 2>&1 || _rc=$?
    if ((_rc == 0)); then PASS=$((PASS+1)); printf '  \033[0;32m✓\033[0m %s\n' "$name"
    else FAIL=$((FAIL+1)); printf '  \033[0;31m✗\033[0m %s\n' "$name"; fi
}
skip_test() { SKIP=$((SKIP+1)); printf '  \033[0;33m⊘\033[0m %s (skipped: %s)\n' "$1" "$2"; }

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
    [[ "$out" == *"agent-kit git origin"* && "$out" == *"--field"* ]]
}
run_test "origin --help prints usage" test_origin_help

test_origin_default_name() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" origin 2>/dev/null || true)"
    [[ -n "$out" ]]
}
run_test "origin prints a non-empty origin branch name" test_origin_default_name

test_origin_field_base() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" origin --field base 2>/dev/null || true)"
    [[ "$out" =~ ^[0-9a-f]{7,40}$ ]]
}
run_test "origin --field base prints a merge-base sha" test_origin_field_base

test_origin_field_count() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" origin --field count 2>/dev/null || true)"
    [[ "$out" =~ ^[0-9]+$ ]]
}
run_test "origin --field count prints an integer distance" test_origin_field_count

test_origin_field_all() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" origin --field all 2>/dev/null || true)"
    [[ "$(awk -F'\t' '{print NF}' <<<"$out")" == "3" ]]
}
run_test "origin --field all prints name<TAB>base<TAB>count" test_origin_field_all

if command -v jq >/dev/null 2>&1; then
    test_origin_json() {
        local out
        out="$("$BASH_BIN" "$SCRIPT" origin --json 2>/dev/null || true)"
        jq -e '.tool == "git-branch-origin" and (.origin_branch|type=="string") and (.merge_base|type=="string") and (.distance|type=="number")' <<<"$out" >/dev/null
    }
    run_test "origin --json emits a valid envelope" test_origin_json
else
    skip_test "origin --json emits a valid envelope" "jq not installed"
fi

test_origin_override() {
    local out
    out="$(GIT_ORIGIN_REF=origin/main "$BASH_BIN" "$SCRIPT" origin --field name 2>/dev/null || true)"
    [[ -n "$out" ]]
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
    out="$("$BASH_BIN" "$SCRIPT" origin --field=count 2>/dev/null || true)"
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

    test_pr_context_pack() {
        local out
        out="$(cd "$PR_PACK_FIX" && PATH="$PR_GH_BIN:$PATH" OUTPUT_DIR="$TMP/pr-pack-out" AI_SESSION_DURABLE_LOG=0 FAKE_GH_FILES="README.md" "$BASH_BIN" "$SCRIPT" pr-context 1 --pack 2>&1)"
        [[ "$out" == *"Packing PR files as AI context"* ]] || return 1
        compgen -G "$TMP/pr-pack-out/*.xml" >/dev/null
    }
    run_test "pr-context --pack packs PR files via ai-context diff pr" test_pr_context_pack

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
# group-level dispatch
# =============================================================================

test_group_help() {
    local out
    out="$("$BASH_BIN" "$SCRIPT" --help 2>&1 || true)"
    [[ "$out" == *"agent-kit git"* ]]
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
((FAIL == 0)) && printf '\033[0;32mPASSED\033[0m\n' || { printf '\033[0;31mFAILED\033[0m\n'; exit 1; }
