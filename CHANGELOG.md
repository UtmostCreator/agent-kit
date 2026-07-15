# Changelog

All notable changes will be documented here. The project follows Semantic Versioning and the Keep a Changelog structure.

## [Unreleased]

### Added

- Public release documentation, installation scripts, agent instructions, CI, and release packaging.
- Dedicated test coverage for `ai-search-introspect` and `all-f-into-one`.
- A native, dependency-free line-coverage engine (`scripts/coverage.sh`,
  `scripts/lib/cov-hook.sh`) for sandboxes where kcov's ptrace tracer is
  unavailable, plus expanded coverage across guarded-edit, rollback, verify,
  search, context, and docs-check code paths (69.62% line coverage).

## [0.1.0] - 2026-07-12

### Added

- Initial public release of repository search, context, guarded editing, rollback, test-selection, and verification tools.
