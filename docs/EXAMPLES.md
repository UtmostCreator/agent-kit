<!-- restsift:handwritten:header -->

# Examples

One runnable example per command — generated from each command's own
`# Example:` block — plus a **captured output** sample so you can see what each
command actually prints before you run it.

These snippets use the short **`res`** alias, which every installer creates
alongside the canonical `restsift`. They work verbatim after any install — no
setup needed. For the everyday search case, `res s QUERY` is even shorter: it
defaults to text mode and auto-detects the repo root, so `res s TODO` replaces
`res search text TODO .`.

The canonical command is `restsift` — the two are interchangeable, so replace
`res` with `restsift` anywhere you prefer the long form (e.g. in scripts). The
authoritative contract for any command is always `restsift <command> --help`
(and `--introspect` for JSON).

**About the output blocks:** each was captured by running the command against a
small fixture project (paths shown as `~/demo`, timings zeroed for stability).
Every command whose contract supports it also honors `AI_OUTPUT=json` (or
`--json`) for a stable `ai.<tool>/v1` envelope; the human output above stays
byte-identical. Samples that need an optional tool (e.g. `scc`, `lizard`,
security scanners) show a note when it is not installed.

> Regenerate these files with: `bash scripts/gen-examples.sh` — your
> hand-written intros, footers, and per-command notes are preserved.
<!-- /restsift:handwritten:header -->

<!-- restsift:generated:index -->
## Examples by category

- [Repository Search](examples/search.md) — `search`, `rg-code`, `fd-files`, and text search variants
- [Context Building](examples/context.md) — Bundle and pack repository context
- [Guarded Edits & Rollback](examples/edit-rollback.md) — Safe edits with snapshots and rollback
- [Testing & Verification](examples/test-verify.md) — Test selection and project verification
- [Git & Repository](examples/git-repo.md) — Git history, PR context, repository metadata
- [Code Inspection](examples/inspect.md) — Analyze files, scripts, and refactor candidates
- [Session & Utilities](examples/session-utilities.md) — Session checkpoints, watchers, and tools
<!-- /restsift:generated:index -->

<!-- restsift:handwritten:footer -->

For a complete list of all commands and their capabilities, see [COMMANDS.md](COMMANDS.md) or run `restsift --list`.
