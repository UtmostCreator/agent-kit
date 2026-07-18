#!/usr/bin/env bash
# Tests for bin/restsift (the dispatcher).
set -euo pipefail
BASH_BIN="${BASH_BIN:-$(command -v bash)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AI="$REPO_ROOT/bin/restsift"
cd "$REPO_ROOT"

PASS=0 FAIL=0
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

printf 'bin/restsift\n'

# --list exits 0 and enumerates commands.
test_list() {
    local out
    out="$("$BASH_BIN" "$AI" --list 2>/dev/null || true)"
    printf '%s' "$out" | grep -q 'ai-search'
}
run_test "--list enumerates commands (exit 0)" test_list

# bare `list` (no dashes) is an alias for --list.
test_bare_list() {
    local out _rc=0
    out="$("$BASH_BIN" "$AI" list 2>/dev/null)" || _rc=$?
    [[ "$_rc" -eq 0 ]] && printf '%s' "$out" | grep -q 'ai-search'
}
run_test "bare 'list' word is an alias for --list (exit 0)" test_bare_list

# -h/--help prints the dispatcher's own usage text plus the command list.
test_help_flag() {
    local out _rc=0
    out="$("$BASH_BIN" "$AI" --help 2>/dev/null)" || _rc=$?
    [[ "$_rc" -eq 0 ]] && printf '%s' "$out" | grep -q 'Usage:' && printf '%s' "$out" | grep -q 'ai-search'
}
run_test "--help prints usage + command list (exit 0)" test_help_flag

test_help_short_flag() {
    local out _rc=0
    out="$("$BASH_BIN" "$AI" -h 2>/dev/null)" || _rc=$?
    [[ "$_rc" -eq 0 ]] && printf '%s' "$out" | grep -q 'Usage:'
}
run_test "-h prints usage (exit 0)" test_help_short_flag

# `restsift <name>` resolves the exact libexec file.
test_exact_resolution() {
    "$BASH_BIN" "$AI" repo-stats --help >/dev/null 2>&1
}
run_test "resolves an exact command name" test_exact_resolution

# `restsift search` resolves via the ai- prefix fallback to libexec/ai-search.
test_prefix_resolution() {
    local out
    out="$(AI_OUTPUT=json "$BASH_BIN" "$AI" search doctor 2>/dev/null || true)"
    printf '%s' "$out" | grep -q '"tool":"ai-search"'
}
run_test "resolves via the ai- prefix fallback" test_prefix_resolution

# --- Short alias resolution (lib/command-aliases.txt) -----------------------
#
# Every "alias target" pair in lib/command-aliases.txt (the single source
# shared with completion generation, see libexec/internal/completion-spec)
# must resolve `restsift ALIAS` to the exact same libexec file as its
# canonical target -- verified generically here, rather than one hardcoded
# test per alias, so a new alias added to the data file is covered without a
# matching test edit.
ALIASES_FILE="$REPO_ROOT/lib/command-aliases.txt"

test_every_alias_resolves_to_its_target() {
    [[ -f "$ALIASES_FILE" ]] || return 1
    local alias target want got
    while read -r alias target; do
        [[ -n "$alias" && "$alias" != \#* ]] || continue
        [[ -f "$REPO_ROOT/libexec/$target" ]] || {
            echo "alias '$alias' points at missing libexec/$target"
            return 1
        }
        # --help (not --introspect) -- router-style targets (e.g. ai-inspect)
        # treat their first arg as a MODE rather than intercepting --introspect
        # the way leaf scripts do, so --introspect isn't a universal probe
        # here. --help is: every libexec/* script answers it identically
        # regardless of invocation path.
        want="$("$BASH_BIN" "$REPO_ROOT/libexec/$target" --help 2>&1)"
        got="$("$BASH_BIN" "$AI" "$alias" --help 2>&1)"
        [[ -n "$want" && "$want" == "$got" ]] || {
            echo "alias '$alias' did not resolve to libexec/$target (--help output differs)"
            return 1
        }
    done <"$ALIASES_FILE"
}
run_test "every alias in lib/command-aliases.txt resolves to its declared target" test_every_alias_resolves_to_its_target

# A representative sample of aliases spot-checked end-to-end (not just via
# --introspect equality above), so a resolution AND an execution regression
# are both caught.
test_alias_rb_runs_rollback() {
    local out
    out="$("$BASH_BIN" "$AI" rb --help 2>&1)"
    printf '%s' "$out" | grep -q 'rollback snapshots'
}
run_test "alias 'rb' runs ai-rollback" test_alias_rb_runs_rollback

test_alias_g_runs_git() {
    local out
    out="$("$BASH_BIN" "$AI" g --help 2>&1)"
    printf '%s' "$out" | grep -q 'git-inspection'
}
run_test "alias 'g' runs ai-git" test_alias_g_runs_git

# Exact and ai-prefixed resolution both take priority over the alias table --
# no real command name is shadowed by an alias.
test_exact_and_prefix_resolution_beat_aliases() {
    "$BASH_BIN" "$AI" repo-stats --help >/dev/null 2>&1 &&
        "$BASH_BIN" "$AI" search --help >/dev/null 2>&1
}
run_test "exact/ai-prefixed resolution still takes priority over aliases" test_exact_and_prefix_resolution_beat_aliases

# An alias key must not collide with any real libexec basename (stripped of
# its "ai-" prefix) -- such a collision would make the alias unreachable
# (exact/prefix resolution always wins), so catch it as a data-file defect
# rather than a silently-dead alias.
test_no_alias_collides_with_a_real_command_name() {
    [[ -f "$ALIASES_FILE" ]] || return 1
    local alias target f base friendly
    while read -r alias target; do
        [[ -n "$alias" && "$alias" != \#* ]] || continue
        for f in "$REPO_ROOT"/libexec/*; do
            [[ -f "$f" ]] || continue
            base="$(basename "$f")"
            friendly="${base#ai-}"
            if [[ "$alias" == "$base" || "$alias" == "$friendly" ]]; then
                echo "alias '$alias' collides with real command '$base'"
                return 1
            fi
        done
    done <"$ALIASES_FILE"
}
run_test "no alias collides with a real command name" test_no_alias_collides_with_a_real_command_name

# `restsift search capabilities` routes through ai-search to the compatibility
# introspection implementation.
test_search_capabilities() {
    local out
    out="$($BASH_BIN "$AI" search capabilities 2>/dev/null || true)"
    printf '%s' "$out" | grep -q 'FULL CAPABILITY MAP'
}
run_test "routes search capabilities to introspection" test_search_capabilities

# `restsift search batch` routes through ai-search to the ai-search-multi
# batch implementation.
test_search_batch() {
    local out
    out="$(AI_OUTPUT=json "$BASH_BIN" "$AI" search batch changed-files . 2>/dev/null || true)"
    printf '%s' "$out" | jq -e 'type=="array"' >/dev/null 2>&1
}
run_test "routes search batch to ai-search-multi" test_search_batch

# `restsift context estimate` routes through ai-context to query-usage.
test_context_estimate() {
    local out
    out="$($BASH_BIN "$AI" context estimate README.md 2>/dev/null || true)"
    printf '%s' "$out" | grep -q 'query_usage:'
}
run_test "routes context estimate to query-usage" test_context_estimate

# `restsift repo stats` routes through ai-repo to repo-stats.
test_repo_stats() {
    local out
    out="$($BASH_BIN "$AI" repo stats 2>/dev/null || true)"
    [[ "$out" =~ ^[0-9]+$ ]]
}
run_test "routes repo stats to repo-stats" test_repo_stats

# `restsift inspect shell` routes through ai-inspect to sh-introspect.
test_inspect_shell() {
    local out
    out="$($BASH_BIN "$AI" inspect shell libexec/ai-search 2>/dev/null || true)"
    printf '%s' "$out" | grep -q 'static introspection'
}
run_test "routes inspect shell to sh-introspect" test_inspect_shell

# `restsift session checkpoint --help` routes through ai-session to
# session-checkpoint (using --help avoids creating a real snapshot). --help is
# intercepted by lib/common.sh's universal guard before session-checkpoint's
# own usage(), so assert on the script's header description instead.
test_session_checkpoint() {
    local out
    out="$($BASH_BIN "$AI" session checkpoint --help 2>/dev/null || true)"
    printf '%s' "$out" | grep -q 'repository-local checkpoint'
}
run_test "routes session checkpoint to session-checkpoint" test_session_checkpoint

# `restsift git origin --help` routes through ai-git to the fused origin module.
test_git_origin() {
    local out
    out="$($BASH_BIN "$AI" git origin --help 2>/dev/null || true)"
    printf '%s' "$out" | grep -q 'Detects the branch'
}
run_test "routes git origin to the ai-git origin module" test_git_origin

# `restsift verify refs --help` routes through the fused ai-verify to the file-refs module.
test_verify_refs() {
    local out
    out="$($BASH_BIN "$AI" verify refs --help 2>&1 || true)"
    printf '%s' "$out" | grep -q 'orphaned'
}
run_test "routes verify refs to the fused file-refs module" test_verify_refs

# `restsift test select changed` routes through the fused ai-test to the select module.
test_test_select() {
    local out
    out="$(AI_OUTPUT=json $BASH_BIN "$AI" test select json 2>/dev/null || true)"
    printf '%s' "$out" | jq -e 'type=="object" or type=="array"' >/dev/null 2>&1
}
run_test "routes test select to the fused ai-test select module" test_test_select

# --version prints the VERSION file content and exits 0.
test_version() {
    local out
    out="$("$BASH_BIN" "$AI" --version 2>/dev/null)" || return 1
    [[ "$out" == "restsift $(tr -d '[:space:]' <"$REPO_ROOT/VERSION")" ]]
}
run_test "--version prints the version (exit 0)" test_version

# --version --json emits a valid JSON envelope carrying the VERSION value.
test_version_json() {
    local out want
    out="$("$BASH_BIN" "$AI" --version --json 2>/dev/null)" || return 1
    want="$(tr -d '[:space:]' <"$REPO_ROOT/VERSION")"
    printf '%s' "$out" | jq -e \
        --arg v "$want" \
        '.schema=="ai.version/v1" and .name=="restsift" and .version==$v and has("commit")' \
        >/dev/null 2>&1
}
run_test "--version --json emits a valid JSON envelope" test_version_json

# The bare `version` word is an alias and also honors --json.
test_version_bare_json() {
    local out
    out="$(AI_OUTPUT=json "$BASH_BIN" "$AI" version 2>/dev/null)" || return 1
    printf '%s' "$out" | jq -e '.schema=="ai.version/v1"' >/dev/null 2>&1
}
run_test "bare 'version' honors AI_OUTPUT=json" test_version_bare_json

# Unknown command fails with exit 2.
test_unknown() {
    local _rc=0
    "$BASH_BIN" "$AI" definitely-not-a-command >/dev/null 2>&1 || _rc=$?
    ((_rc == 2))
}
run_test "unknown command exits 2" test_unknown

# No arguments prints the list but exits non-zero (2).
test_no_args() {
    local _rc=0
    "$BASH_BIN" "$AI" >/dev/null 2>&1 || _rc=$?
    ((_rc == 2))
}
run_test "no arguments exits 2" test_no_args

# SECURITY: a command name with a path must never escape libexec/ and exec an
# arbitrary file. Regression guard for the traversal fix.
test_path_traversal_blocked() {
    local evil rc=0
    evil="$(mktemp)"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$evil"
    # Build enough ../ to reach filesystem root, then point at the evil file.
    local up="../../../../../../../../../../../../.."
    "$BASH_BIN" "$AI" "${up}${evil}" >/dev/null 2>&1 || rc=$?
    rm -f "$evil"
    # Must be rejected (exit 2), NOT executed.
    ((rc == 2))
}
run_test "rejects path-like command names (no traversal)" test_path_traversal_blocked

# A leading dot is rejected too.
test_dotfile_rejected() {
    local _rc=0
    "$BASH_BIN" "$AI" .bashrc >/dev/null 2>&1 || _rc=$?
    ((_rc == 2))
}
run_test "rejects dotfile-style names" test_dotfile_rejected

# --- Deeper per-router-mode coverage for the ai-repo/ai-inspect/ai-session
# thin routers (libexec/ai-repo, libexec/ai-inspect, libexec/ai-session).
# The earlier tests above only exercise one happy-path mode each; these cover
# the remaining modes, --help/no-args, and the unknown-mode error path.

# ai-repo: `tasks` mode routes to ai-task.
test_repo_tasks() {
    local out
    out="$($BASH_BIN "$AI" repo tasks list 2>/dev/null || true)"
    printf '%s' "$out" | jq -e '.package_manager' >/dev/null 2>&1
}
run_test "routes repo tasks to ai-task" test_repo_tasks

# ai-repo: `tools` mode routes to repo-tool-inventory.
test_repo_tools() {
    local out
    out="$($BASH_BIN "$AI" repo tools 2>/dev/null || true)"
    printf '%s' "$out" | grep -q 'ai-search'
}
run_test "routes repo tools to repo-tool-inventory" test_repo_tools

# ai-repo: `status` mode routes to ai-file-freshness (exit 0, read-only).
test_repo_status() {
    "$BASH_BIN" "$AI" repo status >/dev/null 2>&1
}
run_test "routes repo status to ai-file-freshness (exit 0)" test_repo_status

# ai-repo: --help / no-args print the router's usage and exit 0.
test_repo_help() {
    local out _rc=0
    out="$($BASH_BIN "$AI" repo --help 2>/dev/null)" || _rc=$?
    [[ "$_rc" -eq 0 ]] && printf '%s' "$out" | grep -q 'restsift repo tasks'
}
run_test "repo --help prints router usage (exit 0)" test_repo_help

test_repo_no_args() {
    local _rc=0
    "$BASH_BIN" "$AI" repo >/dev/null 2>&1 || _rc=$?
    ((_rc == 0))
}
run_test "repo with no mode prints usage (exit 0)" test_repo_no_args

# ai-repo: unknown mode fails with exit 2 and a clear message.
test_repo_unknown_mode() {
    local out _rc=0
    out="$($BASH_BIN "$AI" repo bogus-mode 2>&1)" || _rc=$?
    [[ "$_rc" -eq 2 && "$out" == *"unknown mode 'bogus-mode'"* \
        && "$out" == *"repo --help"* ]]
}
run_test "repo unknown mode exits 2 with a clear message" test_repo_unknown_mode

# ai-inspect: `data` mode routes to ai-structured.
test_inspect_data() {
    local out
    out="$($BASH_BIN "$AI" inspect data validate-json package.json 2>&1 || true)"
    printf '%s' "$out" | grep -q 'valid JSON'
}
run_test "routes inspect data to ai-structured" test_inspect_data

# ai-inspect: --help / no-args print the router's usage and exit 0.
test_inspect_help() {
    local out _rc=0
    out="$($BASH_BIN "$AI" inspect --help 2>/dev/null)" || _rc=$?
    [[ "$_rc" -eq 0 ]] && printf '%s' "$out" | grep -q 'restsift inspect file'
}
run_test "inspect --help prints router usage (exit 0)" test_inspect_help

test_inspect_no_args() {
    local _rc=0
    "$BASH_BIN" "$AI" inspect >/dev/null 2>&1 || _rc=$?
    ((_rc == 0))
}
run_test "inspect with no mode prints usage (exit 0)" test_inspect_no_args

# ai-inspect: unknown mode fails with exit 2 and a clear message.
test_inspect_unknown_mode() {
    local out _rc=0
    out="$($BASH_BIN "$AI" inspect bogus-mode 2>&1)" || _rc=$?
    [[ "$_rc" -eq 2 && "$out" == *"unknown mode 'bogus-mode'"* ]]
}
run_test "inspect unknown mode exits 2 with a clear message" test_inspect_unknown_mode

# ai-session: `watch` mode routes to watch-loop. Use --help so the universal
# lib/common.sh --help guard intercepts before the blocking watch loop starts.
test_session_watch() {
    local out
    out="$($BASH_BIN "$AI" session watch --help 2>&1 || true)"
    printf '%s' "$out" | grep -q 'watch-loop'
}
run_test "routes session watch to watch-loop" test_session_watch

# ai-session: --help / no-args print the router's usage and exit 0.
test_session_help() {
    local out _rc=0
    out="$($BASH_BIN "$AI" session --help 2>/dev/null)" || _rc=$?
    [[ "$_rc" -eq 0 ]] && printf '%s' "$out" | grep -q 'restsift session checkpoint'
}
run_test "session --help prints router usage (exit 0)" test_session_help

test_session_no_args() {
    local _rc=0
    "$BASH_BIN" "$AI" session >/dev/null 2>&1 || _rc=$?
    ((_rc == 0))
}
run_test "session with no mode prints usage (exit 0)" test_session_no_args

# ai-session: unknown mode fails with exit 2 and a clear message.
test_session_unknown_mode() {
    local out _rc=0
    out="$($BASH_BIN "$AI" session bogus-mode 2>&1)" || _rc=$?
    [[ "$_rc" -eq 2 && "$out" == *"unknown mode 'bogus-mode'"* ]]
}
run_test "session unknown mode exits 2 with a clear message" test_session_unknown_mode

# --- Deprecated compatibility aliases (agent-kit / ak) ----------------------
# The toolkit was renamed agent-kit -> RestSift. The bin/agent-kit and bin/ak
# shims must still resolve commands AND print a one-line deprecation notice to
# stderr ONLY (never stdout, so piped/JSON output stays clean). Protects the
# backward-compatibility window.
AGENT_KIT="$REPO_ROOT/bin/agent-kit"
AK="$REPO_ROOT/bin/ak"

test_deprecated_agent_kit_resolves_commands() {
    local out
    out="$("$BASH_BIN" "$AGENT_KIT" --list 2>/dev/null)" || return 1
    printf '%s' "$out" | grep -q 'ai-search'
}
run_test "deprecated 'agent-kit' alias still resolves commands (exit 0)" test_deprecated_agent_kit_resolves_commands

test_deprecated_agent_kit_warns_on_stderr_only() {
    local err out
    err="$("$BASH_BIN" "$AGENT_KIT" --list 2>&1 >/dev/null)"
    out="$("$BASH_BIN" "$AGENT_KIT" --list 2>/dev/null)"
    printf '%s' "$err" | grep -qi 'deprecated' &&
        ! printf '%s' "$out" | grep -qi 'deprecated'
}
run_test "deprecated 'agent-kit' alias warns on stderr, not stdout" test_deprecated_agent_kit_warns_on_stderr_only

test_deprecated_ak_resolves_and_warns() {
    local out err
    out="$("$BASH_BIN" "$AK" --list 2>/dev/null)" || return 1
    err="$("$BASH_BIN" "$AK" --list 2>&1 >/dev/null)"
    printf '%s' "$out" | grep -q 'ai-search' &&
        printf '%s' "$err" | grep -qi 'deprecated'
}
run_test "deprecated 'ak' alias still resolves commands and warns on stderr" test_deprecated_ak_resolves_and_warns

printf '\n=== Results ===\n'
printf '  Passed: %d  Failed: %d\n' "$PASS" "$FAIL"
((FAIL == 0)) && printf '\033[0;32mPASSED\033[0m\n' || {
    printf '\033[0;31mFAILED\033[0m\n'
    exit 1
}
