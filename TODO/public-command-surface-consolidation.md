# Public command-surface consolidation TODO

Status: in progress. Search (`batch`), Verify, Test, and Git families are fully fused (implementation
files physically merged, old top-level names deleted after approval). Repo, Inspect, and Session
families have canonical routing (`libexec/ai-<group>` exec-dispatches into the still-separate
original engines) but are NOT yet physically fused/deleted. Context family is not yet started. Edit
family is routing-only by design (rollback intentionally stays a fully separate, independently
recoverable engine). Human direction later favored physical fusion + deletion over the original
"merge only the public command surface, keep engines separate" rule below for Search/Verify/Test/Git
specifically — treat the per-family sections as authoritative over the global rule where they
disagree.

Target public surface before first stable release: approximately 9 command groups: `search`, `verify`, `test`, `context`, `git`, `repo`, `edit`, `inspect`, and `session`.

## Global rules

- [ ] Keep implementation engines separate when responsibilities differ; merge only the public command surface.
- [ ] Prefer pre-stable removal or de-publicization over permanent compatibility aliases.
- [ ] Do not delete or move tracked files without explicit approval for the exact paths.
- [ ] If deletion is not approved, move engines behind canonical commands, hide them from `agent-kit --list`, and exclude them from shipped public surfaces.
- [ ] Update docs, generated examples, tests, install payloads, npm package contents, Homebrew formula, and release packaging together.
- [ ] Add a publishability gate so duplicate public command names cannot reappear.

## Cross-cutting implementation tasks

- [ ] Define a public command allowlist or duplicate-command denylist for pre-stable release.
- [ ] Update `bin/agent-kit --list` / `libexec/sh-introspect --list` so internal or compatibility engines are not presented as public commands.
- [ ] Decide internal engine location, for example `libexec/internal/`, that `bin/agent-kit` cannot dispatch directly.
- [ ] Update `scripts/gen-examples.sh` so docs are generated only from public commands.
- [ ] Update packaging surfaces: `install.sh`, `scripts/package-release.sh`, `package.json`, `npm/cli.js`, `Formula/agent-kit.rb`.
- [ ] Extend `scripts/check-publishable.sh` to fail when removed/de-publicized names are shipped.

Verification for cross-cutting work:

```bash
bash test/test-bin-agent-kit.sh
bash test/test-install.sh
./scripts/check-publishable.sh
```

## P0 — consolidate before first stable release

### 1. Search family — urgency 100/100

Canonical interface:

```bash
agent-kit search text PATTERN [ROOT]
agent-kit search files QUERY [ROOT]
agent-kit search batch MODE QUERY...
agent-kit search capabilities [--probe]
```

Current state:

- [x] `agent-kit search capabilities` exists in the current working tree.
- [ ] `ai-search-introspect` remains public unless removed/de-publicized.
- [ ] `ai-search-multi`, `rg-code`, and `fd-files` remain public duplicate APIs.

Tasks:

- [ ] Keep `ai-search` as the canonical search engine.
- [ ] Internalize `ai-search-introspect`; public replacement is `agent-kit search capabilities`.
- [x] Add or confirm `agent-kit search batch` before internalizing `ai-search-multi`.
- [ ] Prove `agent-kit search text` covers `rg-code` use cases; then remove/de-publicize `rg-code`.
- [ ] Prove `agent-kit search files` covers `fd-files` use cases; then remove/de-publicize `fd-files`.
- [ ] Stop shipping `rg-code` and `fd-files` as parallel public search APIs.

Verification:

```bash
bash test/test-ai-search.sh
bash test/test-rg-code.sh
bash test/test-fd-files.sh
bash test/test-bin-agent-kit.sh
./scripts/check.sh
./scripts/check-publishable.sh
```

### 2. Verify family — urgency 100/100

Canonical interface:

```bash
agent-kit verify [ROOT]
agent-kit verify --language php [ROOT]
agent-kit verify --language js [ROOT]
agent-kit verify docs [PATH...]
agent-kit verify refs [PATH]
```

Current state:

- [x] `libexec/ai-verify` supports `--language`.
- [x] `ai-verify-html`, `ai-verify-js`, `ai-verify-php`, `ai-verify-ts`, and `ai-verify-vue` deleted; `--language <lang>` is the only route.
- [x] Docs promote `agent-kit verify --language <lang>` / `verify docs` / `verify refs`; no wrapper commands remain.
- [x] `ai-doc-check` and `check-file-refs` fused into `libexec/ai-verify` (`lib/ai-verify/{docs-check,file-refs}.sh`); no longer separate public commands.

Tasks:

- [x] Keep `ai-verify` as the canonical verification engine.
- [x] Use `agent-kit verify --language <lang>` in docs and tests.
- [x] Existing `--language html|js|php|ts|vue` coverage carried over unchanged in `test/test-ai-verify.sh`.
- [x] Remove `ai-verify-html`, `ai-verify-js`, `ai-verify-php`, `ai-verify-ts`, and `ai-verify-vue`.
- [x] Add `agent-kit verify docs` and internalize `ai-doc-check`.
- [x] Add `agent-kit verify refs` and internalize `check-file-refs`.

Verification:

```bash
bash test/test-ai-verify.sh   # ported every ai-doc-check/check-file-refs assertion; 48 passed / 0 failed / 2 skipped (env-gated)
bash test/test-bin-agent-kit.sh
./scripts/check.sh
./scripts/check-publishable.sh
```

### 3. Test family — urgency 96/100

Canonical interface:

```bash
agent-kit test select changed
agent-kit test select file src/Foo.php
agent-kit test run tests/FooTest.php
agent-kit test run --filter FooTest
agent-kit test all
```

Tasks:

- [x] Add `agent-kit test select` backed by fused `lib/ai-test/select.sh` (was `ai-test-select`).
- [x] Add `agent-kit test run` backed by fused `lib/ai-test/run-focused.sh` (was `run-test-focused`).
- [x] Add `agent-kit test all` backed by fused `lib/ai-test/run-all.sh` (was `run-repo-tests`).
- [x] Kept selection, focused execution, and full-suite execution as separate internal modules/functions (`ai_test_select_main` / `ai_test_run_main` / `ai_test_all_main`).
- [x] Removed `ai-test-select`, `run-test-focused`, and `run-repo-tests` from the shipped public surface.

Verification:

```bash
bash test/test-ai-test.sh   # 16 passed / 0 failed / 0 skipped
bash test/test-bin-agent-kit.sh
./scripts/check.sh
./scripts/check-publishable.sh
```

### 4. Context family — urgency 95/100

Canonical interface:

```bash
agent-kit context diff ...
agent-kit context pack ...
agent-kit context file PATH
agent-kit context generate
agent-kit context tree
agent-kit context status
agent-kit context ensure [--regen]
agent-kit context estimate PATH
```

Tasks:

- [x] Add `agent-kit context diff` backed by fused `lib/ai-context/diff.sh` (wraps unchanged `lib/ai-diff-context/*.sh`; was `ai-diff-context`).
- [x] Add `agent-kit context pack` backed by fused `lib/ai-context/pack.sh` (was `pack-context`).
- [x] Add `agent-kit context file` backed by fused `lib/ai-context/file.sh` (was `run-repomix-file`).
- [x] Add `agent-kit context generate` backed by `lib/ai-context/generate.sh`, which execs the relocated (not fused) `libexec/internal/run-repomix-context`.
- [x] Add `agent-kit context tree` backed by `lib/ai-context/tree.sh`, which execs the relocated (not fused) `libexec/internal/repomix-context-tree`. `generate`/`tree` were deliberately kept as separate processes rather than fused, per a confirmed `die()`/`log()`/`estimate_tokens()` name-collision risk between `lib/repomix-context-tree/helpers.sh` and `lib/core.sh`/`lib/tokens.sh` if merged into the shared `ai-context` process.
- [x] Add `agent-kit context status` backed by fused `lib/ai-context/status.sh` (was `repomix-freshness`).
- [x] Add `agent-kit context ensure` backed by fused `lib/ai-context/ensure.sh` (was `repomix-ensure-fresh`).
- [x] Add `agent-kit context estimate` backed by fused `lib/ai-context/estimate.sh` (was `query-usage`).
- [x] `repomix-scc-router` relocated to `libexec/internal/repomix-scc-router`: hidden from `agent-kit --list` and public dispatch, left fully unwired (no public route added, matching this exact instruction).
- [ ] Remove `all-f-into-one` from the shipped public surface — not yet done.

Verification:

```bash
bash test/test-ai-context.sh                 # 26 passed / 0 failed / 0 skipped (ported from 5 old test files)
bash test/test-run-repomix-context.sh        # 3 passed (relocated engine, path updated)
bash test/test-repomix-context-tree.sh       # 4 passed (relocated engine, path updated)
bash test/test-repomix-scc-router.sh         # 9 passed (relocated engine, path updated)
bash test/test-bin-agent-kit.sh
./scripts/check.sh
./scripts/check-publishable.sh
```

## P1 — consolidate strongly

### 5. Git family — urgency 87/100

Canonical interface:

```bash
agent-kit git origin
agent-kit git history --string VALUE
agent-kit git history --regex VALUE
agent-kit git blame FILE --lines 10,20
agent-kit git pr-context NUMBER
```

Tasks:

- [x] Add `agent-kit git origin` backed by fused `lib/ai-git/origin.sh` (was `git-branch-origin`).
- [x] Add `agent-kit git history` and `agent-kit git blame` backed by fused `lib/ai-git/forensics.sh` (was `git-forensics`).
- [x] Add `agent-kit git pr-context` backed by fused `lib/ai-git/pr-context.sh` (was `gh-pr-context`).
- [x] Removed `git-branch-origin`, `git-forensics`, and `gh-pr-context` from the shipped public surface.

Note: implemented as a real fused engine (`libexec/ai-git` sources `lib/ai-git/*.sh` and calls each
mode as a function in the same process), not an exec-router, per later human direction favoring
physical consolidation over the original "keep implementation engines separate" global rule for
this family. See git history for the exact change.

Verification:

```bash
bash test/test-ai-git.sh   # 20 passed / 0 failed / 0 skipped (ports every assertion from the 3 old test files)
bash test/test-bin-agent-kit.sh
./scripts/check-publishable.sh
```

### 6. Repository family — urgency 82/100

Canonical interface:

```bash
agent-kit repo tasks
agent-kit repo stats
agent-kit repo tools
agent-kit repo status
```

Tasks:

- [x] Add `agent-kit repo tasks` backed by `ai-task` (routed via `libexec/ai-repo`, engine kept separate — not yet physically fused).
- [x] Add `agent-kit repo stats` backed by `repo-stats` (routed).
- [x] Add `agent-kit repo tools` backed by `repo-tool-inventory` (routed).
- [x] `agent-kit repo status` routes to `ai-file-freshness` as-is (no `--surface docs` filter added; that remains a future enhancement, not a rename).
- [ ] Remove/de-publicize old top-level public names (`ai-task`, `repo-stats`, `repo-tool-inventory`, `ai-file-freshness` still exist as separate public commands; only routing was added, not fusion+deletion).

Verification:

```bash
bash test/test-ai-task.sh
bash test/test-repo-tool-inventory.sh
bash test/test-misc-wrappers.sh
bash test/test-bin-agent-kit.sh
./scripts/check-publishable.sh
```

### 7. Edit family — urgency 77/100

Canonical interface:

```bash
agent-kit edit apply ...
agent-kit edit rollback ...
```

Tasks:

- [x] Kept `ai-edit` and `ai-rollback` as fully separate engines (zero changes to `ai-rollback`) because rollback must remain independently recoverable.
- [x] Add `agent-kit edit apply` as the canonical edit route (thin `apply` token shift; bare `agent-kit edit MODE ...` still works unchanged).
- [x] Add `agent-kit edit rollback` as the canonical rollback route (early-exit `exec` shim into unchanged `ai-rollback`, same pattern as `ai-search`'s `capabilities` shim).
- [x] `agent-kit rollback` remains as the primary/documented route (not just a compatibility shim); `agent-kit edit rollback` is additive.

Verification:

```bash
bash test/test-ai-edit.sh
bash test/test-ai-rollback.sh
bash test/test-bin-agent-kit.sh
./scripts/check-publishable.sh
```

## P2 — useful namespace cleanup

### 8. Inspection family — urgency 61/100

Canonical interface:

```bash
agent-kit inspect file PATH
agent-kit inspect data json FILE QUERY
agent-kit inspect data yaml FILE QUERY
agent-kit inspect shell SCRIPT
```

Tasks:

- [x] Add `agent-kit inspect file` backed by `preview-file` (routed via `libexec/ai-inspect`, engine kept separate).
- [x] Add `agent-kit inspect data` backed by `ai-structured` (routed).
- [x] Add `agent-kit inspect shell` backed by `sh-introspect` (routed).
- [x] Decision: these stay as separate top-level dispatcher commands too (human review flagged this cluster as "not one coherent engine" — search-ish tools like `fd-files`/`rg-code` belong under `search`, not `inspect`; that reclassification is not yet implemented).

Verification:

```bash
bash test/test-preview-file.sh
bash test/test-ai-structured.sh
bash test/test-sh-introspect.sh
bash test/test-bin-agent-kit.sh
```

### 9. Session family — urgency 52/100

Canonical interface:

```bash
agent-kit session checkpoint
agent-kit session watch
```

Tasks:

- [x] Add `agent-kit session checkpoint` backed by `session-checkpoint` (routed via `libexec/ai-session`, engine kept separate).
- [x] Add `agent-kit session watch` backed by `watch-loop` (routed as-is; watching-scope confirmation not separately re-verified).

Verification:

```bash
bash test/test-session-checkpoint.sh
bash test/test-watch-loop.sh
bash test/test-bin-agent-kit.sh
```

## Final shipped public CLI target

```text
agent-kit
├── search
│   ├── text
│   ├── files
│   ├── history
│   ├── symbols
│   ├── batch
│   └── capabilities
├── verify
│   ├── all
│   ├── --language
│   ├── docs
│   └── refs
├── test
│   ├── select
│   ├── run
│   └── all
├── context
│   ├── diff
│   ├── pack
│   ├── file
│   ├── generate
│   ├── tree
│   ├── status
│   ├── ensure
│   └── estimate
├── git
│   ├── origin
│   ├── history
│   ├── blame
│   └── pr-context
├── repo
│   ├── tasks
│   ├── stats
│   ├── tools
│   └── status
├── edit
│   ├── apply
│   └── rollback
├── inspect
│   ├── file
│   ├── data
│   └── shell
└── session
    ├── checkpoint
    └── watch
```

## Final release gate

- [ ] `agent-kit --list` shows only approved public commands.
- [ ] Docs promote only canonical command groups.
- [ ] Release packages do not expose duplicate public names.
- [ ] All approved removals/internalizations have recorded human approval.
- [ ] Full verification passes.

```bash
./scripts/check.sh
./scripts/check-publishable.sh
```
