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

### `akit context`
ai-context — canonical context-building command group (thin loader).

```bash
akit context diff unstaged --dry-run             # preview a bundle for uncommitted changes
akit context pack auto --include "docs/**/*.md"  # bundle docs into one context file
akit context status .                            # check whether the generated bundle is stale
akit context estimate README.md                  # estimate the token cost of a file
```

### `akit edit`
Guarded edit wrapper for broad repository modifications (thin loader).

```bash
akit edit --help                                 # see every mode and flag, safely
akit edit sd OldName NewName . --dry-run          # preview a rename, changing nothing
akit edit apply sd OldName NewName . --dry-run    # same, with explicit "apply" prefix
akit edit rollback list                           # list rollback snapshots (routes to ai-rollback)
```

### `akit file-freshness`
Show which docs/config files have uncommitted changes (git status of key paths).

```bash
akit file-freshness   # list uncommitted changes under docs/, .github/, AGENTS.md
```

### `akit git`
ai-git — canonical git-inspection command group (thin loader).

```bash
akit git origin                          # print the branch your branch was created from
akit git history S "TODO" README.md      # find commits that added/removed "TODO"
akit git blame 1,20 README.md            # annotate who last changed lines 1-20
akit git pr-context 123 --checks         # show PR #123 metadata plus CI check status
```

### `akit inspect`
Canonical read-only inspection command group (thin router).

```bash
akit inspect file README.md --range 1:40         # show only lines 1-40 of a file
akit inspect data json package.json '.scripts'   # print the "scripts" section with jq
akit inspect shell libexec/ai-search             # see what a script accepts, safely
```

### `akit repo`
Canonical repository-metadata command group (thin router).

```bash
akit repo tasks list    # list every task this project already defines
akit repo stats         # count files Git currently tracks
akit repo tools         # see every command and what it does
akit repo status        # list uncommitted changes under docs/, .github/, AGENTS.md
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
akit search text "TODO" .                          # find every TODO across the tree (human output)
AI_OUTPUT=json akit search text "emit_json" libexec # same search as the stable JSON envelope agents consume
akit search tracked "ai_search_main" .             # search only git-tracked files (git grep, not rg)
akit search changed-text "export" .                # grep ONLY the files you changed in the worktree
akit search diff "emit_json" . --base main         # search this branch's diff against main
akit search history "AgentKit" . --messages        # pickaxe commit history for a string
akit search text "function" libexec --count        # per-file match counts + summary{}
akit search text "emit_json" libexec -C 2          # add 2 lines of context around each match
akit search files config .                         # find files whose NAME contains "config" (fd)
akit search todo .                                 # list curated TODO/FIXME/HACK/XXX markers
akit search doctor                                 # check which search backends are available
akit search capabilities                           # full mode/flag/env capability map
akit search batch text foo bar .                   # run one MODE against several queries
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
akit search batch text foo bar .          # search two terms in one pass
akit search batch files niri vicinae .    # find files matching either name
akit search batch changed-files .         # list files changed but not staged
```

### `akit session`
Canonical agent-session command group (thin router).

```bash
akit session checkpoint before-refactor        # save a labelled snapshot you can find later
akit session watch "akit verify"          # re-run verify whenever files change (Ctrl-C to stop)
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

### `akit test`
ai-test — canonical test-selection/execution command group (thin loader).

```bash
akit test select changed          # list tests for your current changes (read-only)
akit test run --filter FooTest    # run only tests matching FooTest
akit test all --help              # see options and defaults before running (safe)
```

### `akit verify`
Project-aware verification gate for AI-driven changes (thin loader).

```bash
akit verify --help                      # see accepted args before running (safe)
akit verify .                           # verify the change in the current project
akit verify docs links README.md        # check links in one doc file (read-only)
akit verify refs docs --ext md           # find orphaned markdown docs under docs/
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

### `akit fd-files`
Repo-aware file discovery wrapper.

```bash
akit fd-files README .              # find files whose name contains "README"
akit fd-files config docs --type md # find markdown files under docs/ matching "config"
```

### `akit preview-file`
preview-file.sh — safely preview a slice of a text file with guardrails
(size/byte gate, binary + .git blocking, column truncation).

```bash
akit preview-file README.md                # show the first 200 lines, safely
akit preview-file README.md --range 1:40   # show only lines 1-40 of the file
akit preview-file README.md --dry-run      # check a file is previewable (no content)
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
