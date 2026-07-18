# Plan — Repomix config layer + exact-token integration for restsift

> **Target:** `restsift` toolkit at `/home/utmostcreator/Projects/restsift`, HEAD `ad648327d73a8ff1e6ee1fce34f7e76a51bfe0ee`.
> **Contract:** `repomix-config-layer-20260718`.
> **Design-only.** No edits to restsift source in this pass. This plan describes the change; a later implementation pass executes it.
> **Companion deliverable:** `recommendation.md` (part C — token-counting method index) ships alongside this plan.
> **Tests to run at implementation time (all exist today, see section 5):** `bash test/run-all.sh`, plus targeted `test/test-ai-context.sh`, `test/test-repomix-context-tree.sh`, `test/test-repomix-scc-router.sh`, `test/test-run-repomix-context.sh`, `test/test-common.sh`, `test/test-common-source.sh`.

---

## 1. Context

restsift wraps the real `repomix` CLI to build scoped context bundles. Three architectural facts constrain any change:

1. **Isolated engines (hard `exec`).** `libexec/ai-context:64-96` dispatches generate/tree; `lib/ai-context/generate.sh:20-22` execs `libexec/internal/run-repomix-context`; `lib/ai-context/tree.sh:34` execs `libexec/internal/repomix-context-tree`. These are hard `exec` into isolated subprocesses — a config layer must survive the exec boundary (env vars do; in-process shell state does not).
2. **Two real repomix call sites, one arg-building idiom.** `lib/repomix-context-tree/build-pack.sh:273-295` (`pack_route()`, invocations at :293/:295) and `lib/repomix-scc-router/analysis-pack.sh:291-343` (invocations at :332/:343) both build a `repomix_args=(--output ... --style ...)` array and append conditional flags. This idiom is the single insertion point for new flags — near-identical code (>=75 percent overlap) at both sites, so extend it, do not fork it.
3. **Token counting is bytes/4 everywhere.** `lib/tokens.sh:34-51` (`estimate_tokens`) is a bytes/4 estimate with an optional `TOKEN_ESTIMATOR_CMD` hook (:37). No repomix TokenCounter / packResult / --token-count-tree output is ever consumed (F4/F6/F7). Encoding and token-budget knobs **never reach repomix today** (F4).

The gap: users cannot override repomix defaults (encoding, style, compress, token budget, depth, output dir, ignore extras) without editing source, and restsift budget decisions run on a bytes/4 proxy rather than exact tokens.

## 2. Evidence (file:line — authoritative)

- **Dispatch / isolated engines:** `libexec/ai-context:64-96`; `lib/ai-context/generate.sh:20-22`; `lib/ai-context/tree.sh:34`. (F1)
- **Tree engine invocation of internal engine:** `libexec/internal/run-repomix-context:73-84`. (F2)
- **Real repomix CLI call sites (verified):** `lib/repomix-context-tree/build-pack.sh:273-295` — `repomix_args=(--output "$out_abs" --style "$STYLE")` at :273, conditional --no-gitignore/--no-dot-ignore/--no-default-patterns/--compress/--split-output/--include-logs/--include-diffs at :275-281, `repomix --stdin` / `repomix --include` at :293/:295; `lib/repomix-scc-router/analysis-pack.sh:291-343` (same idiom, invocations :332/:343). (F3)
- **No token/encoding flag reaches repomix:** `pack_route()` builds no --token-* / --token-budget / --token-count-encoding. The only --token-budget in the tree is the unrelated restsift `context pack`/`diff` flag: `lib/ai-diff-context/helpers.sh:38-46`, `lib/ai-context/diff.sh:45,56`, consumed by `within_token_budget` (`lib/ai-context/pack.sh:159-165`). (F4)
- **No version pin:** no `npx repomix`, no `repomix@version`, no `repomix --version`; `package.json:1-61` has no dependencies block, no lockfile, no node_modules; guards are `command -v repomix` only. Locally observed repomix 1.15.0 (env state, not a pin). (F5)
- **Token helpers (verified):** `lib/tokens.sh` — `estimate_tokens_string:12`, `estimate_file_tokens_fallback:27-32`, `estimate_tokens:34-51` (TOKEN_ESTIMATOR_CMD hook :37, integer-validated :42, bytes/4 fallback :50), `within_token_budget:53-59` (default max 128000 at :55). (F6)
- **estimate_tokens two-signature collision (verified):** `lib/tokens.sh:34` takes a **file path**; `lib/repomix-context-tree/helpers.sh:80-83` redefines `estimate_tokens()` taking a **byte count** via awk. `lib/repomix-scc-router/helpers.sh` does NOT redefine it. Do not fuse these. (F8)
- **Defaults surface (verified):** `lib/repomix/common-options.sh:35-54` `_repomix_common_defaults` — OUTPUT_DIR=.repomix-context (:36), DEPTH=2 (:37), TOP=0 (:38), MIN_CODE=25 (:39), MIN_FILES=1 (:40), STYLE=xml (:45), COMPRESS=0 (:47), INCLUDE_LOGS=0 / INCLUDE_LOGS_COUNT=20 (:48-49), INCLUDE_DIFFS=0 (:50). **Only INCLUDE_IGNORED (:51) and INCLUDE_REPOMIXIGNORED (:54) already honor env override** via `${VAR:-0}`; every other default is hardcoded. Status knobs REPOMIX_WARN_DAYS=2 / REPOMIX_MAX_DAYS=7 (`lib/ai-context/status.sh:54-55`), REPOMIX_AUTO_REGEN=0 (`lib/ai-context/ensure.sh:78`). No AGENT_KIT_* var exists anywhere. (F9)
- **No config-file seam (verified):** `lib/environment.sh` — assignments only, header :6-8 forbids deps/sourcing; AI_* contract with COPILOT_* fallbacks. `share/config/*.txt` is list-only via `ai_load_config_list()` (`lib/core.sh:59-76`), not key=value scalars. (F10)
- **scc-router is sequential composition, not a branch:** `lib/repomix-scc-router/main.sh:65-91`; run_stats always runs scc (`analysis-pack.sh:9-60`); run_pack always shells to real repomix (`analysis-pack.sh:285-344`). No repomix-vs-scc conditional. (F11)
- **Tests entrypoint:** `test/run-all.sh` (plain bash, iterates `test/test-*.sh`, no bats). (F12)
- **repomix.config.json is native config; repomix reads NO env vars.** Keys: output.{style,compress,removeComments,removeEmptyLines,showLineNumbers,tokenBudget,topFilesLength,git.{includeDiffs,includeLogs,includeLogsCount}}, ignore.{useGitignore,useDotIgnore,useDefaultPatterns,customPatterns}, security.enableSecurityCheck, tokenCount.encoding (default o200k_base), input.maxFileSize. CLI flags that exist: --token-budget, --token-count-tree [threshold], --token-count-encoding, --remove-comments, --remove-empty-lines, --compress, --no-files, --config, --style, --top-files-len. --metrics-only does NOT exist.

---

## 3. Design

### A. Config layer over the existing subsystem

**Goal:** user-overridable repomix defaults threaded to the real CLI without breaking the isolated-engine exec boundary (F1) or the dynamic-scope option pattern in common-options.sh.

**Strategy — extend, do not rewrite (reuse callout).** Two touch points, both extensions of existing idioms:

1. **`_repomix_common_defaults` (`lib/repomix/common-options.sh:35-54`) becomes fully env-overridable.** Change each hardcoded assignment to the `${VAR:-default}` form already used at :51/:54. Mechanical, backward-compatible: absent env, values are identical to today. Survives the exec boundary because env vars propagate into the isolated engines (F1).

   Design intent (not final code):
   - `STYLE="${REPOMIX_STYLE:-xml}"` (was STYLE=xml at :45)
   - `COMPRESS="${REPOMIX_COMPRESS:-0}"` (was :47)
   - `DEPTH="${REPOMIX_DEPTH:-2}"` (was :37)
   - `OUTPUT_DIR="${REPOMIX_OUTPUT_DIR:-.repomix-context}"` (was :36)
   - INCLUDE_IGNORED / INCLUDE_REPOMIXIGNORED — already env-aware at :51/:54, keep as precedent.

2. **Two NEW knobs that currently never reach repomix (F4): encoding + token budget.** Add `REPOMIX_TOKEN_ENCODING` and `REPOMIX_TOKEN_BUDGET` defaults in `_repomix_common_defaults`, and append the corresponding flags in BOTH `repomix_args` builders (`build-pack.sh:273-281` and `analysis-pack.sh:291-343`) using the conditional-append idiom already there:
   - `[[ -n "$REPOMIX_TOKEN_ENCODING" ]] && repomix_args+=(--token-count-encoding "$REPOMIX_TOKEN_ENCODING")`
   - `[[ -n "$REPOMIX_TOKEN_BUDGET" ]] && repomix_args+=(--token-budget "$REPOMIX_TOKEN_BUDGET")`

   > **Reuse callout:** the two call sites are >=75 percent overlapping (F3). Prefer factoring the shared append block into ONE helper in `lib/repomix/common-options.sh` (e.g. `_repomix_apply_common_flags repomix_args`) that both `pack_route()` and the scc-router pack builder call, rather than editing the two arrays independently and letting them drift. If a shared helper is too invasive for a bounded first pass, add the two lines identically at both sites and file a follow-up to dedupe — but flag the drift risk explicitly.

**Knob to CLI flag / config.json key map:**

| restsift knob (default) | repomix CLI flag | repomix.config.json key | Reaches repomix today? |
|---|---|---|---|
| STYLE (xml, :45) | --style | output.style | yes (build-pack.sh:273) |
| COMPRESS (0, :47) | --compress | output.compress | yes (:278) |
| OUTPUT_DIR (.repomix-context, :36) | --output | n/a (path arg) | yes (:273) |
| DEPTH (2, :37) | n/a (restsift tree scope) | n/a | no — internal routing only (F2) |
| INCLUDE_IGNORED (0, :51) | --no-gitignore | ignore.useGitignore=false | yes (:275) |
| INCLUDE_REPOMIXIGNORED (0, :54) | --no-dot-ignore --no-default-patterns | ignore.{useDotIgnore,useDefaultPatterns}=false | yes (:276) |
| INCLUDE_LOGS/_COUNT (0/20, :48-49) | --include-logs / --include-logs-count | output.git.{includeLogs,includeLogsCount} | yes (:279) |
| INCLUDE_DIFFS (0, :50) | --include-diffs | output.git.includeDiffs | yes (:280) |
| **REPOMIX_TOKEN_ENCODING** (NEW, o200k_base) | --token-count-encoding | tokenCount.encoding | **no — closes F4 gap** |
| **REPOMIX_TOKEN_BUDGET** (NEW, unset) | --token-budget | output.tokenBudget | **no — closes F4 gap** |

**Do NOT touch the estimate_tokens collision (F8).** The config layer adds flags to repomix invocations and defaults; it does not unify `lib/tokens.sh:34` (file-path signature) with `lib/repomix-context-tree/helpers.sh:80` (byte-count signature). These stay separate. The exact-counter work (part D) routes through the `TOKEN_ESTIMATOR_CMD` hook at `lib/tokens.sh:37` only — it never rewrites the tree-helper shadow.

### B. Env file for defaults

**Concrete decision: two-tier, both optional, loaded by a NEW documented seam.**

- **Tier 1 — shipped reference (documentation, not sourced by default):** `share/config/repomix-defaults.env.example` — commented reference listing every key and its built-in default. NOT auto-sourced (shipped behavior stays identical to today). Users copy it to enable overrides.
- **Tier 2 — repo-local override dotfile (auto-discovered):** `.restsift/repomix.env` at repo root (or `RESTSIFT_CONFIG` pointing elsewhere). Shell KEY=value format.

**Format:** shell KEY=value, hash-comments allowed — extends the REPOMIX_* env convention directly. Deliberately NOT the list-file format that `ai_load_config_list()` (`lib/core.sh:59-76`) consumes (F10) — that reader is one-item-per-line, not scalar key=value.

**Loading mechanism (NEW seam — documented deviation).** `lib/environment.sh` today sources nothing and its header (:6-8) forbids deps (F10). So the env-file loader does NOT go in `lib/environment.sh`. Instead, add a small dedicated loader (e.g. `lib/repomix/config-file.sh`) that:
1. Runs BEFORE `_repomix_common_defaults` in the option-parse path (so file values become the `${VAR:-...}` defaults, and real process env / CLI flags still win).
2. Sets a key only when it is NOT already in the environment — preserving precedence.
3. Uses an **explicit allow-list of known REPOMIX_* / TOKEN_ESTIMATOR_CMD keys** rather than blanket source (a sourced file is code execution — validate/whitelist).

**Precedence order (highest wins):**
1. CLI flag (e.g. --style markdown, parsed in common-options.sh case block)
2. Process env (REPOMIX_STYLE=markdown ai-context ...)
3. Env-file (.restsift/repomix.env)
4. Built-in default in _repomix_common_defaults

This falls out of `${VAR:-default}`: loader sets env only if unset (real env wins), defaults use `${VAR:-...}` (env-or-file wins over hardcoded), CLI case block assigns last (flags win over all).

**repomix reads no env vars (given).** The env file is restsift surface only; its values are translated to repomix **CLI flags** at the two call sites (section A) — NOT written into a repomix.config.json. A future pass could emit a generated repomix.config.json via --config, but that is out of scope; flags are the bounded path and match the existing idiom.

**Full documented key list (defaults = current hardcoded values):**

```
# .restsift/repomix.env  (all optional; unset = built-in default)
REPOMIX_STYLE=xml                    # --style                (common-options.sh:45)
REPOMIX_COMPRESS=0                   # --compress             (:47)
REPOMIX_OUTPUT_DIR=.repomix-context  # --output dir           (:36)
REPOMIX_DEPTH=2                      # tree scope only        (:37)
REPOMIX_INCLUDE_IGNORED=0            # --no-gitignore         (:51, already env-aware)
REPOMIX_INCLUDE_REPOMIXIGNORED=0     # --no-dot-ignore ...    (:54, already env-aware)
REPOMIX_INCLUDE_LOGS=0               # --include-logs         (:48)
REPOMIX_INCLUDE_LOGS_COUNT=20        # --include-logs-count   (:49)
REPOMIX_INCLUDE_DIFFS=0              # --include-diffs        (:50)
REPOMIX_TOKEN_ENCODING=o200k_base    # --token-count-encoding (NEW, closes F4)
REPOMIX_TOKEN_BUDGET=                # --token-budget         (NEW, closes F4; unset=off)
REPOMIX_WARN_DAYS=2                  # staleness warn         (status.sh:54)
REPOMIX_MAX_DAYS=7                   # staleness hard         (status.sh:55)
REPOMIX_AUTO_REGEN=0                 # auto-regen gate        (ensure.sh:78)
TOKEN_ESTIMATOR_CMD=                 # exact-counter shim     (tokens.sh:37; see D)
```

> **Naming decision — OPEN, needs human (product call).**
> - **Recommended: reuse REPOMIX_*.** Precedent exists (REPOMIX_WARN_DAYS, REPOMIX_MAX_DAYS, REPOMIX_AUTO_REGEN, INCLUDE_IGNORED/INCLUDE_REPOMIXIGNORED — F9). Zero new convention, discoverable next to existing keys, and the toolkit is a repomix wrapper so the prefix is honest.
> - **Alternative: new AGENT_KIT_* / RESTSIFT_*.** Zero precedent today (F9). Cleaner namespace ownership if restsift later wraps non-repomix engines, but introduces a second convention.
> The dotfile path name (.restsift/repomix.env vs .repomix-context/config.env vs RESTSIFT_CONFIG) is coupled to this. Recommend REPOMIX_* keys + .restsift/repomix.env, but surface both to the human.

### C. Recommendation index doc — SEPARATE deliverable

Shipped as `recommendation.md` (this pass produces the staging copy). It guides humans AND LLMs to prefer **repomix library TokenCounter / packResult.fileTokenCounts (exact, structured)** over parsing --token-count-tree human-readable text, and over bytes/4, for any budget-gating decision. Includes the required mermaid decision flow, comparison table, the --metrics-only-does-not-exist correction, the redundant-re-tokenizer note (packResult already exposes totalTokens/fileTokenCounts), and an explicit LLM-guidance callout. Section D wires its recommended path into restsift behind a flag.

### D. Safer integration + rollout

1. **Pin/verify repomix version (none today, F5).** Add a floor check in the shared `need_bin repomix` path (guard already runs in `run_pack()` in build-pack.sh / `analysis-pack.sh:285-344`). After confirming `command -v repomix`, run `repomix --version` and compare against a declared floor (`REPOMIX_MIN_VERSION`, default = the version that first shipped --token-count-encoding/--token-budget). On failure: log_warn and either (a) proceed WITHOUT the new token flags (degrade), or (b) die if REPOMIX_TOKEN_BUDGET was explicitly set and the CLI is too old. Record the floor in package.json/share/config as documentation. Single place a version pin should live, since there is no lockfile (F5).

2. **Keep bytes/4 as offline fallback.** `estimate_tokens` (`lib/tokens.sh:34-51`) stays the default. No behavior change when node/repomix is absent — `estimate_file_tokens_fallback` (:27-32) still runs.

3. **Feature-flag the exact-counter behind the EXISTING hook (reuse callout).** Do NOT add new plumbing. `lib/tokens.sh:37` already branches on `TOKEN_ESTIMATOR_CMD`. Ship a tiny shim (e.g. `libexec/internal/repomix-token-count` or `share/shims/repomix-tokencount.mjs`) that takes a file path, calls the repomix library `new TokenCounter("o200k_base").countTokens(...)` (or runCli + packResult.fileTokenCounts), and prints a single integer — exactly the contract `estimate_tokens` expects at :40-45. Users opt in via `TOKEN_ESTIMATOR_CMD=path/to/shim` in the env file (part B). No code-path change; the hook was built for this.

   > **Reuse callout:** `TOKEN_ESTIMATOR_CMD` (:37) is dormant, pre-built, and integer-validated at :42. Using it avoids touching `within_token_budget` (:53-59) and avoids the F8 shadow entirely.

4. **Do not fuse the F8 shadow.** The shim feeds `lib/tokens.sh` only. `lib/repomix-context-tree/helpers.sh:80-83` (byte-count awk signature) is untouched. Any "unify token counting" temptation is out of scope and dangerous (two incompatible signatures).

**Rollback.** Every change is additive and env-gated:
- Unset all new REPOMIX_* keys / TOKEN_ESTIMATOR_CMD -> behavior byte-identical to HEAD ad648327.
- Revert is per-file: common-options.sh defaults, the two repomix_args appends (or the shared helper), `lib/repomix/config-file.sh` (new — delete), the shim (new — delete), the version check (guarded, log_warn-only).
- No data migration, no state, no generated artifacts touched.

**Risks.**
- **Node dependency** for exact counting — mitigated: opt-in only, bytes/4 fallback intact (D2).
- **Version drift / no lockfile** (F5) — mitigated by the --version floor check (D1); residual risk that repomix changes the TokenCounter API.
- **Isolated-engine helper shadowing (F8)** — mitigated by routing exact counting only through `lib/tokens.sh:37`, never the tree shadow.
- **Sourcing an env file is code execution** — mitigated by allow-listing keys instead of blanket source (B).
- **Two call-site drift** (F3) — mitigated by the shared-helper reuse callout (A).
- **Precedence bugs** — the `${VAR:-default}` + set-if-unset ordering must be tested (section 5).

---

## 4. Reuse-vs-new summary

| Change | Reuse or new | Basis |
|---|---|---|
| Env-overridable defaults | **Reuse** `${VAR:-default}` idiom | already at common-options.sh:51,54 |
| Token encoding/budget flags | **Reuse** conditional-append idiom | build-pack.sh:275-281 |
| Shared flag-append helper | New (dedupe) | avoids F3 two-site drift |
| Exact token counter | **Reuse** TOKEN_ESTIMATOR_CMD hook | tokens.sh:37, dormant/pre-built |
| Env-file loader | **New seam** (documented) | environment.sh forbids deps (F10) |
| repomix version floor | New guard | none exists (F5) |
| repomix token shim | New file | thin, single-integer contract |

---

## 5. Verification (exact commands — all suites exist per F12)

Run from `/home/utmostcreator/Projects/restsift`:

```
bash test/run-all.sh                          # full suite, single entrypoint (F12)
```

Targeted suites (cite in PR):

```
bash test/test-ai-context.sh                  # token-budget + option parsing + status
bash test/test-repomix-context-tree.sh        # tree flags (21 cases)
bash test/test-repomix-scc-router.sh          # scc-router pack flags (35 cases)
bash test/test-run-repomix-context.sh         # internal engine (11 cases)
bash test/test-common.sh                      # estimate_tokens call sites
bash test/test-common-source.sh
```

Existing cases that MUST stay green (baseline) and gain coverage:
- test/test-ai-context.sh: test_pack_token_budget_warns_when_exceeded:213, test_parse_common_option_token_budget_two_arg:589, test_pack_files_list_strict_tokens_dies_when_over_budget:986, test_estimate_file_tokens:1034, status REPOMIX_WARN_DAYS/MAX_DAYS cases :1195-1280.
- test/test-repomix-context-tree.sh: test_equals_form_flags:146, test_combined_flags_pack:217.
- test/test-repomix-scc-router.sh: test_pack_group_optional_repomix_flags_branch:483, test_style_markdown_changes_bundle_extension:493.

New tests to add (design intent):
- Precedence: CLI flag > env > env-file > default (assert STYLE/COMPRESS resolution).
- New flags present in repomix_args when REPOMIX_TOKEN_ENCODING/REPOMIX_TOKEN_BUDGET set, absent when unset (assert against the repomix stub the suites already use).
- Env-file loader: unknown keys ignored (allow-list), missing file is a no-op, real env overrides file.
- Version floor: too-old repomix degrades/dies per policy.
- TOKEN_ESTIMATOR_CMD shim: integer output consumed, non-integer falls back to bytes/4 (tokens.sh:42-47).

**Acceptance:** full `bash test/run-all.sh` green; with all new env keys unset, output bundles byte-identical to HEAD ad648327 (no-regression proof).

---

## 6. Open decisions (need human)

1. ~~**Naming convention: REPOMIX_* vs AGENT_KIT_*.**~~ **RESOLVED 2026-07-18 (human): `REPOMIX_*`** (precedent F9), env-file at `.restsift/repomix.env`. Concrete keys: `REPOMIX_STYLE`, `REPOMIX_COMPRESS`, `REPOMIX_OUTPUT_DIR`, `REPOMIX_DEPTH`, `REPOMIX_TOKEN_ENCODING`, `REPOMIX_TOKEN_BUDGET`.
2. **repomix version floor value** and enforcement mode (warn-and-degrade vs die-when-budget-set).
3. **Env-file auto-source vs explicit opt-in** (RESTSIFT_CONFIG pointer vs fixed .restsift/repomix.env) — allow-list vs blanket source (recommend allow-list).
4. **Config path: flags-only (recommended, matches idiom) vs generate a repomix.config.json + --config.** This pass assumes flags-only.
5. Whether the shared flag-append helper (dedupe of F3 sites) is in-scope for the first slice or a fast-follow.
