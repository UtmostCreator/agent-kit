# restsift command audit — findings

_Full-surface audit of all 28 `libexec/` commands: every subcommand/mode exercised
with valid, invalid, and edge inputs; defects fixed; output quality improved._

This report documents **what the audit found and what was done about it**. Everything
below is verified against the test suite (`scripts/check.sh`) unless explicitly marked
_deferred_. Deferred items are safe, deliberate non-changes that need a product
decision — they are listed so nothing is silently dropped.

## Summary

| Category | Count | Status |
| --- | ---: | --- |
| Functional defects found & fixed | 55 | ✅ fixed, regression-tested |
| Output-quality improvements applied | 103 | ✅ backward-compatible, tested |
| Improvements already satisfied | 14 | ✅ verified present |
| Improvements deferred (need a decision) | 19 | ⏸ see §4 |
| Shared-file follow-ups deferred | 16 | ⏸ see §5 |

Backward compatibility is preserved throughout: existing/default (human) output is
byte-identical; all new machine output is opt-in via `AI_OUTPUT=json` (or an additive
`--json` flag).

## 1. Functional defects fixed

Exercising every command's full surface surfaced 48 defects across 23 commands in the
first pass, plus 7 more found by cross-checking an independent review, plus a baseline
lint warning. All fixed with focused regression tests.

### High-severity (correctness / broken contract)
- **`refactor-scan`** — a clean scan and `--fail-on-findings` returned the wrong exit
  code (1 instead of 0/3): a `set -e` trip in `rs_render_human` fired before the
  fail-on-findings check.
- **`search-multi files`** — the `files` mode was non-functional; `files` was
  misclassified in the query family and every invocation errored.
- **`structured validate-json`** — an empty/whitespace-only file was reported as valid
  JSON (a false positive on a validation gate).
- **`all-f-into-one`** — the rotation `.bak` was re-collected each run, embedding the
  previous combined output and causing unbounded nested duplication.
- **`search` (history `--patch`)** — a large commit patch aborted with `jq: Argument
  list too long` (exit 126); the real bottleneck was the shared envelope emitter
  passing `matches`/`results` on the command line. Fixed with `--slurpfile` (files).
- **`search`/`s` (`diff --base`)** — one `grep` subprocess **per added line** made
  `diff --base` time out on large diffs; replaced with a single-pass grep (exact
  match semantics preserved, verified with a path-vs-text false-match guard).

### Common defect classes (fixed across many commands)
- **`set -u` value-flag crashes** leaking `file:line` instead of a clean error —
  `context estimate`, `fd-files --type`, `preview-file`, `git`, `rollback --days`,
  `rg-code`, `test select`, `verify --language`.
- **Success on bad input (exit 0 on garbage)** — `doctor`, `repo-stats`,
  `file-freshness`, `all-f-into-one`, `s` (empty query), `search-introspect`,
  `verify` (bad `AI_VERIFY_SCOPE`).
- **Broken `--introspect`/`--help` contracts** — `inspect`, `session`, `repo`,
  `file-freshness`, `watch-loop`, `preview-file` (examples dropped because the
  `# Example:` block sat below the `source` line), `git pr-context`/`git blame`
  (`--help` consumed as a positional).
- **Destroyed JSON envelopes** — `edit` (dirty-tree, unknown-mode, bad numeric flag),
  `search` (file-root abort emitting no envelope), `preview-file`, `rg-code` tracked
  mode ignoring `--json`.
- **Misleading contract** — `search-multi --introspect` advertised a dead
  `MAX_QUERIES` env var; only `AI_SEARCH_MULTI_MAX` controls the cap.
- **Baseline lint** — one `SC2318` in `libexec/internal/completion-spec` that halted
  `scripts/check.sh`.

## 2. Output improvements applied (103)

Applied per command, all backward-compatible:

- **Opt-in `AI_OUTPUT=json` / `--json` envelopes** added to commands that only spoke
  human text: `repo-stats`, `fd-files`, `doctor`, `context estimate`, `all-f-into-one`,
  `rollback list`/`show`, `session-checkpoint`, `watch-loop`, `sh-introspect --list`,
  `structured validate-*`, `rg-code`, `verify`, `search-introspect`, and more — each
  using the repo's `{"schema":"ai.<tool>/v1","status":...}` convention.
- **Actionable next-step hints** appended to stderr error paths (e.g. "run
  'restsift … --help'", "install ripgrep (rg)", "run inside a git repository").
- **Exit-code contracts documented** in `--help`/`--introspect` headers.
- **`--introspect` `modes[]`/`flags[]` populated** where empty (via a `# Modes:` header
  line the introspector reads) — `refactor-scan`, `s`, `rg-code`, `doctor`,
  `search-introspect`, `preview-file`, and others.
- **Sharper errors** naming the offending value/path; doubled `Usage:` headers fixed.

## 3. Improvements already satisfied (14)

14 recommendations were already met by the toolkit (e.g. `edit` already routes every
JSON error path through a single `ai.edit/v1` envelope; `edit` already excludes its own
`.ai-logs/` from `changedFiles`). Verified live and by existing tests.

## 4. Deferred — need a product decision (19)

These were intentionally **not** applied because they would change default/human output
that tests or downstream scripts may depend on, alter a command's default execution, or
were vague. Each is a real, reasonable idea — decide per item:

| Command | Item | Why deferred |
| --- | --- | --- |
| `context` | Summarize the secrets-gate raw JSON dump | Needs shared `lib/secrets.sh` / internal engines |
| `task` | Native-vs-fallback command text; `.PHONY` filtering; session side-effects | Changes default `list`/`json` output; session logging is shared |
| `verify` | Treat default scope `ai` like changed/branch for broad scanners | Changes default execution/output |
| `test` | Fold the 4 validators into one run-all accounting loop | Changes default human output |
| `repo` | JSON mode for `stats`/`status` | Routes to independent sibling commands (see §5) |
| `s` | Better bad-ROOT error; `diff` perf | Lives in `ai-search`-owned files, not `ai-s` |
| `search-introspect` | Make `--probe` a nonzero CI health gate | Changes the always-0 exit contract |
| `search-multi` | Label/replace the `---` batch separator | Changes default human stdout format |
| `session` | Routed sub-help naming the invoked path | Engine prints its own name via `exec` |
| `repo-stats` | Label the bare integer in human mode | Breaks the `^[0-9]+$` stdout contract |
| `repo-tool-inventory` | Fix truncated summary; trailing space | Root cause is shared `sh-introspect` |
| `refactor-scan` | Trailing machine-readable summary in human output | Changes default output format |
| `file-freshness` | Non-repo stderr + nonzero exit; affirmative "clean" line | Flips historic exit-0 / default output |

## 5. Shared-file follow-ups deferred (16)

The audit ran each command confined to its **own** files (no cross-command shared-file
edits, to keep every change self-contained and conflict-free). These improvements are
real but need a coordinated change to a shared module — grouped for a follow-up slice:

- **`libexec/sh-introspect`** — extract an `Exit codes:` section into the introspect
  JSON; trim a trailing space in `Requires:/Modes:/Flags:` rendering; join a
  multi-line comment synopsis instead of taking only the first physical line;
  surface `CI` in extracted env. (Affects `git`, `watch-loop`, `task`,
  `repo-tool-inventory`, `rollback`.)
- **`lib/secrets.sh`** / repomix internal engines — summarize the secrets-gate hit
  list and reorder scan-vs-validate so a typo'd subcommand doesn't report "secrets
  detected". (`context`.)
- **`lib/snapshot.sh`** — unborn-branch guard ("no commits yet") and filter the
  command's own `.ai-logs/` artifacts out of captured untracked files.
  (`session-checkpoint`, `rollback`.)
- **`libexec/repo-stats` / `libexec/ai-file-freshness`** — add opt-in JSON so
  `repo status --json` / `repo stats --json` surface structured data. (`repo`.)

## Verification

- `scripts/check.sh` — ShellCheck (all shell files) + the full test suite — is green
  (**35 test files · 888 passing · 8 skipped · 0 failing · 0 ShellCheck warnings**).
- `scripts/coverage.sh` — **69.32% line coverage (6488/9359 executable lines across
  115 files)**, holding steady while ~1000 lines of new JSON-envelope code landed.
- New JSON envelopes and flags each carry a test; default/human output is unchanged.
- Run the suite for correctness with fully-serial output:
  `CHECK_SHELLCHECK_JOBS=1 ./scripts/check.sh`, or one suite via
  `bash test/test-<command>.sh`.
