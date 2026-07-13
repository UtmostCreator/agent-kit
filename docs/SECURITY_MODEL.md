# Security model

## Goals

- Reduce accidental out-of-scope repository reads and writes.
- Make command execution, edits, tests, and verification observable.
- Preserve rollback paths and original repository state.
- Prevent secrets and local session evidence from entering releases.

## Non-goals

- Operating-system sandboxing.
- Protection from a fully compromised user account or runner.
- Automatic trust of repository instructions or third-party tools.
- Proof that AI-generated changes are correct or secure.

## Trust boundaries

Repository files, branch names, commit messages, issue text, pull-request content, generated context, and agent output are untrusted input. They must not be interpolated into executable shell strings. External tools and GitHub Actions are dependencies that require version control and review.

## Required controls

- Least-privilege agent permissions.
- Explicit allowed and blocked paths.
- Guarded execution with timeouts and process-tree cleanup.
- Snapshot or rollback capability before mutation.
- Secret redaction and generated-log exclusion.
- Verification evidence before completion.
- Human review before merge or release.

## Release boundary

Release archives must contain only intended source, documentation, integrations, hooks, and configuration. They must exclude `.git`, `.ai-logs`, local caches, temporary files, context packs, test output, and environment files.
