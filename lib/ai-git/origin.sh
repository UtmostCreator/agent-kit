# shellcheck shell=bash
# ai-git/origin.sh — branch-parent detection ("branched off").
#
# Sourced by libexec/ai-git (thin loader). Not an entrypoint. Behavior is
# byte-for-byte identical to the previous standalone libexec/git-branch-origin,
# just wrapped in ai_git_origin_main() with module-local helper names so it can
# share a process with the other ai-git modules.
#
# Git does not record the parent branch, so this infers it: for every candidate
# branch (local + remote-tracking), compute the merge-base with HEAD and pick
# the candidate whose merge-base is CLOSEST to HEAD (fewest commits on
# base..HEAD). That candidate is almost always the branch you checked out from.

# Patterns that mark a branch as a likely long-lived base (release/integration).
# Override with GIT_BASE_PATTERNS (newline- or space-separated glob list).
AI_GIT_ORIGIN_DEFAULT_BASE_PATTERNS='main master develop dev release/* releases/* phase* stage* staging* stat-* nuxt-* v[0-9]* *-[0-9]*.[0-9]*'

ai_git_origin_usage() {
    cat <<'EOF'
Usage:
  restsift git origin [--json] [--field name|base|count|all]

Detects the branch the current branch was most likely created from.

Options:
  --field name    print only the parent branch name (default)
  --field base    print only the merge-base commit sha
  --field count   print only the commit distance (base..HEAD)
  --field all     print "name<TAB>base<TAB>count"
  --json          emit a JSON envelope with all fields and candidates
  --help, -h      show this help

Environment:
  GIT_ORIGIN_REF       force a specific base ref, skip detection
  GIT_BASE_PATTERNS    override preferred base-branch glob patterns
  GIT_ORIGIN_INCLUDE_REMOTE   set to 0 to skip remote-tracking branches

Exit codes:
  0    success
  1    usage/validation error (invalid --field, not a git repo, no origin found)
EOF
}

# True if a branch short-name matches any preferred base pattern.
ai_git_origin_matches_base_pattern() {
    local name="$1" pat
    local -a base_patterns
    read -r -a base_patterns <<<"${GIT_BASE_PATTERNS:-$AI_GIT_ORIGIN_DEFAULT_BASE_PATTERNS}"
    for pat in "${base_patterns[@]}"; do
        # shellcheck disable=SC2053
        [[ "$name" == $pat ]] && return 0
    done
    return 1
}

# True if a branch shares a meaningful prefix token with the current branch
# (e.g. current "phase3.81.0-fix" vs candidate "phase3.81.0").
ai_git_origin_shares_prefix() {
    local name="$1" current_branch="$2"
    local cur="${current_branch##*/}"
    local cand="${name##*/}"
    [[ -n "$cur" && "$cur" != "HEAD" ]] || return 1
    local cur_tok="${cur%%[-_./]*}"
    local cand_tok="${cand%%[-_./]*}"
    [[ -n "$cur_tok" && "$cur_tok" == "$cand_tok" ]]
}

# Collect candidate branch ref-names (short), local + remote-tracking.
ai_git_origin_collect_candidates() {
    git for-each-ref --format='%(refname:short)' refs/heads/
    if [[ "${GIT_ORIGIN_INCLUDE_REMOTE:-1}" == "1" ]]; then
        git for-each-ref --format='%(refname:short)' refs/remotes/
    fi
}

ai_git_origin_main() {
    require_bins git

    local field="name"
    local output_json=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help | -h)
                ai_git_origin_usage
                exit 0
                ;;
            --json)
                output_json=1
                shift
                ;;
            --field)
                [[ $# -ge 2 ]] || die "--field requires a value (name|base|count|all)"
                field="$2"
                shift 2
                ;;
            --field=*)
                field="${1#*=}"
                shift
                ;;
            *) die "unknown option: $1" ;;
        esac
    done

    case "$field" in
        name | base | count | all) ;;
        *) die "invalid --field: $field (expected name|base|count|all)" ;;
    esac

    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repository"

    local current_branch head_sha
    current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'HEAD')"
    head_sha="$(git rev-parse HEAD 2>/dev/null || true)"
    [[ -n "$head_sha" ]] || die "cannot resolve HEAD"

    # Each scored line: "<priority> <count> <name> <base_sha>"
    # priority: 0 = pattern match, 1 = prefix share, 2 = other. Lower is better.
    # Lower count (distance) is better within the same priority.
    local -a scored=()
    local ref base count priority

    while IFS= read -r ref; do
        [[ -n "$ref" ]] || continue
        case "$ref" in
            "$current_branch" | origin | */HEAD | HEAD) continue ;;
        esac
        git rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1 || continue

        base="$(git merge-base HEAD "$ref" 2>/dev/null || true)"
        [[ -n "$base" ]] || continue
        [[ "$base" == "$head_sha" ]] && continue

        count="$(git rev-list --count "$base..HEAD" 2>/dev/null || printf '999999')"

        priority=2
        if ai_git_origin_matches_base_pattern "$ref"; then
            priority=0
        elif ai_git_origin_shares_prefix "$ref" "$current_branch"; then
            priority=1
        fi

        scored+=("$priority $count $ref $base")
    done < <(ai_git_origin_collect_candidates | sort -u)

    local best_name best_base best_count fallback c best_line _prio

    if [[ ${#scored[@]} -eq 0 ]]; then
        if [[ -n "${GIT_ORIGIN_REF:-}" ]]; then
            fallback="$GIT_ORIGIN_REF"
        else
            fallback=""
            for c in origin/main origin/master main master; do
                if git rev-parse --verify --quiet "$c^{commit}" >/dev/null 2>&1; then
                    fallback="$c"
                    break
                fi
            done
        fi
        [[ -n "$fallback" ]] || die "could not determine a branch origin"
        best_name="$fallback"
        best_base="$(git merge-base HEAD "$fallback" 2>/dev/null || git rev-parse "$fallback")"
        best_count="$(git rev-list --count "$best_base..HEAD" 2>/dev/null || printf '0')"
    else
        if [[ -n "${GIT_ORIGIN_REF:-}" ]]; then
            best_name="$GIT_ORIGIN_REF"
            best_base="$(git merge-base HEAD "$GIT_ORIGIN_REF" 2>/dev/null || git rev-parse "$GIT_ORIGIN_REF")"
            best_count="$(git rev-list --count "$best_base..HEAD" 2>/dev/null || printf '0')"
        else
            best_line="$(printf '%s\n' "${scored[@]}" | sort -t' ' -k1,1n -k2,2n | head -n1)"
            read -r _prio best_count best_name best_base <<<"$best_line"
        fi
    fi

    if [[ "$output_json" == "1" ]]; then
        local candidates_json='[]'
        if [[ ${#scored[@]} -gt 0 ]]; then
            candidates_json="$(printf '%s\n' "${scored[@]}" |
                sort -t' ' -k1,1n -k2,2n |
                jq -R -s 'split("\n") | map(select(length>0)) | map(
                    (. / " ") as $p | {priority: ($p[0]|tonumber), distance: ($p[1]|tonumber), name: $p[2], merge_base: $p[3]}
                )')"
        fi
        jq -cn \
            --arg schema "1" \
            --arg status "ok" \
            --arg tool "git-branch-origin" \
            --arg current "$current_branch" \
            --arg name "$best_name" \
            --arg base "$best_base" \
            --argjson count "${best_count:-0}" \
            --argjson candidates "$candidates_json" \
            '{schema: ($schema|tonumber), status: $status, tool: $tool,
              current_branch: $current, origin_branch: $name, merge_base: $base,
              distance: $count, candidates: $candidates, warnings: [], errors: []}'
    else
        case "$field" in
            name) printf '%s\n' "$best_name" ;;
            base) printf '%s\n' "$best_base" ;;
            count) printf '%s\n' "$best_count" ;;
            all) printf '%s\t%s\t%s\n' "$best_name" "$best_base" "$best_count" ;;
        esac
    fi
}
