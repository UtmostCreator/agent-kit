#!/usr/bin/env bash
# 75-backend-git.sh — git-aware bespoke backends (diff, history).
#
# Purpose: run_diff_mode (unified-diff added-line search with marker/new_line/
#   scope) and run_history_mode (log -S/-G pickaxe over revision metadata, with
#   optional --patch). These build their own results[] shapes and emit + exit
#   directly, because their output does not fit the path:line:text pipeline.
#   Both are read-only history queries (log/show/diff), never history mutations.
# Allowed dependencies: git, awk, grep, jq; require_git_root (60-guards.sh),
#   emit_json()/fail() (40-output-json.sh). Reads diff/history flags + query.
#
# SC2034/SC2154: pattern/case/query/root/diff/history globals and g_summary_json
# are run-state owned across modules (see ai-search.sh load order).
# shellcheck disable=SC2034,SC2154

# query_matches_line LINE — return 0 when the parsed query matches the given
# text under the active pattern/case mode. Used by diff/history line filters.
query_matches_line() {
    local line="$1" grep_args=()
    case "$pattern_mode" in
        fixed) grep_args+=(-F) ;;
        pcre2) grep_args+=(-P) ;;
        *) grep_args+=(-E) ;;
    esac
    case "$case_mode" in
        ignore) grep_args+=(-i) ;;
        sensitive) : ;;
        smart | *) [[ "$query" =~ [[:upper:]] ]] || grep_args+=(-i) ;;
    esac
    printf '%s' "$line" | grep -q "${grep_args[@]}" -- "$query"
}

# query_grep_flags — print (one per line) the grep flags implied by the active
# pattern/case mode. Lets a single grep pass replace a per-line
# query_matches_line call when filtering a large batch of lines (diff mode),
# preserving byte-identical fixed/pcre2/regex + smart-case semantics.
query_grep_flags() {
    case "$pattern_mode" in
        fixed) printf '%s\n' -F ;;
        pcre2) printf '%s\n' -P ;;
        *) printf '%s\n' -E ;;
    esac
    case "$case_mode" in
        ignore) printf '%s\n' -i ;;
        sensitive) : ;;
        smart | *) [[ "$query" =~ [[:upper:]] ]] || printf '%s\n' -i ;;
    esac
}

run_diff_mode() {
    require_git_root
    local repo_root diff_out git_args=() diff_rc=0
    repo_root="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" ||
        fail "error" "not a git repository: $root"

    if [[ -n "$diff_base" ]]; then
        git_args=(diff "$diff_base")
    elif [[ "$diff_staged" -eq 1 ]]; then
        git_args=(diff --cached)
    else
        git_args=(diff)
    fi

    # git diff (no --exit-code) returns 0 regardless of differences; a non-zero
    # status means a real error (e.g. an invalid --base ref), which must surface
    # instead of being swallowed into an empty, success-looking result set.
    diff_out="$(cd "$repo_root" && git "${git_args[@]}" -U0 2>/dev/null)" || diff_rc=$?
    if [[ "$diff_rc" -ne 0 ]]; then
        if [[ -n "$diff_base" ]]; then
            fail "error" "invalid --base ref: $diff_base"
        fi
        fail "error" "git diff failed in $repo_root"
    fi

    # Walk the unified diff: track current file from +++ headers and the new
    # line number from @@ hunk headers; collect added lines matching the query.
    local results
    results="$(
        printf '%s\n' "$diff_out" | awk '
            /^\+\+\+ / {
                p = $2; sub(/^b\//, "", p); cur = p; next
            }
            /^@@ / {
                # @@ -a,b +c,d @@  -> new-file start = c
                match($0, /\+[0-9]+/); ns = substr($0, RSTART+1, RLENGTH-1);
                new_line = ns + 0; next
            }
            /^\+/ && !/^\+\+\+/ {
                text = substr($0, 2);
                printf "%s\t%d\t%s\n", cur, new_line, text;
                new_line++; next
            }
            /^ / { new_line++; next }
        '
    )"

    # Filter added lines by the query in ONE grep pass rather than spawning a
    # grep subprocess per added line (was O(added-lines) processes, so
    # `diff --base` timed out on a branch far ahead of main). Each added line is
    # a single line with no embedded newline, so stripping the leading
    # path<TAB>new_line<TAB> fields reproduces the original text exactly; grep -n
    # then reports the 1-based record indices that match, in order.
    local scope="unstaged"
    [[ "$diff_staged" -eq 1 ]] && scope="staged"
    [[ -n "$diff_base" ]] && scope="base:$diff_base"

    local path line text
    local _grep_flags=() _records=() _match_nums _n _payload=""
    mapfile -t _grep_flags < <(query_grep_flags)
    mapfile -t _records <<<"$results"
    if ((${#_records[@]})) && [[ -n "${_records[0]}" ]]; then
        _match_nums="$(printf '%s\n' "${_records[@]}" |
            sed $'s/^[^\t]*\t[^\t]*\t//' |
            grep -n "${_grep_flags[@]}" -- "$query" | cut -d: -f1 || true)"
        # Collect each match's fields (path, new_line, text — one per line; none
        # of them can contain a newline) into a single stream, then build every
        # result object in ONE jq pass below. The old code spawned one `jq -cn`
        # per match, so a base far ahead of HEAD (tens of thousands of added
        # lines) launched thousands of jq processes and timed out.
        while IFS= read -r _n; do
            [[ -n "$_n" ]] || continue
            IFS=$'\t' read -r path line text <<<"${_records[_n - 1]}"
            [[ -n "$path" ]] || continue
            _payload+="$path"$'\n'"$line"$'\n'"$text"$'\n'
        done <<<"$_match_nums"
    fi

    # Rebuild the {path, marker, new_line, text, scope} objects (same shape and
    # key order the per-match `jq -cn` + `map(.scope=…)` produced) from the
    # newline-delimited field stream in a single jq invocation. Empty payload
    # yields an empty array, matching the previous no-match result.
    g_results_json="$(printf '%s' "$_payload" | jq -Rs --arg scope "$scope" '
        split("\n")
        | (if (length > 0 and .[-1] == "") then .[:-1] else . end)
        | [ range(0; length; 3) as $i
            | { path: .[$i], marker: "+", new_line: (.[$i + 1] | tonumber),
                text: .[$i + 2], scope: $scope } ]
    ')"

    local matches_json status
    matches_json="$(printf '%s' "$g_results_json" |
        jq '[.[] | (.path + ":" + (.new_line|tostring) + ":" + .text)]')"
    status="ok"
    [[ "$(printf '%s' "$matches_json" | jq 'length')" -eq 0 ]] && status="no_matches"

    if [[ "$json_mode" == "json" ]]; then
        g_summary_json="$(printf '%s' "$g_results_json" |
            jq -c '{scope: (.[0].scope // null)}')"
        emit_json "$status" "$matches_json"
    else
        printf '%s' "$g_results_json" | jq -r '.[] | "\(.path):\(.new_line):\(.text)"'
    fi
    exit 0
}

run_history_mode() {
    require_git_root
    local repo_root log_args=() raw
    repo_root="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" ||
        fail "error" "not a git repository: $root"

    # Field-separated commit metadata; %x1f unit separator, %x1e record sep.
    local fmt='%H%x1f%an%x1f%aI%x1f%s'

    if [[ "$history_messages" -eq 1 ]]; then
        log_args=(log "--grep=$query" "--format=$fmt")
        [[ "$pattern_mode" == "fixed" ]] && log_args+=(--fixed-strings)
        [[ "$case_mode" == "ignore" ]] && log_args+=(-i)
    elif [[ "$pattern_mode" == "regex" || "$pattern_mode" == "pcre2" ]]; then
        log_args=(log "-G$query" "--format=$fmt" --name-only)
    else
        # Default/fixed: -S pickaxe is literal by default.
        log_args=(log "-S$query" "--format=$fmt" --name-only)
    fi

    raw="$(cd "$repo_root" && git "${log_args[@]}" 2>/dev/null || true)"

    # Parse: a metadata line (contains \x1f) starts a commit; subsequent plain
    # lines are file paths (present when --name-only is used).
    local commits_json
    commits_json="$(
        printf '%s\n' "$raw" | jq -R -s --arg us $'\x1f' '
            split("\n")
            | reduce .[] as $line ({commits: [], cur: null};
                if ($line | contains($us)) then
                    (if .cur != null then .commits += [.cur] else . end)
                    | ($line | split($us)) as $f
                    | .cur = {
                        commit: $f[0], author: $f[1], date: $f[2],
                        message: $f[3], files: []
                      }
                elif ($line | length) > 0 and (.cur != null) then
                    .cur.files += [$line]
                else . end
              )
            | (if .cur != null then .commits += [.cur] else . end)
            | .commits
        '
    )"

    # Expand to one result per (commit, file). When no files (message search),
    # keep a single row with the commit-level path null.
    local results_json
    results_json="$(printf '%s' "$commits_json" | jq -c '
        map(
            . as $c
            | if (($c.files // []) | length) > 0 then
                ($c.files[] | { commit: $c.commit, author: $c.author,
                  date: $c.date, message: $c.message, path: . })
              else
                { commit: $c.commit, author: $c.author, date: $c.date,
                  message: $c.message, path: null }
              end
        )
    ')"

    if [[ "$history_patch" -eq 1 ]]; then
        # Attach the commit patch text on request only.
        local enriched=() row commit_hash patch _patch_tmp
        _patch_tmp="$(mktemp)"
        while IFS= read -r row; do
            [[ -n "$row" ]] || continue
            commit_hash="$(printf '%s' "$row" | jq -r '.commit')"
            patch="$(cd "$repo_root" && git show --format= --patch "$commit_hash" 2>/dev/null || true)"
            # Pass the patch via --rawfile, not --arg: a large patch exceeds
            # ARG_MAX as a command-line argument (jq: "Argument list too long",
            # exit 126). A file has no such limit.
            printf '%s' "$patch" >"$_patch_tmp"
            enriched+=("$(printf '%s' "$row" | jq -c --rawfile p "$_patch_tmp" '.patch = $p')")
        done < <(printf '%s' "$results_json" | jq -c '.[]')
        rm -f "$_patch_tmp"
        results_json="$(printf '%s\n' "${enriched[@]:-}" | jq -s 'map(select(. != null))')"
    fi

    g_results_json="$results_json"
    local matches_json status
    matches_json="$(printf '%s' "$g_results_json" |
        jq '[.[] | (.commit + " " + (.message // ""))]')"
    status="ok"
    [[ "$(printf '%s' "$g_results_json" | jq 'length')" -eq 0 ]] && status="no_matches"

    if [[ "$json_mode" == "json" ]]; then
        emit_json "$status" "$matches_json"
    else
        printf '%s' "$g_results_json" | jq -r '.[] | "\(.commit) \(.message)"'
    fi
    exit 0
}
