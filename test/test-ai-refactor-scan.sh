#!/usr/bin/env bash
# Tests for libexec/ai-refactor-scan — the scc-complexity + lizard-NLOC refactor scanner.
#
# The scanner is the main entry point for "what should we refactor next", so the
# guarantees here are strict: correct flagging at the documented thresholds,
# honoring the shared ignore list (dot-dirs, node_modules, ...), file-format
# filtering, a valid report document per scc format, a well-formed AI envelope,
# and the CI-gating exit code. Passes that need scc/lizard/jq are skipped (not
# faked) when a binary is absent.
set -euo pipefail
BASH_BIN="${BASH_BIN:-$(command -v bash)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/libexec/ai-refactor-scan"
cd "$REPO_ROOT"

PASS=0 FAIL=0 SKIP=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass() {
    PASS=$((PASS + 1))
    printf '  \033[0;32m✓\033[0m %s\n' "$1"
}
fail() {
    FAIL=$((FAIL + 1))
    printf '  \033[0;31m✗\033[0m %s\n' "$1"
}
skip() {
    SKIP=$((SKIP + 1))
    printf '  \033[0;33m⊘\033[0m %s (skipped: %s)\n' "$1" "$2"
}

# run_test NAME CMD... : succeed when CMD exits 0.
run_test() {
    local name="$1"
    shift
    local rc=0
    "$@" >/dev/null 2>&1 || rc=$?
    ((rc == 0)) && pass "$name" || fail "$name"
}

have() { command -v "$1" >/dev/null 2>&1; }

scan() { "$BASH_BIN" "$SCRIPT" "$@"; }

# --- fixture ------------------------------------------------------------------
# A git repo with: one high-complexity file, one long function, plus a
# high-complexity file inside node_modules and a dot-directory that MUST be
# ignored by the shared ignore list.
FIX="$TMP/proj"
mkdir -p "$FIX/src" "$FIX/node_modules/pkg" "$FIX/.hidden"

gen_complex() { # path funcname -> file whose scc complexity is well over 15
    local path="$1" name="$2" i
    {
        printf 'package main\n\nfunc %s(x int) int {\n' "$name"
        for i in $(seq 1 25); do printf '\tif x == %d {\n\t\treturn %d\n\t}\n' "$i" "$i"; done
        printf '\treturn 0\n}\n'
    } >"$path"
}

gen_long() { # path funcname -> file whose function NLOC is well over 40
    local path="$1" name="$2" i
    {
        printf 'package main\n\nfunc %s() int {\n\tt := 0\n' "$name"
        for i in $(seq 1 60); do printf '\tt += %d\n' "$i"; done
        printf '\treturn t\n}\n'
    } >"$path"
}

gen_complex "$FIX/src/complex.go" "Complex"
gen_long "$FIX/src/long.go" "Longwinded"
# A short function taking many parameters (drives the --param-threshold flag).
printf 'package main\n\nfunc Wide(a, b, c, d, e, f, g int) int { return a+b+c+d+e+f+g }\n' >"$FIX/src/wide.go"
gen_complex "$FIX/node_modules/pkg/vendored.go" "Vendored"
gen_complex "$FIX/.hidden/secret.go" "Secret"
# A short, simple file that must never be flagged.
printf 'package main\n\nfunc Tiny() int { return 1 }\n' >"$FIX/src/tiny.go"

# --- comment-marker fixtures (for the `comments` pass) ------------------------
# Real markers in comments MUST be flagged with exact line numbers; markers that
# only appear inside string literals MUST be ignored (string-aware). Markers in
# ignored dirs (node_modules, dot-dirs) MUST NOT surface.
printf '#!/usr/bin/env bash\nx=1  # TODO real one\nu="# TODO inside a string"\necho "$x" # FIXME leak\n' >"$FIX/src/markers.sh"
# Line 1: HACK in a // comment following a URL string (URL must not confuse it).
# Line 2: a /* TODO */ inside a string literal -> ignored.
# Lines 3-5: a block comment whose FIXME sits on line 4 (line-number precision).
printf 'const url = "https://example.com"; // real HACK here\nconst s = "/* TODO not a comment */";\n/* block\n * FIXME later line\n */\n' >"$FIX/src/markers.js"
printf '// TODO vendored must be ignored\n' >"$FIX/node_modules/pkg/marker.js"
printf '// TODO hidden must be ignored\n' >"$FIX/.hidden/marker.js"

if have git; then
    (cd "$FIX" && git init -q && git add -A &&
        git -c user.email=t@t -c user.name=t commit -qm init) >/dev/null 2>&1 || true
fi

# A plain (non-git) directory with one high-complexity file: proves scanning
# works outside a git repo.
PLAIN="$TMP/plain"
mkdir -p "$PLAIN"
gen_complex "$PLAIN/messy.go" "Messy"

# A directory containing no analyzable code (only docs): proves a clean scan
# yields zero findings and a still-valid envelope/exit code.
EMPTY="$TMP/empty"
mkdir -p "$EMPTY"
printf '# nothing to refactor here\n' >"$EMPTY/README.md"

# A directory with an extra ignore target to exercise --exclude-dir.
CUSTOM="$TMP/custom"
mkdir -p "$CUSTOM/keepme" "$CUSTOM/skipme"
gen_complex "$CUSTOM/keepme/a.go" "KeepA"
gen_complex "$CUSTOM/skipme/b.go" "SkipB"

printf 'ai-refactor-scan\n'

# --- contract surface (no external binaries needed) ---------------------------
test_help() { scan --help 2>&1 | grep -qi 'Usage:'; }
run_test "--help prints usage" test_help

test_introspect() { scan --introspect 2>&1 | grep -q '"tool"'; }
run_test "--introspect emits JSON contract" test_introspect

test_unknown_opt() { ! scan --nonesuch 2>/dev/null; }
run_test "unknown option fails" test_unknown_opt

test_bad_format() { ! scan complexity "$FIX" --scc-format bogus 2>/dev/null; }
run_test "invalid --scc-format is rejected" test_bad_format

test_bad_threshold() { ! scan complexity "$FIX" --complexity-threshold nope 2>/dev/null; }
run_test "non-numeric threshold is rejected" test_bad_threshold

test_missing_folder() { ! scan complexity "$TMP/does-not-exist" 2>/dev/null; }
run_test "missing folder fails" test_missing_folder

test_help_short_flag() { scan -h 2>&1 | grep -qi 'Usage:'; }
run_test "-h prints usage" test_help_short_flag

test_extra_positional() { ! scan complexity "$FIX" extra-arg 2>/dev/null; }
run_test "a second positional argument is rejected" test_extra_positional

# --introspect must advertise the mode surface machine-readably (not an empty []).
test_introspect_modes() {
    scan --introspect 2>/dev/null |
        jq -e '.modes as $m | (($m|type)=="array") and ($m|index("complexity")) and ($m|index("nloc")) and ($m|index("comments")) and ($m|index("all"))' >/dev/null
}
run_test "--introspect reports complexity/nloc/comments/all in modes[]" test_introspect_modes

# A mistyped mode (bareword, not a directory) is diagnosed as an unknown mode,
# not silently reinterpreted as the FOLDER and failed later as "folder not found".
test_unknown_mode() {
    local err
    err="$(scan bogusmode 2>&1)" && return 1
    grep -q "unknown mode 'bogusmode'" <<<"$err"
}
run_test "a mistyped mode is diagnosed as an unknown mode" test_unknown_mode

# Even with a valid trailing folder, the leading bad mode is named correctly.
test_unknown_mode_with_folder() {
    local err
    err="$(scan bogusmode "$FIX" 2>&1)" && return 1
    grep -q "unknown mode 'bogusmode'" <<<"$err"
}
run_test "unknown mode is named even with a trailing folder" test_unknown_mode_with_folder

# A path-like first positional stays a folder error (genuine folder typos are
# not misattributed to the mode enum).
test_pathlike_stays_folder_error() {
    local err
    err="$(scan "$TMP/no/such/dir" 2>&1)" && return 1
    grep -q 'folder not found:' <<<"$err"
}
run_test "a path-like typo still reports folder not found" test_pathlike_stays_folder_error

# The exit-code contract is documented in --help so callers can branch on status.
test_help_exit_codes() {
    scan --help 2>&1 | grep -q 'Exit codes:'
}
run_test "--help documents the exit-code contract" test_help_exit_codes

# --- complexity pass (scc) ----------------------------------------------------
if have scc && have jq; then
    OUT="$TMP/out"

    test_complexity_flags() {
        scan complexity "$FIX" --output-dir "$OUT/c1" --quiet --ai |
            jq -e '.content.complexity.files | map(.path) | any(test("src/complex.go$"))' >/dev/null
    }
    run_test "complexity flags the over-threshold file" test_complexity_flags

    test_complexity_not_tiny() {
        # tiny.go (complexity 1) must not be flagged.
        ! scan complexity "$FIX" --output-dir "$OUT/c2" --quiet --ai |
            jq -e '.content.complexity.files | map(.path) | any(test("tiny.go$"))' >/dev/null
    }
    run_test "complexity ignores the simple file" test_complexity_not_tiny

    test_ignore_node_modules() {
        ! scan complexity "$FIX" --output-dir "$OUT/c3" --quiet --ai |
            jq -e '.content.complexity.files | map(.path) | any(test("node_modules"))' >/dev/null
    }
    run_test "shared ignore list drops node_modules" test_ignore_node_modules

    test_ignore_dotdir() {
        ! scan complexity "$FIX" --output-dir "$OUT/c4" --quiet --ai |
            jq -e '.content.complexity.files | map(.path) | any(test("hidden|secret"))' >/dev/null
    }
    run_test "dot-directories are ignored" test_ignore_dotdir

    test_threshold_override() {
        # With an impossibly high threshold, nothing is flagged.
        local n
        n="$(scan complexity "$FIX" --complexity-threshold 100000 --no-report --quiet --ai |
            jq -r '.content.complexity.flagged_count')"
        [[ "$n" == "0" ]]
    }
    run_test "complexity threshold is user-selectable" test_threshold_override

    test_ext_filter() {
        # Only .py requested but the fixture is all Go -> nothing flagged.
        local n
        n="$(scan complexity "$FIX" --ext py --no-report --quiet --ai |
            jq -r '.content.complexity.flagged_count')"
        [[ "$n" == "0" ]]
    }
    run_test "file-format (--ext) filter is honored" test_ext_filter

    test_csv_report() {
        scan complexity "$FIX" --output-dir "$OUT/c5" --scc-format csv --quiet >/dev/null
        [[ -s "$OUT/c5/complexity-report.csv" ]] &&
            head -1 "$OUT/c5/complexity-report.csv" | grep -qi 'Language'
    }
    run_test "csv report document is written" test_csv_report

    test_json_report() {
        scan complexity "$FIX" --output-dir "$OUT/c6" --scc-format json --quiet >/dev/null
        [[ -s "$OUT/c6/complexity-report.json" ]] &&
            jq -e 'type=="array"' "$OUT/c6/complexity-report.json" >/dev/null
    }
    run_test "json report document is valid JSON" test_json_report

    test_default_folder_is_git_root() {
        # No folder argument, invoked from a subdir -> resolves to the fixture root.
        local got
        got="$(cd "$FIX/src" && "$BASH_BIN" "$SCRIPT" complexity --no-report --quiet --ai |
            jq -r '.content.folder')"
        [[ "$got" == "$FIX" ]]
    }
    run_test "empty folder resolves to the git toplevel" test_default_folder_is_git_root

    test_fail_on_findings() {
        scan complexity "$FIX" --no-report --quiet --fail-on-findings >/dev/null 2>&1
        local rc=$?
        ((rc == 3))
    }
    run_test "--fail-on-findings exits 3 when files are flagged" test_fail_on_findings

    test_no_fail_when_clean() {
        # High threshold -> no findings -> exit 0 even with --fail-on-findings.
        scan complexity "$FIX" --complexity-threshold 100000 --no-report --quiet --fail-on-findings >/dev/null 2>&1
    }
    run_test "--fail-on-findings exits 0 when nothing is flagged" test_no_fail_when_clean

    test_folder_option_form() {
        # --folder must behave like the positional FOLDER argument.
        scan complexity --folder "$FIX" --no-report --quiet --ai |
            jq -e '.content.complexity.files | map(.path) | any(test("src/complex.go$"))' >/dev/null
    }
    run_test "--folder option equals the positional folder" test_folder_option_form

    test_threshold_equals_form() {
        local n
        n="$(scan complexity "$FIX" --complexity-threshold=100000 --no-report --quiet --ai |
            jq -r '.content.complexity.flagged_count')"
        [[ "$n" == "0" ]]
    }
    run_test "--opt=value form is parsed" test_threshold_equals_form

    test_multi_ext_filter() {
        # go,py requested; the Go files must still be flagged.
        scan complexity "$FIX" --ext go,py --no-report --quiet --ai |
            jq -e '.content.complexity.flagged_count >= 1' >/dev/null
    }
    run_test "multi-value --ext keeps matching languages" test_multi_ext_filter

    test_custom_exclude_dir() {
        # skipme is excluded; keepme survives.
        local out
        out="$(scan complexity "$CUSTOM" --exclude-dir skipme --no-report --quiet --ai)"
        jq -e '.content.complexity.files | map(.path) | (any(test("keepme")) and (any(test("skipme"))|not))' <<<"$out" >/dev/null
    }
    run_test "--exclude-dir adds a custom ignore" test_custom_exclude_dir

    test_json2_report_extension() {
        scan complexity "$FIX" --output-dir "$OUT/c7" --scc-format json2 --quiet >/dev/null
        [[ -s "$OUT/c7/complexity-report.json" ]] &&
            jq -e '.' "$OUT/c7/complexity-report.json" >/dev/null
    }
    run_test "json2 report maps to a .json document" test_json2_report_extension

    test_non_git_folder() {
        # A plain directory (no git) must still be scannable.
        scan complexity "$PLAIN" --no-report --quiet --ai |
            jq -e '.content.complexity.files | map(.path) | any(test("messy.go$"))' >/dev/null
    }
    run_test "scans a non-git directory" test_non_git_folder

    test_empty_folder_clean() {
        # No analyzable code -> zero findings, valid envelope, exit 0.
        local out
        out="$(scan complexity "$EMPTY" --no-report --quiet --ai)"
        jq -e '.status=="ok" and .content.complexity.flagged_count==0' <<<"$out" >/dev/null
    }
    run_test "clean folder yields zero findings and a valid envelope" test_empty_folder_clean

    test_output_dir_autocreated() {
        # A not-yet-existing --output-dir must be created.
        local d="$OUT/made/up/path"
        [[ ! -d "$d" ]]
        scan complexity "$FIX" --output-dir "$d" --quiet >/dev/null
        [[ -d "$d" && -s "$d/complexity-report.csv" ]]
    }
    run_test "--output-dir is created when missing" test_output_dir_autocreated
else
    skip "complexity pass (scc/jq)" "scc or jq not installed"
fi

# --- NLOC pass (lizard) -------------------------------------------------------
if have lizard && have jq; then
    OUTN="$TMP/outn"

    test_nloc_flags() {
        scan nloc "$FIX" --output-dir "$OUTN/n1" --quiet --ai |
            jq -e '.content.nloc.functions | map(.function) | any(. == "Longwinded")' >/dev/null
    }
    run_test "nloc flags the over-length function" test_nloc_flags

    test_nloc_reports_nloc_value() {
        # The flagged function's NLOC must actually exceed the threshold.
        scan nloc "$FIX" --no-report --quiet --ai |
            jq -e '.content.nloc.functions | map(select(.function=="Longwinded")) | .[0].nloc > 40' >/dev/null
    }
    run_test "flagged function's NLOC exceeds the threshold" test_nloc_reports_nloc_value

    test_nloc_threshold_override() {
        # Raising the NLOC threshold drops the NLOC-driven function (Longwinded),
        # even though params/CCN-driven flags may remain.
        ! scan nloc "$FIX" --nloc-threshold 100000 --no-report --quiet --ai |
            jq -e '.content.nloc.functions | map(.function) | any(. == "Longwinded")' >/dev/null
    }
    run_test "nloc threshold is user-selectable" test_nloc_threshold_override

    test_nloc_report_written() {
        scan nloc "$FIX" --output-dir "$OUTN/n2" --quiet >/dev/null
        [[ -s "$OUTN/n2/nloc-report.txt" ]]
    }
    run_test "nloc report document is written" test_nloc_report_written

    test_nloc_ignores_node_modules() {
        ! scan nloc "$FIX" --no-report --quiet --ai |
            jq -e '.content.nloc.functions | map(.path) | any(test("node_modules"))' >/dev/null
    }
    run_test "nloc pass honors the ignore list" test_nloc_ignores_node_modules

    test_param_threshold_flags() {
        # Wide() has 7 params (> default 5) and few lines -> flagged for params.
        scan nloc "$FIX" --no-report --quiet --ai | jq -e '
            .content.nloc.functions
            | map(select(.function=="Wide"))
            | .[0].param > 5 and (.[0].reasons | index("params") != null)
        ' >/dev/null
    }
    run_test "functions over --param-threshold are flagged (default >5)" test_param_threshold_flags

    test_param_threshold_selectable() {
        # Raising the threshold above Wide's 7 params clears the params flag.
        ! scan nloc "$FIX" --param-threshold 10 --nloc-threshold 100000 --ccn-threshold 100000 \
            --no-report --quiet --ai |
            jq -e '.content.nloc.functions | map(.function) | any(. == "Wide")' >/dev/null
    }
    run_test "--param-threshold is user-selectable" test_param_threshold_selectable

    test_param_threshold_in_envelope() {
        scan nloc "$FIX" --param-threshold 3 --no-report --quiet --ai |
            jq -e '.content.nloc.param_threshold == 3' >/dev/null
    }
    run_test "param threshold is reported in the envelope" test_param_threshold_in_envelope

    test_nloc_lang_filter() {
        # Restricting to Go must still surface the long Go function.
        scan nloc "$FIX" --lang go --no-report --quiet --ai |
            jq -e '.content.nloc.functions | map(.function) | any(. == "Longwinded")' >/dev/null
    }
    run_test "nloc --lang filter is honored" test_nloc_lang_filter

    test_nloc_human_lists_function() {
        local out
        out="$(scan nloc "$FIX" --no-report --quiet 2>/dev/null)"
        grep -q 'Longwinded' <<<"$out"
    }
    run_test "human nloc output names the flagged function" test_nloc_human_lists_function

    test_nloc_human_no_report_exits_zero() {
        # Regression: in human nloc/all mode with --no-report the render function
        # ended on a `[[ -n "$nloc_report" ]] && printf ...` compound that returns
        # 1 when no report path exists, tripping set -e and exiting 1 on a clean,
        # successful scan. A successful human scan must exit 0.
        scan nloc "$FIX" --no-report --quiet >/dev/null 2>&1
    }
    run_test "human nloc --no-report exits 0 on success (regression: set -e trip)" test_nloc_human_no_report_exits_zero

    test_nloc_human_no_report_fail_on_findings() {
        # Same root cause: the set -e trip aborted before the fail-on-findings
        # block, so findings exited 1 instead of the documented 3.
        scan nloc "$FIX" --no-report --quiet --fail-on-findings >/dev/null 2>&1
        local rc=$?
        ((rc == 3))
    }
    run_test "human nloc --no-report --fail-on-findings exits 3 (regression)" test_nloc_human_no_report_fail_on_findings
else
    skip "nloc pass (lizard/jq)" "lizard or jq not installed"
fi

# --- combined / parallel ------------------------------------------------------
if have scc && have lizard && have jq; then
    test_all_envelope() {
        scan all "$FIX" --no-report --quiet --ai | jq -e '
            .status == "ok" and .tool == "refactor-scan" and
            .content.complexity.flagged_count >= 1 and
            .content.nloc.flagged_count >= 1 and
            .content.flagged_total == (.content.complexity.flagged_count + .content.nloc.flagged_count)
        ' >/dev/null
    }
    run_test "all mode emits a well-formed combined envelope" test_all_envelope

    test_parallel_equals_serial() {
        local p s
        p="$(scan all "$FIX" --no-report --quiet --ai | jq -r '.content.flagged_total')"
        s="$(scan all "$FIX" --no-parallel --no-report --quiet --ai | jq -r '.content.flagged_total')"
        [[ -n "$p" && "$p" == "$s" ]]
    }
    run_test "parallel and serial passes agree" test_parallel_equals_serial

    test_human_output() {
        # Capture first: piping into `grep -q` would SIGPIPE the scanner and
        # trip pipefail before the match is asserted.
        local out
        out="$(scan all "$FIX" --no-report --quiet 2>/dev/null)"
        grep -q 'refactor candidates' <<<"$out"
    }
    run_test "human output lists refactor candidates" test_human_output

    test_all_writes_both_reports() {
        local d="$TMP/out-all"
        scan all "$FIX" --output-dir "$d" --quiet >/dev/null
        [[ -s "$d/complexity-report.csv" && -s "$d/nloc-report.txt" ]]
    }
    run_test "all mode writes both report documents" test_all_writes_both_reports
else
    skip "combined all-mode pass" "scc, lizard or jq not installed"
fi

# --- comments pass (rg + pcre2, string-aware marker scan) ---------------------
if have rg && have jq; then
    OUTC="$TMP/outc"

    test_comments_flags_marker() {
        # The real `# TODO real one` (markers.sh:2) is flagged.
        scan comments "$FIX" --no-report --quiet --ai | jq -e '
            .content.comments.markers_found
            | any(.path|test("markers.sh$")) and
              any(.marker=="TODO" and .line==2 and (.path|test("markers.sh$")))
        ' >/dev/null
    }
    run_test "comments flags a real marker with its exact line" test_comments_flags_marker

    test_comments_ignores_string_marker() {
        # `u="# TODO inside a string"` is markers.sh line 3 -> must NOT be flagged
        # (string-aware). Likewise `"/* TODO not a comment */"` in markers.js:2.
        ! scan comments "$FIX" --no-report --quiet --ai | jq -e '
            .content.comments.markers_found
            | any((.path|test("markers.sh$")) and .line==3)
              or any((.path|test("markers.js$")) and .line==2)
        ' >/dev/null
    }
    run_test "comments ignores markers inside string literals" test_comments_ignores_string_marker

    test_comments_block_line_precision() {
        # FIXME sits on the 4th physical line of a block comment in markers.js.
        scan comments "$FIX" --no-report --quiet --ai | jq -e '
            .content.comments.markers_found
            | any(.marker=="FIXME" and .line==4 and (.path|test("markers.js$")))
        ' >/dev/null
    }
    run_test "comments reports the true line inside a block comment" test_comments_block_line_precision

    test_comments_ignores_node_modules() {
        ! scan comments "$FIX" --no-report --quiet --ai |
            jq -e '.content.comments.markers_found | map(.path) | any(test("node_modules"))' >/dev/null
    }
    run_test "comments honors the ignore list (node_modules)" test_comments_ignores_node_modules

    test_comments_ignores_dotdir() {
        ! scan comments "$FIX" --no-report --quiet --ai |
            jq -e '.content.comments.markers_found | map(.path) | any(test("hidden"))' >/dev/null
    }
    run_test "comments skips dot-directories" test_comments_ignores_dotdir

    test_comments_markers_flag() {
        # Restricting to HACK finds the // HACK line and drops TODO/FIXME.
        scan comments "$FIX" --markers HACK --no-report --quiet --ai | jq -e '
            (.content.comments.markers_found | all(.marker=="HACK")) and
            (.content.comments.flagged_count >= 1)
        ' >/dev/null
    }
    run_test "--markers restricts to the requested words" test_comments_markers_flag

    test_comments_marker_absent() {
        # A marker word that appears nowhere yields zero findings.
        local n
        n="$(scan comments "$FIX" --markers ZZZNOPE --no-report --quiet --ai |
            jq -r '.content.comments.flagged_count')"
        [[ "$n" == "0" ]]
    }
    run_test "an absent marker yields zero findings" test_comments_marker_absent

    test_comments_bad_markers() {
        # A markers value with no valid word is rejected.
        ! scan comments "$FIX" --markers '!!!' --no-report --quiet 2>/dev/null
    }
    run_test "invalid --markers is rejected" test_comments_bad_markers

    test_comments_human_lists() {
        local out
        out="$(scan comments "$FIX" --no-report --quiet 2>/dev/null)"
        grep -q 'TODO' <<<"$out" && grep -q 'marker(s) found' <<<"$out"
    }
    run_test "human comments output lists markers" test_comments_human_lists

    test_comments_report_written() {
        scan comments "$FIX" --output-dir "$OUTC/r1" --quiet >/dev/null
        [[ -s "$OUTC/r1/comments-report.csv" ]] &&
            head -1 "$OUTC/r1/comments-report.csv" | grep -qi 'location,marker'
    }
    run_test "comments report document is written (csv default)" test_comments_report_written

    test_comments_report_json() {
        # --report-format json writes a valid JSON array carrying locations.
        scan comments "$FIX" --report-format json --output-dir "$OUTC/rj" --quiet >/dev/null
        [[ -s "$OUTC/rj/comments-report.json" ]] &&
            jq -e 'type=="array" and (.[0]|has("location") and has("line_start") and has("line_end"))' \
                "$OUTC/rj/comments-report.json" >/dev/null
    }
    run_test "--report-format json exports a JSON report" test_comments_report_json

    test_comments_report_txt() {
        # --report-format txt writes location<TAB>marker<TAB>text lines.
        scan comments "$FIX" --report-format txt --output-dir "$OUTC/rt" --quiet >/dev/null
        [[ -s "$OUTC/rt/comments-report.txt" ]] &&
            grep -qE '^[^	]+:[0-9]+(-[0-9]+)?	[A-Za-z]' "$OUTC/rt/comments-report.txt"
    }
    run_test "--report-format txt exports a text report with locations" test_comments_report_txt

    test_comments_bad_report_format() {
        ! scan comments "$FIX" --report-format bogus --quiet 2>/dev/null
    }
    run_test "invalid --report-format is rejected" test_comments_bad_report_format

    test_comments_fail_on_findings() {
        scan comments "$FIX" --no-report --quiet --fail-on-findings >/dev/null 2>&1
        local rc=$?
        ((rc == 3))
    }
    run_test "comments --fail-on-findings exits 3 when markers exist" test_comments_fail_on_findings

    test_comments_ext_filter() {
        # Only .sh requested -> the .js HACK/FIXME must not appear.
        ! scan comments "$FIX" --ext sh --no-report --quiet --ai |
            jq -e '.content.comments.markers_found | map(.path) | any(test("\\.js$"))' >/dev/null
    }
    run_test "comments honors the --ext file filter" test_comments_ext_filter

    test_comments_envelope_shape() {
        scan comments "$FIX" --no-report --quiet --ai | jq -e '
            .status=="ok" and .tool=="refactor-scan" and
            (.content.comments.markers | type=="array") and
            (.content.comments.flagged_count >= 3) and
            (.content.flagged_total == .content.comments.flagged_count)
        ' >/dev/null
    }
    run_test "comments emits a well-formed envelope" test_comments_envelope_shape

    test_comments_location_block_range() {
        # A marker inside a block comment reports its exact line AND the block's
        # span as location "path:start-end". markers.js block is lines 3-5.
        scan comments "$FIX" --no-report --quiet --ai | jq -e '
            .content.comments.markers_found
            | any(.marker=="FIXME" and (.path|test("markers.js$"))
                  and .line==4 and .line_start==3 and .line_end==5
                  and (.location|test(":3-5$")))
        ' >/dev/null
    }
    run_test "block-comment markers carry a path:start-end location" test_comments_location_block_range

    test_comments_location_single_line() {
        # A single-line comment's location has no range dash (start==end).
        scan comments "$FIX" --no-report --quiet --ai | jq -e '
            .content.comments.markers_found
            | any(.marker=="TODO" and (.path|test("markers.sh$"))
                  and .line_start==.line_end and (.location|test(":[0-9]+$")))
        ' >/dev/null
    }
    run_test "single-line markers carry a path:line location" test_comments_location_single_line

    # --- --all inventory + --max-depth scoping --------------------------------
    test_comments_all_includes_nonmarker() {
        # The shebang on markers.sh:1 is a real comment with no marker word.
        # Default marker scan omits it; --all lists it (tagged "comment").
        scan comments "$FIX" --all --no-report --quiet --ai | jq -e '
            .content.comments.markers_found
            | any((.path|test("markers.sh$")) and .line_start==1 and .marker=="comment")
        ' >/dev/null &&
        ! scan comments "$FIX" --no-report --quiet --ai | jq -e '
            .content.comments.markers_found
            | any((.path|test("markers.sh$")) and .line==1)
        ' >/dev/null
    }
    run_test "--all lists comments with no marker word" test_comments_all_includes_nonmarker

    test_comments_all_block_is_one_record() {
        # In --all, a block comment collapses to ONE record spanning its lines.
        scan comments "$FIX" --all --no-report --quiet --ai | jq -e '
            (.content.comments.markers_found
             | map(select((.path|test("markers.js$")) and .line_start==3))
             | length) == 1
        ' >/dev/null
    }
    run_test "--all collapses a block comment to a single ranged record" test_comments_all_block_is_one_record

    test_comments_all_ge_markers() {
        # An inventory is never smaller than the marker-only subset.
        local a m
        a="$(scan comments "$FIX" --all --no-report --quiet --ai | jq -r '.content.comments.flagged_count')"
        m="$(scan comments "$FIX" --no-report --quiet --ai | jq -r '.content.comments.flagged_count')"
        [[ -n "$a" && -n "$m" ]] && ((a >= m && a > m))
    }
    run_test "--all inventory count exceeds the marker-only count" test_comments_all_ge_markers

    test_comments_maxdepth_toplevel_empty() {
        # $FIX has no code files at its top level -> depth 1 finds nothing.
        local n
        n="$(scan comments "$FIX" --all --max-depth 1 --no-report --quiet --ai |
            jq -r '.content.comments.flagged_count')"
        [[ "$n" == "0" ]]
    }
    run_test "--max-depth 1 scans the folder only (no recursion)" test_comments_maxdepth_toplevel_empty

    test_comments_maxdepth_dir_only() {
        # The marker files live directly in src/, so a depth-1 scan of src/ still
        # finds them: proves 'this directory only' works.
        scan comments "$FIX/src" --max-depth 1 --no-report --quiet --ai |
            jq -e '.content.comments.flagged_count >= 3' >/dev/null
    }
    run_test "--max-depth 1 on a directory finds that directory's markers" test_comments_maxdepth_dir_only

    test_comments_recursive_finds_subdir() {
        # Without --max-depth, scanning $FIX reaches src/ (recursive default).
        scan comments "$FIX" --no-report --quiet --ai |
            jq -e '.content.comments.markers_found | any(.path|test("src/"))' >/dev/null
    }
    run_test "recursive scan reaches nested directories by default" test_comments_recursive_finds_subdir

    test_comments_bad_maxdepth() {
        ! scan comments "$FIX" --max-depth nope --no-report --quiet 2>/dev/null
    }
    run_test "non-numeric --max-depth is rejected" test_comments_bad_maxdepth
else
    skip "comments pass (rg/jq)" "ripgrep or jq not installed"
fi

# --- changed-files scope (--changed / --files-from) + dupes mode -------------
# A git repo: one committed complex+long file, one UNTRACKED complex+long file
# with an identical long body (so it is both a "change" and a duplicate).
if have git && have jq; then
    SCOPE="$TMP/scope"
    mkdir -p "$SCOPE"
    gen_complex "$SCOPE/committed.go" "Committed"
    gen_long "$SCOPE/dupbase.go" "Dupbase"
    (cd "$SCOPE" && git init -q && git add -A &&
        git -c user.email=t@t -c user.name=t commit -qm init) >/dev/null 2>&1 || true
    gen_complex "$SCOPE/changed.go" "Changed"   # untracked, complex
    gen_long "$SCOPE/dupclone.go" "Dupclone"    # untracked, identical long body -> dup

    if have scc; then
        test_scope_changed_untracked() {
            # Only the untracked complex files are flagged; committed.go is not.
            scan complexity "$SCOPE" --changed untracked --no-report --quiet --ai | jq -e '
                ([.content.complexity.files[].path] | (index("changed.go") != null) and (index("committed.go") == null))
                and (.content.scope.scoped == true)
                and (.content.scope.selection == "untracked")' >/dev/null
        }
        run_test "complexity --changed untracked scans only untracked files" test_scope_changed_untracked

        test_scope_full_sees_committed() {
            # Without a scope, the committed complex file IS flagged.
            scan complexity "$SCOPE" --no-report --quiet --ai |
                jq -e '[.content.complexity.files[].path] | index("committed.go") != null' >/dev/null
        }
        run_test "full complexity scan still sees committed files" test_scope_full_sees_committed

        test_scope_files_from_stdin() {
            # A piped file list restricts the scan to exactly those files.
            printf 'changed.go\n' | (cd "$SCOPE" && "$BASH_BIN" "$SCRIPT" complexity --files-from - --no-report --quiet --ai) |
                jq -e '(.content.scope.scoped==true) and ([.content.complexity.files[].path]==["changed.go"])' >/dev/null
        }
        run_test "complexity --files-from - reads a piped file list" test_scope_files_from_stdin

        test_scope_empty_is_clean() {
            # Nothing is staged, so --changed staged resolves to zero files.
            scan complexity "$SCOPE" --changed staged --no-report --quiet --ai |
                jq -e '.content.scope.file_count==0 and .content.complexity.flagged_count==0 and .status=="ok"' >/dev/null
        }
        run_test "--changed with no matching files yields zero findings" test_scope_empty_is_clean

        test_scope_bad_selector() {
            ! scan complexity "$SCOPE" --changed=bogus --quiet 2>/dev/null
        }
        run_test "--changed rejects an invalid selector" test_scope_bad_selector
    else
        skip "changed-scope complexity (scc)" "scc not installed"
    fi

    if have lizard; then
        test_scope_nloc_changed() {
            # nloc --changed untracked flags the untracked long/complex functions,
            # not the committed ones.
            scan nloc "$SCOPE" --changed untracked --no-report --quiet --ai | jq -e '
                ([.content.nloc.functions[].path] | (any(test("dupclone.go$"))) and ((any(test("dupbase.go$")))|not))' >/dev/null
        }
        run_test "nloc --changed untracked scopes to untracked functions" test_scope_nloc_changed

        test_dupes_repo_wide() {
            # dupbase.go and dupclone.go share an identical body -> a clone block.
            scan dupes "$SCOPE" --no-report --quiet --ai | jq -e '
                (.content.dupes.rate > 0) and (.content.dupes.flagged_count >= 1) and
                (.content.dupes.blocks | any(.locations | length >= 2))' >/dev/null
        }
        run_test "dupes reports the repo-wide duplicate rate and blocks" test_dupes_repo_wide

        test_dupes_scoped_involves_changed() {
            # --changed keeps only blocks that touch a changed (untracked) file,
            # while still reporting the repo-wide rate.
            scan dupes "$SCOPE" --changed untracked --no-report --quiet --ai | jq -e '
                (.content.scope.scoped==true) and (.content.dupes.rate > 0) and
                (.content.dupes.blocks | all(.involves_changed))' >/dev/null
        }
        run_test "dupes --changed filters blocks to changed files" test_dupes_scoped_involves_changed

        test_dupes_report_json() {
            scan dupes "$SCOPE" --report-format json --output-dir "$TMP/duprep" --quiet >/dev/null
            [[ -s "$TMP/duprep/dupes-report.json" ]] &&
                jq -e 'has("rate") and has("blocks")' "$TMP/duprep/dupes-report.json" >/dev/null
        }
        run_test "dupes --report-format json exports a report" test_dupes_report_json
    else
        skip "changed-scope nloc + dupes (lizard)" "lizard not installed"
    fi
else
    skip "changed-files scope + dupes" "git or jq not installed"
fi

# --- P0: scanner-failure surfacing (false-green regression) --------------------
# A tool that crashes mid-run must NOT look like a clean scan: the AI envelope
# must report status!="ok" with a populated errors[], human mode must warn, and
# --strict must exit non-zero. A fake scc that exits 2 simulates a crash of an
# *installed* tool (missing tools are already hard-failed before any pass runs).
if have jq; then
    SHIM="$TMP/shim"
    mkdir -p "$SHIM"
    cat >"$SHIM/scc" <<'EOF'
#!/bin/sh
echo "scc: simulated internal error" >&2
exit 2
EOF
    chmod +x "$SHIM/scc"
    crash_scan() { PATH="$SHIM:$PATH" "$BASH_BIN" "$SCRIPT" "$@"; }

    test_crash_status() {
        crash_scan complexity "$FIX" --no-report --quiet --ai | jq -e '
            (.status != "ok") and
            (.errors | length >= 1) and
            (.errors[0].pass == "complexity") and
            (.errors[0].tool == "scc") and
            (.content.complexity.flagged_count == 0)' >/dev/null
    }
    run_test "crashed scc surfaces status+errors in AI envelope (not false-green)" test_crash_status

    test_crash_confidence() {
        crash_scan complexity "$FIX" --no-report --quiet --ai |
            jq -e '(.meta.scan_confidence | type == "number") and (.meta.scan_confidence < 100)' >/dev/null
    }
    run_test "crashed pass lowers scan_confidence below 100" test_crash_confidence

    test_crash_human_warns() {
        crash_scan complexity "$FIX" --no-report --quiet 2>&1 | grep -qiE 'warn|fail|incomplete'
    }
    run_test "crashed scc warns in human output" test_crash_human_warns

    test_crash_strict_exits() {
        local rc=0
        crash_scan complexity "$FIX" --no-report --quiet --strict --ai >/dev/null 2>&1 || rc=$?
        ((rc != 0))
    }
    run_test "--strict makes a crashed pass exit non-zero" test_crash_strict_exits

    # Guards against a false pass above where --strict is merely an unknown flag:
    # on a clean scan (real scc) --strict must be accepted and exit 0.
    if have scc; then
        test_strict_clean_ok() {
            local rc=0
            scan complexity "$FIX" --no-report --quiet --strict --ai >/dev/null 2>&1 || rc=$?
            ((rc == 0))
        }
        run_test "--strict is a valid flag (clean scan still exits 0)" test_strict_clean_ok
    fi

    test_crash_default_exit_zero() {
        # Backward-compat: without --strict the documented exit contract holds
        # (a swallowed tool error still exits 0); the truth now lives in status.
        local rc=0
        crash_scan complexity "$FIX" --no-report --quiet --ai >/dev/null 2>&1 || rc=$?
        ((rc == 0))
    }
    run_test "default (non-strict) keeps exit 0 on a crashed pass" test_crash_default_exit_zero

    test_elapsed_real() {
        crash_scan complexity "$FIX" --no-report --quiet --ai |
            jq -e '(.meta.elapsed_ms | type == "number") and (.meta.elapsed_ms > 0)' >/dev/null
    }
    run_test "meta.elapsed_ms is a real (non-zero) measured duration" test_elapsed_real
else
    skip "scanner-failure surfacing" "jq not installed"
fi

# --- token-count threshold (parsed-but-unused -> wired) ------------------------
if have lizard && have jq; then
    TOK="$TMP/tok"
    mkdir -p "$TOK"
    # A short (low-NLOC, low-CCN) function with many tokens via a long expression.
    {
        printf 'package main\nfunc Tokens() int {\n\treturn 1'
        for _i in $(seq 1 200); do printf ' + %d' "$_i"; done
        printf '\n}\n'
    } >"$TOK/tok.go"

    test_token_threshold_flags() {
        scan nloc "$TOK" --nloc-threshold 9999 --ccn-threshold 9999 --param-threshold 9999 \
            --token-threshold 50 --no-report --quiet --ai | jq -e '
            .content.nloc.functions | any(.reasons | index("token"))' >/dev/null
    }
    run_test "--token-threshold flags a high-token function on the token reason" test_token_threshold_flags

    test_token_default_off() {
        # Default (no --token-threshold) must not flag on tokens -> no behavior change.
        scan nloc "$TOK" --nloc-threshold 9999 --ccn-threshold 9999 --param-threshold 9999 \
            --no-report --quiet --ai | jq -e '
            .content.nloc.functions | all((.reasons | index("token")) | not)' >/dev/null
    }
    run_test "token flagging is opt-in (default off)" test_token_default_off
else
    skip "token-count threshold" "lizard or jq not installed"
fi

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d  Skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
((FAIL == 0)) && printf '\033[0;32mPASSED\033[0m\n' || {
    printf '\033[0;31mFAILED\033[0m\n'
    exit 1
}
