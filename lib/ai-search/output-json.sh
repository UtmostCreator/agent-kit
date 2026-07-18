#!/usr/bin/env bash
# 40-output-json.sh — JSON envelope output and failure handling.
#
# Purpose: render the canonical envelope (emit_json), the error/blocked path
#   (fail), the legacy string-array helpers (to_json_array, lines_to_matches),
#   canonical_root(), and validate_non_negative_int().
# Allowed dependencies: jq; common.sh log_error. Reads run-state globals
#   (g_query, g_mode, g_results_json, g_summary_json, g_max_results, g_truncated,
#   g_warnings, json_mode).
#
# Load-order constraint: emit_json() MUST be defined before fail(), because
#   fail() calls emit_json() in JSON mode.
#
# SC2154: g_query/g_mode/g_results_json/g_summary_json/g_max_results/g_truncated/
# g_warnings/json_mode are run-state globals set by sibling modules.
# shellcheck disable=SC2154

# to_json_array ITEMS... — render arguments as a JSON string array, dropping
# empty entries. Prints [] when called with no arguments.
to_json_array() {
    if [[ "$#" -eq 0 ]]; then
        printf '[]'
    else
        printf '%s\n' "$@" | jq -R -s 'split("\n") | map(select(length > 0))'
    fi
}

# emit_json STATUS [MATCHES_JSON] [ERRORS_JSON] [WARNINGS_JSON]
# Renders the canonical envelope. Warnings default to g_warnings.
emit_json() {
    local status="$1" matches_json="${2:-[]}" errors="${3:-[]}" warnings="${4:-}"
    local returned truncated="${g_truncated:-false}"

    if [[ -z "$warnings" ]]; then
        warnings="$(to_json_array "${g_warnings[@]}")"
    fi

    returned="$(printf '%s' "$matches_json" | jq 'length')"

    # `matches` and `results` can be arbitrarily large (e.g. `history --patch`
    # embeds full commit patches). Pass them to jq via files (--slurpfile), not
    # --argjson on the command line: a single argv element over ~128 KB
    # (MAX_ARG_STRLEN on Linux) aborts jq with "Argument list too long" (exit
    # 126). --slurpfile wraps each file's JSON value in a 1-element array, hence
    # the [0] indexing below.
    local _m_tmp _r_tmp
    _m_tmp="$(mktemp)"
    _r_tmp="$(mktemp)"
    printf '%s' "$matches_json" >"$_m_tmp"
    printf '%s' "${g_results_json:-[]}" >"$_r_tmp"

    jq -cn \
        --arg schema "1" \
        --arg status "$status" \
        --arg tool "ai-search" \
        --arg query "${g_query:-}" \
        --arg mode "${g_mode:-}" \
        --slurpfile matches "$_m_tmp" \
        --slurpfile results "$_r_tmp" \
        --argjson errors "$errors" \
        --argjson warnings "$warnings" \
        --argjson max_results "$g_max_results" \
        --argjson returned "$returned" \
        --argjson truncated "$truncated" \
        --argjson summary "${g_summary_json:-null}" \
        --arg error_code "${g_error_code:-}" \
        --arg error_hint "${g_error_hint:-}" \
        '{
            schema: $schema,
            status: $status,
            tool: $tool,
            query: $query,
            mode: $mode,
            matches: $matches[0],
            results: $results[0],
            warnings: $warnings,
            errors: $errors,
            limits: { max_results: $max_results },
            meta: { returned: $returned, truncated: $truncated }
        }
        | if $summary != null then .summary = $summary else . end
        | if $error_code != "" then .error_code = $error_code else . end
        | if $error_hint != "" then .error_hint = $error_hint else . end'

    rm -f "$_m_tmp" "$_r_tmp"
}

# fail STATUS MESSAGE [RC] [CODE] [HINT] — emit an error/blocked/unavailable
# envelope in JSON mode, or a plain stderr line otherwise, then exit.
#
# CODE (optional) is a stable machine-readable error identifier (e.g.
# not_a_git_repository) surfaced as the additive envelope field `error_code`,
# so agents can branch on it instead of fragile message text. HINT (optional) is
# a concrete next step surfaced as `error_hint` (and appended to the plain-mode
# stderr line). Both are additive: when unset, no key is added and the ok/
# no_matches envelopes stay byte-identical.
fail() {
    local status="$1" msg="$2" rc="${3:-1}" code="${4:-}" hint="${5:-}"
    g_error_code="$code"
    g_error_hint="$hint"

    if [[ "$json_mode" == "json" ]]; then
        emit_json "$status" "[]" "$(jq -cn --arg m "$msg" '[$m]')"
    elif [[ -n "$hint" ]]; then
        log_error "$msg ($hint)"
    else
        log_error "$msg"
    fi

    exit "$rc"
}

# lines_to_matches — turn newline-delimited backend output into a JSON string
# array, dropping empty lines.
lines_to_matches() {
    jq -R -s 'split("\n") | map(select(length > 0))'
}

canonical_root() {
    local root_input="$1"

    if git -C "$root_input" rev-parse --show-toplevel >/dev/null 2>&1; then
        git -C "$root_input" rev-parse --show-toplevel
    elif [[ -f "$root_input" ]]; then
        ( cd "$(dirname -- "$root_input")" 2>/dev/null && pwd -P ) || printf '%s' "$root_input"
    else
        ( cd "$root_input" 2>/dev/null && pwd -P ) || printf '%s' "$root_input"
    fi
    return 0
}

validate_non_negative_int() {
    local flag="$1"
    local value="$2"

    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        fail "error" "$flag requires a non-negative integer"
    fi
}
