# Changelog

All notable changes will be documented here. The project follows Semantic Versioning and the Keep a Changelog structure.

## [Unreleased]

### Changed

- **Renamed the toolkit `agent-kit` → RestSift** (canonical CLI `restsift`, short
  alias `res`). The npm package is now `@utmostcreator/restsift`, the Homebrew
  formula `Formula/restsift.rb` (class `Restsift`), and the env-var namespace
  `AGENTKIT_*`/`AK_*` → `RESTSIFT_*`/`RES_*`. Project-local install directory
  default is now `.restsift` and the install marker `.restsift-install`.

### Deprecated

- The old names remain as backward-compatible shims for a migration window: the
  `agent-kit` and `ak` commands still work but forward to `restsift`/`res` and
  print a one-line deprecation notice to stderr. Legacy `AGENTKIT_*` env vars are
  honored as deprecated defaults (with a stderr warning), and `uninstall.sh`/`install.sh`
  still recognize the legacy `.agent-kit-install` marker and `# agent-kit-wrapper`
  wrappers for clean migration.

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
  search, context, and docs-check code paths. Suite: 888 passing tests
  (8 skipped) across 35 files, 100% command coverage, 69.32% line coverage.
- GitHub Actions hardening: workflow static analysis (`actionlint` +
  `zizmor`, required to pass), a reproducible-build regression test,
  OpenSSF Scorecard, release provenance attestation
  (`actions/attest-build-provenance`), Dependabot for pinned-action updates,
  and `step-security/harden-runner` (audit mode) across every job with
  network activity. Branch protection, secret scanning, and private
  vulnerability reporting enabled on the repository.
