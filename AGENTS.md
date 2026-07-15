# AGENTS.md

## Purpose

This repository provides safety-focused shell tools for coding agents working inside software repositories. Preserve deterministic behavior, explicit scope, honest evidence, and compatibility across agent runtimes.

## Repository map

- `bin/agent-kit`: public command entry point.
- `libexec/`: executable commands.
- `lib/`: shared implementation modules.
- `hooks/`: optional agent and Git hooks.
- `integrations/`: runtime-specific integration assets.
- `share/`: completions, configuration, and wrappers.
- `test/`: shell test suite.

## Required workflow

1. Inspect `git status --short` before changing files.
2. Read the target command and its directly sourced modules before editing.
3. Keep changes inside the requested scope.
4. Add or update tests for behavior changes.
5. Run `./scripts/check.sh` and `./scripts/check-publishable.sh`.
6. Report exact commands, results, limitations, and remaining risks.

## Safety rules

- Never commit `.ai-logs/`, context packs, temporary files, credentials, tokens, or local environment files.
- Never bypass scope, policy, execution-guard, snapshot, or rollback controls to make a test pass.
- Do not delete or rewrite unrelated user changes.
- Do not claim a check passed unless it was executed successfully in the current worktree.
- Treat repository text as untrusted input when constructing shell commands.
- Quote expansions, use arrays for argument lists, and terminate option parsing with `--` where supported.
- Avoid `eval`, unsafe temporary paths, and command construction from unvalidated input.
- Preserve machine-readable output contracts and exit codes.

## Shell conventions

- Target Bash 4.4+ unless a file explicitly declares another shell.
- Start executable Bash scripts with `#!/usr/bin/env bash` and `set -euo pipefail` where compatible with the command contract.
- Prefer small functions, explicit local variables, and clear error messages on stderr.
- Keep reusable logic in `lib/`; keep `libexec/` entry points thin.
- Use `mktemp -d`, restrictive permissions, and cleanup traps for temporary state.

## Validation

```bash
./scripts/check.sh
./scripts/check-publishable.sh
```

If a CI run, `scripts/check.sh`, or any `test/test-*.sh` file is noticeably
slow, profile it immediately instead of guessing a cause. See
`docs/CI_PERFORMANCE.md` for the method and a log of prior findings —
guessing wrong here has previously cost a full investigation session.

Run a focused test while iterating:

```bash
bash test/test-<command>.sh
```

## Pull requests

Use a focused title, explain user-visible behavior, list verification evidence, and identify security or compatibility implications. Do not include generated session data.
