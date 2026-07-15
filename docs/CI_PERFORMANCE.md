# CI / test-suite performance

## Rule: profile before guessing

If a CI job, `scripts/check.sh`, or any `test/test-*.sh` file takes noticeably
longer than expected, profile it immediately — do not guess a cause, add a
speculative timeout, or reach for "maybe it's the secrets/security scan"
without checking. Guessing here previously burned a full investigation
session's worth of tokens across five separate root causes; the profiling
steps below take minutes and point straight at the real cost.

1. **Per-file split** (which test file is slow): pull the workflow log
   (`gh run view <run-id> --log`), find each `test/test-*.sh`'s `==>` marker
   timestamp for the job, and diff consecutive timestamps. This ranks every
   file by wall time in one pass, no local reproduction needed yet.
2. **Per-test split** (which test inside that file is slow): copy the file,
   wrap its `run_test()` to log `$EPOCHREALTIME` before/after each call to a
   scratch file, run it, `sort -rn`. Takes one script, reusable across files.
3. **Don't forget non-test phases.** `scripts/check.sh` also runs `shellcheck`
   over every shell file before any test executes — this was the single
   largest cost in the whole suite (~93s alone) and would never show up in a
   per-test-file breakdown, because it isn't a test file.
4. **Verify every fix against the actual condition**, not "looks faster":
   A/B benchmark the old vs. new implementation, or reproduce the exact
   before/after with a standalone repro, before touching test files. A fix
   that isn't benchmarked isn't confirmed.
5. **Watch for changed correctness, not just speed**, when splitting a slow
   step into smaller/parallel units — see the shellcheck case below, where
   naive parallelization would have introduced false positives.

## Findings (2026-07-15 investigation, `feat/project-local-install`)

| cost | root cause | fix | commit |
|---|---|---|---|
| ~6-7s **per call site**, ~13 call sites across 6 test files | `build_path_without`/`path_without` helpers hid a binary by symlinking every *other* PATH executable into a dir, resolving each file's name via `` basename "$f" `` — a forked process per PATH entry | swap to `${f##*/}` (bash builtin, no fork) + batch the `ln` calls | `72aa5f2` |
| 20s per run | `test_branch_scope_recognized` ran the real verify script with a 20s timeout it reliably hit in full, even though the assertion it checks resolves in <1s | cut timeout to 3s (confirmed empirically sufficient) | `72aa5f2` |
| ~6.5s x 3 tests | `run_with_fake_lychee`'s fixture repo has no commits, so the default scope treated every file as "changed" and pulled in the real trivy/semgrep/osv-scanner security-scan block — unrelated to what those tests check (lychee invocation only) | set `AI_VERIFY_SCOPE=branch` in the fixture's env | `72aa5f2` |
| ~14s / ~9s | `run_guarded`'s CPU-percent sampler sleeps 1s (default) per sample, x2 samples needed to confirm idle | override `AI_GUARD_CPU_SAMPLE=0.2` in the two tests that sample CPU at all (detection accuracy unchanged: a `sleep 30` child reads 0% either window) | `72aa5f2` |
| ~93s (single largest cost in the whole suite) | `scripts/check.sh` ran `shellcheck` once over all 148 shell files | sharded across parallel `shellcheck` processes with `-x`/`--external-sources` (required for correctness — see below) | `31cdcab` |

**The shellcheck case is worth reading in full before touching this again.**
Naively splitting the file list across parallel single-file `shellcheck`
invocations looked like an easy 30x win (93s → ~3s) but silently introduced
5 false-positive "appears unused" warnings, because shellcheck refuses by
default to follow a `source` statement to a path outside the current
invocation's file list — and this codebase deliberately threads globals like
`$REPO_ROOT` and `$failures` from a root script into sourced `lib/*.sh`
siblings. Adding `-x` (allow `source` anywhere on disk, regardless of the
invocation's own file list) fixes this for real, confirmed by checking each
previously-flagged file in total isolation and getting a clean result
matching the single-invocation baseline exactly. Net result: ~93s → ~41s
(smaller, ~5-file shards — batches past ~20 files were measured to blow up
super-linearly rather than just amortizing better).

**On the "just skip the secrets check locally" idea:** checked and it
doesn't apply here — gitleaks-based secret scanning is already gated behind
`command -v gitleaks` in every test that needs it and skips cleanly when
gitleaks isn't installed, which is the case in this repo's CI (only
shellcheck/jq/ripgrep get installed). It was never actually running in CI,
so it wasn't a real contributor to the slowness above.

## Net result

`test/*.sh` total wall time in CI: 256s → 164s (ubuntu-22.04), 263s → 94s
(ubuntu-24.04, -64%). Full `scripts/check.sh` locally: 3m52s → 3m3s after the
shellcheck fix landed on top of the test-file fixes.
