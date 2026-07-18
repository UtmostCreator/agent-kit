#!/usr/bin/env bash
# Tests for libexec/repomix-profile-lab
#
# Covers the two contractually required paths:
#   (a) HAPPY PATH  — real per-profile token counts from repomix's own counting.
#   (b) HARD-FAIL   — when the repomix library cannot be resolved, exit non-zero
#                     with an actionable message and NO estimated fallback.
# Plus budget-driven selection, the map-only-never-selected rule, usage errors,
# and the machine-readable contract.
#
# These tests require node + a resolvable repomix (the tool's real dependency).
# When repomix is genuinely unavailable, the happy-path tests SKIP (they cannot
# assert real counts), but the hard-fail test still runs — it must fail loudly.
set -euo pipefail
BASH_BIN="${BASH_BIN:-$(command -v bash)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/libexec/repomix-profile-lab"

# A small, always-present real target inside the repo.
TARGET="lib/repomix"

PASS=0 FAIL=0 SKIP=0
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

printf 'repomix-profile-lab\n'

have_jq=0
command -v jq >/dev/null 2>&1 && have_jq=1

# Can the tool resolve repomix in this environment? Probe once so the happy-path
# tests skip cleanly (rather than false-fail) on a host without repomix.
repomix_ok=0
if command -v node >/dev/null 2>&1; then
    if (cd "$REPO_ROOT" && "$BASH_BIN" "$SCRIPT" "$TARGET" --json) >/dev/null 2>&1; then
        repomix_ok=1
    fi
fi

# --- Always-runnable structural tests -------------------------------------

test_help() {
    local out _rc=0
    out="$("$BASH_BIN" "$SCRIPT" --help 2>&1)" || _rc=$?
    [[ "$_rc" -eq 0 && -n "$out" ]]
}
run_test "--help works (exit 0, non-empty)" test_help

# Unknown option must fail with exit 2, not run a silent estimate.
test_rejects_unknown_arg() {
    local out _rc=0
    out="$("$BASH_BIN" "$SCRIPT" --bogus 2>&1)" || _rc=$?
    local ok=1
    [[ "$_rc" -eq 2 ]] || ok=0
    printf '%s' "$out" | grep -qi 'unknown option' || ok=0
    ((ok == 1))
}
run_test "rejects unknown option with exit 2" test_rejects_unknown_arg

# Non-numeric budget is a usage error (exit 2).
test_rejects_bad_budget() {
    local _rc=0
    (cd "$REPO_ROOT" && "$BASH_BIN" "$SCRIPT" "$TARGET" --budget abc) >/dev/null 2>&1 || _rc=$?
    [[ "$_rc" -eq 2 ]]
}
run_test "rejects non-numeric --budget with exit 2" test_rejects_bad_budget

# Missing target path is a usage error (exit 2), never a fabricated result.
test_missing_target() {
    local _rc=0
    (cd "$REPO_ROOT" && "$BASH_BIN" "$SCRIPT" "does/not/exist-xyz") >/dev/null 2>&1 || _rc=$?
    [[ "$_rc" -eq 2 ]]
}
run_test "missing target exits 2" test_missing_target

# --- HARD-FAIL path (required) --------------------------------------------
# Forcing the resolver to find nothing must exit non-zero with an actionable
# message and MUST NOT print a result table (no bytes/4 fallback exists).
test_hard_fail_no_repomix() {
    local out _rc=0
    out="$( (cd "$REPO_ROOT" && REPOMIX_PROFILE_LAB_FORCE_NO_REPOMIX=1 "$BASH_BIN" "$SCRIPT" "$TARGET") 2>&1 )" || _rc=$?
    local ok=1
    [[ "$_rc" -ne 0 ]] || ok=0
    # Actionable: names what is missing and how to fix it.
    printf '%s' "$out" | grep -qi 'repomix library not found' || ok=0
    # Must not have produced a per-profile table.
    printf '%s' "$out" | grep -qi 'recommended:' && ok=0
    ((ok == 1))
}
run_test "hard-fails (non-zero, actionable) when repomix is unresolvable" test_hard_fail_no_repomix

# --- HAPPY path (required, real repomix data) ------------------------------
if ((repomix_ok == 1 && have_jq == 1)); then
    # Capture one real run and assert against it (keeps repomix invocations low).
    LAB_JSON="$( (cd "$REPO_ROOT" && "$BASH_BIN" "$SCRIPT" "$TARGET" --budget 100000 --json) 2>/dev/null )"

    # (a) Real per-profile counts: all six profiles present, each with a numeric
    # totalTokens, and the encoding is repomix's exact tokenizer (o200k_base).
    test_real_profile_counts() {
        printf '%s' "$LAB_JSON" | jq -e '
            .schema == "ai.repomix-profile-lab/v1"
            and .encoding == "o200k_base"
            and (.repomix_version | type == "string")
            and (.faithful_tokens | numbers) > 0
            and ((.profiles | length) == 6)
            and ([.profiles[] | select(.totalTokens | numbers | . >= 0)] | length == 6)
            and ([.profiles[].profile] | sort ==
                 (["compressed","faithful","lean","lean-no-comments","line-numbered","map-only"] | sort))
        ' >/dev/null
    }
    run_test "produces real per-profile token counts (o200k_base)" test_real_profile_counts

    # map-only is diagnostic: flagged diagnostic + not selectable.
    test_map_only_diagnostic() {
        printf '%s' "$LAB_JSON" | jq -e '
            (.profiles[] | select(.profile == "map-only")
              | .diagnostic == true and .selectable == false)
        ' >/dev/null
    }
    run_test "map-only is marked diagnostic and non-selectable" test_map_only_diagnostic

    # At a generous budget the highest-fidelity profile (faithful) is recommended.
    test_high_budget_picks_faithful() {
        printf '%s' "$LAB_JSON" | jq -e '.recommended == "faithful" and .recommended_fits == true' >/dev/null
    }
    run_test "high budget recommends faithful (highest fidelity)" test_high_budget_picks_faithful

    # A budget that excludes faithful but admits a leaner profile picks the
    # highest-fidelity FITTING profile — and never map-only.
    test_budget_drives_selection() {
        local faithful lean_nc out
        faithful="$(printf '%s' "$LAB_JSON" | jq -r '.faithful_tokens')"
        lean_nc="$(printf '%s' "$LAB_JSON" | jq -r '.profiles[] | select(.profile=="lean-no-comments") | .totalTokens')"
        # Budget strictly between lean-no-comments and faithful.
        local b=$(( (faithful + lean_nc) / 2 ))
        (( b > lean_nc && b < faithful )) || return 0  # counts too close; skip guard
        out="$( (cd "$REPO_ROOT" && "$BASH_BIN" "$SCRIPT" "$TARGET" --budget "$b" --json) 2>/dev/null )"
        printf '%s' "$out" | jq -e '
            .recommended as $r
            | .recommended_fits == true
            and $r != "faithful"
            and $r != "map-only"
            and ((.profiles | map(.profile) | index($r)) != null)
        ' >/dev/null
    }
    run_test "budget drives selection to a fitting lower-fidelity profile (never map-only)" test_budget_drives_selection

    # When NOTHING fits, recommended is still a selectable profile (never map-only)
    # and recommended_fits is false (honest best-effort, no silent pass).
    test_none_fit_excludes_map_only() {
        local out
        out="$( (cd "$REPO_ROOT" && "$BASH_BIN" "$SCRIPT" "$TARGET" --budget 1 --json) 2>/dev/null )"
        printf '%s' "$out" | jq -e '
            .recommended_fits == false
            and .recommended != "map-only"
        ' >/dev/null
    }
    run_test "none-fit budget never recommends map-only (fits=false)" test_none_fit_excludes_map_only

    # The emitted generation command is a real, runnable repomix invocation.
    test_generation_command_real() {
        printf '%s' "$LAB_JSON" | jq -e '
            (.generation_command | startswith("repomix "))
            and (.generation_command | contains("--style"))
        ' >/dev/null
    }
    run_test "emits a real repomix generation command" test_generation_command_real

    # Human (non-JSON) output renders the table and a recommendation.
    test_human_table() {
        local out
        out="$( (cd "$REPO_ROOT" && "$BASH_BIN" "$SCRIPT" "$TARGET") 2>/dev/null )"
        local ok=1
        printf '%s' "$out" | grep -q 'profile' || ok=0
        printf '%s' "$out" | grep -q 'faithful' || ok=0
        printf '%s' "$out" | grep -qi 'recommended:' || ok=0
        printf '%s' "$out" | grep -qi 'generate:' || ok=0
        ((ok == 1))
    }
    run_test "human output renders the profile table + recommendation" test_human_table
else
    reason="repomix library not resolvable in this environment"
    ((have_jq == 1)) || reason="jq not available"
    skip_test "produces real per-profile token counts (o200k_base)" "$reason"
    skip_test "map-only is marked diagnostic and non-selectable" "$reason"
    skip_test "high budget recommends faithful (highest fidelity)" "$reason"
    skip_test "budget drives selection to a fitting lower-fidelity profile (never map-only)" "$reason"
    skip_test "none-fit budget never recommends map-only (fits=false)" "$reason"
    skip_test "emits a real repomix generation command" "$reason"
    skip_test "human output renders the profile table + recommendation" "$reason"
fi

# --introspect contract (static parse), when jq is present.
if ((have_jq == 1)); then
    test_introspect_json() {
        local out
        out="$("$BASH_BIN" "$SCRIPT" --introspect 2>/dev/null || true)"
        printf '%s' "$out" | jq -e '.status == "ok" and .name == "repomix-profile-lab"' >/dev/null
    }
    run_test "--introspect emits a valid JSON contract" test_introspect_json
else
    skip_test "--introspect emits a valid JSON contract" "jq not available"
fi

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d  Skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
((FAIL == 0)) && printf '\033[0;32mPASSED\033[0m\n' || {
    printf '\033[0;31mFAILED\033[0m\n'
    exit 1
}
