# Command map

The exact supported options and output schema are authoritative in each command's `--help` output.

Commands are shown as `agent-kit <command>`. If you set the optional alias
`alias akit='agent-kit'`, the short form `akit <command>` works everywhere
(see [EXAMPLES.md](EXAMPLES.md)).

| Command | Purpose |
|---|---|
| `agent-kit search` | Scoped repository search across available backends. |
| `agent-kit search-multi` | Run multiple bounded searches. |
| `agent-kit search-introspect` | Explain search capability and routing. |
| `agent-kit diff-context` | Build context around current changes. |
| `agent-kit structured` | Produce machine-readable command output. |
| `agent-kit task` | Run a bounded repository task workflow. |
| `agent-kit edit` | Apply guarded, reviewable edits. |
| `agent-kit rollback` | Restore a prior guarded-edit state. |
| `agent-kit test-select` | Select tests relevant to changed files. |
| `agent-kit verify` | Run repository-aware verification. |
| `agent-kit doc-check` | Check documentation references and freshness. |
| `pack-context` | Package selected context for an agent. |
| `preview-file` | Safely preview bounded file content. |
| `git-forensics` | Inspect repository history and change provenance. |
| `gh-pr-context` | Collect focused pull-request context. |
| `repomix-context-tree` | Build a structured Repomix context tree. |
| `repomix-scc-router` | Route context packing using repository size and language data. |
| `query-usage` | Inspect recorded tool usage. |
| `session-checkpoint` | Record a session checkpoint. |

Use `agent-kit --help`, `agent-kit <command> --help`, or the executable's direct `--help` output before automation. Do not infer unsupported flags from this overview.
