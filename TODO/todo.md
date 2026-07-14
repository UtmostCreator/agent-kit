## Priority scale

| Phase  |  Score | Meaning                                                   |
| ------ | -----: | --------------------------------------------------------- |
| **P0** | 90–100 | Consolidate before first stable release                   |
| **P1** |  75–89 | Consolidate immediately after core release blockers       |
| **P2** |  55–74 | Simplify public surface; retain implementation internally |
| **P3** |  30–54 | Optional namespace cleanup                                |
| **P4** |   0–29 | Keep separate                                             |

## P0 — merge or remove now

| Scripts                                                                            |   Score | Action                                                                   | Canonical destination                             |
| ---------------------------------------------------------------------------------- | ------: | ------------------------------------------------------------------------ | ------------------------------------------------- |
| `all-f-into-one`                                                                   | **100** | **Remove**                                                               | `ai-context pack`                                 |
| `ai-verify-html`, `ai-verify-js`, `ai-verify-php`, `ai-verify-ts`, `ai-verify-vue` | **100** | **Remove implementations**; optionally retain tiny compatibility aliases | `ai-verify --language <lang>`                     |
| `ai-file-freshness`                                                                |  **99** | **Remove or completely rename**                                          | `ai-search changed-files` or `ai-repo status`     |
| `rg-code`                                                                          |  **98** | **Merge and remove**                                                     | `ai-search text` / `tracked` / `config`           |
| `fd-files`                                                                         |  **97** | **Merge and remove**                                                     | `ai-search files`                                 |
| `ai-search-multi`                                                                  |  **94** | **Merge and remove**                                                     | `ai-search --batch`, repeated `--query`, or stdin |
| `repomix-freshness`                                                                |  **93** | **Internalise**                                                          | `ai-context status`                               |
| `repomix-ensure-fresh`                                                             |  **92** | **Merge public interface**                                               | `ai-context ensure`                               |
| `run-repomix-context`                                                              |  **90** | Keep engine, merge public interface                                      | `ai-context generate`                             |

### Why these are P0

`all-f-into-one` is a legacy Zsh concatenator that writes every selected file into `combined_output.txt`. It lacks the secret scanning, token budgeting, backend selection and manifest generation already provided by `pack-context`.

The five language verification commands contain no verification logic; they delegate directly to `ai-verify.sh --language`.

`ai-file-freshness` does not calculate freshness. It runs one fixed `git status --short` command against several directories, making its name and contract misleading.

`rg-code` and `fd-files` duplicate search modes already exposed by `ai-search`, including text, tracked files, configuration files, file discovery, case control, context and output shaping.

`repomix-ensure-fresh` already calls both `repomix-freshness` and `run-repomix-context`. It even determines whether status is stale by parsing the checker’s human-readable first line. These should share one internal status function rather than communicate through text.

## P1 — consolidate next

| Scripts                |  Score | Action                                       | Canonical destination    |        |
| ---------------------- | -----: | -------------------------------------------- | ------------------------ | ------ |
| `ai-test-select`       | **89** | Merge                                        | `ai-test select`         |        |
| `run-test-focused`     | **88** | Merge                                        | `ai-test run`            |        |
| `run-repo-tests`       | **86** | Merge public interface; retain runner module | `ai-test all`            |        |
| `ai-doc-check`         | **85** | Merge public interface                       | `ai-verify docs`         |        |
| `run-repomix-file`     | **84** | Merge                                        | `ai-context file`        |        |
| `ai-search-introspect` | **82** | Merge                                        | `ai-search capabilities` |        |
| `git-forensics`        | **79** | Partially merge                              | `ai-git history          | blame` |
| `check-file-refs`      | **76** | Retain algorithm, remove standalone command  | `ai-verify refs`         |        |

### Test cluster

These currently divide one lifecycle across three commands:

- `ai-test-select` discovers candidate tests but does not execute them.
- `run-test-focused` executes a selected PHPUnit file or filter.
- `run-repo-tests` executes complete suites and validators.

That should become one command with `select`, `run` and `all` modes.

### Verification cluster

`ai-doc-check` is already a verification orchestrator covering Markdown, links and repository drift validators. It belongs under the canonical `ai-verify` interface rather than beside it.

`check-file-refs` provides useful orphan detection and should not be deleted, but it is naturally a verification profile rather than an independent top-level utility.

### Context cluster

`run-repomix-file` duplicates Repomix invocation, output creation and manifest generation already conceptually owned by `pack-context`.

### Git/search cluster

`git-forensics` modes `S` and `G` overlap `ai-search history`, which already supports string versus regex history searches and patches. Keep line history and blame, but place them under a single `ai-git` command.

## P2 — internalise or namespace

| Scripts                |  Score | Action                                         | Destination                     |
| ---------------------- | -----: | ---------------------------------------------- | ------------------------------- |
| `repomix-context-tree` | **74** | Make internal implementation                   | `internal/context/repomix-tree` |
| `repomix-scc-router`   | **71** | Make internal implementation                   | `internal/context/scc-router`   |
| `query-usage`          | **69** | Merge                                          | `ai-context estimate`           |
| `git-branch-origin`    | **66** | Merge public interface or internalise          | `ai-git origin`                 |
| `repo-stats`           | **63** | Merge public namespace                         | `ai-repo stats`                 |
| `repo-tool-inventory`  | **62** | Merge public namespace; retain PHP backend     | `ai-repo tools`                 |
| `gh-pr-context`        | **59** | Merge public namespace                         | `ai-git pr` or `ai-context pr`  |
| `ai-diff-context`      | **57** | Retain implementation, rename public interface | `ai-context diff`               |

`query-usage` is specifically a byte/token estimator, so it fits the context domain rather than remaining a generic “query” command.

`git-branch-origin` remains valuable, particularly because verification uses its merge-base information, but it does not require a separate top-level executable.

## P3 — optional consolidation

| Scripts                  |  Score | Recommendation                                                          |                                                       |
| ------------------------ | -----: | ----------------------------------------------------------------------- | ----------------------------------------------------- |
| `ai-task`                | **48** | Expose as `ai-repo tasks`; retain implementation                        |                                                       |
| `ai-edit`, `ai-rollback` | **40** | Optionally expose as `ai-edit apply                                     | rollback`, but keep separate internal risk boundaries |
| `pack-context`           | **35** | Rename public interface to `ai-context pack`; keep as canonical backend |                                                       |

`ai-task` discovers project-provided package, Composer, Make, Just and Taskfile commands, so it is related to repository inspection rather than context packing or verification.

## P4 — keep separate

| Script               |  Score | Reason                                 |
| -------------------- | -----: | -------------------------------------- |
| `ai-search`          |  **0** | Canonical search engine                |
| `ai-verify`          |  **0** | Canonical verification engine          |
| `ai-structured`      | **10** | Distinct JSON/YAML/CSV/XML querying    |
| `preview-file`       | **10** | Distinct safe-preview boundary         |
| `sh-introspect`      |  **5** | Canonical shell contract introspector  |
| `session-checkpoint` | **10** | Distinct session persistence operation |
| `watch-loop`         | **15** | Distinct long-running orchestration    |
| `ai-edit`            | **15** | Distinct guarded mutation operation    |
| `ai-rollback`        | **15** | Distinct recovery operation            |

## Recommended final public surface

```text
ai-search
  text | files | history | symbols | batch | capabilities

ai-verify
  all | language | docs | refs

ai-test
  select | run | all

ai-context
  diff | pack | file | generate | status | ensure | estimate

ai-git
  origin | history | blame | pr

ai-repo
  tasks | stats | tools

ai-edit
  apply | rollback

ai-structured
preview-file
session-checkpoint
sh-introspect
watch-loop
```

This reduces **40 executables to approximately 12 canonical commands**, while retaining compatibility shims only where published users may already depend on the old names.

## Verdict

**For the bounded `search capabilities` slice: 96/100 — complete and correctly implemented.**

**Against the full consolidation plan: approximately 12/100 — most recommended work remains.**

You completed one item:

| Recommendation                                             | Status                    |
| ---------------------------------------------------------- | ------------------------- |
| Merge `ai-search-introspect` into `ai-search capabilities` | **Functionally complete** |
| Preserve old command temporarily                           | **Complete**              |
| Update canonical documentation                             | **Complete**              |
| Test direct and dispatcher invocation                      | **Complete**              |
| Validate publishing surface                                | **Complete**              |
| Independent reviewer pass                                  | **Pending**               |

## What was done correctly

- The canonical route is now `agent-kit search capabilities`.
- Existing implementation was reused rather than duplicated.
- The split `lib/ai-search/*` parsing defect was fixed.
- Both direct and dispatcher paths have regression coverage.
- Documentation now promotes the canonical command.
- Full repository and publishability checks passed.
- `TODO/todo.md` was correctly excluded from the implementation scope.
- `/review-diff` is the correct next handoff.

## Important distinction

You **merged the behaviour**, but you have **not reduced the public command surface** because `ai-search-introspect` remains installed and callable.

That is acceptable during a compatibility period. However, if this package has not had its first stable release, retaining a permanent compatibility command is probably unnecessary. Prefer:

```text
Public:
  agent-kit search capabilities

Internal implementation:
  libexec/internal/ai-search-capabilities
```

rather than shipping both public names indefinitely.

## Major consolidation work still outstanding

### P0

| Cluster                          | Remaining action                                              |
| -------------------------------- | ------------------------------------------------------------- |
| `ai-verify-{html,js,php,ts,vue}` | Convert to aliases or remove in favour of `verify --language` |
| `rg-code`                        | Merge into `search text`                                      |
| `fd-files`                       | Merge into `search files`                                     |
| `ai-search-multi`                | Merge into `search --batch` or repeated queries               |
| `all-f-into-one`                 | Remove in favour of context packing                           |
| `ai-file-freshness`              | Remove or rename because its contract is misleading           |
| Repomix freshness commands       | Consolidate checker, ensure and generator lifecycle           |

### P1

| Cluster                                                | Remaining action                                 |
| ------------------------------------------------------ | ------------------------------------------------ |
| `ai-test-select`, `run-test-focused`, `run-repo-tests` | Consolidate under one test interface             |
| `ai-doc-check`, `check-file-refs`                      | Expose through verification modes                |
| `run-repomix-file`                                     | Consolidate under the context interface          |
| `git-forensics`                                        | Move history functionality under a Git namespace |

## Recommended status wording

Your current summary should not imply the overall consolidation is complete. Use:

```text
Status: verified implementation of the bounded `ai-search capabilities` consolidation slice.

This slice is complete, compatibility-preserving and publishable. It does not complete the broader command-surface consolidation plan; P0 removals and the remaining P1/P2 command merges are intentionally deferred pending explicit public-surface approval.
```

The implementation itself appears sound from the evidence provided, but I could not independently inspect `/home/utmostcreator/Projects/agent-kit` because that local path is not mounted in this session.

## Remaining public command-surface consolidation plan

Status: the bounded `agent-kit search capabilities` slice is implemented and verified, but the broader public command-surface consolidation is unfinished. Treat this section as the implementation plan for the remaining work.

### Compatibility and deletion policy

AgentKit is pre-stable (`0.1.0`), so confusing duplicate public command names should be removed or de-publicized before the first stable release instead of preserved indefinitely.

Rules:

- Canonical public commands must be documented and tested through `agent-kit <domain> <mode>` forms.
- Legacy top-level command names may remain only as short temporary aliases with an explicit removal window.
- Tracked-file deletion requires explicit approval before implementation. If deletion is not approved, move implementation behind canonical commands under a non-dispatchable internal path, exclude legacy aliases from packaging, or keep temporary aliases with dated removal notes.
- Before stable release, the public package/install surface should not expose: `ai-search-introspect`, `ai-search-multi`, `rg-code`, `fd-files`, `ai-file-freshness`, `ai-verify-html`, `ai-verify-js`, `ai-verify-php`, `ai-verify-ts`, or `ai-verify-vue`.

### Slice 1 — Canonical language verification

Goal: language-specific verification is invoked and promoted only as:

```bash
agent-kit verify --language <lang>
```

Current evidence: `libexec/ai-verify` supports `--language`; the five `ai-verify-<lang>` files are already thin wrappers that exec `ai-verify --language <lang>`. Do not document `--lang` unless code is explicitly changed to support it.

Implementation steps:

1. Keep `libexec/ai-verify` as the only canonical verification entrypoint.
2. Replace docs/examples for `verify-html`, `verify-js`, `verify-php`, `verify-ts`, and `verify-vue` with canonical examples:
   - `agent-kit verify --language html .`
   - `agent-kit verify --language js .`
   - `agent-kit verify --language php .`
   - `agent-kit verify --language ts .`
   - `agent-kit verify --language vue .`
3. Add dispatcher tests proving `agent-kit verify --language html|js|php|ts|vue .` reaches language dispatch.
4. Approval decision: remove the tracked wrapper files before stable release, or keep them only as temporary aliases excluded from public docs.

Acceptance criteria:

- `docs/EXAMPLES.md`, `docs/COMMANDS.md`, and README-facing surfaces no longer promote `agent-kit verify-<lang>`.
- Tests cover `agent-kit verify --language html|js|php|ts|vue`.
- No test requires users to call `agent-kit verify-html`, `verify-js`, `verify-php`, `verify-ts`, or `verify-vue`.
- If wrapper files remain, they are labelled temporary compatibility aliases only.

Verification:

```bash
bash test/test-ai-verify.sh
bash test/test-bin-agent-kit.sh
./scripts/check.sh
./scripts/check-publishable.sh
```

### Slice 2 — Search duplicate command de-publicization

Goal: public search usage converges on `agent-kit search ...`.

Canonical replacements:

- `agent-kit search capabilities` replaces `agent-kit search-introspect`.
- `agent-kit search text ...` replaces `rg-code`.
- `agent-kit search files ...` replaces `fd-files`.
- `agent-kit search --batch` or another approved `search` batch form replaces `search-multi`.

Implementation steps:

1. Keep the existing `search capabilities` behavior.
2. Add or confirm canonical batch support before removing `ai-search-multi` from the public surface.
3. Port any unique behavior from `rg-code`, `fd-files`, and `ai-search-multi` into `ai-search` modes or internal modules.
4. Stop promoting duplicate search names in docs/examples.
5. With explicit approval, remove or move duplicate top-level `libexec` commands so `agent-kit --list` no longer presents them as public commands.

Acceptance criteria:

- `agent-kit search capabilities` is the only promoted capability-map command.
- `agent-kit search text` covers documented `rg-code` use cases.
- `agent-kit search files` covers documented `fd-files` use cases.
- Batch search has one canonical documented command form.
- Before stable release, `agent-kit --list` does not list duplicate search names unless a temporary compatibility window is explicitly approved.

Verification:

```bash
bash test/test-ai-search.sh
bash test/test-bin-agent-kit.sh
bash test/test-rg-code.sh
bash test/test-fd-files.sh
./scripts/check.sh
./scripts/check-publishable.sh
```

### Slice 3 — Misleading freshness command removal or rename

Goal: eliminate `ai-file-freshness` as a confusing public name.

Implementation steps:

1. Choose the canonical destination: `agent-kit search changed-files` for changed-file discovery, or `agent-kit repo status` if a repository-status namespace is introduced.
2. Port useful behavior into the chosen canonical destination.
3. Replace `test/test-misc-wrappers.sh` coverage so it proves the canonical replacement instead of the public wrapper.
4. Removal of the tracked top-level file requires explicit approval.

Acceptance criteria:

- Docs do not promote `ai-file-freshness`.
- Tests prove the canonical replacement.
- Public package/install surface does not ship `ai-file-freshness` as a top-level callable command before stable release unless explicitly approved as a temporary alias.

Verification:

```bash
bash test/test-misc-wrappers.sh
bash test/test-bin-agent-kit.sh
./scripts/check.sh
./scripts/check-publishable.sh
```

### Slice 4 — Packaging and install surface gate

Goal: removed or de-publicized names must not be shipped by install, Homebrew, npm, or release archives.

Surfaces to update or test:

- `install.sh`
- `scripts/package-release.sh`
- `Formula/agent-kit.rb`
- `package.json`
- `npm/cli.js`
- `bin/agent-kit`

Implementation steps:

1. Add a publishable/public-surface allowlist or denylist test for pre-stable duplicate names.
2. Ensure internal implementations live somewhere `bin/agent-kit` cannot dispatch by command name.
3. Ensure packaging does not expose removed aliases as top-level executables.
4. Add tests that inspect installed, staged, and package surfaces for absence of duplicate public command names.

Acceptance criteria:

- Install payload, release archive, Homebrew install, and npm package do not expose duplicate top-level commands.
- `agent-kit --list` reflects the canonical public surface.
- `./scripts/check-publishable.sh` fails if duplicate public command names reappear.

Verification:

```bash
bash test/test-install.sh
bash test/test-bin-agent-kit.sh
./scripts/check-publishable.sh
```

### Slice 5 — Final TODO/documentation update

Goal: make the plan state clear after each slice lands.

Acceptance criteria:

- This TODO distinguishes the completed `search capabilities` slice from unfinished consolidation.
- Each completed duplicate-name removal is marked with the canonical replacement and verification evidence.
- Deletion approvals are recorded next to any tracked-file removals.
- Public docs show canonical commands only, especially `agent-kit verify --language <lang>` for per-language verification.
