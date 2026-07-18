#!/usr/bin/env bash
# 95-dispatch.sh — mode dispatch, backend selection, and output assembly.
#
# Purpose: ai_search_main orchestrates the run (state -> parse -> normalise ->
#   scope -> guards -> dispatch). run_backend selects the path:line:text-style
#   backend (the bespoke modes exit earlier). emit_results builds the structured
#   results[], applies count/file-only shaping, bounds, and emits the envelope.
# Allowed dependencies: every earlier module. Must load LAST.
#
# SC2034/SC2154: this module orchestrates run-state globals owned across all
# sibling modules (see ai-search.sh load order).
# shellcheck disable=SC2034,SC2154

# run_backend — dispatch the canonical (path:line:text) backends. Bespoke modes
# (diff/history/todo/unsafe-patterns/struct/symbols/class/doctor) exit before
# this point, so only the simple `out`-setting backends remain here.
run_backend() {
    case "$mode" in
        changed-files) backend_changed_files ;;
        staged-files) backend_staged_files ;;
        changed-text) backend_changed_text ;;
        staged-text) backend_staged_text ;;
        tracked) backend_tracked ;;
        text) backend_text ;;
        docs | tests | config | deps | route | config-key) backend_surface ;;
        function | method | interface | enum) backend_shortcut_text ;;
        files) backend_files ;;
        *)
            fail "error" "unknown mode: $mode" 1 \
                "unknown_mode" "run 'restsift search --help' to list valid modes"
            ;;
    esac
}

# emit_results — convert the backend `out` into the canonical envelope. Mirrors
# the pre-split JSON-output tail exactly, including count/file-only shaping and
# the match-line cap. Plain mode just prints `out`.
emit_results() {
    local matches_json root_abs source_tool results_bytes count final

    # Routing key shared by the JSON and plain branches. text/docs/tests/config/
    # deps and the function/method/interface/enum shortcuts stream rg --json in
    # `out`; tracked/changed-text/staged-text and text degraded to git grep are
    # line-oriented path:line:text. Use a local key so the reported g_mode
    # ("text") is not clobbered.
    local route_mode="$mode"
    if [[ "$mode" == "text" && "${g_text_fallback:-0}" == "1" ]]; then
        route_mode="__text_fallback"
    fi

    if [[ "$json_mode" == "json" ]]; then
        # Phase 3A/3B/3C: additive structured results for content searches.
        # text/docs come from an rg --json stream (accurate column, colon-safe
        # paths); tracked/changed-text/staged-text are line-oriented.
        case "$route_mode" in
            text | docs | tests | config | deps | route | config-key | function | method | interface | enum)
                root_abs="$(canonical_root "$root")"
                matches_json="$(printf '%s' "$out" | rg_json_to_matches)"
                g_results_json="$(printf '%s' "$out" | rg_json_to_results "rg" "$root_abs")"
                g_results_json="$(add_context_to_results "$root_abs" "$g_results_json")"

                if [[ "$max_bytes" -gt 0 ]]; then
                    results_bytes="$(printf '%s' "$g_results_json" | wc -c | tr -d ' ')"

                    if [[ "$results_bytes" -gt "$max_bytes" ]]; then
                        g_truncated=true
                        g_results_json="$(
                            printf '%s' "$g_results_json" | jq '
                            map(if has("context") then .context.before = [] | .context.after = [] else . end)
                        '
                        )"
                    fi
                fi
                ;;
            tracked | changed-text | staged-text | __text_fallback)
                matches_json="$(printf '%s' "$out" | lines_to_matches)"
                root_abs="$(canonical_root "$root")"
                source_tool="rg"

                if [[ "$route_mode" == "tracked" || "$route_mode" == "__text_fallback" ]]; then
                    source_tool="git-grep"
                fi

                g_results_json="$(printf '%s' "$out" | lines_to_structured_results "$source_tool" "$root_abs")"
                g_results_json="$(add_context_to_results "$root_abs" "$g_results_json")"

                if [[ "$max_bytes" -gt 0 ]]; then
                    results_bytes="$(printf '%s' "$g_results_json" | wc -c | tr -d ' ')"

                    if [[ "$results_bytes" -gt "$max_bytes" ]]; then
                        g_truncated=true

                        # Preserve match identity, but remove bulky context payload.
                        g_results_json="$(
                            printf '%s' "$g_results_json" | jq '
                            map(
                                if has("context") then
                                    .context.before = [] | .context.after = []
                                else
                                    .
                                end
                            )
                        '
                        )"
                    fi
                fi
                ;;
            *)
                # File-list and structural modes: plain string matches, no results[].
                matches_json="$(printf '%s' "$out" | lines_to_matches)"
                g_results_json="[]"
                ;;
        esac

        # Phase 3D: count / file-only output. Aggregate the structured results into
        # per-file rows and publish a summary, without dumping every match line.
        # `matches[]` (the legacy string array) is preserved unchanged.
        if [[ "$count_mode" != "none" ]]; then
            g_summary_json="$(
                printf '%s' "$g_results_json" | jq -c '
                    {
                        total_files: ([.[].path] | unique | length),
                        total_matches: length
                    }
                '
            )"

            case "$count_mode" in
                files)
                    g_results_json="$(
                        printf '%s' "$g_results_json" | jq -c '
                        [.[].path] | unique | map({ path: . })
                    '
                    )"
                    ;;
                count)
                    g_results_json="$(
                        printf '%s' "$g_results_json" | jq -c '
                        group_by(.path)
                        | map({ path: .[0].path, count: length })
                    '
                    )"
                    ;;
                count-matches)
                    g_results_json="$(
                        printf '%s' "$g_results_json" | jq -c '
                        group_by(.path)
                        | map({ path: .[0].path, count: length })
                    '
                    )"
                    ;;
            esac
        fi

        count="$(printf '%s' "$matches_json" | jq 'length')"

        if [[ "$count" -gt "$g_max_results" ]]; then
            matches_json="$(printf '%s' "$matches_json" | jq --argjson n "$g_max_results" '.[:$n]')"
            # In count modes results[] are aggregated per-file rows, not per match
            # line, so the match-line cap must not truncate them.
            if [[ "$count_mode" == "none" ]]; then
                g_results_json="$(printf '%s' "$g_results_json" | jq --argjson n "$g_max_results" '.[:$n]')"
            fi
            g_truncated=true
        fi

        final="$(printf '%s' "$matches_json" | jq 'length')"

        if [[ "$final" -eq 0 ]]; then
            emit_json "no_matches" "$matches_json"
        else
            emit_json "ok" "$matches_json"
        fi
    else
        # Aggregation flags shape only the AI_OUTPUT=json envelope (results[]/
        # summary{}); plain terminal output prints match lines instead. Warn on
        # stderr so a human running `--count`/`--count-matches`/-l does not
        # silently get a raw match dump. stdout stays byte-identical.
        if [[ "${count_mode:-none}" != "none" ]]; then
            printf 'note: --count/--count-matches/--files-with-matches shape only AI_OUTPUT=json output; printing match lines. Re-run with AI_OUTPUT=json for counts.\n' >&2
        fi

        # Plain (non-JSON) output. The rg --json backends emit an NDJSON wire
        # stream in `out`; render it to human/agent-readable path:line:text first
        # so plain mode never dumps raw ripgrep JSON. Line-oriented backends
        # (tracked/changed-text/staged-text and text degraded to git grep) are
        # already path:line:text.
        local plain_out="$out"
        case "$route_mode" in
            text | docs | tests | config | deps | route | config-key | function | method | interface | enum)
                plain_out="$(printf '%s' "$out" | rg_json_to_matches | jq -r '.[]')"
                ;;
        esac

        # The JSON branch caps matches at g_max_results; mirror that here so a
        # degenerate match-everything query (e.g. `tracked .`) cannot dump every
        # line of every tracked file. Without this cap, plain mode streams the
        # entire backend output unbounded.
        local total_lines
        if [[ -z "$plain_out" ]]; then
            return 0
        fi
        total_lines="$(printf '%s\n' "$plain_out" | wc -l | tr -d ' ')"
        if [[ "$total_lines" -gt "$g_max_results" ]]; then
            # awk (not `head`) prints the first N lines but keeps reading to EOF,
            # so the upstream printf never takes SIGPIPE. Under `set -o pipefail`
            # a `head` that closes the pipe early turns printf's SIGPIPE into a
            # fatal 141 exit for the whole script instead of a clean truncation.
            printf '%s\n' "$plain_out" | awk -v n="$g_max_results" 'NR <= n'
            printf '... (truncated: showed %s of %s matches; use --max-results N or a narrower query)\n' \
                "$g_max_results" "$total_lines" >&2
        else
            printf '%s\n' "$plain_out"
        fi
    fi
}

# ai_search_main — top-level orchestrator. Receives the full original argv.
ai_search_main() {
    init_run_state "${1:-}"

    if [[ "$mode" == "--help" || "$mode" == "-h" || -z "$mode" ]]; then
        usage
        introspect_help_summary
        exit 0
    fi

    # doctor takes no query/root; report real tool diagnostics.
    if [[ "$mode" == "doctor" ]]; then
        run_doctor_mode
    fi

    # Flags are accepted in any position. Positionals are interpreted per mode
    # family after legacy-alias normalization.
    shift # consume MODE
    parse_flags "$@"

    normalize_legacy_alias
    interpret_positionals
    handle_dry_run

    build_case_pattern_args
    apply_global_gitignore
    build_rg_scope_args

    check_tool_guards

    # Early dispatch for bespoke result shapes.
    case "$mode" in
        diff) run_diff_mode ;;
        history) run_history_mode ;;
        todo) run_todo_mode ;;
        unsafe-patterns) run_unsafe_patterns_mode ;;
        struct | symbols | class) run_ast_mode ;;
    esac

    run_backend
    emit_results
}
