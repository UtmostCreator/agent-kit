# Packages per command

What each `agent-kit` command actually shells out to, why, a real captured
example (run against a live clone or an isolated sandbox — see notes per
command), and why it beats reaching for the raw tool directly. The exact
supported flags remain authoritative in each command's `--help`/`--introspect`
output; this file explains *dependencies* and *rationale*, not the full flag
grammar.

Commands are shown as `agent-kit <command>` (the leading `ai-` in a
`libexec/ai-*` filename is optional — see [COMMANDS.md](COMMANDS.md)).

## Quick reference

| Tier | Packages | Unlocks |
|---|---|---|
| **Core** (required) | `bash` 4.4+, `git`, `ripgrep` (`rg`), `jq` | Baseline for nearly every command — search, git inspection, JSON envelopes. |
| **Optional — search/edit** | `fd`/`fdfind`, `ast-grep`/`sg`, `sd`, `comby` | `search files`, `search struct`/`symbols`/`class`, `edit ast-grep`, `edit sd`, `edit comby`. |
| **Optional — context** | `repomix` (Node), `files-to-prompt`, `code2prompt` | `context pack`/`file`/`generate`/`tree` (auto-detected in that preference order). |
| **Optional — structured data** | `yq`, `mlr` (Miller) or `csvcut`, `xmllint` | `structured yaml`/`csv`/`xml`, `inspect data`. |
| **Optional — git/PR** | `gh` (GitHub CLI) | `git pr-context`. |
| **Optional — verify/test** | `lychee`, `markdownlint`, `vendor/bin/phpunit`/`paratest`, `bats` | `verify docs links`/`markdownlint`, `test run`/`all` (consumer-project test runners, not agent-kit's own suite). |
| **Optional — watch/session** | `watchexec` or `entr`, `tar` | `session watch`/`watch-loop`, `session checkpoint`/`session-checkpoint` (untracked-file archive). |
| **Optional — misc** | `bat`, `just`, `osascript` (macOS) | Prettier `preview-file` output, `repo tasks`/`ai-task` justfile detection, `all-f-into-one` completion notification. |

See [INSTALL.md](../INSTALL.md) for install instructions and the macOS Bash note. The
root [README.md](../README.md) "Runtime" section lists the same core/optional split
at a glance.

---

### `agent-kit context` (`libexec/ai-context`)

**What it does:** Canonical context-building command group — fuses `diff`, `pack`, `file`, `generate`, `tree`, `status`, `ensure`, and `estimate` into one entrypoint for building/checking AI context bundles.

**Safety:** read-only for `status`/`diff --dry-run`/`estimate`; `pack`/`file`/`generate` write files (tested in an isolated sandbox).

**Packages used:**
| Package | Why |
|---|---|
| `git` | `estimate.sh` uses `git ls-files` to size a repo's tracked bytes; `diff.sh`/pack backends diff against git state. |
| `rg` | `estimate.sh` falls back to `rg --files` when not inside a git repo. |
| `jq` | `pack.sh`/`status.sh` build/parse the JSON manifest and session envelopes. |
| `repomix` | Primary context-packer backend for `pack`/`file`/`generate`/`tree` (Node-based bundler producing the XML/token-counted context file). |
| `files-to-prompt` / `code2prompt` | Alternative pack backends, auto-detected via `command -v` when `repomix` is absent. |

**Real-world example**
```bash
$ agent-kit context status .
{
  "schema": "1", "tool": "repomix-freshness", "status": "missing",
  "manifest": "/home/.../agent-kit/.repomix-context/tree-context/run-manifest.json",
  "regenerate": "agent-kit context generate .",
  "message": "no Repomix context manifest at .repomix-context/tree-context/run-manifest.json"
}

$ agent-kit context diff unstaged --dry-run
{
  "dry_run": true, "label": "unstaged",
  "output": ".repomix-context/diff/unstaged-20260714-013311.xml",
  "file_count": 4, "estimated_input_tokens": 446402, "token_budget": 80000
}

# sandbox only — real write:
$ agent-kit context pack repomix --include "*.md"
✔ Packing completed successfully!
Total Files: 1 files   Total Tokens: 406 tokens
```

**Why this beats the raw command:** Every mode returns one consistent JSON envelope instead of each backend's own ad-hoc output. `diff --dry-run` computes `estimated_input_tokens` vs. `token_budget` *before* anything is written — raw `repomix`/`git diff` piping doesn't give you that. `pack` auto-detects whichever of three different packer binaries is actually installed, instead of requiring the caller to know which one is present.

---

### `agent-kit edit` (`libexec/ai-edit`)

**What it does:** Guarded repository-edit entrypoint over four modes (`ast-grep`, `comby`, `sd`, `patch`) with a mandatory dry-run-first workflow and automatic pre-apply snapshotting.

**Safety:** guarded-mutation — always tested in an isolated sandbox, never against a real project directly from this doc's examples.

**Packages used:**
| Package | Why |
|---|---|
| `rg` | Plans `sd`-mode replacements with `rg --count-matches` to produce an exact per-file count before anything touches disk. |
| `sd` | Actual text-replacement engine invoked once per planned file. |
| `ast-grep`/`sg` | Structural AST-aware rewrite engine for `ast-grep` mode. |
| `comby` | Generic structural rewrite engine for `comby` mode (`-in-place`). |
| `git` | `patch` mode preflights with `git apply --check`/`--numstat`, applies with `git apply --whitespace=warn`; also powers snapshot/rollback. |
| `jq` | Builds/parses the planned-changes JSON and session manifest across all modes. |

**Real-world example**
```bash
$ agent-kit edit sd OldName NewName /tmp/sandbox --dry-run   # AI_OUTPUT=json
{
  "schema": "ai.edit/v1", "status": "dry_run", "mode": "sd",
  "plannedChanges": [
    {"path": ".../sample.md", "replacements": 2, "bytes": 59},
    {"path": ".../sample.sh", "replacements": 1, "bytes": 33}
  ],
  "limits": {"maxFiles": 50, "maxReplacements": 500, "maxBytes": 2000000}
}

# real apply, sandbox only:
$ agent-kit edit patch /tmp/sandbox/staged.diff . --apply
{"status": "applied", "mode": "patch",
 "changedFiles": [".ai-logs/snapshots/....pre-edit-013611.patch",
                   ".ai-logs/snapshots/....pre-edit-013611.untracked.tar.gz", "sample.md"]}
```

**Why this beats the raw command:** Every apply is preceded by a snapshot (`.patch` + untracked-file tarball + manifest under `.ai-logs/snapshots/`) — a real rollback path raw `sd`/`git apply`/`comby -in-place` never create on their own. `sd` mode plans with `rg --count-matches` first so the caller sees exact counts before any bytes change, and hard bounds (`--max-files`, `--max-replacements`, `--max-bytes`) reject runaway edits. `patch` mode preflights with `git apply --check` plus a path denylist (blocks `.git`, secret-like paths) before ever applying.

---

### `agent-kit file-freshness` (`libexec/ai-file-freshness`)

**What it does:** Prints `git status --short` scoped to `docs`, `.github`, `.opencode`, and `AGENTS.md` — a quick check for uncommitted changes to agent-facing files.

**Safety:** read-only

**Packages used:**
| Package | Why |
|---|---|
| `git` | The entire script is one line: `git status --short docs .github .opencode AGENTS.md`. |

**Real-world example**
```bash
$ agent-kit file-freshness
(no output — docs/.github/.opencode/AGENTS.md all clean)
```

**Why this beats the raw command:** It's a curated path list an agent doesn't have to remember or guess — a bare `git status --short` also surfaces every unrelated untracked/dirty path in the repo, which is noise for a "did the agent-facing docs drift" check.

---

### `agent-kit git` (`libexec/ai-git`)

**What it does:** Canonical git-inspection command group — fuses branch-origin detection, commit-history search (`-S`/`-G`/`-L`), `blame`, and GitHub PR context.

**Safety:** read-only (`origin`/`history`/`blame`); `pr-context` needs network + `gh`.

**Packages used:**
| Package | Why |
|---|---|
| `git` | `origin.sh` uses `for-each-ref`/`merge-base`/`rev-list --count` to find the most-likely parent branch; `forensics.sh` wraps `git log -S/-G/-L` and `git blame -L`. |
| `jq` | JSON-mode output assembly across `origin.sh`/`forensics.sh`/`pr-context.sh`. |
| `gh` | `pr-context.sh` calls `gh pr view/checks/diff` for PR metadata, CI status, and diff content. |

**Real-world example**
```bash
$ agent-kit git origin --json
{"status":"ok","current_branch":"release/v0.1.0-prep","origin_branch":"main",
 "merge_base":"e79e3ed0...","distance":2}

$ agent-kit git blame 1,5 README.md
55699711 (Utmost Creator 2026-07-13 17:50:47 +0100 1) <div align="center">
55699711 (Utmost Creator 2026-07-13 17:50:47 +0100 3) # 🧰 AgentKit
```

**Why this beats the raw command:** `origin` ranks multiple candidate parent branches by commit distance and returns the winner plus every candidate considered — a single raw `git merge-base` call can't do that without the caller already knowing the right branch name. `pr-context --pack` routes into the context engine to bundle the PR diff as a token-estimated artifact in one call.

---

### `agent-kit inspect` (`libexec/ai-inspect`)

**What it does:** Canonical read-only inspection command group — routes `file` (safe preview), `data` (JSON/YAML/CSV/XML query), and `shell` (static shell-script contract introspection).

**Safety:** read-only

**Packages used:**
| Package | Why |
|---|---|
| `jq` | `data json`/`validate-json` modes and every JSON envelope emitted downstream. |
| `xmllint` | `data xml` mode for `--xpath` queries or pretty-formatting. |
| `rg`, `git` | Underlying `sh-introspect` static-parsing dependency set. |

**Real-world example**
```bash
$ agent-kit inspect file README.md --range 1:5 --plain
<div align="center">

# 🧰 AgentKit
...

$ agent-kit inspect data json package.json '.name, .version'
"@utmostcreator/agent-kit"
"0.1.0"
```

**Why this beats the raw command:** `inspect file` has a real safety gate — a 64KiB size cap, binary-content blocking, and `.git`-internals blocking (bypassable only with an explicit `--force`) — so an agent can't accidentally dump a huge binary or `.git/objects` blob into context the way a raw `cat`/`head` would.

---

### `agent-kit repo` (`libexec/ai-repo`)

**What it does:** Canonical repository-metadata command group — routes `tasks`, `stats`, `tools`, and `status`.

**Safety:** read-only

**Packages used:**
| Package | Why |
|---|---|
| `git` | `stats` is `git ls-files \| wc -l`; `status` is `git status --short` on the curated path list. |
| `jq` | `tasks` reads `package.json`/`composer.json` script blocks and normalizes them to JSON; `tools` aggregates every command's `sh-introspect --format=json` output. |
| `just` | `tasks` shells out to `just --summary` when a `justfile` is present. |

**Real-world example**
```bash
$ agent-kit repo stats
179

$ agent-kit repo tasks list
{"package_manager":"npm","package_scripts":{},"composer_scripts":{},
 "just_tasks":[],"make_tasks":[],"taskfile_tasks":[]}
```

**Why this beats the raw command:** `repo tasks` normalizes four different task-declaration ecosystems (npm scripts, composer scripts, `just --summary`, Makefile targets) into one JSON shape instead of requiring the caller to know which of `cat package.json`, `composer.json`, `just --summary`, or `grep Makefile` applies.

---

### `agent-kit rollback` (`libexec/ai-rollback`)

**What it does:** Reviews and applies repository-local guarded-edit snapshots (`.ai-logs/snapshots/`) created by other AgentKit tooling.

**Safety:** read-only for `list`/`show`; `apply`/`prune` are mutating and gated behind an interactive confirmation.

**Packages used:**
| Package | Why |
|---|---|
| `git` | `show` uses `git show --stat`/`git apply --stat` to preview a diff without touching the working tree; `apply` uses git plumbing to restore tracked files. |
| `jq` | Filters manifest JSON down to relevant fields for display. |
| `find` | Globs `.ai-logs/snapshots/*.manifest.json`/`*.patch`/`*.ref`. |

**Real-world example**
```bash
$ agent-kit rollback list
SNAPSHOT                                                      TYPE          SIZE   DATE
====================================================================================
session-checkpoint-20260714-013358-....patch                  legacy-patch  0      2026-07-14 01:33
ai-edit-20260714-013356-106376-pre-edit-013356.patch          legacy-patch  0      2026-07-14 01:33
6 snapshot artifact(s) found
```

**Why this beats the raw command:** It resolves a fuzzy session/id prefix to the exact snapshot file, distinguishes manifest-based vs. legacy `.patch`/`.ref` formats and dispatches to the right preview path automatically, and gates destructive `apply`/`prune` behind a confirmation prompt — a raw `git apply` on a stale patch has none of that.

---

### `agent-kit search` (`libexec/ai-search`)

**What it does:** Unified repository search entrypoint dispatching to rg/git-grep/fd/git-log/ast-grep backends by named "mode", normalized into a stable envelope.

**Safety:** read-only

**Packages used:**
| Package | Why |
|---|---|
| `rg` | `text`/`docs`/`tests`/`config`/`deps`/`todo`/`unsafe-patterns` modes run `rg --json -H -n ...`. |
| `git` | `tracked` uses `git grep`; `changed-files`/`staged-files` use `git diff --name-only`/`git ls-files`; `diff`/`history` use `git log`/`git diff -U0`. |
| `fd`/`fdfind` | `files` mode; falls back to `git ls-files`/POSIX `find` with a warning if absent. |
| `ast-grep` | `struct`/`symbols`/`class` via `ast-grep run --lang ... --pattern ... --json`; fails closed if missing. |
| `jq` | Builds/reshapes the JSON result envelope throughout. |

**Real-world example**
```bash
$ agent-kit search doctor
ai-search doctor: ok

$ AI_OUTPUT=json agent-kit search text "TODO" . --files-with-matches
{"schema":"1","status":"ok","tool":"ai-search","query":"TODO","mode":"text",
 "matches":["./INSTALL.md:122:...","./libexec/ai-git:16:...", ...]}
```

**Why this beats the raw command:** `doctor` checks jq/git/rg/ast-grep/fd availability in one call and reports which mode degrades, instead of a raw command silently erroring. Every backend normalizes into one JSON envelope (`schema`/`status`/`matches`/`warnings`), so downstream tooling doesn't need per-backend parsing logic for rg vs. git-grep vs. ast-grep output shapes.

---

### `agent-kit search-introspect` (`libexec/ai-search-introspect`)

**What it does:** Prints the full mode/flag/env-var capability map for `ai-search`/`ai-search-multi`, parsed live from source.

**Safety:** read-only

**Packages used:**
| Package | Why |
|---|---|
| `awk` | Parses the mode-family `case` blocks out of `lib/ai-search/modes.sh` directly from source. |

**Real-world example**
```bash
$ agent-kit search-introspect
== MODES (grouped by family, parsed from ai-search.sh) ==
Content-search (QUERY required): changed-text class config config-key deps diff docs enum files ...
File-list (no QUERY):            changed-files staged-files
No-query curated:                todo unsafe-patterns
== ENVIRONMENT VARIABLES ==
  AI_LANG   AI_OUTPUT   AI_SEARCH_MULTI_MAX   AI_SEARCH_STRICT
```

**Why this beats the raw command:** Because it parses `modes.sh`/`contract.sh`/`parse-flags.sh` directly, the capability map can't drift out of sync with the real `ai-search` implementation the way a hand-written README table can.

---

### `agent-kit search-multi` / `agent-kit search batch` (`libexec/ai-search-multi`)

**What it does:** Runs one `ai-search` mode against multiple queries in a single invocation.

**Safety:** read-only

**Packages used:**
| Package | Why |
|---|---|
| (delegates entirely to `ai-search`) | Re-invokes `libexec/ai-search` as a subprocess per query — same transitive package set as `agent-kit search` (rg, git, fd, ast-grep, jq). |

**Real-world example**
```bash
$ AI_OUTPUT=json agent-kit search batch text foo bar . --files-with-matches
[
  {"schema":"1","status":"ok","query":"foo","matches":["./libexec/all-f-into-one:5:...", ...]},
  {"query":"bar", ...}
]
```

**Why this beats the raw command:** It caps batch size (`AI_SEARCH_MULTI_MAX`, default 20) to prevent an accidental fork-bomb of subprocess searches, rejects `unsafe-all` outright, and passes each query as a discrete quoted positional argument with no `eval`/`sh -c` — query text can't be interpreted as shell metacharacters the way a hand-rolled `for q in foo bar; do rg "$q"; done` loop risks if a caller forgets to quote.

---

### `agent-kit session` (`libexec/ai-session`)

**What it does:** Thin router for `session checkpoint [label]` (save a snapshot) and `session watch <command>` (re-run on file changes, blocks until Ctrl-C).

**Safety:** `checkpoint` is additive-only (new files under gitignored `.ai-logs/snapshots/`); `watch` blocks.

**Packages used:**
| Package | Why |
|---|---|
| `git` | `checkpoint` uses `git rev-parse HEAD`/`git diff` to build the patch and manifest. |
| `jq` | Builds the `.manifest.json` and structured log line. |
| `watchexec` (preferred) / `entr` (fallback) | `watch` requires one of these; `entr` path pipes `rg --files` into `entr -r`. |

**Real-world example**
```bash
$ agent-kit session checkpoint report-test
checkpoint created: .ai-logs/snapshots/session-checkpoint-20260714-013358-....manifest.json
```
(`.ai-logs/` is in `.gitignore`, so `git status --short` shows no change from this.)

**Why this beats the raw command:** It bundles a `git diff`/`HEAD` capture, an untracked-file archive, and a jq-built manifest into one atomic, labelled, timestamped artifact — a raw `git diff > x.patch` loses untracked files and has no manifest/label/session-id metadata for later lookup by `rollback list`/`show`.

---

### `agent-kit structured` (`libexec/ai-structured`)

**What it does:** Structured data query wrapper — one subcommand per format: `json` (jq), `yaml` (yq), `validate-json`/`validate-yaml`, `csv` (miller/csvcut/head), `xml` (xmllint).

**Safety:** read-only

**Packages used:**
| Package | Why |
|---|---|
| `jq` | `json`/`validate-json` run `jq "$query" "$file"` / `jq empty "$file"`. |
| `yq` | `yaml`/`validate-yaml` run `yq "$query" "$file"` / `yq '.' "$file"`. |
| `mlr` (Miller) / `csvcut` | `csv` prefers `mlr --icsv --opprint head -n N`, falls back to `csvcut \| head`, then plain `head`. |
| `xmllint` | `xml` runs `xmllint --xpath`/`--format`; no fallback if absent. |

**Real-world example**
```bash
$ agent-kit structured json package.json '.bin'
{
  "agent-kit": "npm/cli.js"
}
```

**Why this beats the raw command:** It picks the right tool per format behind one consistent `structured <format> FILE QUERY` interface instead of requiring the caller to remember which binary handles which format, and validates the file exists before invoking the parser.

---

### `agent-kit task` (`libexec/ai-task`)

**What it does:** Discovers a project's already-defined task commands (npm/composer/just/make/Taskfile) and recommends the right `verify`/`test` command instead of guessing.

**Safety:** read-only

**Packages used:**
| Package | Why |
|---|---|
| `jq` | Reads `.scripts`/`.packageManager` from `package.json` and `.scripts` from `composer.json`, assembles the inventory JSON. |
| `just` | If a `justfile` exists, `just --summary` lists just-tasks and is preferred in `recommend_command`. |
| `yq` | If a `Taskfile.yml`/`.yaml` exists, `yq -o=json '.tasks \| keys'` extracts task names. |

**Real-world example**
```bash
$ agent-kit task test
scripts/ai/ai-verify.sh .

$ agent-kit task verify
scripts/ai/ai-verify.sh .
```

**Why this beats the raw command:** It actually inspects `package.json`, `composer.json`, `justfile`, `Makefile`, and `Taskfile.yml` before recommending anything, instead of guessing a generic `npm test` that could fail if the project uses a different task runner.

---

### `agent-kit test` (`libexec/ai-test`)

**What it does:** Canonical test group — `select` maps changed files/symbols to relevant tests, `run` executes a focused PHPUnit selection, `all` runs every discovered suite (paratest/phpunit/bats) with parallel-first defaults. These target a *consumer* project's own test suite (e.g. this repo's own `scripts/check.sh`/bats tests), not agent-kit's internal test format specifically.

**Safety:** read-only for `select`; `run`/`all` are guarded-mutation (heavy test execution).

**Packages used:**
| Package | Why |
|---|---|
| `git` | `select changed` builds the candidate file set from `git diff --name-only`, `git diff --cached --name-only`, `git ls-files --others --exclude-standard`. |
| `jq` | Renders every selection mode's output as JSON. |
| `rg` | `select symbol` uses `rg -l --hidden` to find files referencing a given symbol. |
| `vendor/bin/phpunit` | `run` execs `vendor/bin/phpunit --configuration phpunit.xml.dist "$@"` in a PHP consumer project. |
| `vendor/bin/paratest` (falls back to phpunit) | `all` prefers parallel `paratest --runner=WrapperRunner`, falls back to serial phpunit. |
| `timeout`/`gtimeout` | Wraps focused/all runs with a kill-after timeout when available. |
| `bats` | `all` also discovers and runs a Bats shell-test suite if present. |

**Real-world example**
```bash
$ agent-kit test select changed
{"input_files": [...], "candidate_tests": [], "recommended_commands": []}

$ agent-kit test all --help
ai-test/run-all.sh — run the repository's existing test suites with
parallel-first defaults (the HEAVY, whole-suite runner).
Example:
  PARATEST_PROCS=8 agent-kit test all
```

**Why this beats the raw command:** `select changed` only recommends tests actually touched by the current diff instead of blindly running the whole suite; `run`/`all` centralize timeout-wrapping and paratest/phpunit auto-detection that a hand-typed `vendor/bin/phpunit` command doesn't have.

---

### `agent-kit verify` (`libexec/ai-verify`)

**What it does:** Project-aware verification gate; the root command runs a full change-scoped pipeline, `verify docs` checks markdown lint/links/drift, `verify refs` finds orphaned tracked files.

**Safety:** read-only for `verify docs`/`verify refs`; the full root pipeline can run linters/tests.

**Packages used:**
| Package | Why |
|---|---|
| `git` | `verify refs` builds its candidate list from `git ls-files`. |
| `rg` | `verify refs` searches for references to each candidate basename via `rg --fixed-strings --files-with-matches`. |
| `jq` | Emits the refs-orphan report as JSON, used throughout docs-check/reporting. |
| `lychee` | `verify docs links` runs `lychee --offline --accept "200..=299,403,429"` — offline-only, never dials live URLs. |
| `markdownlint` | `verify docs markdownlint`/`all` runs it if installed, else warns and skips. |

**Real-world example**
```bash
$ agent-kit verify docs links README.md
🔍 23 Total 🔗 21 Unique ✅ 11 OK 🚫 0 Errors 👻 12 Excluded

$ agent-kit verify refs docs --ext md
docs/SECURITY_MODEL.md
```

**Why this beats the raw command:** `verify docs links` forces `lychee --offline` so link-checking can never make a live network call even if a doc has external URLs; `verify refs` cross-references `git ls-files` against `rg` hits per-basename to flag orphaned docs — something a plain `lychee`/`grep` sweep wouldn't assemble on its own.

---

### `agent-kit all-f-into-one` (`libexec/all-f-into-one`)

**What it does:** Recursively collects tracked-tree files (pruning `.git`/`node_modules`/`dist`/etc.) and writes their contents into one `combined_output.txt` at the current project root.

**Safety:** guarded-mutation — writes at `$(pwd)`; tested only in an isolated sandbox.

**Packages used:**
| Package | Why |
|---|---|
| `find` | Walks the tree and prunes ignored directory subtrees/excluded files via a dynamically built `find ... -prune -o ... -print0` expression. |
| `sh-introspect` (repo-internal) | `--help`/`--introspect` exec the sibling script to statically parse this one's own contract. |
| `osascript` (optional, macOS only) | Desktop notification on completion; no-op elsewhere. |

**Real-world example**
```bash
$ cd /tmp/sandbox && all-f-into-one
Success: Combined file created at: /tmp/sandbox/combined_output.txt

$ cat combined_output.txt
===== START FILE: docs/sample.md =====
# Sample doc
Some text.
===== END FILE: docs/sample.md =====
```

**Why this beats the raw command:** It auto-prunes `.git`/`node_modules`/`dist`/`build`/`.next`/`.venv` subtrees (a hand-rolled `find . -type f | xargs cat` would dump `.git` internals and vendor trees too), rotates any prior `combined_output.txt` to a timestamped `.bak` instead of clobbering it, and wraps each file in a machine-parseable `START FILE`/`END FILE` block.

---

### `agent-kit fd-files` (`libexec/fd-files`)

**What it does:** Repo-aware file discovery wrapper around `fd` (falling back to `rg --files` if `fd`/`fdfind` isn't installed), pre-excluding `vendor`, `node_modules`, `dist`, `.git`, `.repomix-context`.

**Safety:** read-only

**Packages used:**
| Package | Why |
|---|---|
| `fd`/`fdfind` | Primary discovery engine, invoked with a standard exclusion set. |
| `rg` | Fallback path when neither `fd`/`fdfind` exists. |
| `jq` | Required unconditionally; renders `--json` output as a JSON array. |

**Real-world example**
```bash
$ agent-kit fd-files README .
./README.md

$ agent-kit fd-files SECURITY docs --type md --json
["docs/SECURITY_MODEL.md"]
```

**Why this beats the raw command:** It bakes in the standard noise-exclusion set on every call and transparently degrades from `fd` to `rg --files` with equivalent filtering when `fd` isn't installed.

---

### `agent-kit preview-file` (`libexec/preview-file`)

**What it does:** Safely previews a bounded slice of a text file (`--range`, `--around`/`--context`, or `--lines`, default first 200 lines) with size/binary/`.git`-path guardrails and per-line column truncation.

**Safety:** read-only

**Packages used:**
| Package | Why |
|---|---|
| `sed` | Extracts the requested line range/window. |
| `wc` | Computes file byte size for the 64KiB max-bytes gate and total line count. |
| `tr` | Counts NUL bytes to detect and block binary files unless `--force`. |
| `awk` | Truncates any displayed line longer than `--max-columns` (default 200). |
| `jq` | Builds the structured JSON envelope when `AI_OUTPUT=json`. |
| `bat` (optional) | Syntax-highlighted pretty-print when installed and not `--plain`. |

**Real-world example**
```bash
$ agent-kit preview-file README.md --range 1:20 --plain
<div align="center">

# 🧰 AgentKit
...
```

**Why this beats the raw command:** Unlike a raw `sed -n '1,20p' file`, it gates on file size and NUL-byte binary detection first so a large or binary file can't flood the agent's context, blocks `.git/` internal paths outright, and truncates over-long lines.

---

### `agent-kit repo-stats` (`libexec/repo-stats`)

**What it does:** Counts the files Git currently tracks in this repository.

**Safety:** read-only

**Packages used:**
| Package | Why |
|---|---|
| `git` | The entire logic is `git ls-files \| wc -l`. |
| `wc` | Counts the lines/paths `git ls-files` emits. |

**Real-world example**
```bash
$ agent-kit repo-stats
179
```

**Why this beats the raw command:** It's a documented, discoverable one-liner that also plugs into the toolkit's uniform `--help`/`--introspect` contract, so an agent can learn its exact behavior without executing it or reading source.

---

### `agent-kit repo-tool-inventory` (`libexec/repo-tool-inventory`)

**What it does:** Lists every toolkit command with its one-line summary, statically parsed from each script's header comment (never executed).

**Safety:** read-only

**Packages used:**
| Package | Why |
|---|---|
| `jq` | Reshapes each command's `sh-introspect --format=json` output into `{name, summary}` and slurps them into one JSON envelope. |

**Real-world example**
```bash
$ agent-kit repo-tool-inventory | head -3
  ai-context               ai-context — canonical context-building command group (thin loader).
  ai-edit                  Guarded edit wrapper for broad repository modifications (thin loader).
  ai-file-freshness        Show which docs/config files have uncommitted changes (git status of key paths).
```

**Why this beats the raw command:** There is no raw-command equivalent — it's a purpose-built catalog generator that never executes any listed script (static parsing only), so surveying the whole command surface, including ones with side effects like `edit`/`rollback`, is guaranteed side-effect-free.

---

### `agent-kit rg-code` (`libexec/rg-code`)

**What it does:** Production-grade code search wrapper with repo-aware defaults, built on `rg`.

**Safety:** read-only

**Packages used:**
| Package | Why |
|---|---|
| `rg` | The core search engine for every mode (`default`/`all`/`php`/`js`/`blade`/`kotlin`/`config`). |
| `jq` | Only in `--json` output mode, reshaping ripgrep's native `--json` match stream into a flat array. |
| `git` | Only in `tracked` mode, shelling out to `git grep` instead of `rg`. |

**Real-world example**
```bash
$ agent-kit rg-code "snapshot_create" . --files
./libexec/session-checkpoint
./lib/snapshot.sh
./lib/ai-edit/main.sh
```

**Why this beats the raw command:** Raw `rg` requires remembering to exclude `vendor`, `node_modules`, `dist`, `.git`, `.repomix-context`, minified/lockfiles, and snapshot files every time; `rg-code` bakes a base exclude list into every mode and gives named, pre-globbed modes instead of hand-writing `-g` patterns each time.

---

### `agent-kit session-checkpoint` (`libexec/session-checkpoint`)

**What it does:** Creates a repository-local checkpoint (patch + manifest + untracked-file archive) using the shared snapshot system.

**Safety:** additive (new files under `.ai-logs/snapshots/`, never modifies existing tracked files)

**Packages used:**
| Package | Why |
|---|---|
| `git` | `git rev-parse`, `git diff --binary HEAD` captures the working-tree diff; `git ls-files --others --exclude-standard` lists untracked files. |
| `jq` | Builds the JSON manifest (`version`, `session`, `label`, `base_ref`, timestamps) and the final log event. |
| `tar` | Archives untracked files so a rollback can restore them; degrades gracefully with a warning if missing. |

**Real-world example**
```bash
$ agent-kit session-checkpoint doc-research-test
checkpoint created: .ai-logs/snapshots/session-checkpoint-20260714-013356-....manifest.json
```

**Why this beats the raw command:** A raw `git diff`/`git stash` only covers tracked-file changes; this also snapshots *untracked* files (via the `tar` archive) and writes a structured, session-tagged JSON manifest that `agent-kit rollback` can later parse to restore both tracked and untracked state.

---

### `agent-kit sh-introspect` (`libexec/sh-introspect`)

**What it does:** Universal shell-script introspector — statically parses a Bash/Zsh script's header comments to report description, usage, examples, flags, env vars, and required commands, without ever executing the target.

**Safety:** read-only

**Packages used:**
| Package | Why |
|---|---|
| `awk` | Core parsing engine — state machines walk the leading `#` comment block and heredoc bodies without sourcing/executing the file. |
| `grep` | Regex-matches flag case labels, env-var references, and infers required binaries from `command -v X` calls. |
| `jq` | Used only for `--format=json` rendering, building the `ai.sh-introspect/v1` JSON envelope. |

**Real-world example**
```bash
$ agent-kit sh-introspect libexec/ai-search | head -4
ai-search
ai-search.sh — unified repository search entrypoint (thin facade).
Usage:
  agent-kit search <mode> [query] [root] [flags]
```

**Why this beats the raw command:** `--help` on a shell script normally means either reading raw source (risky for scripts with side effects like `edit`/`rollback`) or trusting that script's own flag parser; `sh-introspect` guarantees the target is **never executed** and produces the same output whether rendered as a human report, a compact `--help` snippet, or a stable JSON contract.

---

### `agent-kit watch-loop` (`libexec/watch-loop`)

**What it does:** Re-runs a command automatically whenever watched files change (blocks until Ctrl-C).

**Safety:** additive (writes an append-only JSON event log at `.ai-logs/watch-loop.jsonl`; does not modify/delete existing files)

**Packages used:**
| Package | Why |
|---|---|
| `watchexec` | Preferred watcher — `watchexec --debounce ... -e "$extensions" -- bash -lc "$command"` when present. |
| `entr` | Fallback watcher: pipes `rg --files` output into `entr -r bash -lc "$command"`. |
| `rg` | Only used to build the watch-file list for the `entr` fallback path. |
| `jq` | Writes each start event as a JSON line. |

**Real-world example**
```bash
$ timeout 3 agent-kit watch-loop "echo hi" README.md
[Running: bash -lc echo hi]

[Command was successful]
```
(killed cleanly by `timeout 3`, exit code 124, as intended for this doc's example)

**Why this beats the raw command:** Raw `watchexec`/`entr` invocations require remembering debounce flags, per-tool syntax differences, and manual exclude-globbing; `watch-loop` picks whichever watcher is installed, applies a consistent configurable debounce, and normalizes the invocation across both backends, degrading with a clear error if neither tool exists.
