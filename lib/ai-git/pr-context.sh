# shellcheck shell=bash
# ai-git/pr-context.sh — full PR context (metadata, diff, checks, reviews, pack).
#
# Sourced by libexec/ai-git (thin loader). Not an entrypoint. Behavior is
# byte-for-byte identical to the previous standalone libexec/gh-pr-context,
# just wrapped in ai_git_pr_context_main(). Requires AI_GIT_LIBEXEC_DIR (set by
# the loader) to resolve the sibling ai-diff-context engine for --pack, since
# BASH_SOURCE inside a sourced function points at this module file, not the
# libexec/ entrypoint.

ai_git_pr_context_usage() {
    echo "Usage: agent-kit git pr-context <PR-number> [--diff] [--checks] [--reviews] [--pack] [--json]"
}

ai_git_pr_context_main() {
    require_bins gh jq

    local pr="${1:?PR number required}"
    shift || true

    local want_diff=0
    local want_checks=0
    local want_reviews=0
    local want_pack=0
    local output_format="${OUTPUT_FORMAT:-plain}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --diff) want_diff=1 ;;
        --checks) want_checks=1 ;;
        --reviews) want_reviews=1 ;;
        --pack) want_pack=1 ;;
        --json) output_format="json" ;;
        --help | -h)
            ai_git_pr_context_usage
            exit 0
            ;;
        *) die "unknown option: $1" ;;
        esac
        shift
    done

    agent_session_init "gh-pr-context"

    section "PR #$pr metadata"

    local pr_json
    pr_json="$(gh pr view "$pr" \
        --json title,body,author,state,baseRefName,headRefName,files,commits,labels,assignees,reviewRequests,isDraft,url,mergedAt,closedAt,createdAt,updatedAt)"

    local checks_json="null"
    if [[ "$want_checks" == "1" ]]; then
        section "CI checks"
        checks_json="$(gh pr checks "$pr" --json name,state,conclusion,startedAt,completedAt,link 2>/dev/null || echo '[]')"
    fi

    local reviews_json="null"
    if [[ "$want_reviews" == "1" ]]; then
        section "Reviews"
        reviews_json="$(gh pr view "$pr" --json reviews --jq '.reviews | map({author:.author.login, state:.state, body:.body, submittedAt:.submittedAt})')"
    fi

    local diff_content=""
    if [[ "$want_diff" == "1" ]]; then
        section "Diff"
        diff_content="$(gh pr diff "$pr" 2>/dev/null || echo '(diff unavailable)')"
    fi

    if [[ "$output_format" == "json" ]]; then
        jq -n \
            --argjson pr "$pr_json" \
            --argjson checks "${checks_json:-null}" \
            --argjson reviews "${reviews_json:-null}" \
            --arg diff "$diff_content" \
            '{
          pr: {
            title: $pr.title,
            state: $pr.state,
            isDraft: $pr.isDraft,
            url: $pr.url,
            author: $pr.author.login,
            base: $pr.baseRefName,
            head: $pr.headRefName,
            labels: [$pr.labels[].name],
            assignees: [$pr.assignees[].login],
            commitCount: ($pr.commits | length),
            fileCount: ($pr.files | length),
            files: [$pr.files[].path],
            createdAt: $pr.createdAt,
            updatedAt: $pr.updatedAt
          },
          checks: $checks,
          reviews: $reviews,
          diff: (if $diff != "" then $diff else null end)
        }'
    else
        printf '# PR #%s - %s\n\n' "$pr" "$(echo "$pr_json" | jq -r '.title')"
        echo "$pr_json" | jq -r '"**State:** \(.state)  |  **Author:** \(.author.login)  |  **Draft:** \(.isDraft)"'
        echo "$pr_json" | jq -r '"**Base:** \(.baseRefName)  <-  **Head:** \(.headRefName)"'
        echo "$pr_json" | jq -r '"**Files changed:** \(.files | length)  |  **Commits:** \(.commits | length)"'
        echo
        echo "## Files changed"
        echo "$pr_json" | jq -r '.files[].path | "- " + .'
        echo
        echo "## Description"
        echo "$pr_json" | jq -r '.body // "(no description)"'

        if [[ "$want_checks" == "1" ]] && [[ "$checks_json" != "null" ]]; then
            echo
            echo "## CI Checks"
            printf '%-50s  %-12s  %s\n' "NAME" "STATE" "CONCLUSION"
            echo "$checks_json" | jq -r '.[] | [.name, .state, (.conclusion // "-")] | @tsv' |
                while IFS=$'\t' read -r name state conclusion; do
                    printf '%-50s  %-12s  %s\n' "$name" "$state" "$conclusion"
                done
        fi

        if [[ "$want_reviews" == "1" ]] && [[ "$reviews_json" != "null" ]]; then
            echo
            echo "## Reviews"
            echo "$reviews_json" | jq -r '.[] | "- **\(.author)** [\(.state)]: \(.body // "(no comment)")"'
        fi

        if [[ "$want_diff" == "1" ]] && [[ -n "$diff_content" ]]; then
            echo
            echo "## Diff"
            echo '```diff'
            printf '%s\n' "$diff_content"
            echo '```'
        fi
    fi

    if [[ "$want_pack" == "1" ]]; then
        section "Packing PR files as AI context"
        # ai-diff-context was fused into ai-context (mode "diff") during the
        # thin-loader migration (see libexec/ai-context); libexec/ai-diff-context
        # no longer exists as a standalone entrypoint.
        "${AI_GIT_LIBEXEC_DIR:?AI_GIT_LIBEXEC_DIR must be set by the loader}/ai-context" diff pr "$pr"
    fi

    log_json "gh-pr-context.done" \
        "$(jq -cn --arg pr "$pr" --argjson diff "$want_diff" --argjson checks "$want_checks" --argjson reviews "$want_reviews" '{pr:$pr, diff:$diff, checks:$checks, reviews:$reviews}')"
}
