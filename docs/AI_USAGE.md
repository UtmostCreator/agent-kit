# Using RestSift with coding agents

## Operating contract

Give the agent this instruction:

> Use the repository's `restsift` CLI as the preferred interface for repository search, context collection, editing, rollback, test selection, and verification. Start with `restsift --help` and `restsift <command> --help`. Respect scopes and guardrails, prefer structured output where available, and run `restsift verify` before claiming completion.

## Recommended sequence

1. **Discover:** use `restsift search` or `restsift search batch` instead of recursively loading the repository.
2. **Bound context:** use `restsift context pack` or `restsift context diff` (or the Repomix helpers under `restsift context`) only for relevant files.
3. **Plan:** define allowed paths, blocked paths, deletion policy, and verification steps.
4. **Change:** use guarded editing and preserve snapshots.
5. **Test:** use `restsift test select` or `restsift test run` (focused) before `restsift test all` (the full suite).
6. **Verify:** run `restsift verify` (add `docs`/`refs` for documentation or orphaned-file checks) and retain exact evidence.
7. **Recover:** use `restsift rollback` (or `restsift edit rollback`) when a guarded edit must be reverted.
8. **Checkpoint:** use `restsift session checkpoint` before a risky guarded edit.

## Human review

Agents must not receive unrestricted host permissions merely because these tools have safety checks. Keep runtime permissions minimal, inspect diffs, review executed commands, and require passing verification before merge.

## Runtime integration

- **GitHub Copilot:** repository instructions are supplied through `.github/copilot-instructions.md` and `AGENTS.md`.
- **Claude Code:** `CLAUDE.md` points to the canonical `AGENTS.md` contract.
- **OpenCode and compatible agents:** use the root `AGENTS.md` directly.

Keep `AGENTS.md` canonical. Runtime-specific files should only bridge to it or add unavoidable runtime details.
