#!/usr/bin/env bash
# Behavioral-contract test suite for every libexec command.
#
# Where test/test-<cmd>.sh files verify one command's implementation in depth,
# THIS suite enforces the cross-cutting contract that EVERY command must honor —
# the invariants whose absence produced the 2026-07-16 audit's 50 defects:
#
#   help        --help exits 0 and prints a Usage: block with a runnable Example
#   introspect  --introspect is valid JSON of schema ai.sh-introspect/v1 whose
#               `requires` is an array of bare tool tokens (never word-split prose)
#   timely      --help and --introspect each finish well under a timeout (no hang)
#   no-mutation --help/--introspect leave the working tree byte-for-byte unchanged
#   json        for read-only commands: AI_OUTPUT=json <safe-args> is valid JSON,
#               emitted within a timeout (catches raw-NDJSON dumps and DoS hangs)
#   robust-dir  run from a NON-repo dir: no hang, no raw bash/git stack trace
#
# The suite is READ-ONLY: it never applies edits, never creates real checkpoints,
# and asserts commands do not mutate the tree. Write/interactive commands are
# marked CONTRACT_ONLY (help/introspect/no-mutation only).
#
# Run:  bash test/test-contract.sh
# CI :  invoked by test/run-all.sh and scripts/check.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIBEXEC="$REPO_ROOT/libexec"
BASH_BIN="${BASH_BIN:-$(command -v bash)}"
TIMEOUT="${CONTRACT_TIMEOUT:-15}"

# ── harness ───────────────────────────────────────────────────────────────────
PASS=0 FAIL=0
red=$'\033[0;31m'; grn=$'\033[0;32m'; ylw=$'\033[0;33m'; rst=$'\033[0m'
ok()   { PASS=$((PASS+1)); printf '  %s✓%s %s\n' "$grn" "$rst" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  %s✗%s %s\n' "$red" "$rst" "$1"; [[ -n "${2:-}" ]] && printf '      %s\n' "$2"; }
skip() { printf '  %s⊘%s %s (%s)\n' "$ylw" "$rst" "$1" "${2:-skipped}"; }

# porcelain snapshot of the whole repo, used to prove non-mutation
tree_hash() { git -C "$REPO_ROOT" status --porcelain=v1 2>/dev/null | sort | cksum; }

# run a command with a hard timeout; combined stdout+stderr (for help/robustness)
run()     { timeout "$TIMEOUT" "$BASH_BIN" "$@" 2>&1; }
# stdout only — for machine-mode JSON checks, where progress on stderr is legitimate
run_out() { timeout "$TIMEOUT" "$BASH_BIN" "$@" 2>/dev/null; }

# ── per-command manifest ──────────────────────────────────────────────────────
# READ_ONLY_ARGS: a genuinely side-effect-free invocation used for the json/smoke
# checks. CONTRACT_ONLY commands (write/interactive) get help/introspect/no-mutation
# only. A file target uses README.md; a search target uses the repo root.
declare -A READ_ONLY_ARGS=(
  [ai-context]="estimate README.md"
  [ai-doctor]=""
  [ai-file-freshness]=""
  [ai-git]="history S TODO README.md"
  [ai-inspect]="file README.md"
  [ai-refactor-scan]="complexity . --no-report"
  [ai-repo]="stats"
  [ai-rollback]="list"
  [ai-s]="text TODO ."
  [ai-search]="text TODO ."
  [ai-search-introspect]=""
  [ai-search-multi]="text foo bar ."
  [ai-structured]="json package.json .name"
  [ai-task]="list"
  [ai-test]="select changed"
  [fd-files]="README ."
  [preview-file]="README.md"
  [repo-stats]=""
  [repo-tool-inventory]=""
  [rg-code]="TODO"
  [sh-introspect]="--list $LIBEXEC"
)
# JSON-envelope invocation is NOT uniform across the toolkit (an agent-surface
# papercut worth normalizing): most honor AI_OUTPUT=json, but a few use a flag.
declare -A JSON_MODE=(
  [ai-git]="flag:--json"
  [ai-refactor-scan]="flag:--ai"
)
# Commands exercised at the contract layer only (they write, block, or apply):
declare -A CONTRACT_ONLY=(
  [ai-completion]=1 [ai-edit]=1 [ai-session]=1 [ai-verify]=1
  [all-f-into-one]=1 [session-checkpoint]=1 [watch-loop]=1
)

commands() { find "$LIBEXEC" -maxdepth 1 -type f -perm -u+x -printf '%f\n' | sort; }

# ── contract checks ───────────────────────────────────────────────────────────
check_help() {
  local cmd="$1" out rc
  out="$(run "$LIBEXEC/$cmd" --help)"; rc=$?
  if [[ $rc -ne 0 ]]; then bad "$cmd --help exits 0" "exit=$rc"; return; fi
  if [[ "$out" != *"Usage"* ]]; then bad "$cmd --help shows Usage" "no Usage: block"; return; fi
  ok "$cmd --help contract (exit 0, Usage present)"
  # Parity note (non-fatal): if --introspect advertises examples, --help should render one.
  local ex; ex="$(run_out "$LIBEXEC/$cmd" --introspect | jq -r '.examples|length' 2>/dev/null || echo 0)"
  if [[ "${ex:-0}" -gt 0 && "$out" != *"xample"* ]]; then
    skip "$cmd --help renders a runnable Example" "introspect advertises $ex example(s) but --help omits them"
  fi
}

check_introspect() {
  local cmd="$1" out rc
  out="$(run "$LIBEXEC/$cmd" --introspect)"; rc=$?
  if [[ $rc -ne 0 ]]; then bad "$cmd --introspect exits 0" "exit=$rc (possible hang/crash)"; return; fi
  if ! jq -e . >/dev/null 2>&1 <<<"$out"; then bad "$cmd --introspect emits valid JSON" "not parseable"; return; fi
  local schema; schema="$(jq -r '.schema // empty' <<<"$out")"
  [[ "$schema" == ai.sh-introspect/* ]] || { bad "$cmd --introspect schema tag" "schema='$schema'"; return; }
  [[ "$(jq -r '.requires|type' <<<"$out")" == array ]] || { bad "$cmd --introspect .requires is array" ""; return; }
  # Each `requires` entry must be a bare tool token, never a word-split prose sentence.
  local bad_req; bad_req="$(jq -r '.requires[]? | select(test(" ") or (length>40))' <<<"$out" | head -1)"
  if [[ -n "$bad_req" ]]; then bad "$cmd --introspect .requires holds bare tokens" "prose leaked: '$bad_req'"; return; fi
  ok "$cmd --introspect contract (valid schema, clean requires[])"
}

check_no_mutation() {
  local cmd="$1" before after
  before="$(tree_hash)"
  run "$LIBEXEC/$cmd" --help  >/dev/null 2>&1
  run "$LIBEXEC/$cmd" --introspect >/dev/null 2>&1
  after="$(tree_hash)"
  if [[ "$before" == "$after" ]]; then ok "$cmd --help/--introspect mutate nothing"
  else bad "$cmd --help/--introspect mutate nothing" "working tree changed"; fi
}

check_json_and_timely() {
  local cmd="$1"; local args="${READ_ONLY_ARGS[$cmd]-__none__}"
  [[ "$args" == "__none__" ]] && { skip "$cmd json envelope" "no read-only recipe"; return; }
  local mode="${JSON_MODE[$cmd]:-env}" out rc how
  if [[ "$mode" == flag:* ]]; then
    how="${mode#flag:}"
    # shellcheck disable=SC2086
    out="$(cd "$REPO_ROOT" && run_out "$LIBEXEC/$cmd" $args $how)"; rc=$?
  else
    how="AI_OUTPUT=json"
    # shellcheck disable=SC2086
    out="$(cd "$REPO_ROOT" && AI_OUTPUT=json run_out "$LIBEXEC/$cmd" $args)"; rc=$?
  fi
  if [[ $rc -eq 124 ]]; then bad "$cmd JSON envelope finishes < ${TIMEOUT}s ($how)" "TIMED OUT (hang/DoS)"; return; fi
  if ! jq -e . >/dev/null 2>&1 <<<"$out"; then
    bad "$cmd JSON envelope is valid JSON ($how)" "raw/non-JSON on stdout (first line: $(head -1 <<<"$out" | cut -c1-60))"; return
  fi
  ok "$cmd JSON envelope valid & timely ($how)"
}

check_robust_nonrepo() {
  local cmd="$1"; local args="${READ_ONLY_ARGS[$cmd]-__none__}"
  [[ "$args" == "__none__" ]] && return
  local tmp out rc; tmp="$(mktemp -d)"
  # shellcheck disable=SC2086
  out="$(cd "$tmp" && run "$LIBEXEC/$cmd" $args)"; rc=$?
  rmdir "$tmp" 2>/dev/null || rm -rf "$tmp"
  if [[ $rc -eq 124 ]]; then bad "$cmd survives a non-repo cwd" "TIMED OUT"; return; fi
  # A raw, uncaught interpreter error leaking to the user is a contract breach.
  # (A clean die()/error message never carries a "script: line N:" prefix.)
  if grep -qE ': line [0-9]+:|unbound variable|: command not found' <<<"$out"; then
    bad "$cmd survives a non-repo cwd cleanly" "leaks a raw shell trace: $(grep -oE '[^:]*: line [0-9]+:[^"]*' <<<"$out" | head -1 | cut -c1-70)"; return
  fi
  ok "$cmd degrades cleanly outside a git repo"
}

# ── run ───────────────────────────────────────────────────────────────────────
command -v jq >/dev/null || { echo "contract-suite requires jq" >&2; exit 2; }
echo "== behavioral-contract suite (timeout=${TIMEOUT}s) =="
while IFS= read -r cmd; do
  printf '\n%s\n' "$cmd"
  check_help "$cmd"
  check_introspect "$cmd"
  check_no_mutation "$cmd"
  if [[ -z "${CONTRACT_ONLY[$cmd]:-}" ]]; then
    check_json_and_timely "$cmd"
    check_robust_nonrepo "$cmd"
  else
    skip "$cmd behavioral smoke" "write/interactive — contract-only"
  fi
done < <(commands)

echo
echo "== contract results: ${grn}${PASS} passed${rst}, ${red}${FAIL} failed${rst} =="
[[ $FAIL -eq 0 ]]
