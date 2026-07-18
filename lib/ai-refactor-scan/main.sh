# shellcheck shell=bash
# shellcheck disable=SC2154  # cross-module globals resolved at source time
# ai-refactor-scan/main.sh — scc complexity + lizard NLOC refactor scanner.
#
# Sourced by libexec/ai-refactor-scan (thin loader). Not a standalone entrypoint.
#
# Analysis passes:
#   complexity  scc ranks files by cyclomatic complexity; files over the
#               threshold (default 15) are flagged for refactor.
#   nloc        lizard measures per-function NLOC; functions over the threshold
#               (default 40) are flagged for refactor.
#   comments    string-aware ripgrep (PCRE2) scan for marker words (TODO/FIXME/
#               ...) in real comments only; markers inside string literals are
#               ignored. Its own mode, not part of `all`.
#   dupes       lizard -Eduplicate reports the repo-wide duplicate rate and clone
#               blocks. Duplication is cross-file, so it always scans the whole
#               folder; with a change scope active it filters blocks to those
#               touching a changed file. Its own mode, not part of `all`.
# In `all` mode the complexity + nloc passes run in parallel and are joined.
#
# Scope: --changed [SELECTORS] (via `git files`) or --files-from FILE|- restrict
# the complexity/nloc passes to specific files (both metrics are file-local, so
# this is exact). dupes is always repo-wide, then filtered.
#
# Human output is CSV/table; AI output (AI_OUTPUT=json or --ai) is a JSON
# envelope. A full report document is written per pass in an scc-allowed format.

[[ "${AI_REFACTOR_SCAN_LOADED:-0}" == "1" ]] && return 0
AI_REFACTOR_SCAN_LOADED=1

# --- defaults -----------------------------------------------------------------
RS_MODE="all"              # complexity | nloc | comments | all
RS_FOLDER=""               # scan root; empty -> git toplevel, else PWD
RS_OUTPUT_FMT="human"      # human | ai
RS_SCC_FORMAT="csv"        # report-document format (scc-allowed)
RS_COMPLEXITY_THRESHOLD=15 # flag files with scc complexity strictly above
RS_NLOC_THRESHOLD=40       # flag functions with lizard NLOC strictly above
RS_PARAM_THRESHOLD=5       # flag functions with parameter count strictly above
RS_CCN_THRESHOLD=15        # flag functions with lizard CCN strictly above
RS_MARKERS="TODO,FIXME,HACK,XXX,BUG"  # comment-marker words the `comments` pass flags
RS_COMMENTS_ALL=0          # comments pass: emit every comment, not just marker lines
RS_MAX_DEPTH=""            # comments pass: rg --max-depth (1 = the folder only, no recursion)
RS_REPORT_FORMAT="csv"     # comments report-document format: csv | json | txt
RS_FILES_FROM=""           # read the scan file-list from this path ('-' = stdin)
RS_CHANGED=0               # scope the scan to git-changed files via `git files`
RS_CHANGED_SELECTORS="staged,unstaged,untracked"  # default --changed selection
RS_EXTS=""                 # comma list, e.g. "go,py,sh" (file-format filter)
RS_LANGS=""                # comma list of lizard languages, e.g. "python,go"
RS_OUTPUT_DIR=""           # where report documents are written
RS_PARALLEL=1              # run both passes concurrently in `all` mode
RS_WRITE_REPORT=1          # write report documents to disk
RS_FAIL_ON_FINDINGS=0      # exit 3 when any file/function is flagged
RS_TOKEN_THRESHOLD=""      # nloc pass: flag functions with lizard token count above (opt-in)
RS_STRICT=0                # exit non-zero (1) when a scanner pass fails internally
RS_STATUS_DIR=""           # per-pass failure records (set by the orchestrator to a tmp dir)
RS_QUIET=0
RS_EXTRA_EXCLUDE_DIRS=()

RS_SCC_BIN=""
RS_LIZARD_BIN=""
RS_RG_BIN=""
RS_IGNORE_DIRS=()
RS_SCOPED=0                # 1 when --changed/--files-from restricts the scan
RS_FILE_LIST=()            # resolved, folder-relative, existing files to scan
RS_TARGETS=(".")           # what scc/lizard receive: the file list, or "."
declare -gA RS_CPAT=()     # pattern key   -> string-aware pcre2 regex
declare -gA RS_EXT2KEY=()  # file extension -> pattern key

rs_die() {
    printf 'refactor-scan: %s\n' "$1" >&2
    exit "${2:-1}"
}
rs_log() {
    ((RS_QUIET)) && return 0
    printf '[refactor-scan] %s\n' "$1" >&2
    return 0
}

rs_need_bin() {
    command -v "$1" >/dev/null 2>&1 || rs_die "required binary '$1' not found (install it and retry)"
}

# Monotonic-ish wall clock in milliseconds for the meta.elapsed_ms field.
rs_now_ms() {
    # EPOCHREALTIME is "<sec>.<usec>" (or ",<usec>" under some locales); strip the
    # separator to get integer microseconds, then reduce to milliseconds.
    if [[ -n "${EPOCHREALTIME:-}" ]]; then
        local usec="${EPOCHREALTIME//[.,]/}"
        printf '%d\n' "$(( usec / 1000 ))"
    else
        printf '%d\n' "$(( $(date +%s%N) / 1000000 ))"
    fi
}

# Record a pass failure so the orchestrator can surface it. The analytic passes
# run in $()/background subshells, so a file under RS_STATUS_DIR is the only
# reliable channel back to the parent (globals set in a subshell do not persist).
#   rs_record_error <pass> <tool> <code> <message>
rs_record_error() {
    [[ -n "$RS_STATUS_DIR" ]] || return 0
    jq -n --arg pass "$1" --arg tool "$2" --argjson code "${3:-1}" \
        --arg message "$(printf '%s' "${4:-}" | tr -d '\000' | head -c 500)" \
        '{pass: $pass, tool: $tool, code: $code, message: $message}' \
        >"$RS_STATUS_DIR/$1.json" 2>/dev/null || true
}

# scc's -f/--format allowlist. Reject anything else so we never hand scc an
# invalid format and mislabel the report extension.
rs_valid_scc_format() {
    case "$1" in
        tabular | wide | json | json2 | csv | csv-stream | cloc-yaml | html | html-table | sql | sql-insert | openmetrics) return 0 ;;
        *) return 1 ;;
    esac
}

rs_report_ext() {
    case "$1" in
        json | json2) printf 'json\n' ;;
        csv | csv-stream) printf 'csv\n' ;;
        html | html-table) printf 'html\n' ;;
        cloc-yaml) printf 'yaml\n' ;;
        sql | sql-insert) printf 'sql\n' ;;
        *) printf 'txt\n' ;;
    esac
}

rs_is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

# A single `git files` status selector (mirrors ai-git/status.sh).
rs_valid_selector() {
    case "$1" in
        all | tracked | untracked | staged | unstaged | modified | added | new | deleted | renamed | conflicted) return 0 ;;
        *) return 1 ;;
    esac
}

# A non-empty comma list of valid selectors, e.g. "staged,untracked".
rs_valid_selector_list() {
    local IFS=',' tok
    [[ -n "$1" ]] || return 1
    for tok in $1; do
        rs_valid_selector "$tok" || return 1
    done
    return 0
}

# --- usage --------------------------------------------------------------------
rs_usage() {
    cat <<'EOF'
Usage:
  restsift refactor-scan [complexity|nloc|comments|dupes|all] [FOLDER] [options]

Modes:
  complexity   Rank files by scc cyclomatic complexity; flag files over the
               --complexity-threshold (default 15).
  nloc         Measure per-function NLOC with lizard; flag functions over the
               --nloc-threshold (default 40).
  comments     String-aware scan (ripgrep + PCRE2) for marker words in real
               comments only. Reports marker/line/text/path. Ignores markers
               inside string literals (e.g. "TODO" in a URL or quoted string).
               Not part of `all`; run it explicitly. Requires ripgrep.
  dupes        Report the repo-wide duplicate rate and clone blocks via
               lizard -Eduplicate. Cross-file, so always scans the whole folder;
               with --changed/--files-from it filters blocks to those touching a
               changed file. Not part of `all`. Requires lizard.
  all          Run the complexity + nloc passes (in parallel) and join the
               results. (default)

Scope (complexity/nloc): restrict the scan to specific files. Both metrics are
file-local, so scoping is exact. dupes always scans repo-wide, then filters.
  --changed [SELECTORS]     Scan only git-changed files. SELECTORS is a comma
                            list of git-file categories (default
                            staged,unstaged,untracked); see `git files --help`.
  --files-from FILE|-       Read the file list from FILE (or stdin with -),
                            newline- or NUL-separated. Compose with
                            `restsift git files ... --name-only`.

Arguments:
  FOLDER                    Directory to scan. When omitted, the git toplevel
                            is used, falling back to the current directory.

Options:
  --folder DIR              Scan root (alternative to the positional FOLDER).
  --complexity-threshold N  scc complexity flag threshold (default 15).
  --nloc-threshold N        lizard NLOC flag threshold (default 40).
  --param-threshold N       lizard parameter-count flag threshold (default 5):
                            functions taking more than N arguments are flagged.
  --ccn-threshold N         lizard cyclomatic-complexity flag threshold
                            (default 15) for the per-function nloc pass.
  --markers LIST            Comment-marker words for the `comments` pass
                            (default TODO,FIXME,HACK,XXX,BUG). Matched
                            case-sensitively on word boundaries.
  --all                     comments pass: list EVERY comment (inventory), not
                            just marker lines. The marker column tags any line
                            that still contains a marker word, else "comment".
  --max-depth N             comments pass: limit the walk depth. N=1 scans the
                            given folder only (no recursion); omit for a full
                            recursive scan (the default).
  --report-format FMT       comments report-document format: csv (default),
                            json, or txt. Each record includes a location
                            "path:line" or "path:start-end" (block comments).
  --ext LIST                Only analyze these file extensions, e.g. go,py,sh.
  --lang LIST              lizard language filter, e.g. python,go,cpp.
  --exclude-dir NAME        Extra directory name to ignore (repeatable).
  --scc-format FMT          Report-document format for the complexity pass:
                            tabular, wide, json, json2, csv, csv-stream,
                            cloc-yaml, html, html-table, sql, sql-insert,
                            openmetrics (default csv).
  --output-dir DIR          Where report documents are written
                            (default: ./.ai-logs/refactor-scan).
  --token-threshold N       lizard token-count flag threshold (opt-in; unset by
                            default so token count never drives a flag).
  --no-report               Do not write report documents to disk.
  --no-parallel             Run passes sequentially in `all` mode.
  --fail-on-findings        Exit 3 when any file or function is flagged.
  --strict, --fail-on-error Exit 1 when any pass fails internally (see below).
  --ai                      Emit a machine-readable JSON envelope.
  --human                   Emit human CSV/table output (default).
  --quiet                   Suppress progress logs on stderr.
  --help                    Show this help.

Exit codes:
  0   Success. The scan completed; findings may or may not be present.
  1   Usage, validation, or runtime error (bad flag, unknown mode, missing
      folder, missing required binary), or a pass failed and --strict was given.
  3   Findings present AND --fail-on-findings was given (CI gate).
  Scanner failures: if scc/lizard/rg fails mid-run, that pass yields no findings
  BUT the failure is surfaced — `status` becomes "partial"/"error", the failed
  pass is listed in `errors[]`, `meta.scan_confidence` drops below 100 (AI mode),
  and human mode prints a WARNING. A crashed scan is no longer indistinguishable
  from a clean one. The process still exits 0 by default (backward-compatible);
  pass --strict to turn a scanner failure into a non-zero exit for CI.

Ignore rules:
  Dot-directories (.git, .github, .claude, ...) are always skipped, together
  with the shared source-exclude list (node_modules, vendor, dist, build,
  coverage, target, ...) reused from share/config/source-exclude-dirs.txt.

Examples:
  restsift refactor-scan                       # scan the repo, both passes
  restsift refactor-scan complexity src --ext go --scc-format json
  restsift refactor-scan nloc . --nloc-threshold 60 --lang python
  restsift refactor-scan all . --ai --fail-on-findings
  restsift refactor-scan comments .            # markers across the whole project (recursive)
  restsift refactor-scan comments . --markers TODO,FIXME,DEBUG --ai
  restsift refactor-scan comments . --all      # every comment in the project (recursive)
  restsift refactor-scan comments src --all --max-depth 1   # one directory only, no recursion
  restsift refactor-scan comments src --all    # recurse from a single directory
  restsift refactor-scan comments . --report-format json --output-dir out   # export JSON report
  restsift refactor-scan comments . --all --report-format txt               # export text report
  restsift refactor-scan complexity --changed             # scc on uncommitted/untracked files only
  restsift refactor-scan nloc --changed staged,untracked  # lizard on selected changed files
  restsift git files --modified --name-only -0 | restsift refactor-scan all --files-from -
  restsift refactor-scan dupes --changed --ai             # duplication of changed files vs the repo
EOF
}

# --- argument parsing ---------------------------------------------------------
rs_parse_args() {
    local positional_folder_set=0
    local mode_explicit=0
    while (($# > 0)); do
        case "$1" in
            complexity | nloc | comments | dupes | all)
                RS_MODE="$1"
                mode_explicit=1
                ;;
            --folder)
                [[ $# -ge 2 ]] || rs_die "--folder requires a value"
                RS_FOLDER="$2"
                shift
                ;;
            --folder=*) RS_FOLDER="${1#*=}" ;;
            --complexity-threshold)
                [[ $# -ge 2 ]] || rs_die "--complexity-threshold requires a value"
                RS_COMPLEXITY_THRESHOLD="$2"
                shift
                ;;
            --complexity-threshold=*) RS_COMPLEXITY_THRESHOLD="${1#*=}" ;;
            --nloc-threshold)
                [[ $# -ge 2 ]] || rs_die "--nloc-threshold requires a value"
                RS_NLOC_THRESHOLD="$2"
                shift
                ;;
            --nloc-threshold=*) RS_NLOC_THRESHOLD="${1#*=}" ;;
            --param-threshold)
                [[ $# -ge 2 ]] || rs_die "--param-threshold requires a value"
                RS_PARAM_THRESHOLD="$2"
                shift
                ;;
            --param-threshold=*) RS_PARAM_THRESHOLD="${1#*=}" ;;
            --ccn-threshold)
                [[ $# -ge 2 ]] || rs_die "--ccn-threshold requires a value"
                RS_CCN_THRESHOLD="$2"
                shift
                ;;
            --ccn-threshold=*) RS_CCN_THRESHOLD="${1#*=}" ;;
            --token-threshold)
                [[ $# -ge 2 ]] || rs_die "--token-threshold requires a value"
                RS_TOKEN_THRESHOLD="$2"
                shift
                ;;
            --token-threshold=*) RS_TOKEN_THRESHOLD="${1#*=}" ;;
            --markers)
                [[ $# -ge 2 ]] || rs_die "--markers requires a value"
                RS_MARKERS="$2"
                shift
                ;;
            --markers=*) RS_MARKERS="${1#*=}" ;;
            --all) RS_COMMENTS_ALL=1 ;;
            --max-depth)
                [[ $# -ge 2 ]] || rs_die "--max-depth requires a value"
                RS_MAX_DEPTH="$2"
                shift
                ;;
            --max-depth=*) RS_MAX_DEPTH="${1#*=}" ;;
            --report-format)
                [[ $# -ge 2 ]] || rs_die "--report-format requires a value"
                RS_REPORT_FORMAT="$2"
                shift
                ;;
            --report-format=*) RS_REPORT_FORMAT="${1#*=}" ;;
            --files-from)
                [[ $# -ge 2 ]] || rs_die "--files-from requires a value (path or -)"
                RS_FILES_FROM="$2"
                shift
                ;;
            --files-from=*) RS_FILES_FROM="${1#*=}" ;;
            --changed)
                RS_CHANGED=1
                # An optional selector list may follow (e.g. --changed staged,untracked).
                # Only consume the next token when it is a valid selector list, so a
                # trailing FOLDER is never mistaken for selectors.
                if [[ $# -ge 2 && "$2" != -* ]] && rs_valid_selector_list "$2"; then
                    RS_CHANGED_SELECTORS="$2"
                    shift
                fi
                ;;
            --changed=*)
                RS_CHANGED=1
                RS_CHANGED_SELECTORS="${1#*=}"
                ;;
            --ext)
                [[ $# -ge 2 ]] || rs_die "--ext requires a value"
                RS_EXTS="$2"
                shift
                ;;
            --ext=*) RS_EXTS="${1#*=}" ;;
            --lang)
                [[ $# -ge 2 ]] || rs_die "--lang requires a value"
                RS_LANGS="$2"
                shift
                ;;
            --lang=*) RS_LANGS="${1#*=}" ;;
            --exclude-dir)
                [[ $# -ge 2 ]] || rs_die "--exclude-dir requires a value"
                RS_EXTRA_EXCLUDE_DIRS+=("$2")
                shift
                ;;
            --exclude-dir=*) RS_EXTRA_EXCLUDE_DIRS+=("${1#*=}") ;;
            --scc-format)
                [[ $# -ge 2 ]] || rs_die "--scc-format requires a value"
                RS_SCC_FORMAT="$2"
                shift
                ;;
            --scc-format=*) RS_SCC_FORMAT="${1#*=}" ;;
            --output-dir)
                [[ $# -ge 2 ]] || rs_die "--output-dir requires a value"
                RS_OUTPUT_DIR="$2"
                shift
                ;;
            --output-dir=*) RS_OUTPUT_DIR="${1#*=}" ;;
            --no-report) RS_WRITE_REPORT=0 ;;
            --no-parallel) RS_PARALLEL=0 ;;
            --fail-on-findings) RS_FAIL_ON_FINDINGS=1 ;;
            --strict) RS_STRICT=1 ;;
            --fail-on-error) RS_STRICT=1 ;;
            --ai | --json) RS_OUTPUT_FMT="ai" ;;
            --human) RS_OUTPUT_FMT="human" ;;
            --quiet) RS_QUIET=1 ;;
            -h | --help)
                rs_usage
                exit 0
                ;;
            --)
                shift
                break
                ;;
            -*)
                rs_die "unknown option '$1' (see --help)"
                ;;
            *)
                if ((positional_folder_set == 0)); then
                    # The mode is a small closed enum that must lead. A bareword
                    # first positional that is neither a known mode nor an
                    # existing directory is almost always a mistyped mode; name
                    # it as such instead of silently treating it as the FOLDER
                    # and failing later with a misleading "folder not found".
                    # A path-like token (contains '/') is left to folder
                    # resolution so genuine folder typos still say "folder not
                    # found: <path>".
                    if ((mode_explicit == 0)) && [[ "$1" != */* && ! -d "$1" ]]; then
                        rs_die "unknown mode '$1' (expected complexity|nloc|comments|dupes|all)"
                    fi
                    RS_FOLDER="$1"
                    positional_folder_set=1
                else
                    rs_die "unexpected argument '$1' (see --help)"
                fi
                ;;
        esac
        shift
    done

    # Trailing positional folder after `--`.
    if (($# > 0)) && ((positional_folder_set == 0)) && [[ -z "$RS_FOLDER" ]]; then
        RS_FOLDER="$1"
    fi

    rs_is_uint "$RS_COMPLEXITY_THRESHOLD" || rs_die "--complexity-threshold must be a non-negative integer"
    rs_is_uint "$RS_NLOC_THRESHOLD" || rs_die "--nloc-threshold must be a non-negative integer"
    rs_is_uint "$RS_PARAM_THRESHOLD" || rs_die "--param-threshold must be a non-negative integer"
    rs_is_uint "$RS_CCN_THRESHOLD" || rs_die "--ccn-threshold must be a non-negative integer"
    [[ -z "$RS_TOKEN_THRESHOLD" ]] || rs_is_uint "$RS_TOKEN_THRESHOLD" ||
        rs_die "--token-threshold must be a non-negative integer"
    rs_valid_scc_format "$RS_SCC_FORMAT" || rs_die "unsupported --scc-format '$RS_SCC_FORMAT' (see --help)"

    if ((RS_CHANGED)); then
        rs_valid_selector_list "$RS_CHANGED_SELECTORS" ||
            rs_die "--changed: invalid selector in '$RS_CHANGED_SELECTORS' (see --help)"
    fi

    if [[ "$RS_MODE" == "comments" ]]; then
        # Normalize the marker list (drop blanks/whitespace) and require at least
        # one alnum/underscore token so the pass never builds an empty regex.
        local -a _mk=() _m
        local IFS=','
        for _m in $RS_MARKERS; do
            _m="${_m//[[:space:]]/}"
            [[ "$_m" =~ ^[A-Za-z0-9_]+$ ]] || continue
            _mk+=("$_m")
        done
        ((${#_mk[@]} > 0)) || rs_die "--markers must list at least one [A-Za-z0-9_] word"
        IFS=','
        RS_MARKERS="${_mk[*]}"
        [[ -z "$RS_MAX_DEPTH" ]] || rs_is_uint "$RS_MAX_DEPTH" ||
            rs_die "--max-depth must be a non-negative integer"
        case "$RS_REPORT_FORMAT" in
            csv | json | txt) ;;
            *) rs_die "unsupported --report-format '$RS_REPORT_FORMAT' (csv|json|txt)" ;;
        esac
    fi

    if [[ "${AI_OUTPUT:-}" == "json" && "$RS_OUTPUT_FMT" == "human" ]]; then
        RS_OUTPUT_FMT="ai"
    fi
}

# --- environment resolution ---------------------------------------------------
rs_resolve_folder() {
    local f="$RS_FOLDER"
    if [[ -z "$f" ]]; then
        if git rev-parse --show-toplevel >/dev/null 2>&1; then
            f="$(git rev-parse --show-toplevel)"
        else
            f="$PWD"
        fi
    fi
    [[ -d "$f" ]] || rs_die "folder not found: $f"
    # Absolute, normalized path so tools never receive a leading-dash argument.
    f="$(cd "$f" && pwd)"
    RS_FOLDER="$f"
}

# Resolve --changed/--files-from into RS_FILE_LIST: a de-duplicated set of
# existing, folder-relative files. scc and lizard are then pointed at exactly
# these paths (complexity and NLOC are file-local, so scoping is correct). When
# a scope is requested but resolves to zero files, RS_TARGETS is left empty and
# the scans short-circuit to no findings.
rs_resolve_targets() {
    RS_TARGETS=(".")
    RS_SCOPED=0
    ((RS_CHANGED)) || [[ -n "$RS_FILES_FROM" ]] || return 0
    RS_SCOPED=1

    local -a raw=()
    if [[ -n "$RS_FILES_FROM" ]]; then
        # Accept newline- or NUL-separated paths (git files --name-only [-0],
        # fd, rg --files, xargs). NUL is normalized to newline for reading.
        if [[ "$RS_FILES_FROM" == "-" ]]; then
            mapfile -t raw < <(tr '\0' '\n')
        else
            [[ -f "$RS_FILES_FROM" ]] || rs_die "--files-from file not found: $RS_FILES_FROM"
            mapfile -t raw < <(tr '\0' '\n' <"$RS_FILES_FROM")
        fi
    fi

    if ((RS_CHANGED)); then
        rs_need_bin git
        local aigit="${RS_SHARE_DIR%/share}/libexec/ai-git"
        [[ -x "$aigit" || -f "$aigit" ]] || rs_die "cannot locate ai-git for --changed: $aigit"
        local -a sel_flags=()
        local IFS=',' s
        for s in $RS_CHANGED_SELECTORS; do
            [[ -n "$s" ]] && sel_flags+=("--$s")
        done
        unset IFS
        local -a changed=()
        mapfile -t changed < <(cd "$RS_FOLDER" && bash "$aigit" files "${sel_flags[@]}" --name-only 2>/dev/null)
        raw+=("${changed[@]}")
    fi

    RS_FILE_LIST=()
    local -A seen=()
    local p abs rel
    for p in "${raw[@]}"; do
        [[ -n "$p" ]] || continue
        if [[ "$p" == /* ]]; then
            abs="$p"
        elif [[ -e "$RS_FOLDER/$p" ]]; then
            abs="$RS_FOLDER/$p"
        else
            abs="$PWD/$p"
        fi
        [[ -f "$abs" ]] || continue # drop dirs, deleted, and missing paths
        case "$abs" in
            "$RS_FOLDER"/*) rel="${abs#"$RS_FOLDER"/}" ;;
            *) continue ;; # outside the scan folder -> ignore
        esac
        [[ -n "${seen[$rel]:-}" ]] && continue
        seen[$rel]=1
        RS_FILE_LIST+=("$rel")
    done

    if ((${#RS_FILE_LIST[@]} > 0)); then
        RS_TARGETS=("${RS_FILE_LIST[@]}")
    else
        RS_TARGETS=()
    fi
}

# Build the ignore-directory list from the shared source-exclude config, the
# always-on dot/VCS directories, and any user --exclude-dir values. scc's
# --exclude-dir matches directory *names*, so multi-segment config entries are
# reduced to their basename; a --not-match regex handles the rest.
rs_load_ignore_dirs() {
    local cfg="$RS_SHARE_DIR/config/source-exclude-dirs.txt"
    local -a list=()
    ai_load_config_list list "$cfg" \
        .git .ai-logs .ai-backups .repomix-context node_modules vendor dist \
        build coverage target tmp temp cache logs

    RS_IGNORE_DIRS=()
    local item base seen
    declare -A seen=()
    for item in "${list[@]}" .git .hg .svn .ai-logs .ai-backups .repomix-context \
        "${RS_EXTRA_EXCLUDE_DIRS[@]}"; do
        [[ -n "$item" ]] || continue
        base="${item%/}"
        base="${base##*/}"
        [[ -n "$base" ]] || continue
        [[ -n "${seen[$base]:-}" ]] && continue
        seen[$base]=1
        RS_IGNORE_DIRS+=("$base")
    done
}

rs_ignore_dirs_csv() {
    local joined
    printf -v joined '%s,' "${RS_IGNORE_DIRS[@]}"
    printf '%s' "${joined%,}"
}

rs_ensure_output_dir() {
    [[ "$RS_WRITE_REPORT" == 1 ]] || return 0
    [[ -n "$RS_OUTPUT_DIR" ]] || RS_OUTPUT_DIR="$PWD/.ai-logs/refactor-scan"
    mkdir -p "$RS_OUTPUT_DIR" || rs_die "cannot create output dir: $RS_OUTPUT_DIR"
    # Absolute so scc's --output still resolves after we cd into the scan folder.
    RS_OUTPUT_DIR="$(cd "$RS_OUTPUT_DIR" && pwd)"
}

# --- complexity pass (scc) ----------------------------------------------------
# Writes a compact JSON array of flagged files to stdout.
rs_complexity_flagged_json() {
    local scc_json rc=0
    # A requested scope that resolved to zero files: nothing to analyze.
    ((RS_SCOPED)) && ((${#RS_TARGETS[@]} == 0)) && {
        printf '[]\n'
        return 0
    }
    local -a args=(--by-file --format json --no-cocomo --sort complexity
        --exclude-dir "$(rs_ignore_dirs_csv)" --not-match '(^|/)\.[^/]+/')
    [[ -n "$RS_EXTS" ]] && args+=(--include-ext "$RS_EXTS")

    # Scan from inside the folder so paths are relative and directory excludes
    # never over-match an absolute path prefix (e.g. a scan root under /tmp).
    # RS_TARGETS is "." for a full scan, or the resolved changed-file list.
    local errf; errf="$(mktemp "${TMPDIR:-/tmp}/rs-scc.XXXXXX")"
    scc_json="$(cd "$RS_FOLDER" && "$RS_SCC_BIN" "${args[@]}" -- "${RS_TARGETS[@]}" 2>"$errf")" || rc=$?
    # scc exits 0 on success (including "no files"); any non-zero is a real
    # failure. Surface it instead of silently returning an empty (clean) result.
    ((rc == 0)) || {
        rs_record_error complexity scc "$rc" "scc exited $rc: $(head -c 300 "$errf" 2>/dev/null)"
        rm -f "$errf"
        printf '[]\n'
        return 0
    }
    rm -f "$errf"
    [[ -n "$scc_json" ]] || {
        printf '[]\n'
        return 0
    }

    printf '%s' "$scc_json" | jq -c --argjson t "$RS_COMPLEXITY_THRESHOLD" '
        [ .[] as $lang
          | ($lang.Files // [])[]
          | { path: .Location, complexity: .Complexity, lines: .Lines,
              code: .Code, language: $lang.Name } ]
        | map(select(.complexity > $t))
        | sort_by(-.complexity)
    ' 2>/dev/null || printf '[]\n'
}

rs_write_complexity_report() {
    [[ "$RS_WRITE_REPORT" == 1 ]] || return 0
    ((RS_SCOPED)) && ((${#RS_TARGETS[@]} == 0)) && return 0
    local dest
    dest="$RS_OUTPUT_DIR/complexity-report.$(rs_report_ext "$RS_SCC_FORMAT")"
    local -a args=(--by-file --format "$RS_SCC_FORMAT" --no-cocomo --sort complexity
        --exclude-dir "$(rs_ignore_dirs_csv)" --not-match '(^|/)\.[^/]+/')
    [[ -n "$RS_EXTS" ]] && args+=(--include-ext "$RS_EXTS")
    if (cd "$RS_FOLDER" && "$RS_SCC_BIN" "${args[@]}" --output "$dest" -- "${RS_TARGETS[@]}") >/dev/null 2>&1; then
        printf '%s' "$dest"
    else
        printf ''
    fi
}

# --- NLOC pass (lizard) -------------------------------------------------------
# Writes a compact JSON array of flagged functions to stdout.
rs_nloc_flagged_json() {
    local out rc=0 lang
    ((RS_SCOPED)) && ((${#RS_TARGETS[@]} == 0)) && {
        printf '[]\n'
        return 0
    }
    local -a args=(-w
        -T "nloc=$RS_NLOC_THRESHOLD"
        -T "parameter_count=$RS_PARAM_THRESHOLD"
        -T "cyclomatic_complexity=$RS_CCN_THRESHOLD"
        -x '*/.*/*')
    # Opt-in: also let lizard emit a warning for high token-count functions so
    # the parsed `token` value can drive a flag reason (default: off).
    [[ -n "$RS_TOKEN_THRESHOLD" ]] && args+=(-T "token_count=$RS_TOKEN_THRESHOLD")
    local d
    for d in "${RS_IGNORE_DIRS[@]}"; do
        args+=(-x "*/$d/*")
    done
    if [[ -n "$RS_LANGS" ]]; then
        local IFS=','
        for lang in $RS_LANGS; do
            [[ -n "$lang" ]] && args+=(-l "$lang")
        done
    fi

    # Scan from inside the folder so glob excludes match relative paths and never
    # over-match an absolute prefix. RS_TARGETS is "." or the changed-file list.
    local errf; errf="$(mktemp "${TMPDIR:-/tmp}/rs-lizard.XXXXXX")"
    out="$(cd "$RS_FOLDER" && "$RS_LIZARD_BIN" "${args[@]}" "${RS_TARGETS[@]}" 2>"$errf")" || rc=$?
    # lizard's exit code is not a reliable failure signal: depending on version it
    # may be 0 even with warnings, or the warning count. A genuine crash (bad
    # invocation, unreadable input, Python traceback) writes to stderr AND exits
    # non-zero — normal operation (with or without warnings) leaves stderr empty.
    if ((rc != 0)) && [[ -s "$errf" ]]; then
        rs_record_error nloc lizard "$rc" "lizard exited $rc: $(head -c 300 "$errf" 2>/dev/null)"
        rm -f "$errf"
        printf '[]\n'
        return 0
    fi
    rm -f "$errf"

    local ext_filter=""
    [[ -n "$RS_EXTS" ]] && ext_filter="${RS_EXTS//,/|}"

    local line path lineno func nloc ccn token param length reasons
    local first=1
    local buf=""
    while IFS= read -r line; do
        # Format: PATH:LINE: warning: FUNC has N NLOC, C CCN, T token, P PARAM, L length, ...
        [[ "$line" == *" warning: "* ]] || continue
        if [[ "$line" =~ ^(.+):([0-9]+):\ warning:\ (.+)\ has\ ([0-9]+)\ NLOC,\ ([0-9]+)\ CCN,\ ([0-9]+)\ token,\ ([0-9]+)\ PARAM,\ ([0-9]+)\ length ]]; then
            path="${BASH_REMATCH[1]}"
            lineno="${BASH_REMATCH[2]}"
            func="${BASH_REMATCH[3]}"
            nloc="${BASH_REMATCH[4]}"
            ccn="${BASH_REMATCH[5]}"
            token="${BASH_REMATCH[6]}"
            param="${BASH_REMATCH[7]}"
            length="${BASH_REMATCH[8]}"
        else
            continue
        fi
        # Flag a function when ANY configured threshold is exceeded, recording
        # which one(s) drove it so the caller can suggest a targeted refactor.
        reasons=""
        ((nloc > RS_NLOC_THRESHOLD)) && reasons="nloc"
        ((ccn > RS_CCN_THRESHOLD)) && reasons="${reasons:+$reasons,}ccn"
        ((param > RS_PARAM_THRESHOLD)) && reasons="${reasons:+$reasons,}params"
        [[ -n "$RS_TOKEN_THRESHOLD" ]] && ((token > RS_TOKEN_THRESHOLD)) && reasons="${reasons:+$reasons,}token"
        [[ -n "$reasons" ]] || continue
        if [[ -n "$ext_filter" ]]; then
            [[ "$path" =~ \.(${ext_filter})$ ]] || continue
        fi
        buf+=$'\x1e'"$path"$'\x1f'"$lineno"$'\x1f'"$func"$'\x1f'"$nloc"$'\x1f'"$ccn"$'\x1f'"$token"$'\x1f'"$param"$'\x1f'"$length"$'\x1f'"$reasons"
        first=0
    done <<<"$out"

    if ((first == 1)); then
        printf '[]\n'
        return 0
    fi

    # Convert the record-separated buffer into JSON with jq (handles quoting).
    printf '%s' "$buf" | jq -R -s '
        split("\u001e")
        | map(select(length > 0))
        | map(split("\u001f"))
        | map({ path: .[0], line: (.[1]|tonumber), function: .[2],
                nloc: (.[3]|tonumber), ccn: (.[4]|tonumber),
                token: (.[5]|tonumber), param: (.[6]|tonumber),
                length: (.[7]|tonumber),
                reasons: (.[8] | split(",")) })
        | sort_by(-(.nloc), -(.ccn), -(.param))
    ' 2>/dev/null || printf '[]\n'
}

rs_write_nloc_report() {
    [[ "$RS_WRITE_REPORT" == 1 ]] || return 0
    ((RS_SCOPED)) && ((${#RS_TARGETS[@]} == 0)) && return 0
    local dest="$RS_OUTPUT_DIR/nloc-report.txt" lang
    local -a args=(
        -T "nloc=$RS_NLOC_THRESHOLD"
        -T "parameter_count=$RS_PARAM_THRESHOLD"
        -T "cyclomatic_complexity=$RS_CCN_THRESHOLD"
        -x '*/.*/*')
    local d
    for d in "${RS_IGNORE_DIRS[@]}"; do
        args+=(-x "*/$d/*")
    done
    if [[ -n "$RS_LANGS" ]]; then
        local IFS=','
        for lang in $RS_LANGS; do
            [[ -n "$lang" ]] && args+=(-l "$lang")
        done
    fi
    if (cd "$RS_FOLDER" && "$RS_LIZARD_BIN" "${args[@]}" "${RS_TARGETS[@]}") >"$dest" 2>/dev/null; then
        printf '%s' "$dest"
    else
        # lizard exits non-zero when warnings are present; the file is still valid.
        [[ -s "$dest" ]] && printf '%s' "$dest" || printf ''
    fi
}

# --- duplication pass (lizard -Eduplicate) ------------------------------------
# Duplication is inherently cross-file: a changed file can duplicate code in an
# UNCHANGED one. So this always scans the whole folder for the repo-wide rate and
# clone blocks, then (when a scope is active) filters the blocks to those that
# touch a changed file. lizard ignores sub-threshold clones, so small snippets
# are intentionally not reported. Emits a single JSON object:
#   { rate, unique_rate, block_count, blocks: [ { locations:[{path,start,end}],
#     involves_changed } ] }
rs_dupes_flagged_json() {
    local out rc=0 lang d
    local -a args=(-Eduplicate -x '*/.*/*')
    for d in "${RS_IGNORE_DIRS[@]}"; do
        args+=(-x "*/$d/*")
    done
    if [[ -n "$RS_LANGS" ]]; then
        local IFS=','
        for lang in $RS_LANGS; do
            [[ -n "$lang" ]] && args+=(-l "$lang")
        done
    fi
    local errf; errf="$(mktemp "${TMPDIR:-/tmp}/rs-dupes.XXXXXX")"
    out="$(cd "$RS_FOLDER" && "$RS_LIZARD_BIN" "${args[@]}" . 2>"$errf")" || rc=$?
    # A genuine lizard crash writes to stderr and exits non-zero; surface it
    # rather than reporting a (false) 0% duplicate rate. See the nloc pass note.
    if ((rc != 0)) && [[ -s "$errf" ]]; then
        rs_record_error dupes lizard "$rc" "lizard exited $rc: $(head -c 300 "$errf" 2>/dev/null)"
        rm -f "$errf"
        printf '{"rate":0,"unique_rate":100,"block_count":0,"blocks":[]}\n'
        return 0
    fi
    rm -f "$errf"

    # Parse the "Duplicate block:" sections and the summary rates.
    local rate="0" unique="100"
    local in_block=0 curblock="" line p s e
    local buf=""
    while IFS= read -r line; do
        if [[ "$line" == "Duplicate block:" ]]; then
            in_block=1
            curblock=""
            continue
        fi
        if ((in_block)); then
            if [[ "$line" =~ ^(.+):([0-9]+)\ ~\ ([0-9]+)$ ]]; then
                p="${BASH_REMATCH[1]#./}"
                s="${BASH_REMATCH[2]}"
                e="${BASH_REMATCH[3]}"
                curblock+="${curblock:+$'\x1e'}$p"$'\x1f'"$s"$'\x1f'"$e"
            elif [[ "$line" == "^"* ]]; then
                [[ -n "$curblock" ]] && buf+="${buf:+$'\x1d'}$curblock"
                in_block=0
                curblock=""
            fi
            continue
        fi
        [[ "$line" =~ Total\ duplicate\ rate:\ ([0-9.]+)% ]] && rate="${BASH_REMATCH[1]}"
        [[ "$line" =~ Total\ unique\ rate:\ ([0-9.]+)% ]] && unique="${BASH_REMATCH[1]}"
    done <<<"$out"

    local changed_json='[]'
    ((${#RS_FILE_LIST[@]} > 0)) && changed_json="$(printf '%s\n' "${RS_FILE_LIST[@]}" |
        jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || printf '[]')"

    local blocks_json='[]'
    [[ -n "$buf" ]] && blocks_json="$(printf '%s' "$buf" |
        jq -R -s --argjson changed "$changed_json" --argjson scoped "$RS_SCOPED" '
            ($changed | map({(.): true}) | add // {}) as $ch
            | split("\u001d")
            | map(select(length > 0))
            | map( split("\u001e")
                   | map(select(length > 0))
                   | map(split("\u001f"))
                   | map({ path: .[0], start: (.[1]|tonumber), end: (.[2]|tonumber) }) )
            | map({ locations: ., involves_changed: (any(.[]; $ch[.path] == true)) })
            | (if $scoped == 1 then map(select(.involves_changed)) else . end)
        ' 2>/dev/null || printf '[]')"

    jq -n --argjson rate "${rate:-0}" --argjson unique "${unique:-100}" \
        --argjson blocks "$blocks_json" \
        '{ rate: $rate, unique_rate: $unique, block_count: ($blocks|length), blocks: $blocks }'
}

rs_write_dupes_report() {
    [[ "$RS_WRITE_REPORT" == 1 ]] || return 0
    local json="$1" dest
    case "$RS_REPORT_FORMAT" in
        json)
            dest="$RS_OUTPUT_DIR/dupes-report.json"
            printf '%s' "$json" | jq '.' >"$dest" 2>/dev/null && printf '%s' "$dest" || printf ''
            ;;
        *)
            dest="$RS_OUTPUT_DIR/dupes-report.txt"
            {
                printf 'duplicate_rate\t%s%%\n' "$(printf '%s' "$json" | jq -r '.rate')"
                printf '%s' "$json" | jq -r '.blocks[] | "block\t" + ([.locations[] | "\(.path):\(.start)-\(.end)"] | join("  "))' 2>/dev/null || true
            } >"$dest" && printf '%s' "$dest" || printf ''
            ;;
    esac
}

# --- comments pass (rg, string-aware marker scan) -----------------------------
# Load share/config/comment-patterns.txt into RS_CPAT (key->regex) and
# RS_EXT2KEY (ext->key). Tab-delimited, 3 fields; `#`-leading lines are config
# comments (patterns themselves contain `#`, so we cannot strip inline).
rs_load_comment_patterns() {
    local cfg="$RS_SHARE_DIR/config/comment-patterns.txt"
    [[ -f "$cfg" ]] || rs_die "missing comment pattern config: $cfg"
    RS_CPAT=()
    RS_EXT2KEY=()
    local key exts pat ext IFS
    while IFS=$'\t' read -r key exts pat || [[ -n "$key" ]]; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        [[ -n "$pat" ]] || continue
        RS_CPAT["$key"]="$pat"
        IFS=','
        for ext in $exts; do
            [[ -n "$ext" ]] || continue
            RS_EXT2KEY["$ext"]="$key"
        done
    done <"$cfg"
    ((${#RS_CPAT[@]} > 0)) || rs_die "no comment patterns loaded from $cfg"
}

# Files to scan: rg --files (respects .gitignore, skips hidden) plus explicit
# excludes for the shared ignore list so node_modules is dropped even without a
# .gitignore (parity with the scc/lizard passes).
rs_comment_files() {
    local -a globs=() d
    for d in "${RS_IGNORE_DIRS[@]}"; do
        globs+=(-g "!**/$d/**" -g "!$d/**")
    done
    # --max-depth 1 restricts the scan to the folder itself (no recursion into
    # subdirectories); omitted means a full recursive walk from the folder.
    [[ -n "$RS_MAX_DEPTH" ]] && globs+=(--max-depth "$RS_MAX_DEPTH")
    local out rc=0 errf; errf="$(mktemp "${TMPDIR:-/tmp}/rs-rg.XXXXXX")"
    out="$(cd "$RS_FOLDER" && "$RS_RG_BIN" --files "${globs[@]}" 2>"$errf")" || rc=$?
    # rg exits 1 when it simply lists nothing (normal); >=2 is a real error.
    ((rc >= 2)) && rs_record_error comments rg "$rc" "rg exited $rc: $(head -c 300 "$errf" 2>/dev/null)"
    rm -f "$errf"
    # Preserve a trailing newline (the caller reads this with `while read`, which
    # would otherwise drop the final path); emit nothing when the list is empty.
    [[ -n "$out" ]] && printf '%s\n' "$out"
    return 0
}

# Writes a compact JSON array of flagged comments/markers to stdout. Each record
# carries the enclosing comment's span so callers get an AI-friendly location:
#   { path, line, line_start, line_end, location, marker, text }
# location is "path:N" for a single-line comment, "path:S-E" for a block comment
# (S..E). In marker mode `line` is the marker's exact line; in --all mode it is
# the comment's first line. Sorted by path, line_start, line.
rs_comments_flagged_json() {
    local -a markers=()
    local IFS=','
    read -ra markers <<<"$RS_MARKERS"
    unset IFS

    local ext_filter=""
    [[ -n "$RS_EXTS" ]] && ext_filter=",${RS_EXTS//[[:space:]]/},"

    local sent_a=$'\001' sent_b=$'\002'
    local repl=$'\001${c}\002'
    local buf="" first=1
    local file ext key raw oline lineno rest

    # emit_record PATH LINE START END MARKER TEXT
    emit_record() {
        local loc
        if (($3 == $4)); then loc="$1:$3"; else loc="$1:$3-$4"; fi
        buf+=$'\x1e'"$1"$'\x1f'"$2"$'\x1f'"$3"$'\x1f'"$4"$'\x1f'"$loc"$'\x1f'"$5"$'\x1f'"$6"
        first=0
    }

    # A complete comment spans c_start..c_end; its per-line texts sit in
    # cl_lineno[]/cl_text[]. An all-empty comment was a masked string literal.
    local c_start=0 c_end=0 in_comment=0
    local -a cl_lineno=() cl_text=()
    finalize_comment() {
        ((in_comment)) || return 0
        in_comment=0
        local i joined="" tag="comment" mk t
        for i in "${!cl_lineno[@]}"; do
            t="${cl_text[$i]}"
            [[ -n "$t" ]] || continue
            joined+="${joined:+ }$t"
        done
        [[ -n "$joined" ]] || return 0                # all-empty -> masked string
        ((${#joined} > 200)) && joined="${joined:0:197}..."

        if ((RS_COMMENTS_ALL)); then
            for mk in "${markers[@]}"; do
                if [[ "$joined" =~ (^|[^A-Za-z0-9_])"$mk"([^A-Za-z0-9_]|$) ]]; then
                    tag="$mk"
                    break
                fi
            done
            emit_record "$file" "$c_start" "$c_start" "$c_end" "$tag" "$joined"
            return 0
        fi
        # Marker mode: one record per marker occurrence, at its exact line.
        for i in "${!cl_lineno[@]}"; do
            t="${cl_text[$i]}"
            [[ -n "$t" ]] || continue
            ((${#t} > 200)) && t="${t:0:197}..."
            for mk in "${markers[@]}"; do
                if [[ "$t" =~ (^|[^A-Za-z0-9_])"$mk"([^A-Za-z0-9_]|$) ]]; then
                    emit_record "$file" "${cl_lineno[$i]}" "$c_start" "$c_end" "$mk" "$t"
                fi
            done
        done
        return 0
    }

    local has_a has_b
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        ext="${file##*.}"
        ext="${ext,,}"
        [[ "$ext" == "$file" ]] && continue           # no extension -> skip
        key="${RS_EXT2KEY[$ext]:-}"
        [[ -n "$key" ]] || continue
        [[ -n "$ext_filter" && "$ext_filter" != *",$ext,"* ]] && continue

        raw="$(cd "$RS_FOLDER" && "$RS_RG_BIN" -nUo --pcre2 -r "$repl" -e "${RS_CPAT[$key]}" -- "$file" 2>/dev/null || true)"
        [[ -n "$raw" ]] || continue

        in_comment=0
        cl_lineno=()
        cl_text=()
        while IFS= read -r oline; do
            [[ "$oline" == *:* ]] || continue
            lineno="${oline%%:*}"
            [[ "$lineno" =~ ^[0-9]+$ ]] || continue
            rest="${oline#*:}"
            has_a=0
            has_b=0
            [[ "$rest" == *"$sent_a"* ]] && has_a=1
            [[ "$rest" == *"$sent_b"* ]] && has_b=1
            rest="${rest//$sent_a/}"
            rest="${rest//$sent_b/}"
            rest="${rest#"${rest%%[![:space:]]*}"}"   # ltrim
            rest="${rest%"${rest##*[![:space:]]}"}"   # rtrim

            # \x01 opens a comment span, \x02 closes it; lines in between are the
            # block comment's continuation body.
            if ((has_a)) && ((! in_comment)); then
                in_comment=1
                c_start="$lineno"
                cl_lineno=()
                cl_text=()
            fi
            if ((in_comment)); then
                cl_lineno+=("$lineno")
                cl_text+=("$rest")
            fi
            if ((has_b)) && ((in_comment)); then
                c_end="$lineno"
                finalize_comment
            fi
        done <<<"$raw"
        finalize_comment                              # flush any unterminated span
    done < <(rs_comment_files)

    if ((first == 1)); then
        printf '[]\n'
        return 0
    fi

    printf '%s' "$buf" | jq -R -s '
        split("\u001e")
        | map(select(length > 0))
        | map(split("\u001f"))
        | map({ path: .[0], line: (.[1]|tonumber),
                line_start: (.[2]|tonumber), line_end: (.[3]|tonumber),
                location: .[4], marker: .[5], text: .[6] })
        | sort_by(.path, .line_start, .line)
    ' 2>/dev/null || printf '[]\n'
}

# Write the comments report in the requested format (csv|json|txt). Returns the
# written path on stdout (empty on failure / --no-report).
rs_write_comments_report() {
    [[ "$RS_WRITE_REPORT" == 1 ]] || return 0
    local json="$1" dest
    case "$RS_REPORT_FORMAT" in
        json)
            dest="$RS_OUTPUT_DIR/comments-report.json"
            printf '%s' "$json" | jq '.' >"$dest" 2>/dev/null && printf '%s' "$dest" || printf ''
            ;;
        txt)
            dest="$RS_OUTPUT_DIR/comments-report.txt"
            printf '%s' "$json" |
                jq -r '.[] | "\(.location)\t\(.marker)\t\(.text)"' >"$dest" 2>/dev/null &&
                printf '%s' "$dest" || printf ''
            ;;
        *)
            dest="$RS_OUTPUT_DIR/comments-report.csv"
            {
                printf 'location,marker,line,text,path\n'
                printf '%s' "$json" | jq -r '.[] | [.location, .marker, .line, .text, .path] | @csv' 2>/dev/null || true
            } >"$dest" && printf '%s' "$dest" || printf ''
            ;;
    esac
}

# --- output rendering ---------------------------------------------------------
rs_render_human() {
    local complexity_json="$1" nloc_json="$2" complexity_report="$3" nloc_report="$4"
    local comments_json="${5:-[]}" comments_report="${6:-}"
    local dupes_json="${7:-}" dupes_report="${8:-}"
    local scan_status="${9:-ok}" errors_json="${10:-[]}"
    local n_files n_funcs n_marks n_blocks dup_rate

    if [[ "$RS_MODE" == "complexity" || "$RS_MODE" == "all" ]]; then
        n_files="$(printf '%s' "$complexity_json" | jq 'length' 2>/dev/null || printf '0')"
        printf '# Complexity refactor candidates (scc complexity > %s)\n' "$RS_COMPLEXITY_THRESHOLD"
        printf 'complexity,code,lines,language,path\n'
        printf '%s' "$complexity_json" | jq -r '.[] | [.complexity, .code, .lines, .language, .path] | @csv' 2>/dev/null || true
        printf '# %s file(s) flagged for refactor\n' "$n_files"
        [[ -n "$complexity_report" ]] && printf '# report: %s\n' "$complexity_report"
        printf '\n'
    fi

    if [[ "$RS_MODE" == "nloc" || "$RS_MODE" == "all" ]]; then
        n_funcs="$(printf '%s' "$nloc_json" | jq 'length' 2>/dev/null || printf '0')"
        printf '# Function refactor candidates (lizard NLOC>%s, params>%s, CCN>%s)\n' \
            "$RS_NLOC_THRESHOLD" "$RS_PARAM_THRESHOLD" "$RS_CCN_THRESHOLD"
        printf 'nloc,ccn,params,line,reasons,function,path\n'
        printf '%s' "$nloc_json" | jq -r '.[] | [.nloc, .ccn, .param, .line, (.reasons|join("+")), .function, .path] | @csv' 2>/dev/null || true
        printf '# %s function(s) flagged for refactor\n' "$n_funcs"
        [[ -n "$nloc_report" ]] && printf '# report: %s\n' "$nloc_report"
    fi

    if [[ "$RS_MODE" == "comments" ]]; then
        n_marks="$(printf '%s' "$comments_json" | jq 'length' 2>/dev/null || printf '0')"
        if ((RS_COMMENTS_ALL)); then
            printf '# All comments (string-aware; markers tagged: %s)\n' "$RS_MARKERS"
        else
            printf '# Comment markers (%s; string-aware)\n' "$RS_MARKERS"
        fi
        printf 'location,marker,text\n'
        printf '%s' "$comments_json" | jq -r '.[] | [.location, .marker, .text] | @csv' 2>/dev/null || true
        if ((RS_COMMENTS_ALL)); then
            printf '# %s comment(s) found\n' "$n_marks"
        else
            printf '# %s marker(s) found\n' "$n_marks"
        fi
        [[ -n "$comments_report" ]] && printf '# report: %s\n' "$comments_report"
    fi

    if [[ "$RS_MODE" == "dupes" ]]; then
        n_blocks="$(printf '%s' "$dupes_json" | jq -r '.block_count' 2>/dev/null || printf '0')"
        dup_rate="$(printf '%s' "$dupes_json" | jq -r '.rate' 2>/dev/null || printf '0')"
        printf '# Duplicate blocks (lizard -Eduplicate, repo-wide; duplicate rate %s%%)\n' "$dup_rate"
        printf 'locations\n'
        printf '%s' "$dupes_json" | jq -r '.blocks[] | [.locations[] | "\(.path):\(.start)-\(.end)"] | join("  ~  ")' 2>/dev/null || true
        if ((RS_SCOPED)); then
            printf '# %s block(s) involving changed files (of the repo-wide scan)\n' "$n_blocks"
        else
            printf '# %s duplicate block(s) repo-wide\n' "$n_blocks"
        fi
        [[ -n "$dupes_report" ]] && printf '# report: %s\n' "$dupes_report"
    fi

    # Surface scanner failures so a crashed pass is not mistaken for a clean scan.
    if [[ "$scan_status" != "ok" ]]; then
        printf '\n# WARNING: scan %s — results are incomplete.\n' "$scan_status"
        printf '%s' "$errors_json" | jq -r '.[] | "#   \(.pass) pass failed (\(.tool) exit \(.code)) — \(.message)"' 2>/dev/null || true
    fi
    return 0
}

rs_render_ai() {
    local complexity_json="$1" nloc_json="$2" complexity_report="$3" nloc_report="$4"
    local comments_json="${5:-[]}" comments_report="${6:-}"
    local dupes_json="${7:-}" dupes_report="${8:-}"
    local scan_status="${9:-ok}" errors_json="${10:-[]}"
    local scan_confidence="${11:-100}" elapsed_ms="${12:-0}"
    [[ -n "$dupes_json" ]] || dupes_json='{"rate":0,"unique_rate":100,"block_count":0,"blocks":[]}'
    local scope_files_json='[]'
    ((${#RS_FILE_LIST[@]} > 0)) && scope_files_json="$(printf '%s\n' "${RS_FILE_LIST[@]}" |
        jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || printf '[]')"
    # Emit the machine-readable envelope directly (schema/status/tool/content/
    # warnings/errors/meta) so the content object is preserved verbatim.
    jq -n \
        --arg mode "$RS_MODE" \
        --arg folder "$RS_FOLDER" \
        --argjson complexity_threshold "$RS_COMPLEXITY_THRESHOLD" \
        --argjson nloc_threshold "$RS_NLOC_THRESHOLD" \
        --argjson param_threshold "$RS_PARAM_THRESHOLD" \
        --argjson ccn_threshold "$RS_CCN_THRESHOLD" \
        --arg markers "$RS_MARKERS" \
        --argjson scoped "$RS_SCOPED" \
        --arg selectors "$([[ -n "$RS_FILES_FROM" ]] && printf 'files-from' || printf '%s' "$RS_CHANGED_SELECTORS")" \
        --argjson scope_files "$scope_files_json" \
        --argjson complexity "$complexity_json" \
        --argjson nloc "$nloc_json" \
        --argjson comments "$comments_json" \
        --argjson dupes "$dupes_json" \
        --arg complexity_report "$complexity_report" \
        --arg nloc_report "$nloc_report" \
        --arg comments_report "$comments_report" \
        --arg dupes_report "$dupes_report" \
        --arg token_threshold "$RS_TOKEN_THRESHOLD" \
        --arg scan_status "$scan_status" \
        --argjson errors "$errors_json" \
        --argjson scan_confidence "$scan_confidence" \
        --argjson elapsed_ms "$elapsed_ms" \
        '{
            schema: 1,
            status: $scan_status,
            tool: "refactor-scan",
            content: {
                mode: $mode,
                folder: $folder,
                scope: {
                    scoped: ($scoped == 1),
                    selection: (if $scoped == 1 then $selectors else null end),
                    file_count: ($scope_files | length),
                    files: $scope_files
                },
                thresholds: {
                    complexity: $complexity_threshold,
                    nloc: $nloc_threshold,
                    params: $param_threshold,
                    ccn: $ccn_threshold
                },
                complexity: {
                    threshold: $complexity_threshold,
                    flagged_count: ($complexity | length),
                    report: (if $complexity_report == "" then null else $complexity_report end),
                    files: $complexity
                },
                nloc: {
                    threshold: $nloc_threshold,
                    param_threshold: $param_threshold,
                    ccn_threshold: $ccn_threshold,
                    token_threshold: (if $token_threshold == "" then null else ($token_threshold | tonumber) end),
                    flagged_count: ($nloc | length),
                    report: (if $nloc_report == "" then null else $nloc_report end),
                    functions: $nloc
                },
                comments: {
                    markers: ($markers | split(",")),
                    flagged_count: ($comments | length),
                    report: (if $comments_report == "" then null else $comments_report end),
                    markers_found: $comments
                },
                dupes: {
                    rate: $dupes.rate,
                    unique_rate: $dupes.unique_rate,
                    flagged_count: $dupes.block_count,
                    report: (if $dupes_report == "" then null else $dupes_report end),
                    blocks: $dupes.blocks
                },
                flagged_total: (($complexity | length) + ($nloc | length) + ($comments | length) + $dupes.block_count)
            },
            warnings: [],
            errors: $errors,
            meta: { elapsed_ms: $elapsed_ms, scan_confidence: $scan_confidence, truncated: false }
        }'
}

# --- orchestration ------------------------------------------------------------
refactor_scan_main() {
    rs_parse_args "$@"
    rs_resolve_folder
    rs_resolve_targets
    rs_load_ignore_dirs
    rs_ensure_output_dir

    rs_need_bin jq
    if ((RS_SCOPED)); then
        rs_log "scope: ${#RS_FILE_LIST[@]} file(s) via $([[ -n "$RS_FILES_FROM" ]] && printf -- '--files-from' || printf -- '--changed %s' "$RS_CHANGED_SELECTORS")"
    fi
    RS_SCC_BIN="$(command -v scc || true)"
    RS_LIZARD_BIN="$(command -v lizard || true)"
    RS_RG_BIN="$(command -v rg || true)"

    local complexity_json='[]' nloc_json='[]' comments_json='[]'
    local dupes_json='{"rate":0,"unique_rate":100,"block_count":0,"blocks":[]}'
    local complexity_report='' nloc_report='' comments_report='' dupes_report=''
    local run_complexity=0 run_nloc=0 run_comments=0 run_dupes=0
    [[ "$RS_MODE" == "complexity" || "$RS_MODE" == "all" ]] && run_complexity=1
    [[ "$RS_MODE" == "nloc" || "$RS_MODE" == "all" ]] && run_nloc=1
    [[ "$RS_MODE" == "comments" ]] && run_comments=1
    [[ "$RS_MODE" == "dupes" ]] && run_dupes=1

    ((run_complexity)) && [[ -z "$RS_SCC_BIN" ]] && rs_die "required binary 'scc' not found (install it and retry)"
    ((run_nloc)) && [[ -z "$RS_LIZARD_BIN" ]] && rs_die "required binary 'lizard' not found (install it and retry)"
    ((run_comments)) && [[ -z "$RS_RG_BIN" ]] && rs_die "required binary 'rg' (ripgrep, PCRE2) not found (install it and retry)"
    ((run_dupes)) && [[ -z "$RS_LIZARD_BIN" ]] && rs_die "required binary 'lizard' not found (install it and retry)"

    local tmp
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/refactor-scan.XXXXXX")" || rs_die "cannot create temp dir"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" EXIT

    # Passes run in $()/background subshells and record any internal failure as a
    # JSON file under this dir (globals set in a subshell would not survive).
    RS_STATUS_DIR="$tmp/status"
    mkdir -p "$RS_STATUS_DIR"
    local _rs_start
    _rs_start="$(rs_now_ms)"

    if ((run_complexity && run_nloc && RS_PARALLEL)); then
        rs_log "scanning $RS_FOLDER (complexity + nloc, parallel)"
        (rs_complexity_flagged_json >"$tmp/complexity.json") &
        local pid_c=$!
        (rs_nloc_flagged_json >"$tmp/nloc.json") &
        local pid_n=$!
        wait "$pid_c" || true
        wait "$pid_n" || true
        complexity_json="$(cat "$tmp/complexity.json" 2>/dev/null)"
        nloc_json="$(cat "$tmp/nloc.json" 2>/dev/null)"
        complexity_report="$(rs_write_complexity_report)"
        nloc_report="$(rs_write_nloc_report)"
    else
        if ((run_complexity)); then
            rs_log "scanning $RS_FOLDER (complexity)"
            complexity_json="$(rs_complexity_flagged_json)"
            complexity_report="$(rs_write_complexity_report)"
        fi
        if ((run_nloc)); then
            rs_log "scanning $RS_FOLDER (nloc)"
            nloc_json="$(rs_nloc_flagged_json)"
            nloc_report="$(rs_write_nloc_report)"
        fi
        if ((run_comments)); then
            rs_log "scanning $RS_FOLDER (comments: $RS_MARKERS)"
            rs_load_comment_patterns
            comments_json="$(rs_comments_flagged_json)"
            comments_report="$(rs_write_comments_report "$comments_json")"
        fi
        if ((run_dupes)); then
            rs_log "scanning $RS_FOLDER (dupes: lizard -Eduplicate, repo-wide)"
            dupes_json="$(rs_dupes_flagged_json)"
            dupes_report="$(rs_write_dupes_report "$dupes_json")"
        fi
    fi

    [[ -n "$complexity_json" ]] || complexity_json='[]'
    [[ -n "$nloc_json" ]] || nloc_json='[]'
    [[ -n "$comments_json" ]] || comments_json='[]'
    [[ -n "$dupes_json" ]] || dupes_json='{"rate":0,"unique_rate":100,"block_count":0,"blocks":[]}'

    # Collect any per-pass failure records into the envelope. A pass that errored
    # internally is no longer indistinguishable from a clean scan.
    local errors_json='[]'
    if compgen -G "$RS_STATUS_DIR/*.json" >/dev/null 2>&1; then
        errors_json="$(cat "$RS_STATUS_DIR"/*.json | jq -s '.' 2>/dev/null || printf '[]')"
    fi
    local run_count=$((run_complexity + run_nloc + run_comments + run_dupes))
    local err_count
    err_count="$(printf '%s' "$errors_json" | jq 'length' 2>/dev/null || printf '0')"
    local scan_status="ok" scan_confidence=100
    if ((err_count > 0)); then
        ((err_count >= run_count)) && scan_status="error" || scan_status="partial"
        ((run_count > 0)) && scan_confidence=$(((run_count - err_count) * 100 / run_count)) || scan_confidence=0
    fi
    local elapsed_ms=$(($(rs_now_ms) - _rs_start))
    ((elapsed_ms >= 0)) || elapsed_ms=0

    if [[ "$RS_OUTPUT_FMT" == "ai" ]]; then
        rs_render_ai "$complexity_json" "$nloc_json" "$complexity_report" "$nloc_report" "$comments_json" "$comments_report" "$dupes_json" "$dupes_report" "$scan_status" "$errors_json" "$scan_confidence" "$elapsed_ms"
    else
        rs_render_human "$complexity_json" "$nloc_json" "$complexity_report" "$nloc_report" "$comments_json" "$comments_report" "$dupes_json" "$dupes_report" "$scan_status" "$errors_json"
    fi

    # --strict: a failed pass is a runtime error (exit 1 per the documented
    # contract), and takes precedence over the findings gate.
    if ((RS_STRICT)) && ((err_count > 0)); then
        exit 1
    fi

    if ((RS_FAIL_ON_FINDINGS)); then
        local total
        total="$(jq -n --argjson a "$complexity_json" --argjson b "$nloc_json" --argjson c "$comments_json" --argjson d "$dupes_json" \
            '($a|length)+($b|length)+($c|length)+($d.block_count)' 2>/dev/null || printf '0')"
        ((total > 0)) && exit 3
    fi
    return 0
}
