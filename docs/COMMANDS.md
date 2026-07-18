# Command map

The exact supported options and output schema are authoritative in each command's `--help` output.
For the packages each command depends on, why, and a real captured example, see
[PACKAGES.md](PACKAGES.md).

Commands are shown as `restsift <command>`. The installers also create the
short **`res`** alias, so `res <command>` works everywhere — and `res s QUERY` is
sugar for `restsift search text QUERY <repo-root>` (see the search section
below and [EXAMPLES.md](EXAMPLES.md)).

Canonical command groups fuse several single-purpose engines behind one name
(`search`, `context`, `git`, `repo`, `inspect`, `session`, `verify`, `test`,
`edit`); prefer the group form below to avoid guessing which similarly-named
top-level command is the right one.

| Command | Purpose |
|---|---|
| `restsift s` / `res s` | Short search: `res s QUERY [ROOT]` defaults to text mode and auto-detects the root; mode flags (`--tracked`/`--changed`/`--staged`/`--diff`/`--history`/`--docs`/`--tests`/`--config`/`--deps`) switch families. Sugar over `restsift search`. |
| `restsift search` | Scoped repository search across available backends; use `restsift search capabilities` for the capability map or `restsift search batch` to run one mode against several queries. |
| `restsift doctor` | Installation + environment health: Bash version, required/optional tools, install root, PATH, git-tree. Text or `--json` (schema `ai.doctor/v1`). |
| `restsift completion` | Print a generated Bash/Zsh/Fish completion definition (`bash`\|`zsh`\|`fish`\|`auto`); non-mutating, generated from the command surface via `scripts/gen-completions.sh` — see [INSTALL.md](../INSTALL.md#shell-completion). |
| `restsift search-multi` | Compatibility command for batch searches; use `restsift search batch`. |
| `restsift search-introspect` | Compatibility command for the search capability map. |
| `restsift context` | Canonical context-building group (fused engine): `diff` (changed-file bundle), `pack` (repomix/files-to-prompt/code2prompt), `file` (single-file pack), `generate` (full ranked tree), `tree` (tree-pack engine), `status` (freshness check), `ensure` (freshness gate), `estimate` (token cost). `generate`/`tree` still shell out to process-isolated internal engines (`libexec/internal/`) rather than being fully fused, to avoid a confirmed function-name collision risk (`die`/`estimate_tokens` redefinitions) if merged into the shared process. |
| `restsift git` | Canonical git-inspection group (fused engine): `origin` (branch-parent detection), `history` (log -S/-G/-L), `blame` (line annotation), `pr-context` (PR metadata/diff/checks/reviews). |
| `restsift repo` | Canonical repository-metadata group: `tasks` (defined project tasks), `stats` (tracked-file count), `tools` (full command catalog), `status` (uncommitted docs/config drift). |
| `restsift inspect` | Canonical read-only inspection group: `file` (bounded file preview), `data` (structured json/yaml/csv/xml queries), `shell` (static script contract). |
| `restsift session` | Canonical session-support group: `checkpoint` (recoverable snapshot), `watch` (re-run a command on file change). |
| `restsift verify` | Canonical verification group (fused engine): default/`--language <lang>` (project-aware verification gate), `docs` (documentation lint/links/drift), `refs` (orphaned tracked-file detection). |
| `restsift test` | Canonical test group (fused engine): `select` (list relevant tests, read-only), `run` (focused PHPUnit selection), `all` (whole suite, heavy). |
| `restsift structured` | Produce machine-readable command output. |
| `restsift task` | Run a bounded repository task workflow. |
| `restsift edit` | Apply guarded, reviewable edits; `restsift edit apply MODE ...` is equivalent to the bare form, `restsift edit rollback ...` routes to `restsift rollback`. |
| `restsift rollback` | Restore a prior guarded-edit state; kept as an independently recoverable engine (never fused into `edit`). |
| `preview-file` | Safely preview bounded file content; also reachable as `restsift inspect file`. |
| `session-checkpoint` | Record a session checkpoint; also reachable as `restsift session checkpoint`. |

`repomix-context-tree` and `repomix-scc-router` moved to `libexec/internal/` — no longer public
commands. `repomix-context-tree` backs `restsift context tree`/`restsift context generate` as a
process-isolated internal engine; `repomix-scc-router` is unwired (private, no public route
approved). `pack-context`, `run-repomix-file`, `ai-diff-context`, `query-usage`,
`repomix-freshness`, and `repomix-ensure-fresh` were deleted; their logic now lives in
`restsift context pack|file|diff|estimate|status|ensure` respectively.

Use `restsift --help`, `restsift <command> --help`, or the executable's direct `--help` output before automation. Do not infer unsupported flags from this overview.

## Every command — canonical + short forms

The complete surface (`restsift --list` prints the same set live). The `res`
column is the short alias installed alongside `restsift`; the `ai-` prefix is
optional, so `res search` and `res ai-search` both resolve. The **Alias** column
is a short first-token shortcut for the command itself (e.g. `res rb list` ==
`res rollback list`), defined once in `lib/command-aliases.txt` and shared with
generated shell completions — a blank cell means no shortcut is registered
(the canonical name is already short, or the word is reserved for a different
command). Group commands (e.g. `context`, `git`, `repo`) take a mode as their
first argument — see the rows above and each command's `--help`.

| Canonical | Short | Alias | Purpose |
|---|---|---|---|
| `restsift s` | `res s` | | **Short search** — default text mode, auto-detected root; mode flags switch families. Sugar over `search`. |
| `restsift search` | `res search` | | Unified repository search across `rg`, `git grep`, `fd`, `git log/diff`, and `ast-grep`, behind one JSON envelope. |
| `restsift search-multi` | `res search-multi` | `res sm` | Run one search mode against several queries (also `restsift search batch`). |
| `restsift search-introspect` | `res search-introspect` | `res si` | Print the full search capability map — modes, flags, env (also `restsift search capabilities`). |
| `restsift rg-code` | `res rg-code` | `res rg` | Code-search wrapper with repo-aware ripgrep defaults. |
| `restsift fd-files` | `res fd-files` | `res fd` | Repo-aware file discovery (fd wrapper). |
| `restsift preview-file` | `res preview-file` | `res peek` | Safely preview a bounded slice of a text file (also `restsift inspect file`). |
| `restsift context` | `res context` | `res ctx` | Context-building group: `diff` · `pack` · `file` · `generate` · `tree` · `status` · `ensure` · `estimate`. |
| `restsift edit` | `res edit` | `res e` | Guarded, reviewable edits (sd / comby / ast-grep / patch) with dry-run, scope checks, snapshots. |
| `restsift rollback` | `res rollback` | `res rb` | Review and apply repository-local rollback snapshots (`list`/`show`/`apply` accept a numeric index too — `1` = most recent, git-stash style). |
| `restsift session` | `res session` | | Session-support group: `checkpoint` (snapshot) · `watch` (re-run on change). |
| `restsift session-checkpoint` | `res session-checkpoint` | `res ckpt` | Create a repository-local snapshot checkpoint (also `restsift session checkpoint`). |
| `restsift watch-loop` | `res watch-loop` | `res w` | Re-run a command whenever watched files change (also `restsift session watch`). |
| `restsift test` | `res test` | `res t` | Test group: `select` (relevant tests, read-only) · `run` (focused) · `all` (whole suite). |
| `restsift verify` | `res verify` | `res v` | Project-aware verification gate; `docs`, `refs`, and `--language` modes. |
| `restsift git` | `res git` | `res g` | Git-inspection group: `origin` · `history` · `blame` · `pr-context`. |
| `restsift repo` | `res repo` | | Repository-metadata group: `tasks` · `stats` · `tools` · `status`. |
| `restsift repo-stats` | `res repo-stats` | `res stats` | Count git-tracked files (also `restsift repo stats`). |
| `restsift repo-tool-inventory` | `res repo-tool-inventory` | `res tools` | List every command with a one-line summary (also `restsift repo tools`). |
| `restsift task` | `res task` | `res tsk` | Discover defined project tasks (also `restsift repo tasks`). |
| `restsift file-freshness` | `res file-freshness` | `res fresh` | Show which docs/config files have uncommitted changes (also `restsift repo status`). |
| `restsift refactor-scan` | `res refactor-scan` | `res refactor` | Rank refactor candidates by scc complexity and lizard NLOC. |
| `restsift inspect` | `res inspect` | `res i` | Read-only inspection group: `file` · `data` · `shell`. |
| `restsift structured` | `res structured` | `res data` | Structured-data queries: json / yaml / csv / xml (also `restsift inspect data`). |
| `restsift sh-introspect` | `res sh-introspect` | | Static introspector — a script's contract without executing it (also `restsift inspect shell`). |
| `restsift doctor` | `res doctor` | | Installation + environment health (Bash, tools, PATH, git-tree); text or `--json`. |
| `restsift completion` | `res completion` | `res comp` | Print a generated shell-completion definition for bash / zsh / fish (`auto` detects). |
| `restsift all-f-into-one` | `res all-f-into-one` | `res bundle` | Combine multiple files into a single concatenated bundle. |

Two global forms round out the surface: `restsift --version [--json]` (version,
optionally as an `ai.version/v1` envelope) and `restsift --list` (the live
command list). Compatibility/internal engines under `libexec/internal/` are not
public commands.

## `restsift search` in depth

`restsift search` is a single facade over five search backends — `rg`, `git
grep`, `fd`, `git log`/`git diff`, and `ast-grep` — selected by a leading
**mode**. Every mode emits the *same* JSON envelope when `AI_OUTPUT=json` is set,
so callers parse one shape no matter which tool ran underneath. Runnable
examples for each are in [EXAMPLES.md](EXAMPLES.md); the live capability map is
`restsift search capabilities`.

```
restsift search MODE [QUERY] [ROOT] [FLAGS]
```

**Short form.** `res s QUERY` (command `restsift s`) is the everyday entry point:
it defaults to the `text` mode and auto-detects the root (explicit `ROOT` > Git
top-level > current dir), so `res s TODO` replaces `restsift search text TODO .`.
Mode-selecting flags map onto the families below:

| Short | Expands to |
|---|---|
| `res s Q` | `search text Q <root>` |
| `res s Q --tracked` | `search tracked Q <root>` |
| `res s Q --changed` | `search changed-text Q <root>` |
| `res s Q --staged` | `search staged-text Q <root>` |
| `res s Q --diff [--base REF]` | `search diff Q <root>` |
| `res s Q --history [--messages]` | `search history Q <root>` |
| `res s Q --docs`/`--tests`/`--config`/`--deps` | surface-scoped `search <mode> Q <root>` |

Every other flag (`--count`, `-C N`, `--base`, `--glob`, …) is forwarded
verbatim to `restsift search`. The full mode list is still available on the
canonical command.

### Modes

| Family | Modes | Backend | Query? |
|---|---|---|---|
| Content | `text` `tracked` `docs` `tests` `config` `config-key` `deps` `route` | `rg` / `git grep` | required |
| Changed-scope | `changed-text` `staged-text` | `rg` over changed/staged files | required |
| Git | `diff` (`--staged`, `--base REF`), `history` (`--messages`, `--patch`, `-S`/`-G`) | `git diff` / `git log` | required |
| Structural (AST) | `struct` `symbols` `class` `function` `method` `interface` `enum` (`--lang LANG`) | `ast-grep` | required |
| File name | `files` | `fd` | required |
| File lists | `changed-files` `staged-files` | git | none |
| Curated | `todo` `unsafe-patterns` | `rg` | none |
| Special | `doctor` (backend availability), `capabilities` (mode/flag map), `batch MODE Q1 Q2 …` | — | — |

Common flags across `rg`-backed modes: `--fixed`/`--regex`/`-i`/`--case-sensitive`/`--smart-case`,
`--glob`, `--type`, `--exclude`, `--max-depth`, context (`-C`/`-B`/`-A N`),
output shape (`-l`, `--count`, `--count-matches`), and bounds (`--max-results N`
default 100, `--max-bytes N`). See `restsift search --help`.

### JSON envelope

With `AI_OUTPUT=json`, every mode returns the same top-level keys:

```json
{ "schema": "1", "status": "ok", "tool": "ai-search", "query": "…", "mode": "text",
  "matches": ["path:line:text", "…"],
  "results": [{ "path": "…", "line": 9, "column": 40, "text": "…",
                "source_tool": "rg", "root": "/abs/root", "language": null }],
  "warnings": [], "errors": [], "limits": { "max_results": 100 },
  "meta": { "returned": 3, "truncated": false } }
```

`status` is one of `ok | no_matches | error | unavailable | dry_run | blocked`.
Count/file-only modes add `summary{total_files,total_matches}`; `symbols`/`class`
add `symbols[]`; `diff`/`history` results carry marker/commit metadata.

### Why use this instead of `rg | …`?

For a quick grep on your own screen, plain `rg` is the right tool — this facade
does not try to beat it interactively. It earns its place when something *other
than a human* reads the output, or when the search bounds matter:

- **One stable schema over five tools.** An agent or script parses the same
  `status` / `results[]` / `meta.truncated` envelope whether the match came from
  `rg`, `git grep`, `fd`, `git log`, or `ast-grep`. Raw pipes give a different
  output format per tool that every caller must special-case.
- **One vocabulary for multi-tool pipelines.** `changed-text "x"` collapses
  `git diff --name-only … | xargs rg "x"` into a single mode; `diff --base main`,
  `history -S`, `symbols --lang`, and `files` (name search via `fd`) are likewise
  distinct tools reached through one flag grammar.
- **Bounds and guardrails by default.** Results cap at `max_results: 100` with
  `meta.truncated` flagged, `--max-bytes` trims payloads, `.gitignore` is honored,
  `doctor` reports missing backends, and `unsafe-all` returns `status: blocked`.
  For an autonomous agent these caps keep a bad regex from flooding the context
  window.

Rule of thumb: reach for `rg`/`grep`/`awk` for your own quick lookups; use
`restsift search` when a program consumes the results, when the query spans
several search backends, or when output must stay bounded and machine-parseable.
