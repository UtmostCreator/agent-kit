<!-- agent-kit:generated:_title -->

# Context building and analysis

Commands: `ak context`

<!-- /agent-kit:generated:_title -->

<!-- agent-kit:handwritten:header -->

> Hand-written intro for this category. Edit anything between the header
> markers (add prose, links, a diagram); it survives `bash scripts/gen-examples.sh`.

<!-- /agent-kit:handwritten:header -->

<!-- agent-kit:generated:ai-context -->

### `ak context`

ai-context — canonical context-building command group (thin loader).

```bash
ak context diff unstaged --dry-run             # preview a bundle for uncommitted changes
ak context pack auto --include "docs/**/*.md"  # bundle docs into one context file
ak context status .                            # check whether the generated bundle is stale
ak context estimate README.md                  # estimate the token cost of a file
```

_Output:_

```
query_usage:
  path: README.md
  bytes: 139
  raw_estimated_tokens: 35
  multiplier_label: 1x
  multiplier: 1
  weighted_usage: 35.00
  reserved_output_tokens: 4000
```

_Machine-readable (`AI_OUTPUT=json`):_

```json
{
    "bytes": 0,
    "multiplier": 1,
    "multiplier_label": "1x",
    "path": "README.md",
    "raw_estimated_tokens": 35,
    "reserved_output_tokens": 4000,
    "schema": "ai.context-estimate/v1",
    "status": "ok",
    "tool": "context-estimate",
    "weighted_usage": 35.0
}
```

<!-- /agent-kit:generated:ai-context -->

<!-- agent-kit:notes:ai-context -->
<!-- Add hand-written notes for `ak context` here — caveats, gotchas, or
     real-world recipes. Everything between the notes markers is kept
     verbatim when scripts/gen-examples.sh reruns. -->
<!-- /agent-kit:notes:ai-context -->

<!-- agent-kit:handwritten:footer -->

## Repomix: Repository Context Packing

`ak context tree` and `ak context generate` both use **Repomix** — a repository packing engine that converts your codebase into LLM-ready XML bundles with intelligent ranking and token budgeting.

### Two Strategies

#### 1. `repomix-context-tree` (Folder-ranked by git churn)

- Groups folders, ranks by change frequency (git history)
- Packs each ranked folder into separate XML bundles
- **Best for:** Code that's actively changing; agile teams iterating on specific subsystems
- **Speed:** Faster (git-only analysis)

#### 2. `repomix-scc-router` (SCC complexity-ranked)

- Analyzes code complexity metrics via [SCC](https://github.com/boyter/scc)
- Ranks by cyclomatic complexity, NLOC (non-comment lines), function depth
- **Best for:** High-value code paths; critical, complex functions worth deep review
- **Speed:** Slower (full static analysis) but targets high-impact code

### What It Generates

After running `ak context tree all .`:

```
.repomix-context/tree-context/
├── bundles/                  # XML files, one per ranked folder (compressed)
│   ├── lib.xml              # ~50K tokens
│   ├── src.xml              # ~100K tokens
│   └── tests.xml            # ~30K tokens
├── index.md                  # Human-readable index + ranking rationale
├── index.json                # Machine-readable index
├── tree-manifest.json        # Manifest (files, token counts per bundle)
├── tree-plan.json            # Full ranking plan + scoring details
├── tree-plan.tsv             # Same plan as tab-separated table
├── run-manifest.json         # Metadata from this run (timestamp, root, bundle count)
└── scc-openmetrics-*.txt     # Code metrics analysis (split into ~200 file chunks)
```

### Default Parameters

When you run `bash scripts/ai/run-repomix-context.sh .`, these defaults apply:

| Parameter                | Default       | Purpose                                     |
| ------------------------ | ------------- | ------------------------------------------- |
| `--compress`             | **enabled**   | Gzip-compress bundles for storage           |
| `--style`                | **xml**       | Output format (xml, markdown, json, plain)  |
| `--depth`                | **2**         | Folder nesting level for ranking stats      |
| `--top`                  | **0**         | Max routes to pack; 0 = all folders         |
| `--min-code`             | **25**        | Skip folders with <25 lines of code         |
| `--min-files`            | **1**         | Skip folders with <1 file                   |
| `--context-window`       | **1,000,000** | Total token budget (1M tokens)              |
| `--reserved-output`      | **25,000**    | Tokens reserved for LLM response            |
| `--instruction-overhead` | **30,000**    | Tokens for system instructions & preamble   |
| `--safety-factor`        | **0.8**       | Use 80% of available tokens (safety margin) |

**Effective usable tokens:** 1,000,000 × 0.8 - 25,000 - 30,000 = **750,000 tokens** available for code bundles
(Note: 1M × 0.8 = 800K; 800K - 25K - 30K = 745K; rounded to 750K for safety margin)

### Bundle Size Ranges

Real-world example from a 2,058-file CMS project (54 bundles):

- **Small bundles** (configs, build files): ~400-3,000 tokens (25th percentile)
- **Medium bundles** (tools, services, utilities): ~15K-35K tokens (median to 75th percentile)
- **Large bundles** (data, resources, complex modules): ~100K-460K tokens

⚠️ **Single largest bundle can be 460K tokens (61% of your 750K budget!)**

If you need context from multiple areas of the repo, you'll hit budget limits quickly. See "Bundle Selection" guide below for strategies.

### Quick Usage

```bash
# Generate full context (tree-ranked, compressed)
ak context tree all . --top 5

# Check what was packed and their token counts
cat .repomix-context/tree-context/index.md

# Use as machine-readable plan
jq '.routes[] | {path, tokens, files}' .repomix-context/tree-context/tree-manifest.json | head -20

# Customize for smaller LLM (e.g., Claude Haiku with 200K context)
ak context tree all . \
  --context-window 200000 \
  --reserved-output 12000 \
  --instruction-overhead 18000 \
  --safety-factor 0.85
# Effective: 200K × 0.85 - 12K - 18K = ~140K tokens for code

# Pack only high-complexity folders (best for critical path review)
ak context tree all . \
  --min-complexity 20 \
  --min-code 100 \
  --top 10
# Packs top 10 folders with cyclomatic complexity >20 and >100 LOC

# Include git history in bundles
ak context tree all . \
  --include-logs \
  --include-logs-count 50
# Adds 50-commit git log to each bundle for context

# Force-pack git-ignored folders (e.g., vendor configs, generated assets)
ak context tree all . \
  --no-ignore
# Bypasses .gitignore and .repomixignore (.git and output dir always excluded)
```

### Using the Bundles

After generation, open `.repomix-context/tree-context/index.md` to see:

- All bundles with token counts
- Which files are in each bundle
- Ranking rationale (why each folder was chosen)
- Recommended usage order (pack largest bundles first to stay in budget)

**Paste bundles into Claude:**

```
<context>
<file path="bundles/lib.xml">[paste bundle content here]</file>
<file path="bundles/src.xml">[paste bundle content here]</file>
</context>

Here's my codebase. Please analyze...
```

Or use the manifest to select bundles by token budget:

```bash
# Check which bundles fit in a 100K token budget
jq '.routes[] | select(.tokens <= 100000) | .path + " (" + (.tokens | tostring) + " tokens)"' \
  .repomix-context/tree-context/tree-manifest.json
```

### Budget Tuning Examples

**For Claude Sonnet 4 (200K context):**

```bash
ak context tree all . \
  --context-window 200000 --safety-factor 0.80
# ~126K tokens for code
```

**For Claude Opus (200K context, more aggressive):**

```bash
ak context tree all . \
  --context-window 200000 --safety-factor 0.85
# ~140K tokens for code
```

**For Claude Haiku (200K context, conservative):**

```bash
ak context tree all . \
  --context-window 200000 --safety-factor 0.75
# ~110K tokens for code
```

### Key Parameters for Different Use Cases

| Use Case                      | Command                                                                           |
| ----------------------------- | --------------------------------------------------------------------------------- |
| **All code, LLM-agnostic**    | `ak context tree all . --top 5` (safe default: ~600K tokens)                      |
| **Focused on recent changes** | `ak context tree all . --changed-since main --top 5` (only recent, top 5 folders) |
| **High-complexity only**      | `ak context tree all . --min-complexity 15 --top 10` (critical paths)             |
| **Small models**              | `ak context tree all . --context-window 200000 --safety-factor 0.75`              |
| **Large models**              | `ak context tree all . --context-window 1000000 --safety-factor 0.9`              |
| **With git history**          | `ak context tree all . --include-logs --include-logs-count 100`                   |
| **Include ignored files**     | `ak context tree all . --no-ignore --min-code 10`                                 |

### Bundle Selection: Staying Within Budget

Based on real-world data (54 bundles from the 2,058-file CMS project), here's how to select bundles for different LLM models:

| LLM Model | Context Window | Usable Budget | Recommended Strategy | Total Tokens | Safety Margin |
|-----------|----------------|---------------|----------------------|--------------|---------------|
| **Haiku** | 200K           | ~110K         | Top 1 bundle (app.xml) | 46K | 58% free |
| **Sonnet 4** | 200K        | ~150K         | Top 1-2 bundles (app + graphify) | 711K | ⚠️ Tight, 5% free |
| **Opus** | 1M             | ~750K         | Top 2-3 bundles (largest: 711K) | 750K | ✓ Safe |

**Key insight:** The largest bundle (app.xml at 460K tokens) alone uses 61% of your usable budget. If you need context from multiple areas:

1. **Option A: Use --top N flag** (recommended)
   ```bash
   # Use top 5 bundles safely across all models
   ak context tree all . --top 5
   ```

2. **Option B: Filter by complexity or recency**
   ```bash
   # Only high-complexity code, fewer bundles
   ak context tree all . --min-complexity 15 --top 3
   
   # Only recently changed files
   ak context tree all . --changed-since main --top 5
   ```

3. **Option C: Check bundle sizes before selecting**
   ```bash
   # List bundles and their token counts
   jq '.routes[] | {path, tokens}' .repomix-context/tree-context/tree-manifest.json
   
   # Select bundles that fit your budget
   jq '.routes[] | select(.tokens <= 100000) | .path' .repomix-context/tree-context/tree-manifest.json
   ```
