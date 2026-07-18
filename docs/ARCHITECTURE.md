# Architecture

How restsift is put together: the dispatch model, the module system, the
single-source-of-truth chain that keeps help/completions/docs in sync, the
install lifecycle, the safety machinery, and the test/release pipelines.

This document describes the repository as of the `feat/project-local-install`
branch. For what each command does, see [COMMANDS.md](COMMANDS.md) — and note
that per-command options and output schemas are authoritative in each command's
own `--help`, not here. This document covers *how the pieces fit*, not command
reference material.

## Overview

restsift is a dependency-light Bash CLI toolkit that gives coding agents a
controlled, observable interface to a repository: bounded search, guarded
edits, snapshots and rollback, context packing, verification gates. The core
requires Bash >= 4.4, `git`, `rg`, and `jq` — both installers (`install.sh`,
`web-install.sh`) gate on all four before doing anything, and the Homebrew
formula declares them as dependencies. Everything else (`fd`, `ast-grep`,
`repomix`, `gitleaks`, …) is an optional backend that individual commands
probe for and degrade without (see [PACKAGES.md](PACKAGES.md)).

Design principles that show up everywhere:

- **Thin executables, reusable libraries.** Files under `libexec/` are
  entrypoints — argument routing plus a header contract. Logic lives in
  sourced modules under `lib/`.
- **Mechanism vs policy.** Low-level capability (e.g. snapshot create/apply in
  `lib/snapshot.sh`) is kept strictly separate from the CLI/confirmation/
  approval layer that decides *when* to use it (e.g. `libexec/ai-rollback`).
- **Single source of truth.** A command's header comment drives its `--help`,
  its `--introspect` JSON, shell completions, and the generated examples doc.
  Aliases live in exactly one file. Nothing is hand-synchronized twice.
- **Safety guards by default.** Result caps, timeouts, hung-process watchdogs,
  approval gates, secret scanning, and pre-mutation snapshots are built into
  the shared modules rather than re-implemented (or forgotten) per command.
- **Machine output is opt-in and stable.** Human text is the default;
  `AI_OUTPUT=json` (or `--json` where offered) switches to versioned JSON
  envelopes with `schema` identifiers like `ai.version/v1`, `ai.doctor/v1`,
  `ai.rollback/v1`.

## Command dispatch

`bin/restsift` is the single public entrypoint, mirroring the
`git-<subcommand>` convention: `restsift search …` execs `libexec/ai-search`.

It is deliberately Bash-3.2-safe so it can bootstrap on macOS: if launched
under an old Bash it probes `TOOL_BASH`, the Homebrew paths, `PATH`, and
`/bin/bash` for a Bash >= 4.4 and re-execs itself under it, guarded against
loops by the `_AI_BASH_REEXEC` environment marker. If no capable Bash exists
it fails with instructions and exit 127.

Three built-ins are handled inline before any subcommand resolution:
`--list`/`list` (live command surface via `sh-introspect --list`),
`--help`/`-h` (the dispatcher's own header), and `--version`/`-V`/`version`
(with `--json` or `AI_OUTPUT=json` producing an `ai.version/v1` envelope,
hand-built so the dispatcher never needs `jq`). Bare `restsift` with no
arguments prints the same command list but exits 2.

Subcommand names must match `^[A-Za-z0-9][A-Za-z0-9._-]*$` — no slashes, no
leading dot — so `restsift ../../etc/x` can never escape `libexec/` and exec
an arbitrary file. Resolution order is:

1. exact file: `libexec/<cmd>`
2. `ai-` prefixed form: `libexec/ai-<cmd>` (so the `ai-` prefix is optional)
3. short alias from `lib/command-aliases.txt`

Aliases are checked *last* by design: an alias can never shadow a real
command. `libexec/internal/` is a subdirectory, so its engines are unreachable
through the dispatcher by construction — the name regex admits no slash.
Finally the dispatcher runs `exec "${BASH:-bash}" "$target" "$@"`, propagating
the same capable Bash to the subcommand.

The short `res` command is not a second program: the installer wrappers, the
Homebrew formula, and the npm `bin` map all point `res` at this same
dispatcher.

## Layout and the module system

| Path | Role |
|---|---|
| `bin/restsift` | dispatcher (above) |
| `libexec/` | one executable per public command; each is complete and directly runnable |
| `libexec/internal/` | private engines: `completion-spec`, `repomix-context-tree`, `repomix-scc-router`, `run-repomix-context` — not public commands |
| `lib/common.sh` | shared facade every command sources (below) |
| `lib/*.sh` | the ordered shared modules behind `common.sh` |
| `lib/exec-guard/` | execution-guard submodules behind the `lib/exec-guard.sh` facade |
| `lib/ai-search/`, `lib/ai-context/`, `lib/ai-diff-context/`, `lib/ai-edit/`, `lib/ai-git/`, `lib/ai-test/`, `lib/ai-verify/`, `lib/ai-refactor-scan/`, `lib/repomix*/` | per-command-group module directories (`lib/ai-diff-context/` is shared: sourced by `lib/ai-context/diff.sh`, while `lib/ai-git/pr-context.sh --pack` reaches it via an `ai-context diff` subprocess) |
| `lib/command-aliases.txt` | the alias single source (see next section) |
| `share/config/` | data files: comment patterns, excluded-directory lists |
| `hooks/agent/` | optional agent-runtime hook wrappers (`session-checkpoint`, `watch-loop`) |
| `completions/` | committed, generated shell completions (bash/zsh/fish) |
| `scripts/` | maintainer tooling: `check.sh`, `coverage.sh`, `gen-completions.sh` + `scripts/completions/render-*.sh`, `gen-examples.sh`, `check-publishable.sh`, `package-release.sh` |
| `npm/cli.js` | npm entry shim (Bash resolver, spawns the dispatcher) |
| `Formula/restsift.rb` | Homebrew formula — the repo is its own tap |
| `test/` | standalone shell test files + `run-all.sh` |
| `dist/` | untracked local build output from `package-release.sh` |

### `lib/common.sh`

Every command that needs shared behavior sources exactly one file,
`lib/common.sh` — a thin facade that sources the shared modules in a fixed
00→90 order (the numbers are a documented load order, not filename prefixes):
`environment.sh`, `core.sh`, `json.sh`, `paths.sh`, `logging.sh`,
`log-redaction.sh`, `session.sh`, `policy.sh`, `exec-guard.sh`, `secrets.sh`,
`tokens.sh`, `snapshot.sh`. Each module carries a unique source guard, so
re-sourcing `common.sh` is idempotent. `lib/exec-guard.sh` is itself a facade
over four submodules in `lib/exec-guard/` (`run-timeout.sh`,
`cpu-sampling.sh`, `kill-tree.sh`, `run-guarded.sh`). Commands source *only*
`common.sh`, never lib modules directly.

`common.sh` also installs two universal guards before loading anything: if the
sourcing script's first argument is `--introspect` or `--help`/`-h`, it execs
`libexec/sh-introspect` against the sourcing script and exits — the target is
parsed statically, never executed. That is why every command gets a uniform
`--help`/`--introspect` surface for free (commands with richer bespoke help,
like `ai-search`, simply handle the flag before sourcing).

### Two entrypoint styles

- **Fused loaders.** `libexec/ai-search` sources 18 modules from
  `lib/ai-search/` in a documented, constraint-annotated order and calls
  `ai_search_main`. The same pattern backs `ai-context`, `ai-edit`, `ai-git`,
  `ai-refactor-scan`, `ai-test`, and `ai-verify` — real function-call fusion
  in one process.
- **Thin routers.** `ai-inspect`, `ai-repo`, `ai-session`, and `ai-s` just
  exec the underlying standalone engine (`preview-file`, `repo-stats`,
  `session-checkpoint`, `ai-search`, …); every routed engine remains a
  complete, directly runnable script.

The exception proves the rule: `restsift context generate` and
`restsift context tree` deliberately shell out to *isolated subprocess
engines* under `libexec/internal/` instead of being fused. The repomix
engines' own `helpers.sh` files locally redefine `die()`/`log()`/
`estimate_tokens()`, shadowing `common.sh`'s versions for their own throwaway
process — fusing them into the shared process would let whichever module
loaded last silently corrupt the other modes. The header comment at the top
of `libexec/ai-context` (and `lib/ai-context/generate.sh`) records this
rationale.

## The single-source-of-truth chain

The repository's most distinctive idea: a command's structured header comment
is the *only* place its contract is written, and everything else is derived
from it mechanically.

```text
libexec/<cmd> header comment  (Usage / Modes / Flags / Example / Exit codes)
        │
        ▼  parsed statically — the target script is NEVER executed
libexec/sh-introspect  (pure-Bash static parser)
        │
        ├─► <cmd> --help            (human contract, --format=help)
        ├─► <cmd> --introspect      (ai.sh-introspect/v1 JSON contract)
        ├─► restsift --list        (one-line summaries)
        ├─► libexec/internal/completion-spec   (aggregate JSON of every
        │        command's name, modes, flags — plus the alias table)
        │        │
        │        ▼
        │   scripts/gen-completions.sh
        │        │  validates the spec with jq, then renders via
        │        │  scripts/completions/render-{bash,zsh,fish}.sh
        │        ▼
        │   completions/  (committed: restsift.bash, _restsift, restsift.fish)
        │
        └─► scripts/gen-examples.sh ─► docs/EXAMPLES.md (index)
                 │                       docs/examples/*.md (per-category)
                 (each command's own `# Example:` block, plus captured,
                  normalized output samples. Marker-based injection: only the
                  `<!-- restsift:generated:… -->` regions are rewritten;
                  handwritten header/footer/notes regions are preserved.)
```

Completions are generated from `sh-introspect --format=json`, never from
parsing `--help` text. The generated `completions/` files are committed so
installs need no generation step; regenerate with
`bash scripts/gen-completions.sh` after changing any command surface.

Short aliases have the same property. `lib/command-aliases.txt` holds one
`alias canonical-basename` pair per line and is read by both the dispatcher
(resolution step 3) and `libexec/internal/completion-spec` — a new alias is
added in exactly one place, and the test suite checks the file's invariants
(no collision with a real command name, since collisions would be silently
unreachable rather than an error).

## Install / uninstall lifecycle

`install.sh` supports two targets:

- **Global (default):** prefix `${XDG_DATA_HOME:-$HOME/.local/share}/restsift`,
  wrapper scripts `restsift` and `res` in `$HOME/.local/bin`.
- **Project-local:** `--project [DIR]` (or `RESTSIFT_PROJECT_DIR=<DIR>`)
  installs into `<DIR>/.restsift/{toolkit,bin}`, vendoring the toolkit inside
  a repository. The folder name is configurable via `RESTSIFT_DIR_NAME`
  (default `.restsift`); an explicit `--prefix` always wins.

`web-install.sh` is the `curl | bash` bootstrap: it resolves the newest
published `v*` release tag by default (overridable with `RESTSIFT_REF`, where
`main` is the explicit development channel), clones into a cache directory
(`${XDG_CACHE_HOME:-$HOME/.cache}/restsift/src` by default), refuses to reuse
a cache that points at a *different* remote, and then runs the repo's own
`install.sh`.

Install mechanics worth knowing:

- **Gates first.** The installer verifies its dependency and Bash-version
  requirements and that the source tree is complete (`bin/restsift`, `lib`,
  `libexec`, `share`) before touching anything.
- **Atomic staged install.** Files are copied into a staging directory
  created next to the prefix, then swapped in with `mv`. An existing install
  is first moved aside as a timestamped backup; an `EXIT` trap restores the
  backup on any failure, so a broken run never leaves a half-installed prefix.
- **Identity marker.** The install writes `.restsift-install` (containing
  `restsift`) into the prefix. Uninstall refuses to remove any directory
  lacking that marker.
- **Foreign-wrapper guard.** `restsift` and `res` are generic names. The
  installer only overwrites a wrapper in `--bindir` if it carries the
  `# restsift-wrapper` marker line; anything else is refused (leaving the
  existing install intact) unless `RESTSIFT_FORCE=1`.
- **Completion auto-drop (global installs only).** Fish completions go into
  the standard `${XDG_CONFIG_HOME:-~/.config}/fish/completions` drop-in (with
  a tiny `res.fish` stub so first-tab-on-`res` works), Bash into
  `${XDG_DATA_HOME:-~/.local/share}/bash-completion/completions`. Zsh stays a
  documented manual step. Project-local installs skip all of this — no
  dotfile writes.

`uninstall.sh` is the mirror image: it removes the prefix only when the
`.restsift-install` marker matches, removes wrappers by *marker match* rather
than path match (so a foreign `restsift` binary is never deleted), and cleans
up parent directories only via `rmdir`, which succeeds only on truly empty
directories — an emptied project-local `.restsift/` disappears, a shared one
survives. It also removes the auto-dropped fish/bash completion files, but
only when both the prefix and the bindir are still at their untouched
defaults — the exact mirror of install's global-only completion auto-drop.

## Safety and runtime data

All runtime evidence lands under `.ai-logs/` in the target repository
(`AI_LOG_DIR` override): `sessions/` (session state), `snapshots/`
(pre-mutation restore points), `tool-usage.jsonl` (structured event log,
`AI_EVENT_LOG`), and `watch-loop.jsonl`. `.ai-logs/` must never be committed
or released — `check-publishable.sh` enforces this.

- **Snapshots (mechanism vs policy).** `lib/snapshot.sh` is the mechanism
  only: it records a `git diff --binary` patch, a manifest, and a tar.gz of
  untracked files, and can apply them back. Everything policy-shaped — CLI
  parsing and interactive confirmation (with a documented
  non-interactive/`CI=true` path, plus `ROLLBACK_REMOVE_CREATED_UNTRACKED`
  for untracked-file removal) — lives in
  `libexec/ai-rollback` (`list`/`show` read-only, `apply` mutating,
  git-stash-style numeric indexes). The two files each document this boundary;
  keep it.
- **Approval policy (library, not yet wired in).** `lib/policy.sh` is a
  classification/approval library available to sourcing scripts and agent
  integrations. `classify_command` sorts a command into one of six
  categories — read, write, destructive, network, install, unknown — and
  `enforce_command_policy` gates destructive/network/install/unknown on the
  matching `AI_APPROVE_*` environment variable and write on `AI_TASK_SCOPE`,
  exiting 2 when the gate is unset. Note that no shipped command currently
  calls `enforce_command_policy`: only the test suite exercises it, and
  `lib/logging.sh` reuses the same taxonomy for event-log labels.
- **Execution guards.** `lib/exec-guard/` provides a hard-timeout wrapper, a
  hung-process watchdog that samples CPU to distinguish "busy" from "stuck",
  and process-group kill for tree cleanup.
- **Secrets and redaction.** `lib/secrets.sh` wraps `gitleaks` (skipped with
  a warning when not installed; `SECRETS_SCAN=0` bypass), and
  `lib/log-redaction.sh` redacts structured logs before they are written.
- **Session support.** `libexec/session-checkpoint` records a recoverable
  checkpoint; `libexec/watch-loop` re-runs a command on file change, logging
  to `.ai-logs/watch-loop.jsonl`. `hooks/agent/` exposes both to agent
  runtimes.
- **The contract itself.** [AGENTS.md](../AGENTS.md) is the in-repo agent
  contract (required workflow, safety rules, shell conventions);
  [SECURITY_MODEL.md](SECURITY_MODEL.md) states the trust boundaries these
  mechanisms serve.

## Test architecture

`test/` holds 35 standalone `test-*.sh` files plus `run-all.sh`. Each file is
directly runnable, carries its own small `run_test` harness with
`PASS`/`FAIL` (and where needed `SKIP`) counters, and prints a per-file
summary. Tests that need an optional tool (`repomix`, `scc`, `gitleaks`, …)
skip with a reason instead of failing, so the suite passes in a minimal
sandbox; `test/test-ai-search.sh` additionally gates a set of extended
assertions behind `AI_SEARCH_RUN_P1_TESTS=1`. `test/test-install.sh`
deliberately installs into paths *with spaces* and redirects
`XDG_CONFIG_HOME`/`XDG_DATA_HOME` into its stage so completion auto-drop never
touches the developer's real dotfiles.

`scripts/check.sh` is the one gate to run before reporting completion. It
first shellcheck-lints the tracked shell scripts — files matching `*.sh` plus
everything under `bin/`, `libexec/`, and `hooks/`, keeping those whose first
line mentions sh/bash (a shebang or a `shellcheck shell=` directive);
zsh scripts are skipped, and the generated `completions/` files are not
linted at all. The lint is sharded across parallel
processes via `xargs -0 -P<jobs> -n5` (`CHECK_SHELLCHECK_JOBS=1` forces serial
mode); `-x` (`--external-sources`) is required for correctness once files are
split into separate invocations, because a sourced file may land in a
different shard — the file documents the empirical evidence. It then runs
every `test/test-*.sh` serially.

`scripts/coverage.sh` measures real line coverage of `bin/`, `lib/`, and
`libexec/` by running the suite under a native Bash DEBUG-trap collector
(`scripts/lib/cov-hook.sh`, injected via `BASH_ENV`) — no ptrace required.
kcov's bash tracer needs `PTRACE_TRACEME`, which is EPERM'd in
seccomp-restricted sandboxes and then silently reports 0/0 lines;
`COVERAGE_ENGINE=kcov` opts into kcov on hosts where ptrace works.

## Release pipeline

The version triple must agree: the git tag `vX.Y.Z`, the `VERSION` file, and
`package.json`'s version — `scripts/package-release.sh` refuses to build
otherwise. `CHANGELOG.md` is hand-maintained.

- `scripts/check-publishable.sh` gates payload minimality: it rejects tracked
  `.ai-logs/`, env files, private-key material, generated output directories,
  and session artifacts, and requires the core publication files to exist.
- `scripts/package-release.sh` stages an include list into a clean directory,
  normalizes permissions, and builds a *reproducible* tarball —
  `tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner | gzip -n`
  — plus a zip and `SHA256SUMS`, into `dist/`.
- **CI (`.github/workflows/ci.yml`).** A `checks` matrix job (raw
  `git`-command checkout — no `actions/checkout`), a `format` job (`shfmt -d`),
  a `workflow-security` job (checksum-pinned `actionlint` + `zizmor`), and a
  `required` job that gates on all three results. Every job that touches the
  network starts with SHA-pinned `step-security/harden-runner` in audit mode;
  the `required` job deliberately skips it (no network activity). The
  third-party-Actions policy is in [SECURITY_MODEL.md](SECURITY_MODEL.md).
- **Release (`.github/workflows/release.yml`).** Three permission-isolated
  jobs: `release` (validate, test, build archives, publish the GitHub
  release), then `attest` (SHA-pinned `actions/attest-build-provenance`, with
  only `id-token`/`attestations` write), then `npm-publish` (OIDC trusted
  publishing with `--provenance`, no long-lived npm token).
- `scorecard.yml` runs OpenSSF Scorecard informationally; `dependabot.yml`
  watches the pinned Action SHAs monthly and npm weekly, with 7-day cooldowns.
- The human layer is [RELEASE_CHECKLIST.md](../RELEASE_CHECKLIST.md) and
  [RELEASING.md](../RELEASING.md). Until a tagged release exists, Homebrew
  installs come from the self-tap with `--HEAD`.

## Distribution channels

| Channel | Entry | Notes |
|---|---|---|
| Release tarball / zip | `install.sh` inside the archive | reproducible build, `SHA256SUMS`, GitHub build-provenance attestation verifiable via `gh attestation verify` |
| npm | `npm/cli.js` shim | Node locates the packaged `bin/restsift`, resolves a Bash >= 4.4 (`TOOL_BASH`, Homebrew paths, `PATH`, `/bin/bash`) and spawns the dispatcher; exits 127 with guidance if none found |
| Homebrew | `Formula/restsift.rb` (self-tap) | wrappers for `restsift` *and* `res` pinned to the brewed Bash; wires the committed completions into Homebrew's bash/zsh/fish completion dirs |
| Web one-liner | `web-install.sh` | newest `v*` tag by default; see the install section above |
| Git clone | `./install.sh` or run `bin/restsift` in place | the dev workflow |

## Documentation and sync

- **Generated — never hand-edit:** `docs/EXAMPLES.md` (from
  `scripts/gen-examples.sh`) and `completions/` (from
  `scripts/gen-completions.sh`).
- **Hand-maintained:** `README.md`, `INSTALL.md`, `AGENTS.md`,
  `CONTRIBUTING.md`, `RELEASING.md`, `RELEASE_CHECKLIST.md`, and under
  `docs/`: `COMMANDS.md`, `PACKAGES.md`, `SECURITY_MODEL.md`, `AI_USAGE.md`,
  `CI_PERFORMANCE.md`, and this file.
- **Runtime drift checks:** `restsift verify docs` lints documentation,
  checks links, and detects doc/command drift; `restsift verify refs` finds
  orphaned tracked files; `restsift file-freshness` (`restsift repo status`)
  reports uncommitted docs/config changes.

## Known drift

Honest list of places where the tree currently disagrees with itself:

- **Stale `scripts/ai/` path comments.** Several headers and `shellcheck
  source=` directives still reference a pre-rename `scripts/ai/…` layout
  (e.g. `lib/common.sh`'s module-map comment, `libexec/ai-search`'s module
  map, `libexec/ai-rollback`'s source directive). The code paths themselves
  are correct; only the prose is stale.
- **Historical verification evidence predates recent changes.**
  `RELEASING.md`'s and `RELEASE_CHECKLIST.md`'s evidence logs record a
  clean-clone verification run (655 tests across 27 files, archive contents
  inspected) that predates the suite's growth to 35 files / 888 passing and
  the addition of `completions/` to the release tarball. The entries are
  kept as-is deliberately — they record what was actually verified — and
  flag that the run should be repeated before tagging.

Previously listed here and since fixed: release tarballs now ship
`completions/`; the ghost `integrations/` references were removed; the
`lib/snapshot.sh`, `web-install.sh`, and `lib/ai-git/pr-context.sh` header
comments were corrected; `CHANGELOG.md`'s unreleased 0.1.0 entry now carries
the current test figures.

## Where to look first

New to the codebase? Read in this order:

1. [AGENTS.md](../AGENTS.md) — the working contract: workflow, safety rules,
   shell conventions.
2. `bin/restsift` — the whole dispatch model in ~130 lines.
3. `lib/common.sh` — the module map and the universal `--help`/`--introspect`
   guards.
4. `libexec/ai-search` — the canonical fused-loader example, with its
   load-order constraints documented inline.
5. `libexec/sh-introspect` and `scripts/gen-completions.sh` — the
   single-source-of-truth chain in practice.
6. `lib/snapshot.sh` next to `libexec/ai-rollback` — the mechanism/policy
   split.
7. `scripts/check.sh` — what "the checks pass" actually means here.
