# shellcheck shell=bash
# shellcheck disable=SC2154  # cross-module globals resolved at source time
# ai-refactor-scan/main.sh — scc complexity + lizard NLOC refactor scanner.
#
# Sourced by libexec/ai-refactor-scan (thin loader). Not a standalone entrypoint.
#
# Two analysis passes, either or both:
#   complexity  scc ranks files by cyclomatic complexity; files over the
#               threshold (default 15) are flagged for refactor.
#   nloc        lizard measures per-function NLOC; functions over the threshold
#               (default 40) are flagged for refactor.
# In `all` mode the two passes run in parallel and their results are joined.
#
# Human output is CSV/table; AI output (AI_OUTPUT=json or --ai) is a JSON
# envelope. A full report document is written per pass in an scc-allowed format.

[[ "${AI_REFACTOR_SCAN_LOADED:-0}" == "1" ]] && return 0
AI_REFACTOR_SCAN_LOADED=1

# --- defaults -----------------------------------------------------------------
RS_MODE="all"              # complexity | nloc | all
RS_FOLDER=""               # scan root; empty -> git toplevel, else PWD
RS_OUTPUT_FMT="human"      # human | ai
RS_SCC_FORMAT="csv"        # report-document format (scc-allowed)
RS_COMPLEXITY_THRESHOLD=15 # flag files with scc complexity strictly above
RS_NLOC_THRESHOLD=40       # flag functions with lizard NLOC strictly above
RS_PARAM_THRESHOLD=5       # flag functions with parameter count strictly above
RS_CCN_THRESHOLD=15        # flag functions with lizard CCN strictly above
RS_EXTS=""                 # comma list, e.g. "go,py,sh" (file-format filter)
RS_LANGS=""                # comma list of lizard languages, e.g. "python,go"
RS_OUTPUT_DIR=""           # where report documents are written
RS_PARALLEL=1              # run both passes concurrently in `all` mode
RS_WRITE_REPORT=1          # write report documents to disk
RS_FAIL_ON_FINDINGS=0      # exit 3 when any file/function is flagged
RS_QUIET=0
RS_EXTRA_EXCLUDE_DIRS=()

RS_SCC_BIN=""
RS_LIZARD_BIN=""
RS_IGNORE_DIRS=()

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

# --- usage --------------------------------------------------------------------
rs_usage() {
    cat <<'EOF'
Usage:
  agent-kit refactor-scan [complexity|nloc|all] [FOLDER] [options]

Modes:
  complexity   Rank files by scc cyclomatic complexity; flag files over the
               --complexity-threshold (default 15).
  nloc         Measure per-function NLOC with lizard; flag functions over the
               --nloc-threshold (default 40).
  all          Run both passes (in parallel) and join the results. (default)

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
  --ext LIST                Only analyze these file extensions, e.g. go,py,sh.
  --lang LIST              lizard language filter, e.g. python,go,cpp.
  --exclude-dir NAME        Extra directory name to ignore (repeatable).
  --scc-format FMT          Report-document format for the complexity pass:
                            tabular, wide, json, json2, csv, csv-stream,
                            cloc-yaml, html, html-table, sql, sql-insert,
                            openmetrics (default csv).
  --output-dir DIR          Where report documents are written
                            (default: ./.ai-logs/refactor-scan).
  --no-report               Do not write report documents to disk.
  --no-parallel             Run passes sequentially in `all` mode.
  --fail-on-findings        Exit 3 when any file or function is flagged.
  --ai                      Emit a machine-readable JSON envelope.
  --human                   Emit human CSV/table output (default).
  --quiet                   Suppress progress logs on stderr.
  --help                    Show this help.

Ignore rules:
  Dot-directories (.git, .github, .claude, ...) are always skipped, together
  with the shared source-exclude list (node_modules, vendor, dist, build,
  coverage, target, ...) reused from share/config/source-exclude-dirs.txt.

Examples:
  agent-kit refactor-scan                       # scan the repo, both passes
  agent-kit refactor-scan complexity src --ext go --scc-format json
  agent-kit refactor-scan nloc . --nloc-threshold 60 --lang python
  agent-kit refactor-scan all . --ai --fail-on-findings
EOF
}

# --- argument parsing ---------------------------------------------------------
rs_parse_args() {
    local positional_folder_set=0
    while (($# > 0)); do
        case "$1" in
            complexity | nloc | all)
                RS_MODE="$1"
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
    rs_valid_scc_format "$RS_SCC_FORMAT" || rs_die "unsupported --scc-format '$RS_SCC_FORMAT' (see --help)"

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
    local -a args=(--by-file --format json --no-cocomo --sort complexity
        --exclude-dir "$(rs_ignore_dirs_csv)" --not-match '(^|/)\.[^/]+/')
    [[ -n "$RS_EXTS" ]] && args+=(--include-ext "$RS_EXTS")

    # Scan from inside the folder so paths are relative and directory excludes
    # never over-match an absolute path prefix (e.g. a scan root under /tmp).
    scc_json="$(cd "$RS_FOLDER" && "$RS_SCC_BIN" "${args[@]}" -- . 2>/dev/null)" || rc=$?
    ((rc == 0)) || {
        printf '[]\n'
        return 0
    }
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
    local dest
    dest="$RS_OUTPUT_DIR/complexity-report.$(rs_report_ext "$RS_SCC_FORMAT")"
    local -a args=(--by-file --format "$RS_SCC_FORMAT" --no-cocomo --sort complexity
        --exclude-dir "$(rs_ignore_dirs_csv)" --not-match '(^|/)\.[^/]+/')
    [[ -n "$RS_EXTS" ]] && args+=(--include-ext "$RS_EXTS")
    if (cd "$RS_FOLDER" && "$RS_SCC_BIN" "${args[@]}" --output "$dest" -- .) >/dev/null 2>&1; then
        printf '%s' "$dest"
    else
        printf ''
    fi
}

# --- NLOC pass (lizard) -------------------------------------------------------
# Writes a compact JSON array of flagged functions to stdout.
rs_nloc_flagged_json() {
    local out rc=0 lang
    local -a args=(-w
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

    # Scan from inside the folder ('.') so glob excludes match relative paths and
    # never over-match an absolute prefix (e.g. a scan root under /tmp/...).
    out="$(cd "$RS_FOLDER" && "$RS_LIZARD_BIN" "${args[@]}" . 2>/dev/null)" || rc=$?
    # lizard exits non-zero when warnings exist; that is expected here.

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
    if (cd "$RS_FOLDER" && "$RS_LIZARD_BIN" "${args[@]}" .) >"$dest" 2>/dev/null; then
        printf '%s' "$dest"
    else
        # lizard exits non-zero when warnings are present; the file is still valid.
        [[ -s "$dest" ]] && printf '%s' "$dest" || printf ''
    fi
}

# --- output rendering ---------------------------------------------------------
rs_render_human() {
    local complexity_json="$1" nloc_json="$2" complexity_report="$3" nloc_report="$4"
    local n_files n_funcs

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
}

rs_render_ai() {
    local complexity_json="$1" nloc_json="$2" complexity_report="$3" nloc_report="$4"
    # Emit the machine-readable envelope directly (schema/status/tool/content/
    # warnings/errors/meta) so the content object is preserved verbatim.
    jq -n \
        --arg mode "$RS_MODE" \
        --arg folder "$RS_FOLDER" \
        --argjson complexity_threshold "$RS_COMPLEXITY_THRESHOLD" \
        --argjson nloc_threshold "$RS_NLOC_THRESHOLD" \
        --argjson param_threshold "$RS_PARAM_THRESHOLD" \
        --argjson ccn_threshold "$RS_CCN_THRESHOLD" \
        --argjson complexity "$complexity_json" \
        --argjson nloc "$nloc_json" \
        --arg complexity_report "$complexity_report" \
        --arg nloc_report "$nloc_report" \
        '{
            schema: 1,
            status: "ok",
            tool: "refactor-scan",
            content: {
                mode: $mode,
                folder: $folder,
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
                    flagged_count: ($nloc | length),
                    report: (if $nloc_report == "" then null else $nloc_report end),
                    functions: $nloc
                },
                flagged_total: (($complexity | length) + ($nloc | length))
            },
            warnings: [],
            errors: [],
            meta: { elapsed_ms: 0, truncated: false }
        }'
}

# --- orchestration ------------------------------------------------------------
refactor_scan_main() {
    rs_parse_args "$@"
    rs_resolve_folder
    rs_load_ignore_dirs
    rs_ensure_output_dir

    rs_need_bin jq
    RS_SCC_BIN="$(command -v scc || true)"
    RS_LIZARD_BIN="$(command -v lizard || true)"

    local complexity_json='[]' nloc_json='[]'
    local complexity_report='' nloc_report=''
    local run_complexity=0 run_nloc=0
    [[ "$RS_MODE" == "complexity" || "$RS_MODE" == "all" ]] && run_complexity=1
    [[ "$RS_MODE" == "nloc" || "$RS_MODE" == "all" ]] && run_nloc=1

    ((run_complexity)) && [[ -z "$RS_SCC_BIN" ]] && rs_die "required binary 'scc' not found (install it and retry)"
    ((run_nloc)) && [[ -z "$RS_LIZARD_BIN" ]] && rs_die "required binary 'lizard' not found (install it and retry)"

    local tmp
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/refactor-scan.XXXXXX")" || rs_die "cannot create temp dir"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" EXIT

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
    fi

    [[ -n "$complexity_json" ]] || complexity_json='[]'
    [[ -n "$nloc_json" ]] || nloc_json='[]'

    if [[ "$RS_OUTPUT_FMT" == "ai" ]]; then
        rs_render_ai "$complexity_json" "$nloc_json" "$complexity_report" "$nloc_report"
    else
        rs_render_human "$complexity_json" "$nloc_json" "$complexity_report" "$nloc_report"
    fi

    if ((RS_FAIL_ON_FINDINGS)); then
        local total
        total="$(jq -n --argjson a "$complexity_json" --argjson b "$nloc_json" '($a|length)+($b|length)' 2>/dev/null || printf '0')"
        ((total > 0)) && exit 3
    fi
    return 0
}
