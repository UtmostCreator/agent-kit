# Coverage plan: 46.58% → 60–70%

Baseline measured with `./scripts/coverage.sh` (native Bash `DEBUG`-trap
collector — see `scripts/lib/cov-hook.sh`; kcov's ptrace tracer is unusable in
this sandbox, see git history). Full per-file numbers: `coverage/report.txt`.

## Current state

**46.58% (3570/7665 executable lines, 108 files), all 26 test files pass.**

This already includes one applied fix (below). Everything else in this
document is **planned, not implemented** — re-run `./scripts/coverage.sh`
after each phase and treat the estimates here as sizing, not commitments.
The one empirically-verified estimate in this doc (the P1-flip below) came in
at **28% of the naive prediction** (137 actual vs. ~495 estimated), so the
per-phase estimates below are directional, not precise.

## Already applied: free win from a dormant test gate

`test/test-ai-search.sh` has ~269 already-written Phase 3–6 assertions
(structural search, git diff/history modes, curated todo/unsafe-patterns
modes, richer flag parsing) gated behind `AI_SEARCH_RUN_P1_TESTS=1`. Neither
`scripts/check.sh` (the CI gate) nor anything else in the repo ever sets that
var, so **269 passing assertions were not running in CI**. Verified standalone
(`AI_SEARCH_RUN_P1_TESTS=1 bash test/test-ai-search.sh` → 269 pass, 0 fail,
exit 0) before wiring it into `scripts/coverage.sh`'s test loop.

Result: 44.79% → 46.58% (+137 lines), zero new test code.

**Follow-up recommended (not yet done — changes the CI gate, out of this
task's scope):** set `AI_SEARCH_RUN_P1_TESTS=1` in `scripts/check.sh` too, so
these assertions actually gate merges instead of only running under
`coverage.sh`. Small, low-risk, high-value; do this first regardless of the
rest of this plan.

## Out of scope for the 60–70% target

Don't spend budget here — re-measure at the end and see if there's slack:

- **`lib/ai-verify/{kotlin-files,kotlin-dispatch,android-guards,gradle-policy}.sh`**
  (0%, 127 lines total). Needs a dedicated minimal Kotlin+Gradle(+Android)
  fixture project under a `test/fixtures/` dir — a separate, larger effort,
  not a few test cases. Track separately.
- **P0-marked-for-removal commands** per `TODO/todo.md`: `rg-code`, `fd-files`,
  `ai-search-multi`, `all-f-into-one` (already have thin smoke tests; low
  scores 45–72%). These are slated to be merged into `ai-search`/`ai-context`
  before stable release — new tests here are thrown away work. Leave as-is.
- **`lib/ai-git/pr-context.sh`** (12.1%, 87 uncovered) needs a stubbed `gh`
  binary on `PATH` to get past arg-parsing into the real JSON-assembly logic.
  Doable, but bundled into Phase 4 rather than the critical path since
  `gh`-mocking is a small side-project of its own.

## Phase 1 — safety-critical (do first regardless of coverage target)

This is the toolkit's actual safety promise (guarded mutation + rollback).
Coverage here matters independent of the 60–70% number.

| File | Now | Uncovered | Concrete gap |
|---|---|---|---|
| `lib/snapshot.sh` | 25.2% (38/151) | 113 | `snapshot_apply_manifest` — the actual restore mechanism — is **entirely untested**: `git reset --hard`, conditional patch apply, `ROLLBACK_REMOVE_CREATED_UNTRACKED` deletion loop, protected-path guard (`.git`/`AI_LOG_DIR`/`.ai-logs`/`.repomix-context` must survive), untracked-archive re-extraction. Only exercised transitively via `ai-edit --apply`, never against its own contract. |
| `libexec/ai-rollback` | 36.5% (62/170) | 108 | No test ever creates a snapshot then shows/applies/prunes it. `cmd_apply`'s real mutation path, `cmd_prune`'s real `-mtime` deletion, and `cmd_list`/`cmd_show`'s non-empty rendering are all untested. `CI=true` bypasses the confirm prompt (verified: `confirm_mutation` at `libexec/ai-rollback:41`) — no pty needed. |
| `lib/ai-edit/helpers.sh` | 32.4% (59/182) | 123 | `finish()`'s non-JSON branch for each status string, `on_error` ERR-trap firing (force a mid-mode failure), `resolve_ast_grep`'s not-found→exit-127 path. |
| `lib/ai-edit/parse.sh` | 39.7% (31/78) | 47 | Nearly every "flag given without a value" error path (`--format`, `--glob`, `--exclude`, `--max-files`, `--max-replacements`, `--max-bytes`) and `=`-form flag parsing are untested — cheap, mechanical, one line per case. |
| `lib/ai-edit/main.sh` | 52.7% (59/112) | 53 | `ast-grep`/`comby` modes (both installed in this env — `ast-grep`, `sg`), `--verify` flag success/failure, `--allow-dirty-tree` vs. default require-clean gate. |
| `lib/ai-edit/plan-apply.sh` | 62.9% (78/124) | 46 | Oversized-file skip in `sd_plan`, `structural_scope_guard` blocking `--glob`/`--exclude` with `ast-grep`/`comby`/`patch`, `patch_guard_paths` denylist beyond `.env`/`.git` (`*.pem`, `*.sqlite`, `*.zip`), rename-form patch hunks. |
| `lib/exec-guard/cpu-sampling.sh` | 68.2% (45/66) | 21 | Direct jiffies-delta assertion (source module, sample a real busy `sleep` loop) rather than only indirectly through `run_guarded`. |
| `lib/exec-guard/run-guarded.sh` | 73.8% (79/107) | 28 | No-args call (`log_warn` + return 2), `setsid`-unavailable branch (strip it from `PATH`), idle-debounce streak count (current test only asserts eventual 124, not that it survives one idle sample first). |

**Verification:**
```bash
bash test/test-ai-rollback.sh
bash test/test-ai-edit.sh
bash test/test-common.sh
./scripts/coverage.sh
```

## Phase 2 — canonical verify engine

`ai-verify` is P4 in `TODO/todo.md` (score 0, "canonical, keep forever").
`libexec/ai-verify` sources every module below unconditionally — confirmed
none of this is dead code despite some stale "not yet wired" header comments.

| File | Now | Uncovered | Concrete gap |
|---|---|---|---|
| `lib/ai-verify/language-dispatch.sh` | 0.0% (0/122) | 122 | Full `ai_verify_language` dispatch never invoked by any test — 0 calls to `--language php\|js\|ts\|vue\|html`. Needs a fixture repo with `package.json`/`composer.json` + fake `eslint`/`phpstan`/etc. on `PATH`. |
| `lib/ai-verify/reporting.sh` | 0.0% (0/13) | 13 | `verify_report_dir` / `write_verify_report_file` — pure logic, no external deps, near-free win. |
| `lib/ai-verify/tool-policy.sh` | 0.0% (0/29) | 29 | `is_standalone_safe_tool`, `has_composer_bin`, `can_run_tool` dispatch — pure logic, near-free win. |
| `lib/ai-verify/language-files.sh` | 0.0% (0/27) | 27 | `language_pathspecs` (all 5 langs + unknown→die), `scoped_language_files` — pure logic given a git fixture, near-free win. |
| `lib/ai-verify/duplication.sh` | 8.0% (4/50) | 46 | Only the `VERIFY_JSCPD` off-by-default skip line runs. Needs a fake `jscpd`/`npx` on `PATH` emitting a canned report to hit the warn/fail-tier arithmetic. |
| `lib/ai-verify/plan-status.sh` | 21.1% (15/71) | 56 | Only the off-by-default skip runs. Needs a fixture with `docs/tickets/*/plan.md` containing checklist + difficulty-phrase lines, `VERIFY_PLAN_STATUS=1`. |
| `lib/ai-verify/step-runner.sh` | 27.3% (12/44) | 32 | `diagnose_pnpm_auth`'s `.npmrc` var-extraction, `VERIFY_GUARD=0` fallback path, `has_package_script`/`has_package_dependency` branches. |
| `lib/ai-verify/run.sh` | 46.5% (99/213) | 114 | `VERIFY_FULL=1` block (phpunit/pest/deptrac), `VERIFY_SECRETS=1`/`VERIFY_SECURITY=1` blocks, `branch` scope case arm — needs fake `phpunit`/`gitleaks`/`trivy` binaries + env flags. |
| `lib/ai-verify/docs-check.sh` | 52.8% (65/123) | 58 | `ai_verify_docs_run_drift`'s 11 gated steps never see a fake `php` (pass or fail), so the `failures+=1` branch is never hit. |

**Verification:**
```bash
bash test/test-ai-verify.sh
./scripts/coverage.sh
```

## Phase 3 — context/repomix internal engines + diff-context

`ai-context`/repomix routers are P2 in `TODO/todo.md` ("make internal
implementation" — kept, just renamed publicly). `ai-diff-context` is P2
("retain implementation, rename public interface to `ai-context diff`") —
algorithm survives regardless of the public name.

**Known confound:** the shared repomix test fixtures are 2 tiny files, likely
never reaching `MIN_CODE=25`, so current tests only exercise the
fallback/skip path, not the primary `build_plan`/`write_bundle_plan`
selection logic. New tests need a bigger fixture (10+ files, 30+ code lines
each) before the "concrete gap" items below become reachable at all.

| File | Now | Uncovered | Concrete gap |
|---|---|---|---|
| `lib/repomix-context-tree/build-pack.sh` | 2.4% (6/255) | 249 | `run_pack`/`pack_route`/`run_all`/`run_clean`/`run_purge`/`generate_child_index` never invoked — only `analyze` runs today. |
| `lib/repomix-scc-router/analysis-pack.sh` | 18.3% (47/257) | 210 | `write_bundle_plan` (`plan`), `pack_group`/`run_pack`, `run_clean`, `run_purge` untested. |
| `lib/repomix/common-options.sh` | 21.6% (32/148) | 116 | Only `--output-dir` exercised. `--depth`, `--top`, `--min-code`, `--min-files`, `--min-score`, `--changed-since`, `--split-size`, `--compress`, and `=value` forms all untested. |
| `libexec/internal/run-repomix-context` | 20.0% (13/65) | 52 | `require_bins` failure, secrets-scan failure, missing-artifact `die` branches, `bundle_count == 0` die branch. |
| `lib/ai-diff-context/commands.sh` | 18.7% (23/123) | 100 | Only `cmd_since` (dry-run) is tested. `cmd_unstaged`, `cmd_pr`, `cmd_recent`, `cmd_touched` are **entirely untested** — 4 of 5 command functions at 0%. |
| `lib/ai-diff-context/helpers.sh` | 25.7% (69/269) | 200 | Largest single untested surface in the repo. Entire non-dry-run half of `pack_files_list` (secrets scan, packer selection, token-budget warn/die, manifest write), `write_diff_artifact`'s 5 mode branches, most of `parse_common_option`. |

**Verification:**
```bash
bash test/test-repomix-context-tree.sh
bash test/test-repomix-scc-router.sh
bash test/test-run-repomix-context.sh
bash test/test-ai-context.sh
./scripts/coverage.sh
```

## Phase 4 — remaining polish

Only needed if Phase 1–3 land short of 70%; re-measure before starting this.

| File | Now | Uncovered | Concrete gap |
|---|---|---|---|
| `lib/ai-git/pr-context.sh` | 12.1% (12/99) | 87 | Needs a stubbed `gh` binary emitting canned `pr view`/`checks`/`diff` JSON. |
| `lib/ai-git/origin.sh` | 67.6% (75/111) | 36 | Prefix-matching branch, `GIT_ORIGIN_INCLUDE_REMOTE=0`, no-candidates fallback (fresh single-commit repo). |
| `lib/ai-context/status.sh` | 39.4% (26/66) | 40 | Fresh/stale/expired/unparseable-`ts` states — write `run-manifest.json` with a controlled timestamp. |
| `lib/ai-context/ensure.sh` | 50.0% (39/78) | 39 | Fresh short-circuit, stale-with-regen-accepted path (stub `ai_context_generate_main`). |
| `lib/ai-context/pack.sh` | 56.7% (59/104) | 45 | "No packer found" die, `code2prompt` backend, token-budget-exceeded warn. |
| `lib/ai-context/file.sh` | 57.6% (53/92) | 39 | Missing-arg / not-on-PATH / unknown-option error branches — mechanical. |
| `lib/ai-test/run-all.sh` | 16.5% (18/109) | 91 | Test `ai_test_all_run_job` directly (sourced) rather than the full orchestrator, to avoid recursive suite runs. |
| `lib/ai-test/select.sh` | 64.4% (87/135) | 48 | `ai_test_select_command_for_test` branches (artisan/pest/phpunit, pnpm/npm) — source module, call directly with fake project files. |
| `lib/logging.sh` | 43.9% (76/173) | 97 | No-`uuidgen` fallback, `SESSION_LOG` append branch, `AI_SESSION_DURABLE_LOG=1` branch, no-`flock` degradation. |
| `libexec/preview-file` | 53.3% (106/199) | 93 | `--force` bypass, invalid `--around`/`--context` values, `bat`-present rendering path (bat is installed here — verify), `=`-form flags. |

## Rough trajectory (directional, not a commitment)

| After phase | Est. new lines | Running total | Est. % |
|---|---:|---:|---:|
| Baseline (P1-flip already applied) | — | 3570 | 46.6% |
| + Phase 1 (safety) | ~250–400 | ~3820–3970 | ~50–52% |
| + Phase 2 (verify engine) | ~250–370 | ~4070–4340 | ~53–57% |
| + Phase 3 (context/repomix/diff) | ~450–640 | ~4520–4980 | ~59–65% |
| + Phase 4 (polish) | ~250–365 | ~4770–5345 | ~62–70% |

Phases 1–3 alone should comfortably clear **60%**. Reaching **70%** likely
needs most of Phase 4, or dipping into the excluded pool (Kotlin/Android/
Gradle fixtures, `gh`-stubbed `pr-context`) if Phase 4's real yield undershoots
like the P1-flip did.

## How to verify progress at any point

```bash
./scripts/coverage.sh              # full report, coverage/report.txt
./scripts/check.sh                 # shellcheck + full suite must still pass
./scripts/check-publishable.sh
```

Re-read `coverage/report.txt` after each phase and adjust remaining scope —
don't chase the table above past what the real numbers show.
