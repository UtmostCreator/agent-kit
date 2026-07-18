<!-- restsift:generated:_title -->
# Code inspection and analysis

Commands: `res inspect`, `res refactor-scan`, `res structured`, `res preview-file`, `res sh-introspect`
<!-- /restsift:generated:_title -->

<!-- restsift:handwritten:header -->

> Hand-written intro for this category. Edit anything between the header
> markers (add prose, links, a diagram); it survives `bash scripts/gen-examples.sh`.
<!-- /restsift:handwritten:header -->

<!-- restsift:generated:ai-inspect -->
### `res inspect`
Canonical read-only inspection command group (thin router).

```bash
res inspect file README.md --range 1:40         # show only lines 1-40 of a file
res inspect data json package.json '.scripts'   # print the "scripts" section with jq
res inspect shell libexec/ai-search             # see what a script accepts, safely
```

_Output:_

```
# Demo project

A tiny fixture used to capture example output.

TODO: wire up the CSV exporter.
TODO: add regression tests for the parser.
```
<!-- /restsift:generated:ai-inspect -->

<!-- restsift:notes:ai-inspect -->
<!-- Add hand-written notes for `res inspect` here — caveats, gotchas, or
     real-world recipes. Everything between the notes markers is kept
     verbatim when scripts/gen-examples.sh reruns. -->
<!-- /restsift:notes:ai-inspect -->

<!-- restsift:generated:ai-refactor-scan -->
### `res refactor-scan`
Flag refactor candidates: rank files by scc complexity and functions by lizard NLOC.

```bash
res refactor-scan all .            # flag files (scc complexity > 15) and functions (lizard NLOC > 40)
res refactor-scan complexity src --ext go --scc-format json --ai
res refactor-scan comments .       # flag TODO/FIXME/... markers in real comments (string-aware)
res refactor-scan complexity --changed   # scc on git-changed files only
res refactor-scan dupes --changed  # duplication of changed files vs the whole repo
```

_Output:_

```
[refactor-scan] scanning ~/demo (complexity + nloc, parallel)
# Complexity refactor candidates (scc complexity > 15)
complexity,code,lines,language,path
# 0 file(s) flagged for refactor

# Function refactor candidates (lizard NLOC>40, params>5, CCN>15)
nloc,ccn,params,line,reasons,function,path
# 0 function(s) flagged for refactor
```
<!-- /restsift:generated:ai-refactor-scan -->

<!-- restsift:notes:ai-refactor-scan -->
<!-- Add hand-written notes for `res refactor-scan` here — caveats, gotchas, or
     real-world recipes. Everything between the notes markers is kept
     verbatim when scripts/gen-examples.sh reruns. -->
<!-- /restsift:notes:ai-refactor-scan -->

<!-- restsift:generated:ai-structured -->
### `res structured`
Structured data query wrapper for AI agents.
CSV mode auto-uses mlr or csvcut when present, else falls back to plain head.
Set AI_OUTPUT=json to make validate-json/validate-yaml emit a machine-readable
ai.ai-structured/v1 envelope on stdout (the human [OK] line stays on stderr).

```bash
res structured json package.json '.scripts'    # print the "scripts" section of package.json with jq
res structured validate-json composer.json     # check that composer.json is valid JSON
res structured csv data.csv --head 20          # preview the first 20 rows of a CSV file
```

_Output:_

```
{
  "test": "jest",
  "build": "tsc --noEmit"
}
```

_Machine-readable (`AI_OUTPUT=json`):_

```json
{
  "file": "package.json",
  "mode": "validate-json",
  "root_type": "object",
  "schema": "ai.ai-structured/v1",
  "status": "ok",
  "tool": "ai-structured",
  "valid": true
}
```
<!-- /restsift:generated:ai-structured -->

<!-- restsift:notes:ai-structured -->
<!-- Add hand-written notes for `res structured` here — caveats, gotchas, or
     real-world recipes. Everything between the notes markers is kept
     verbatim when scripts/gen-examples.sh reruns. -->
<!-- /restsift:notes:ai-structured -->

<!-- restsift:generated:preview-file -->
### `res preview-file`
preview-file.sh — safely preview a slice of a text file with guardrails
(size/byte gate, binary + .git blocking, column truncation).

```bash
res preview-file README.md                # show the first 200 lines, safely
res preview-file README.md --range 1:40   # show only lines 1-40 of the file
res preview-file README.md --dry-run      # check a file is previewable (no content)
```

_Output:_

```
# Demo project

A tiny fixture used to capture example output.

TODO: wire up the CSV exporter.
TODO: add regression tests for the parser.
```

_Machine-readable (`AI_OUTPUT=json`):_

```json
{
  "content": "# Demo project\n\nA tiny fixture used to capture example output.",
  "errors": [],
  "limits": {
    "max_bytes": 65536,
    "max_columns": 200
  },
  "meta": {
    "size_bytes": 147
  },
  "path": "README.md",
  "range": {
    "end": 3,
    "start": 1
  },
  "schema": "1",
  "status": "ok",
  "tool": "preview-file",
  …
```
<!-- /restsift:generated:preview-file -->

<!-- restsift:notes:preview-file -->
<!-- Add hand-written notes for `res preview-file` here — caveats, gotchas, or
     real-world recipes. Everything between the notes markers is kept
     verbatim when scripts/gen-examples.sh reruns. -->
<!-- /restsift:notes:preview-file -->

<!-- restsift:generated:sh-introspect -->
### `res sh-introspect`
Universal shell-script introspector (static, pure-Bash parser).

```bash
sh-introspect libexec/ai-search            # see what ai-search accepts, safely
sh-introspect --format=json libexec/ai-edit | jq .   # machine-readable contract
sh-introspect --list libexec               # a discoverable map of every command
```

_Output:_

```
ai-repo

Canonical repository-metadata command group (thin router).

Usage:
  restsift repo tasks [list|verify|test|lint|typecheck|json]  (ai-task)
  restsift repo stats                                         (repo-stats)
  restsift repo tools [--json]                                (repo-tool-inventory)
  restsift repo status                                        (ai-file-freshness)

Example:
  restsift repo tasks list    # list every task this project already defines
  restsift repo stats         # count files Git currently tracks
  restsift repo tools         # see every command and what it does
…
```

_Machine-readable (`AI_OUTPUT=json`):_

```json
{
  "description": "Canonical repository-metadata command group (thin router).",
  "env": [],
  "examples": [
    "restsift repo tasks list    # list every task this project already defines",
    "restsift repo stats         # count files Git currently tracks",
    "restsift repo tools         # see every command and what it does",
    "restsift repo status        # list uncommitted changes under docs/, .github/, AGENTS.md"
  ],
  "flags": [
    "--introspect"
  ],
  "meta": {
    "exit_codes": {
      "error": 2,
      "ok": 0
    },
    "target_executed": false
  …
```
<!-- /restsift:generated:sh-introspect -->

<!-- restsift:notes:sh-introspect -->
<!-- Add hand-written notes for `res sh-introspect` here — caveats, gotchas, or
     real-world recipes. Everything between the notes markers is kept
     verbatim when scripts/gen-examples.sh reruns. -->
<!-- /restsift:notes:sh-introspect -->

<!-- restsift:handwritten:footer -->

<!-- Add hand-written sections below (guides, advanced usage, deep dives).
     Everything between the footer markers survives regeneration. -->
