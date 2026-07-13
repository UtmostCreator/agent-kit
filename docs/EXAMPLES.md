# Examples

One runnable example per command, generated from each command's own `# Example:`
block.

These snippets use the short **`akit`** alias. Enable it once (add to your shell
rc), then every example below works verbatim:

```bash
alias akit='agent-kit'
```

The canonical command is `agent-kit` — if you have not set the alias, replace
`akit` with `agent-kit`. The authoritative contract for any command is always
`agent-kit <command> --help` (and `--introspect` for JSON).

> Regenerate this file with: `bash scripts/gen-examples.sh > docs/EXAMPLES.md`

### `akit diff-context`
Pack changed or targeted files into AI context bundles.
(thin loader — implementation under scripts/ai/internal/ai-diff-context/)

```bash
akit diff-context unstaged --dry-run       # preview which changed files would be packed
akit diff-context since HEAD~1 --dry-run   # preview a bundle for the last commit's changes
```

### `akit doc-check`
Verify documentation quality (lint, links, drift) for AI agents.

```bash
akit doc-check --help             # see modes and env before running (safe)
akit doc-check links README.md    # check links in one file (read-only)
```

### `akit edit`
Guarded edit wrapper for broad repository modifications (thin loader).

```bash
akit edit --help                            # see every mode and flag, safely
akit edit sd OldName NewName . --dry-run     # preview a rename, changing nothing
```

### `akit file-freshness`
Show which docs/config files have uncommitted changes (git status of key paths).

```bash
akit file-freshness   # list uncommitted changes under docs/, .github/, AGENTS.md
```

### `akit rollback`
Review and apply repository-local rollback snapshots created by AI tooling sessions.

```bash
akit rollback list                       # list restore points (read-only, safe)
akit rollback show SNAPSHOT_ID           # preview one snapshot's files (id from `list`)
```

### `akit search`
ai-search.sh — unified repository search entrypoint (thin facade).

```bash
akit search text "TODO" .        # find every TODO across the tree
akit search todo .               # list curated TODO/FIXME/HACK/XXX markers
akit search files config .       # find files whose name contains "config"
akit search-introspect           # full mode/flag/env capability map
akit search doctor               # check which search backends are available
```

### `akit search-introspect`
ai-search-introspect.sh — print 100% of the modes, flags, env vars, and
per-mode argument contracts that ai-search.sh and ai-search-multi.sh accept.

```bash
akit search-introspect            # print the full ai-search capability map
akit search-introspect --probe    # confirm every search mode is reachable
```

### `akit search-multi`
Batch wrapper around ai-search.sh: run one safe search MODE against several
queries in a single approved invocation.

```bash
akit search-multi text foo bar .          # search two terms in one pass
akit search-multi files niri vicinae .    # find files matching either name
akit search-multi changed-files .         # list files changed but not staged
```

### `akit structured`
Structured data query wrapper for AI agents.

```bash
akit structured json package.json '.scripts'    # print the "scripts" section of package.json with jq
akit structured validate-json composer.json     # check that composer.json is valid JSON
akit structured csv data.csv --head 20          # preview the first 20 rows of a CSV file
```

### `akit task`
Project task discovery wrapper for AI agents.

```bash
akit task list             # list every task this project already defines
akit task test             # print the command to run this repo's tests
akit task verify           # print the recommended "verify" command to run
```

### `akit test-select`
Select focused tests for AI-driven changes (lists tests; never runs them).

```bash
akit test-select changed          # list tests for your current changes (read-only)
akit test-select json | jq .      # feed the selection to another tool
```

### `akit verify`
Project-aware verification gate for AI-driven changes (thin loader).

```bash
akit verify --help                      # see accepted args before running (safe)
akit verify .                           # verify the change in the current project
```

### `akit verify-html`
Verify only the HTML files in a change (thin wrapper over `agent-kit verify`).

```bash
akit verify-html --help              # see what the HTML verify wrapper does, safely
akit verify-html .                   # verify the HTML files in the current project
```

### `akit verify-js`
Verify only the JavaScript files in a change (thin wrapper over `agent-kit verify`).

```bash
akit verify-js --help                # see what the JS verify wrapper does, safely
akit verify-js .                     # verify the JavaScript files in the current project
```

### `akit verify-php`
Verify only the PHP files in a change (thin wrapper over `agent-kit verify`).

```bash
akit verify-php --help               # see what the PHP verify wrapper does, safely
akit verify-php .                    # verify the PHP files in the current project
```

### `akit verify-ts`
Verify only the TypeScript files in a change (thin wrapper over `agent-kit verify`).

```bash
akit verify-ts --help                # see what the TS verify wrapper does, safely
akit verify-ts .                     # verify the TypeScript files in the current project
```

### `akit verify-vue`
Verify only the Vue files in a change (thin wrapper over `agent-kit verify`).

```bash
akit verify-vue --help               # see what the Vue verify wrapper does, safely
akit verify-vue .                    # verify the Vue files in the current project
```

### `akit all-f-into-one`
all-f-into-one.sh (formerly all_in_one.sh / combine_files.sh)
Recursively collects filenames and contents, writes them to a single output file at project root.
Prunes ignored directories (entire subtrees) and excludes selected files.
Each file block (header + content + footer) is wrapped inside triple backticks.

```bash
akit all-f-into-one --help        # see what this does without combining anything
akit all-f-into-one --introspect  # print the machine-readable JSON contract
```

### `akit check-file-refs`
Find tracked files that are not referenced anywhere else in the repository.
Read-only: surfaces orphaned docs and unused assets. No mutation.

```bash
akit check-file-refs .              # list tracked files nothing else references
akit check-file-refs docs --ext md  # find orphaned markdown docs under docs/
```

### `akit fd-files`
Repo-aware file discovery wrapper.

```bash
akit fd-files README .              # find files whose name contains "README"
akit fd-files config docs --type md # find markdown files under docs/ matching "config"
```

### `akit gh-pr-context`
Full PR context wrapper for review and context packing.

```bash
akit gh-pr-context 123                  # show PR #123 metadata, files, and description
akit gh-pr-context 123 --checks --reviews  # add CI check status and review summaries
akit gh-pr-context 123 --json           # emit the full PR context as JSON for tools
```

### `akit git-branch-origin`
Detect the branch the current branch was most likely created from ("branched off").

```bash
akit git-branch-origin                # print the branch your branch was created from
akit git-branch-origin --field all    # show name, merge-base sha, and commit distance
akit git-branch-origin --json         # same detection as a JSON envelope for tools
```

### `akit git-forensics`
Repo-aware git history and blame wrapper.

```bash
akit git-forensics S "TODO" README.md       # find commits that added/removed "TODO" in README.md
akit git-forensics G "function foo" README.md  # search history by regex in one file
akit git-forensics blame 1,20 README.md      # annotate who last changed lines 1-20
```

### `akit pack-context`
Safe context packer wrapper.

```bash
akit pack-context auto --include "docs/**/*.md"   # bundle the docs into one AI context file
```

### `akit preview-file`
preview-file.sh — safely preview a slice of a text file with guardrails
(size/byte gate, binary + .git blocking, column truncation).

```bash
akit preview-file README.md                # show the first 200 lines, safely
akit preview-file README.md --range 1:40   # show only lines 1-40 of the file
akit preview-file README.md --dry-run      # check a file is previewable (no content)
```

### `akit query-usage`
Estimate the context/token cost of a file or directory (read-only budgeting).

```bash
akit query-usage libexec            # estimate the token cost of the libexec/ directory
akit query-usage README.md          # estimate the token cost of a single file
akit query-usage . --multiplier 2   # weight the whole-repo estimate by 2x
```

### `akit repomix-context-tree`
Plan and pack a repository into ranked Repomix context bundles, grouped by folder tree.

```bash
akit repomix-context-tree analyze .   # analyze the repo and write a bundle plan without packing anything
akit repomix-context-tree all .       # analyze, then pack every route the plan marks for packing
```

### `akit repomix-ensure-fresh`
Ensure the Repomix context bundle is fresh before an agent relies on it.

```bash
akit repomix-ensure-fresh .           # check bundle freshness and only report (never regenerates)
akit repomix-ensure-fresh . --regen   # check, and regenerate the bundle if it is stale, expired, or missing
```

### `akit repomix-freshness`
Check freshness of the generated Repomix context bundle.

```bash
akit repomix-freshness .                  # report how old the generated context bundle is
AI_OUTPUT=json akit repomix-freshness .   # same freshness check as machine-readable JSON
```

### `akit repomix-scc-router`
Rank a repository's folders by scc code metrics and pack them into Repomix bundles.

```bash
akit repomix-scc-router stats .   # run scc analysis and write per-file and per-folder code metrics
akit repomix-scc-router all .     # run stats, build a ranked bundle plan, then pack the bundles
```

### `akit repo-stats`
Count the files Git currently tracks in this repository.

```bash
akit repo-stats   # print how many files Git currently tracks in this repository
```

### `akit repo-tool-inventory`
List every toolkit command with its one-line summary (a discoverable map).

```bash
akit repo-tool-inventory                 # see every command and what it does
akit repo-tool-inventory --json | jq .   # feed the catalog to an agent
```

### `akit rg-code`
Production-grade code search wrapper with repo-aware defaults.

```bash
akit rg-code "TODO" .                 # find every TODO under the current directory
akit rg-code "function" src --files   # list files under src/ that contain "function"
akit rg-code "config" . --mode php    # search only PHP files for "config"
```

### `akit run-repomix-context`
Generate repository context tree through the safer shared wrapper path.

```bash
akit run-repomix-context .                     # pack the whole current repo into an LLM-ready context bundle
akit run-repomix-context . --depth 2 --top 0   # same, but tune folder depth and pack all ranked routes
```

### `akit run-repomix-file`
Exact single-file Repomix wrapper.

```bash
akit run-repomix-file . README.md                              # pack a single file into a compressed context bundle
akit run-repomix-file . src/app.js --style json --no-compress  # pack one file as uncompressed JSON output
```

### `akit run-repo-tests`
Run the repository's existing test suites with parallel-first defaults.

```bash
akit run-repo-tests --help           # see options and defaults before running (safe)
PARATEST_PROCS=8 akit run-repo-tests # run the full suite with 8 parallel workers
```

### `akit run-test-focused`
Run a FOCUSED PHPUnit selection (a --filter pattern or a single test file).

```bash
akit run-test-focused --help                 # see accepted forms before running (safe)
akit run-test-focused --filter MyThingTest   # run only tests matching MyThingTest
```

### `akit session-checkpoint`
Create a repository-local checkpoint using the shared snapshot system.

```bash
akit session-checkpoint                 # save a snapshot into .ai-logs/snapshots/
akit session-checkpoint before-refactor # save a labelled snapshot you can find later
```

### `akit sh-introspect`
Universal shell-script introspector (static, pure-Bash parser).

```bash
sh-introspect libexec/ai-search            # see what ai-search accepts, safely
sh-introspect --format=json libexec/ai-edit | jq .   # machine-readable contract
sh-introspect --list libexec               # a discoverable map of every command
```

### `akit watch-loop`
Re-run a command automatically whenever watched files change (blocks until Ctrl-C).

```bash
akit watch-loop "akit verify"          # re-run verify whenever files change (Ctrl-C to stop)
akit watch-loop "akit task test" sh,md # re-run tests only when .sh or .md files change
```
