# shellcheck shell=bash
# ai-git/status.sh — working-tree status selector + conflict-marker scanner.
#
# Sourced by libexec/ai-git (thin loader). Not an entrypoint. Two modes:
#
#   files      Dump paths from `git status --porcelain=v1 -z`, filtered by one
#              or more status selectors (--staged/--unstaged/--untracked/
#              --tracked/--modified/--new/--added/--deleted/--renamed/
#              --conflicted, or --all). Union when several are given.
#   conflicts  Scan the working tree for merge-conflict markers
#              (<<<<<<<, |||||||, =======, >>>>>>>) with ripgrep, and list the
#              files git itself reports as unmerged.
#
# Human output is pipe-friendly (bare data on stdout, summary on stderr, or a
# porcelain-style XY<TAB>path table). --json emits a schema envelope matching
# the other ai-git modes.

# --- porcelain code -> category set ------------------------------------------
# Given the two status columns X (index) and Y (worktree), print a comma list of
# the categories the entry belongs to. Categories mirror the CLI selectors.
_ai_git_categories() {
    local x="$1" y="$2" cats=()
    if [[ "$x$y" == "??" ]]; then
        cats+=(untracked new)
    else
        cats+=(tracked)
        # staged == an index-side change; unstaged == a worktree-side change.
        [[ "$x" != " " ]] && cats+=(staged)
        [[ "$y" != " " ]] && cats+=(unstaged)
        [[ "$x" == "M" || "$y" == "M" ]] && cats+=(modified)
        [[ "$x" == "A" ]] && cats+=(added new)
        [[ "$x" == "D" || "$y" == "D" ]] && cats+=(deleted)
        [[ "$x" == "R" || "$x" == "C" ]] && cats+=(renamed)
        # Unmerged: any U column, or the AA/DD both-sides codes.
        [[ "$x" == "U" || "$y" == "U" || "$x$y" == "AA" || "$x$y" == "DD" ]] && cats+=(conflicted)
    fi
    local IFS=','
    printf '%s' "${cats[*]}"
}

ai_git_files_usage() {
    cat <<'EOF'
Usage:
  restsift git files [SELECTOR...] [PATHSPEC] [--name-only] [--json] [-0]

Dump working-tree paths from `git status`, filtered by status selectors. With
several selectors the result is their union; with none, every reported path is
listed (equivalent to --all).

Selectors:
  --all           every path git status reports (default when none given)
  --tracked       tracked paths with any change (everything except untracked)
  --untracked     untracked paths (?? )
  --staged        an index-side (staged) change
  --unstaged      a worktree-side (unstaged) change
  --modified      modified (M in either column)
  --added         added to the index (A)
  --new           brand-new: added (A) OR untracked
  --deleted       deleted (D in either column)
  --renamed       renamed/copied (R/C)
  --conflicted    unmerged (UU/AU/UD/UA/DU/AA/DD)

Options:
  --name-only     print bare paths only (default prints "XY<TAB>path")
  -0, --null      with --name-only, NUL-separate paths (xargs -0 safe)
  --json          emit a JSON envelope
  --help, -h      show this help

Examples:
  restsift git files --staged --name-only        # what is staged, one path/line
  restsift git files --modified --unstaged        # unstaged modifications
  restsift git files --untracked -0 | xargs -0 ...
  restsift git files --conflicted --json          # unmerged paths, machine-readable

Exit codes:
  0    success            1    usage/validation error (bad selector, not a repo)
EOF
}

ai_git_files_main() {
    require_bins git jq

    local -A want=()
    local name_only=0 output_json=0 nul=0 pathspec=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all | --tracked | --untracked | --staged | --unstaged | --modified | \
                --added | --new | --deleted | --renamed | --conflicted)
                want["${1#--}"]=1
                ;;
            --conflicts) want[conflicted]=1 ;;
            --name-only) name_only=1 ;;
            -0 | --null) nul=1 ;;
            --json) output_json=1 ;;
            --help | -h)
                ai_git_files_usage
                exit 0
                ;;
            --)
                shift
                [[ $# -gt 0 ]] && pathspec="$1"
                break
                ;;
            -*) die "unknown option: $1 (see 'restsift git files --help')" ;;
            *)
                [[ -z "$pathspec" ]] || die "unexpected extra argument: $1"
                pathspec="$1"
                ;;
        esac
        shift
    done

    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repository"

    # --all (or no selector) means "match everything".
    local match_all=0
    [[ -n "${want[all]:-}" || ${#want[@]} -eq 0 ]] && match_all=1

    local -a entries=()
    if [[ -n "$pathspec" ]]; then
        mapfile -d '' entries < <(git status --porcelain=v1 -z -- "$pathspec" 2>/dev/null)
    else
        mapfile -d '' entries < <(git status --porcelain=v1 -z 2>/dev/null)
    fi

    local buf="" count=0
    local i=0 entry x y path orig cats keep sel
    while ((i < ${#entries[@]})); do
        entry="${entries[i]}"
        [[ -z "$entry" ]] && {
            i=$((i + 1))
            continue
        }
        x="${entry:0:1}"
        y="${entry:1:1}"
        path="${entry:3}"
        orig=""
        if [[ "$x" == "R" || "$x" == "C" ]]; then
            orig="${entries[i + 1]:-}"
            i=$((i + 2))
        else
            i=$((i + 1))
        fi
        cats="$(_ai_git_categories "$x" "$y")"

        keep=$match_all
        if ((! keep)); then
            for sel in "${!want[@]}"; do
                [[ ",$cats," == *",$sel,"* ]] && {
                    keep=1
                    break
                }
            done
        fi
        ((keep)) || continue
        count=$((count + 1))
        buf+=$'\x1e'"$x$y"$'\x1f'"$x"$'\x1f'"$y"$'\x1f'"$path"$'\x1f'"$orig"$'\x1f'"$cats"
    done

    if ((output_json)); then
        local files_json='[]'
        [[ -n "$buf" ]] && files_json="$(printf '%s' "$buf" | jq -R -s '
            split("\u001e")
            | map(select(length > 0))
            | map(split("\u001f"))
            | map({ code: .[0], x: .[1], y: .[2], path: .[3],
                    orig: (if .[4] == "" then null else .[4] end),
                    categories: (.[5] | split(",")) })
            | sort_by(.path)
        ' 2>/dev/null || printf '[]')"
        local sel_json
        sel_json="$( ( ((match_all)) && printf 'all' || printf '%s\n' "${!want[@]}" ) |
            jq -R -s 'split("\n") | map(select(length>0))' 2>/dev/null || printf '[]')"
        jq -cn \
            --arg tool "git-files" \
            --arg pathspec "$pathspec" \
            --argjson selectors "$sel_json" \
            --argjson files "$files_json" \
            '{schema: 1, status: "ok", tool: $tool,
              pathspec: (if $pathspec == "" then null else $pathspec end),
              selectors: $selectors, count: ($files|length), files: $files,
              warnings: [], errors: []}' 2>/dev/null ||
            jq -cn --argjson files "$files_json" '{schema:1,status:"ok",tool:"git-files",files:$files,count:($files|length),warnings:[],errors:[]}'
        return 0
    fi

    # Human output. --name-only: bare paths (stdout only, pipe-friendly);
    # otherwise a porcelain-style "XY<TAB>path" table. Summary goes to stderr so
    # stdout stays clean for piping.
    local sep=$'\n'
    ((nul)) && sep=$'\0'
    if [[ -n "$buf" ]]; then
        local rec
        while IFS= read -r -d $'\x1e' rec; do
            [[ -n "$rec" ]] || continue
            IFS=$'\x1f' read -r code _x _y path _orig _cats <<<"$rec"
            if ((name_only)); then
                printf '%s' "$path"
                printf '%s' "$sep"
            else
                printf '%s\t%s\n' "$code" "$path"
            fi
        done <<<"$buf"$'\x1e'
    fi
    printf '%d file(s)\n' "$count" >&2
    return 0
}

# --- conflicts ----------------------------------------------------------------
# Line-anchored, exactly-seven-char conflict markers (git's own width):
#   <<<<<<< ours      ======= (separator)      >>>>>>> theirs      ||||||| base
# The <, >, | markers allow a trailing label; the = separator stands alone.
AI_GIT_CONFLICT_RE='^(<{7}|>{7}|\|{7})([ \t].*)?$|^={7}$'

ai_git_conflicts_usage() {
    cat <<'EOF'
Usage:
  restsift git conflicts [FOLDER] [--json] [--fail-on-findings]

Scan the working tree for merge-conflict markers and list the files git reports
as unmerged. Each finding records the marker kind (begin/base/sep/end), its line
number, and the line text.

Marker regex (7 chars, line-anchored):
  begin  ^<<<<<<<( label)?    base  ^|||||||( label)?
  sep    ^=======             end   ^>>>>>>>( label)?

Options:
  --json                emit a JSON envelope
  --fail-on-findings    exit 3 when any conflict marker is found (CI gate)
  --help, -h            show this help

Exit codes:
  0    success (no findings, or findings without --fail-on-findings)
  1    usage/validation error
  3    conflict markers found AND --fail-on-findings was given
EOF
}

ai_git_conflicts_main() {
    require_bins rg jq

    local output_json=0 fail_on=0 folder="."
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) output_json=1 ;;
            --fail-on-findings) fail_on=1 ;;
            --help | -h)
                ai_git_conflicts_usage
                exit 0
                ;;
            --)
                shift
                [[ $# -gt 0 ]] && folder="$1"
                break
                ;;
            -*) die "unknown option: $1 (see 'restsift git conflicts --help')" ;;
            *)
                folder="$1"
                ;;
        esac
        shift
    done
    [[ -d "$folder" ]] || die "folder not found: $folder"

    # Marker findings, classified by kind. rg --json gives exact path/line/text
    # regardless of odd characters in the path.
    # rg exits 1 on no-match; `|| true` keeps that from tripping pipefail (which
    # would otherwise double the output with a fallback). jq -s always yields a
    # (possibly empty) array, so findings stays valid JSON.
    local findings
    findings="$({ rg --json --color never -e "$AI_GIT_CONFLICT_RE" -- "$folder" 2>/dev/null || true; } |
        jq -c 'select(.type=="match")
            | (.data.lines.text | rtrimstr("\n")) as $t
            | { path: .data.path.text, line: .data.line_number, text: $t,
                marker: (if   ($t|startswith("<<<<<<<")) then "begin"
                         elif ($t|startswith(">>>>>>>")) then "end"
                         elif ($t|startswith("|||||||")) then "base"
                         else "sep" end) }' |
        jq -s 'sort_by(.path, .line)' 2>/dev/null)"
    [[ -n "$findings" ]] || findings='[]'

    # Files git itself considers unmerged (independent of the text scan).
    local unmerged='[]'
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        unmerged="$(git diff --name-only --diff-filter=U 2>/dev/null |
            jq -R -s 'split("\n") | map(select(length>0))' 2>/dev/null || printf '[]')"
    fi

    local count
    count="$(printf '%s' "$findings" | jq 'length' 2>/dev/null || printf '0')"

    if ((output_json)); then
        jq -cn \
            --arg tool "git-conflicts" \
            --arg folder "$folder" \
            --argjson findings "$findings" \
            --argjson unmerged "$unmerged" \
            '{schema: 1, status: "ok", tool: $tool, folder: $folder,
              count: ($findings|length), markers: $findings,
              unmerged_files: $unmerged, warnings: [], errors: []}'
    else
        printf '# Conflict markers in %s\n' "$folder"
        printf 'location\tmarker\ttext\n'
        printf '%s' "$findings" | jq -r '.[] | "\(.path):\(.line)\t\(.marker)\t\(.text)"' 2>/dev/null || true
        printf '# %s marker(s) found\n' "$count"
        local n_unmerged
        n_unmerged="$(printf '%s' "$unmerged" | jq 'length' 2>/dev/null || printf '0')"
        ((n_unmerged > 0)) && printf '# git reports %s unmerged file(s)\n' "$n_unmerged"
    fi

    if ((fail_on)) && ((count > 0)); then
        exit 3
    fi
    return 0
}
