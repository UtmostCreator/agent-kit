# Changelog

All notable changes will be documented here. The project follows Semantic Versioning and the Keep a Changelog structure.

## [Unreleased]

## [0.1.0] - 2026-07-15

### Added

- Initial public release of repository search, context, guarded editing,
  rollback, test-selection, and verification tools.
- Public release documentation, installation scripts, agent instructions, CI,
  and release packaging.
- Project-local install mode (`install.sh --project`), vendoring the toolkit
  inside a consuming repository at a configurable folder name.
- Dedicated test coverage for `ai-search-introspect` and `all-f-into-one`.
- A native, dependency-free line-coverage engine (`scripts/coverage.sh`,
  `scripts/lib/cov-hook.sh`) for sandboxes where kcov's ptrace tracer is
  unavailable, plus expanded coverage across guarded-edit, rollback, verify,
  search, context, and docs-check code paths. Suite: 655 passing tests
  across 27 files, 100% command coverage, 69.62% line coverage.
- GitHub Actions hardening: workflow static analysis (`actionlint` +
  `zizmor`, required to pass), a reproducible-build regression test,
  OpenSSF Scorecard, release provenance attestation
  (`actions/attest-build-provenance`), Dependabot for pinned-action updates,
  and `step-security/harden-runner` (audit mode) across every job with
  network activity. Branch protection, secret scanning, and private
  vulnerability reporting enabled on the repository.
