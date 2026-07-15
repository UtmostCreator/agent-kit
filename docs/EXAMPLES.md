# Examples

One runnable example per command, generated from each command's own `# Example:`
block.

These snippets use the short **`ak`** alias, which every installer creates
alongside the canonical `agent-kit`. They work verbatim after any install — no
setup needed. For the everyday search case, `ak s QUERY` is even shorter: it
defaults to text mode and auto-detects the repo root, so `ak s TODO` replaces
`ak search text TODO .`.

The canonical command is `agent-kit` — the two are interchangeable, so replace
`ak` with `agent-kit` anywhere you prefer the long form (e.g. in scripts). The
authoritative contract for any command is always `agent-kit <command> --help`
(and `--introspect` for JSON).

> Regenerate this file with: `bash scripts/gen-examples.sh > docs/EXAMPLES.md`

### `ak completion`
Print a generated shell-completion definition for agent-kit (and its short
alias `ak`) to stdout. Non-mutating: it only prints a file, it never touches
shell configuration or installs anything.

```bash
source <(ak completion bash)                                    # this session only
ak completion fish > ~/.config/fish/completions/agent-kit.fish  # persistent, fish
echo 'source <(ak completion zsh)' >> ~/.zshrc                  # persistent, zsh
```

### `ak context`
ai-context — canonical context-building command group (thin loader).

```bash
ak context diff unstaged --dry-run             # preview a bundle for uncommitted changes
ak context pack auto --include "docs/**/*.md"  # bundle docs into one context file
ak context status .                            # check whether the generated bundle is stale
ak context estimate README.md                  # estimate the token cost of a file
```

### `ak doctor`
Report agent-kit installation and environment health for bug triage.

```bash
ak doctor            # a quick "is my install healthy?" check
ak doctor --json | jq .status   # paste into a bug report as evidence
```

### `ak edit`
Guarded edit wrapper for broad repository modifications (thin loader).

```bash
ak edit --help                                 # see every mode and flag, safely
ak edit sd OldName NewName . --dry-run          # preview a rename, changing nothing
ak edit apply sd OldName NewName . --dry-run    # same, with explicit "apply" prefix
ak edit rollback list                           # list rollback snapshots (routes to ai-rollback)
```

### `ak file-freshness`
Show which docs/config files have uncommitted changes (git status of key paths).

```bash
ak file-freshness   # list uncommitted changes under docs/, .github/, AGENTS.md
```

### `ak git`
ai-git — canonical git-inspection command group (thin loader).

```bash
ak git origin                          # print the branch your branch was created from
ak git history S "TODO" README.md      # find commits that added/removed "TODO"
ak git blame 1,20 README.md            # annotate who last changed lines 1-20
ak git pr-context 123 --checks         # show PR #123 metadata plus CI check status
```

### `ak inspect`
Canonical read-only inspection command group (thin router).

```bash
ak inspect file README.md --range 1:40         # show only lines 1-40 of a file
ak inspect data json package.json '.scripts'   # print the "scripts" section with jq
ak inspect shell libexec/ai-search             # see what a script accepts, safely
```

### `ak refactor-scan`
Flag refactor candidates: rank files by scc complexity and functions by lizard NLOC.

```bash
ak refactor-scan all .            # flag files (scc complexity > 15) and functions (lizard NLOC > 40)
ak refactor-scan complexity src --ext go --scc-format json --ai
```

### `ak repo`
Canonical repository-metadata command group (thin router).

```bash
ak repo tasks list    # list every task this project already defines
ak repo stats         # count files Git currently tracks
ak repo tools         # see every command and what it does
ak repo status        # list uncommitted changes under docs/, .github/, AGENTS.md
```

### `ak rollback`
Review and apply repository-local rollback snapshots created by AI tooling sessions.

```bash
ak rollback list                       # list restore points (read-only, safe)
ak rollback show SNAPSHOT_ID           # preview one snapshot's files (id from `list`)
```

### `ak s`
Short repository search: default to text mode and auto-detect the search root.

```bash
ak s TODO                         # every TODO in the repo, no '.' needed
ak s emit_json libexec            # scope the search to a subdirectory
ak s export --changed             # only the files you changed
ak s AgentKit --history --messages
AI_OUTPUT=json ak s emit_json     # stable JSON envelope for agents
```

### `ak search`
ai-search.sh — unified repository search entrypoint (thin facade).

```bash
ak search text "TODO" .                          # find every TODO across the tree (human output)
AI_OUTPUT=json ak search text "emit_json" libexec # same search as the stable JSON envelope agents consume
ak search tracked "ai_search_main" .             # search only git-tracked files (git grep, not rg)
ak search changed-text "export" .                # grep ONLY the files you changed in the worktree
ak search diff "emit_json" . --base main         # search this branch's diff against main
ak search history "AgentKit" . --messages        # pickaxe commit history for a string
ak search text "function" libexec --count        # per-file match counts + summary{}
ak search text "emit_json" libexec -C 2          # add 2 lines of context around each match
ak search files config .                         # find files whose NAME contains "config" (fd)
ak search todo .                                 # list curated TODO/FIXME/HACK/XXX markers
ak search doctor                                 # check which search backends are available
ak search capabilities                           # full mode/flag/env capability map
ak search batch text foo bar .                   # run one MODE against several queries
```

### `ak search-introspect`
ai-search-introspect.sh — print 100% of the modes, flags, env vars, and
per-mode argument contracts that ai-search.sh and ai-search-multi.sh accept.

```bash
ak search-introspect            # print the full ai-search capability map
ak search-introspect --probe    # confirm every search mode is reachable
```

### `ak search-multi`
Batch wrapper around ai-search.sh: run one safe search MODE against several
queries in a single approved invocation.

```bash
ak search batch text foo bar .          # search two terms in one pass
ak search batch files niri vicinae .    # find files matching either name
ak search batch changed-files .         # list files changed but not staged
```

### `ak session`
Canonical agent-session command group (thin router).

```bash
ak session checkpoint before-refactor        # save a labelled snapshot you can find later
ak session watch "ak verify"          # re-run verify whenever files change (Ctrl-C to stop)
```

### `ak structured`
Structured data query wrapper for AI agents.

```bash
ak structured json package.json '.scripts'    # print the "scripts" section of package.json with jq
ak structured validate-json composer.json     # check that composer.json is valid JSON
ak structured csv data.csv --head 20          # preview the first 20 rows of a CSV file
```

### `ak task`
Project task discovery wrapper for AI agents.

```bash
ak task list             # list every task this project already defines
ak task test             # print the command to run this repo's tests
ak task verify           # print the recommended "verify" command to run
```

### `ak test`
ai-test — canonical test-selection/execution command group (thin loader).

```bash
ak test select changed          # list tests for your current changes (read-only)
ak test run --filter FooTest    # run only tests matching FooTest
ak test all --help              # see options and defaults before running (safe)
```

### `ak verify`
Project-aware verification gate for AI-driven changes (thin loader).

```bash
ak verify --help                      # see accepted args before running (safe)
ak verify .                           # verify the change in the current project
ak verify docs links README.md        # check links in one doc file (read-only)
ak verify refs docs --ext md           # find orphaned markdown docs under docs/
```

### `ak all-f-into-one`
all-f-into-one.sh (formerly all_in_one.sh / combine_files.sh)
Recursively collects filenames and contents, writes them to a single output file at project root.
Prunes ignored directories (entire subtrees) and excludes selected files.
Each file block (header + content + footer) is wrapped inside triple backticks.

```bash
ak all-f-into-one --help        # see what this does without combining anything
ak all-f-into-one --introspect  # print the machine-readable JSON contract
```

### `ak fd-files`
Repo-aware file discovery wrapper.

```bash
ak fd-files README .              # find files whose name contains "README"
ak fd-files config docs --type md # find markdown files under docs/ matching "config"
```

### `ak preview-file`
preview-file.sh — safely preview a slice of a text file with guardrails
(size/byte gate, binary + .git blocking, column truncation).

```bash
ak preview-file README.md                # show the first 200 lines, safely
ak preview-file README.md --range 1:40   # show only lines 1-40 of the file
ak preview-file README.md --dry-run      # check a file is previewable (no content)
```

### `ak repo-stats`
Count the files Git currently tracks in this repository.

```bash
ak repo-stats   # print how many files Git currently tracks in this repository
```

### `ak repo-tool-inventory`
List every toolkit command with its one-line summary (a discoverable map).

```bash
ak repo-tool-inventory                 # see every command and what it does
ak repo-tool-inventory --json | jq .   # feed the catalog to an agent
```

### `ak rg-code`
Production-grade code search wrapper with repo-aware defaults.

```bash
ak rg-code "TODO" .                 # find every TODO under the current directory
ak rg-code "function" src --files   # list files under src/ that contain "function"
ak rg-code "config" . --mode php    # search only PHP files for "config"
```

### `ak session-checkpoint`
Create a repository-local checkpoint using the shared snapshot system.

```bash
ak session-checkpoint                 # save a snapshot into .ai-logs/snapshots/
ak session-checkpoint before-refactor # save a labelled snapshot you can find later
```

### `ak sh-introspect`
Universal shell-script introspector (static, pure-Bash parser).

```bash
sh-introspect libexec/ai-search            # see what ai-search accepts, safely
sh-introspect --format=json libexec/ai-edit | jq .   # machine-readable contract
sh-introspect --list libexec               # a discoverable map of every command
```

### `ak watch-loop`
Re-run a command automatically whenever watched files change (blocks until Ctrl-C).

```bash
ak watch-loop "ak verify"          # re-run verify whenever files change (Ctrl-C to stop)
ak watch-loop "ak task test" sh,md # re-run tests only when .sh or .md files change
```
