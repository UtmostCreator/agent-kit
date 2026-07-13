# Repository instructions

Follow the canonical instructions in `AGENTS.md`.

This is a Bash-based safety toolkit for coding-agent repository operations. Prefer existing `agent-kit` commands and shared modules over ad hoc shell logic. Preserve scope checks, execution guards, snapshots, rollback, redaction, machine-readable output, and exit-code contracts.

Never commit `.ai-logs/`, session data, context packs, credentials, or local environment files. Do not bypass a safety control to make a test pass. Add tests for behavior changes and run:

```bash
./scripts/check.sh
./scripts/check-publishable.sh
```

Report exact verification evidence and any checks that could not be run.
