# Command map

The exact supported options and output schema are authoritative in each command's `--help` output.
For the packages each command depends on, why, and a real captured example, see
[PACKAGES.md](PACKAGES.md).

Commands are shown as `agent-kit <command>`. The installers also create the
short **`ak`** alias, so `ak <command>` works everywhere — and `ak s QUERY` is
sugar for `agent-kit search text QUERY <repo-root>` (see the search section
below and [EXAMPLES.md](EXAMPLES.md)).

Canonical command groups fuse several single-purpose engines behind one name
(`search`, `context`, `git`, `repo`, `inspect`, `session`, `verify`, `test`,
`edit`); prefer the group form below to avoid guessing which similarly-named
top-level command is the right one.

| Command | Purpose |
|---|---|
| `agent-kit s` / `ak s` | Short search: `ak s QUERY [ROOT]` defaults to text mode and auto-detects the root; mode flags (`--tracked`/`--changed`/`--staged`/`--diff`/`--history`/`--docs`/`--tests`/`--config`/`--deps`) switch families. Sugar over `agent-kit search`. |
| `agent-kit search` | Scoped repository search across available backends; use `agent-kit search capabilities` for the capability map or `agent-kit search batch` to run one mode against several queries. |
| `agent-kit doctor` | Installation + environment health: Bash version, required/optional tools, install root, PATH, git-tree. Text or `--json` (schema `ai.doctor/v1`). |
| `agent-kit completion` | Print a generated Bash/Zsh/Fish completion definition (`bash`\|`zsh`\|`fish`\|`auto`); non-mutating, generated from the command surface via `scripts/gen-completions.sh` — see [INSTALL.md](../INSTALL.md#shell-completion). |
| `agent-kit search-multi` | Compatibility command for batch searches; use `agent-kit search batch`. |
| `agent-kit search-introspect` | Compatibility command for the search capability map. |
| `agent-kit context` | Canonical context-building group (fused engine): `diff` (changed-file bundle), `pack` (repomix/files-to-prompt/code2prompt), `file` (single-file pack), `generate` (full ranked tree), `tree` (tree-pack engine), `status` (freshness check), `ensure` (freshness gate), `estimate` (token cost). `generate`/`tree` still shell out to process-isolated internal engines (`libexec/internal/`) rather than being fully fused, to avoid a confirmed function-name collision risk (`die`/`estimate_tokens` redefinitions) if merged into the shared process. |
| `agent-kit git` | Canonical git-inspection group (fused engine): `origin` (branch-parent detection), `history` (log -S/-G/-L), `blame` (line annotation), `pr-context` (PR metadata/diff/checks/reviews). |
| `agent-kit repo` | Canonical repository-metadata group: `tasks` (defined project tasks), `stats` (tracked-file count), `tools` (full command catalog), `status` (uncommitted docs/config drift). |
| `agent-kit inspect` | Canonical read-only inspection group: `file` (bounded file preview), `data` (structured json/yaml/csv/xml queries), `shell` (static script contract). |
| `agent-kit session` | Canonical session-support group: `checkpoint` (recoverable snapshot), `watch` (re-run a command on file change). |
| `agent-kit verify` | Canonical verification group (fused engine): default/`--language <lang>` (project-aware verification gate), `docs` (documentation lint/links/drift), `refs` (orphaned tracked-file detection). |
| `agent-kit test` | Canonical test group (fused engine): `select` (list relevant tests, read-only), `run` (focused PHPUnit selection), `all` (whole suite, heavy). |
| `agent-kit structured` | Produce machine-readable command output. |
| `agent-kit task` | Run a bounded repository task workflow. |
| `agent-kit edit` | Apply guarded, reviewable edits; `agent-kit edit apply MODE ...` is equivalent to the bare form, `agent-kit edit rollback ...` routes to `agent-kit rollback`. |
| `agent-kit rollback` | Restore a prior guarded-edit state; kept as an independently recoverable engine (never fused into `edit`). |
| `preview-file` | Safely preview bounded file content; also reachable as `agent-kit inspect file`. |
| `session-checkpoint` | Record a session checkpoint; also reachable as `agent-kit session checkpoint`. |

`repomix-context-tree` and `repomix-scc-router` moved to `libexec/internal/` — no longer public
commands. `repomix-context-tree` backs `agent-kit context tree`/`agent-kit context generate` as a
process-isolated internal engine; `repomix-scc-router` is unwired (private, no public route
approved). `pack-context`, `run-repomix-file`, `ai-diff-context`, `query-usage`,
`repomix-freshness`, and `repomix-ensure-fresh` were deleted; their logic now lives in
`agent-kit context pack|file|diff|estimate|status|ensure` respectively.

Use `agent-kit --help`, `agent-kit <command> --help`, or the executable's direct `--help` output before automation. Do not infer unsupported flags from this overview.

## `agent-kit search` in depth

`agent-kit search` is a single facade over five search backends — `rg`, `git
grep`, `fd`, `git log`/`git diff`, and `ast-grep` — selected by a leading
**mode**. Every mode emits the *same* JSON envelope when `AI_OUTPUT=json` is set,
so callers parse one shape no matter which tool ran underneath. Runnable
examples for each are in [EXAMPLES.md](EXAMPLES.md); the live capability map is
`agent-kit search capabilities`.

```
agent-kit search MODE [QUERY] [ROOT] [FLAGS]
```

**Short form.** `ak s QUERY` (command `agent-kit s`) is the everyday entry point:
it defaults to the `text` mode and auto-detects the root (explicit `ROOT` > Git
top-level > current dir), so `ak s TODO` replaces `agent-kit search text TODO .`.
Mode-selecting flags map onto the families below:

| Short | Expands to |
|---|---|
| `ak s Q` | `search text Q <root>` |
| `ak s Q --tracked` | `search tracked Q <root>` |
| `ak s Q --changed` | `search changed-text Q <root>` |
| `ak s Q --staged` | `search staged-text Q <root>` |
| `ak s Q --diff [--base REF]` | `search diff Q <root>` |
| `ak s Q --history [--messages]` | `search history Q <root>` |
| `ak s Q --docs`/`--tests`/`--config`/`--deps` | surface-scoped `search <mode> Q <root>` |

Every other flag (`--count`, `-C N`, `--base`, `--glob`, …) is forwarded
verbatim to `agent-kit search`. The full mode list is still available on the
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
default 100, `--max-bytes N`). See `agent-kit search --help`.

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
`agent-kit search` when a program consumes the results, when the query spans
several search backends, or when output must stay bounded and machine-parseable.
