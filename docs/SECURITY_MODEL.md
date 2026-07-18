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
- Workflow static analysis (`actionlint` + `zizmor`) on every push and pull request.

## Third-party GitHub Actions

CI and release workflows use zero third-party GitHub Actions in their
critical path — `ci.yml` and `release.yml`'s core steps use raw `git`/`gh`
commands instead of `actions/checkout` or similar, specifically to avoid
supply-chain risk from marketplace Actions. Four deliberate exceptions
exist, all pinned to a full 40-character commit SHA, never a floating tag.
Three are read-only, audit-only, or attestation-only (never able to affect
what ships): `.github/workflows/scorecard.yml` (OpenSSF Scorecard,
informational only, never gates a PR); `release.yml`'s `attest` job
(`actions/attest-build-provenance`, runs only after a release is already
published, in its own permission-scoped job); and `step-security/harden-runner`
as the first step of every job that does real network activity (`ci.yml`'s
`checks`, `format`, and `workflow-security`; `release.yml`'s `release`,
`attest`, and `npm-publish`; `scorecard.yml`'s `analysis` — seven uses in
total), running in `egress-policy: audit` mode — it only observes and logs
outbound network calls, never blocks any, and needs no allowlist to configure
or maintain (the `required` job is deliberately skipped: it makes no network
calls, just inspects prior job results). The fourth, `actions/setup-node` in
`release.yml`'s `npm-publish` job, does sit in the publish path: it installs
the Node toolchain and npm registry configuration that OIDC trusted
publishing needs, and it runs in a job scoped to only `id-token: write` and
`contents: read`. Any future third-party Action must follow the
same policy: full-SHA pin, minimal job-scoped permissions,
and a stated reason it couldn't be done with a plain shell command instead.
Dependabot (`.github/dependabot.yml`) watches these pinned SHAs for updates.

## Release boundary

Release archives must contain only intended source, documentation, completions, hooks, and configuration. They must exclude `.git`, `.ai-logs`, local caches, temporary files, context packs, test output, and environment files.
