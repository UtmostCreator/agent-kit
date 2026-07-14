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

pass() { PASS=$((PASS + 1)); printf '  \033[0;32m✓\033[0m %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[0;31m✗\033[0m %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf '  \033[0;33m⊘\033[0m %s (skipped: %s)\n' "$1" "$2"; }

# run_test NAME CMD... : succeed when CMD exits 0.
run_test() {
    local name="$1"; shift; local rc=0
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

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d  Skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
((FAIL == 0)) && printf '\033[0;32mPASSED\033[0m\n' || { printf '\033[0;31mFAILED\033[0m\n'; exit 1; }
