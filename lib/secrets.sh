#!/usr/bin/env bash
# 70-secrets.sh — secret-scanning helpers.
#
# Purpose: gitleaks wrapper, SECRETS_SCAN=0 bypass, and clean-failure on detect.
# Allowed dependencies: 05-core.sh (log_warn, die). No repomix, context packing,
#   rollback, or git reset.

[[ "${AI_LIB_SECRETS_LOADED:-0}" == "1" ]] && return 0
AI_LIB_SECRETS_LOADED=1

secrets_scan() {
    local target="${1:-.}"
    if command -v gitleaks >/dev/null 2>&1; then
        gitleaks detect --source "$target" --redact --no-banner --exit-code 1 >/dev/null 2>&1
    else
        log_warn "gitleaks not installed; skipping secrets scan"
        return 0
    fi
}

require_clean_secret_scan() {
    local target="${1:-.}"

    if [[ "${SECRETS_SCAN:-1}" != "1" ]]; then
        log_warn "SECRETS_SCAN disabled"
        return 0
    fi

    if command -v gitleaks >/dev/null 2>&1; then
        local report_file
        report_file=$(mktemp) || {
            die "secrets detected; refusing to continue (failed to create temp report file)"
        }
        # shellcheck disable=SC2064
        trap "rm -f '$report_file'" RETURN

        # Run gitleaks and capture JSON output
        if ! gitleaks detect --source "$target" --report-format json --report-path "$report_file" --redact >/dev/null 2>&1; then
            # Extract file:line information from JSON report
            local error_msg="secrets detected; refusing to continue"

            if [[ -f "$report_file" ]] && command -v jq >/dev/null 2>&1; then
                # Try to parse JSON and extract files with line numbers
                local files_info
                files_info=$(jq -r '.[] | "\(.File):\(.StartLine)"' "$report_file" 2>/dev/null | sort -u)

                if [[ -n "$files_info" ]]; then
                    error_msg+=$'\n\nDetected in:\n'
                    while IFS= read -r line; do
                        error_msg+="  $line"$'\n'
                    done <<< "$files_info"
                fi
            fi

            error_msg+=$'\n\nTo skip this check, run: SECRETS_SCAN=0 res context pack auto'
            die "$error_msg"
        fi
    else
        log_warn "gitleaks not installed; skipping secrets scan"
    fi
}
