# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034  # cross-module globals set by ai_edit_main/parse_tail via dynamic scope
# ai-edit/10-helpers.sh — JSON/diff/session/status helpers.
#
# Sourced by scripts/ai/ai-edit.sh (thin loader). Not an entrypoint. Behavior is
# byte-for-byte identical to the previous monolithic ai-edit.sh.

show_diff() {
    git --no-pager diff --stat || true
    git --no-pager diff --color=always | sed -n '1,240p' || true
}

dirty_files_json() {
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        printf '[]\n'
        return 0
    fi

    # Filter out the tool's own log/session/snapshot tree (AI_LOG_DIR, e.g.
    # ".ai-logs/") so changedFiles/baselineDirtyFiles/sessionChangedFiles report
    # only user-facing edits, not this run's manifests and snapshots. grep -v may
    # legitimately drop every line (a run that touched only its own logs), so it
    # is guarded with `|| true` to keep the pipeline green under pipefail.
    local log_prefix="${AI_LOG_DIR%/}"
    {
        git diff --name-only || true
        git diff --cached --name-only || true
        git ls-files --others --exclude-standard || true
    } | sort -u | sed '/^$/d' |
        { grep -v -e "^${log_prefix}/" -e "^${log_prefix}\$" || true; } |
        jq -R . | jq -s -c .
}

is_json_output() {
    [[ "${format:-text}" == "json" || "${AI_OUTPUT:-}" == "json" ]]
}

add_warning() {
    warnings_json="$(jq -c --arg v "$1" '. + [$v]' <<<"$warnings_json")"
}

add_error() {
    errors_json="$(jq -c --arg v "$1" '. + [$v]' <<<"$errors_json")"
}

json_array_diff() {
    jq -c -n --argjson before "$1" --argjson after "$2" '$after - $before'
}

save_diff_artifacts() {
    mkdir -p "$SESSION_DIR"
    git --no-pager diff --stat >"$SESSION_DIR/diff.stat" || true
    git --no-pager diff >"$SESSION_DIR/diff.patch" || true
}

write_session_manifest() {
    local status="$1"
    local manifest_path="$SESSION_DIR/edit-session.json"
    local after_json session_changed_json

    mkdir -p "$SESSION_DIR"
    after_json="$(dirty_files_json)"
    session_changed_json="$(json_array_diff "$baseline_dirty_json" "$after_json")"

    # shellcheck disable=SC2086  # $manifest_path is injected as a JSON string literal into the jq program; path is repo-internal
    jq -n \
        --arg session "${SESSION_ID:-unknown}" \
        --arg mode "${mode:-unknown}" \
        --arg root "${root:-.}" \
        --arg status "$status" \
        --arg snapshot "${snapshot:-}" \
        --arg apply "${apply:-0}" \
        --arg verify "${verify:-0}" \
        --arg require_clean_tree "${require_clean_tree_flag:-1}" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg diff_patch "$SESSION_DIR/diff.patch" \
        --arg diff_stat "$SESSION_DIR/diff.stat" \
        --argjson plannedChanges "$planned_json" \
        --argjson baselineDirtyFiles "$baseline_dirty_json" \
        --argjson changedFiles "$after_json" \
        --argjson sessionChangedFiles "$session_changed_json" \
        --argjson warnings "$warnings_json" \
        --argjson errors "$errors_json" \
        '{
          schema: "ai.edit-session/v1",
          session: $session,
          mode: $mode,
          root: $root,
          status: $status,
          snapshot: (if $snapshot == "" then null else $snapshot end),
          apply: ($apply == "1"),
          verify: ($verify == "1"),
          requireCleanTree: ($require_clean_tree == "1"),
          ts: $ts,
          plannedChanges: $plannedChanges,
          baselineDirtyFiles: $baselineDirtyFiles,
          changedFiles: $changedFiles,
          sessionChangedFiles: $sessionChangedFiles,
          warnings: $warnings,
          errors: $errors,
          artifacts: {
            manifest: "'$manifest_path'",
            diffPatch: $diff_patch,
            diffStat: $diff_stat
          }
        }' >"$manifest_path"

    log_json "edit.manifest" "$(cat "$manifest_path")" || true
}

# Maps a terminal status to a short, actionable next-step hint so an agent can
# self-correct (pick the flag to re-run with) without a human in the loop. Only
# non-terminal/blocking statuses carry a hint; success statuses return "" (which
# emit_result_json renders as JSON null). Additive: surfaced only in the
# opt-in ai.edit/v1 envelope, never in default/human output.
next_step_hint() {
    case "$1" in
    dry_run) printf 're-run with --apply (or APPLY=1) to modify files' ;;
    blocked) printf 'resolve the condition in errors[]: commit/stash or pass --allow-dirty-tree for a dirty tree; for a rejected patch inspect artifacts.diffPatch/patch-check.log; then re-run' ;;
    limit_exceeded) printf 'raise --max-files/--max-replacements/--max-bytes or narrow the scope (root/--glob/--exclude), then re-run' ;;
    unavailable) printf 'install the required backend tool named in errors[], then re-run' ;;
    verify_failed) printf 'inspect the verify log under artifacts.sessionDir, fix the failure, then re-run' ;;
    *) printf '' ;;
    esac
}

emit_result_json() {
    local status="$1"
    local after_json session_changed_json next_step

    after_json="$(dirty_files_json)"
    session_changed_json="$(json_array_diff "$baseline_dirty_json" "$after_json")"
    next_step="$(next_step_hint "$status")"

    jq -n \
        --arg status "$status" \
        --arg nextStep "$next_step" \
        --arg mode "${mode:-unknown}" \
        --arg root "${root:-.}" \
        --arg snapshot "${snapshot:-}" \
        --arg session_dir "${SESSION_DIR:-}" \
        --argjson apply_bool "$([[ "$apply" == "1" ]] && echo true || echo false)" \
        --argjson verify_bool "$([[ "$verify" == "1" ]] && echo true || echo false)" \
        --argjson plannedChanges "$planned_json" \
        --argjson baselineDirtyFiles "$baseline_dirty_json" \
        --argjson changedFiles "$after_json" \
        --argjson sessionChangedFiles "$session_changed_json" \
        --argjson warnings "$warnings_json" \
        --argjson errors "$errors_json" \
        --arg maxFiles "$max_files" \
        --arg maxReplacements "$max_replacements" \
        --arg maxBytes "$max_bytes" \
        '{
          schema: "ai.edit/v1",
          status: $status,
          nextStep: (if $nextStep == "" then null else $nextStep end),
          tool: "ai-edit",
          mode: $mode,
          root: $root,
          apply: $apply_bool,
          verify: $verify_bool,
          plannedChanges: $plannedChanges,
          changedFiles: $changedFiles,
          baselineDirtyFiles: $baselineDirtyFiles,
          sessionChangedFiles: $sessionChangedFiles,
          warnings: $warnings,
          errors: $errors,
          limits: {
            maxFiles: ($maxFiles | tonumber? // null),
            maxReplacements: ($maxReplacements | tonumber? // null),
            maxBytes: ($maxBytes | tonumber? // null)
          },
          snapshot: (if $snapshot == "" then null else $snapshot end),
          artifacts: {
            sessionDir: $session_dir,
            manifest: ($session_dir + "/edit-session.json"),
            diffPatch: ($session_dir + "/diff.patch"),
            diffStat: ($session_dir + "/diff.stat")
          },
          meta: {
            targetExecuted: true,
            truncated: false
          }
        }'
}

finish() {
    local status="$1"
    local exit_code="${2:-0}"

    trap - ERR
    write_session_manifest "$status" || true

    if is_json_output; then
        emit_result_json "$status"
    else
        case "$status" in
            dry_run) printf '\nDry-run only. Re-run with --apply or APPLY=1 to modify files.\n' ;;
            no_matches) printf 'No matches.\n' ;;
            applied) printf 'Applied changes. Manifest: %s/edit-session.json\n' "$SESSION_DIR" ;;
            verified) printf 'Applied and verified. Manifest: %s/edit-session.json\n' "$SESSION_DIR" ;;
            limit_exceeded | blocked | error | verify_failed)
                # Surface the accumulated diagnostic(s) so a human gets an
                # actionable reason, not just the opaque status keyword. The
                # trailing status word is preserved (last line) for backward
                # compatibility with callers/tests that match on it. A
                # non-terminal hint, when one exists, is printed last.
                local _msg _hint
                while IFS= read -r _msg; do
                    [[ -n "$_msg" ]] && printf '%s\n' "$_msg" >&2
                done < <(jq -r '.[]' <<<"$errors_json")
                printf '%s\n' "$status" >&2
                _hint="$(next_step_hint "$status")"
                [[ -n "$_hint" ]] && printf 'next step: %s\n' "$_hint" >&2
                ;;
        esac
    fi

    exit "$exit_code"
}

# shellcheck disable=SC2329  # invoked indirectly via `trap on_error ERR`
on_error() {
    local exit_code=$?
    trap - ERR
    add_error "unexpected failure"
    finish "error" "$exit_code"
}

fail_status() {
    local status="$1"
    local message="$2"
    local code="${3:-2}"
    add_error "$message"
    finish "$status" "$code"
}

validate_uint() {
    local name="$1" value="$2"
    [[ "$value" =~ ^[0-9]+$ ]] || fail_status "error" "$name must be a non-negative integer: $value" 2
}

# Clean-tree preflight for the apply branches. The shared require_clean_tree
# (lib/paths.sh) calls die(), which prints raw non-JSON "[ERROR] ..." text and
# exits 1 — bypassing the ai.edit/v1 envelope under AI_OUTPUT=json. Route the
# same checks through fail_status "blocked" 4 (a documented status) so the JSON
# contract is honored while text-mode output stays equivalent.
require_clean_tree_guarded() {
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
        fail_status "blocked" "not inside a git repository" 4
    if ! git diff --quiet || ! git diff --cached --quiet; then
        fail_status "blocked" "working tree is not clean; commit or stash changes first" 4
    fi
}

# Resolves the ast-grep binary into the caller-visible `ast_bin` global (dynamic
# scope, like the rest of this module) rather than stdout. Emitting the name via
# `printf` forced the caller to use `ast_bin="$(resolve_ast_grep)"`, which ran
# fail_status/finish inside a command-substitution subshell: the JSON envelope
# never reached the real stdout and the failed assignment tripped the generic
# on_error ERR trap. Setting the global keeps fail_status/finish in the parent
# shell so the documented status:"unavailable" / exit 127 actually surfaces.
resolve_ast_grep() {
    if command -v ast-grep >/dev/null 2>&1; then
        ast_bin="ast-grep"
        return 0
    fi
    if command -v sg >/dev/null 2>&1; then
        ast_bin="sg"
        return 0
    fi
    fail_status "unavailable" "required tool not found: ast-grep or sg" 127
}

default_excludes=(
    ".git" ".git/**"
    "vendor" "vendor/**"
    "node_modules" "node_modules/**"
    "dist" "dist/**"
    "build" "build/**"
    "coverage" "coverage/**"
    ".repomix-context" ".repomix-context/**"
    ".cache" ".cache/**"
    "*.min.*" "*.map" "*.lock"
    ".env" ".env.*"
    "*.pem" "*.key" "*.crt"
)

include_globs=()
exclude_globs=()

build_rg_args() {
    rg_args=(--hidden)
    local g
    for g in "${default_excludes[@]}"; do
        rg_args+=(-g "!$g")
    done
    for g in "${exclude_globs[@]}"; do
        rg_args+=(-g "!$g")
    done
    for g in "${include_globs[@]}"; do
        rg_args+=(-g "$g")
    done
}
