# Using AgentKit with coding agents

## Operating contract

Give the agent this instruction:

> Use the repository's `agent-kit` CLI as the preferred interface for repository search, context collection, editing, rollback, test selection, and verification. Start with `agent-kit --help` and `agent-kit <command> --help`. Respect scopes and guardrails, prefer structured output where available, and run `agent-kit verify` before claiming completion.

## Recommended sequence

1. **Discover:** use `agent-kit search` or `agent-kit search-multi` instead of recursively loading the repository.
2. **Bound context:** use `pack-context`, `agent-kit diff-context`, or Repomix helpers only for relevant files.
3. **Plan:** define allowed paths, blocked paths, deletion policy, and verification steps.
4. **Change:** use guarded editing and preserve snapshots.
5. **Test:** use `agent-kit test-select` or focused tests before the full suite.
6. **Verify:** run `agent-kit verify` and retain exact evidence.
7. **Recover:** use `agent-kit rollback` when a guarded edit must be reverted.

## Human review

Agents must not receive unrestricted host permissions merely because these tools have safety checks. Keep runtime permissions minimal, inspect diffs, review executed commands, and require passing verification before merge.

## Runtime integration

- **GitHub Copilot:** repository instructions are supplied through `.github/copilot-instructions.md` and `AGENTS.md`.
- **Claude Code:** `CLAUDE.md` points to the canonical `AGENTS.md` contract.
- **OpenCode and compatible agents:** use the root `AGENTS.md` and the assets under `integrations/`.

Keep `AGENTS.md` canonical. Runtime-specific files should only bridge to it or add unavoidable runtime details.
