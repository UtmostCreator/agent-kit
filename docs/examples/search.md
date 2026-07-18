<!-- restsift:generated:_title -->
# Repository search commands

Commands: `res s`, `res search`, `res search-introspect`, `res search-multi`, `res fd-files`, `res rg-code`
<!-- /restsift:generated:_title -->

<!-- restsift:handwritten:header -->

> Hand-written intro for this category. Edit anything between the header
> markers (add prose, links, a diagram); it survives `bash scripts/gen-examples.sh`.
<!-- /restsift:handwritten:header -->

<!-- restsift:generated:ai-s -->
### `res s`
Short repository search: default to text mode and auto-detect the search root.

```bash
res s TODO                         # every TODO in the repo, no '.' needed
res s emit_json libexec            # scope the search to a subdirectory
res s export --changed             # only the files you changed
res s RestSift --history --messages
AI_OUTPUT=json res s emit_json     # stable JSON envelope for agents
```

_Output:_

```
~/demo/src/app.php:2:function export_data(array $rows): string {
```

_Machine-readable (`AI_OUTPUT=json`):_

```json
{
  "errors": [],
  "limits": {
    "max_results": 100
  },
  "matches": [
    "~/demo/src/app.php:2:function export_data(array $rows): string {"
  ],
  "meta": {
    "returned": 1,
    "truncated": false
  },
  "mode": "text",
  "query": "export_data",
  "results": [
    {
      "column": 10,
      "language": "php",
  …
```
<!-- /restsift:generated:ai-s -->

<!-- restsift:notes:ai-s -->
<!-- Add hand-written notes for `res s` here — caveats, gotchas, or
     real-world recipes. Everything between the notes markers is kept
     verbatim when scripts/gen-examples.sh reruns. -->
<!-- /restsift:notes:ai-s -->

<!-- restsift:generated:ai-search -->
### `res search`
ai-search.sh — unified repository search entrypoint (thin facade).

```bash
res search text "TODO" .                          # find every TODO across the tree (human output)
AI_OUTPUT=json res search text "emit_json" libexec # same search as the stable JSON envelope agents consume
res search tracked "ai_search_main" .             # search only git-tracked files (git grep, not rg)
res search changed-text "export" .                # grep ONLY the files you changed in the worktree
res search diff "emit_json" . --base main         # search this branch's diff against main
res search history "RestSift" . --messages        # pickaxe commit history for a string
res search text "function" libexec --count        # per-file match counts + summary{}
res search text "emit_json" libexec -C 2          # add 2 lines of context around each match
res search files config .                         # find files whose NAME contains "config" (fd)
res search todo .                                 # list curated TODO/FIXME/HACK/XXX markers
res search doctor                                 # check which search backends are available
res search capabilities                           # full mode/flag/env capability map
res search batch text foo bar .                   # run one MODE against several queries
```

_Output:_

```
./src/app.php:2:function export_data(array $rows): string {
```

_Machine-readable (`AI_OUTPUT=json`):_

```json
{
  "errors": [],
  "limits": {
    "max_results": 100
  },
  "matches": [
    "./src/app.php:2:function export_data(array $rows): string {"
  ],
  "meta": {
    "returned": 1,
    "truncated": false
  },
  "mode": "text",
  "query": "export_data",
  "results": [
    {
      "column": 10,
      "language": "php",
  …
```
<!-- /restsift:generated:ai-search -->

<!-- restsift:notes:ai-search -->
<!-- Add hand-written notes for `res search` here — caveats, gotchas, or
     real-world recipes. Everything between the notes markers is kept
     verbatim when scripts/gen-examples.sh reruns. -->
<!-- /restsift:notes:ai-search -->

<!-- restsift:generated:ai-search-introspect -->
### `res search-introspect`
ai-search-introspect.sh — print 100% of the modes, flags, env vars, and
per-mode argument contracts that ai-search.sh and ai-search-multi.sh accept.

```bash
res search-introspect            # print the full ai-search capability map
res search-introspect --probe    # confirm every search mode is reachable
AI_OUTPUT=json res search-introspect   # capability map as a JSON envelope
```

_Output:_

```

############################################################
#  ai-search.sh / ai-search-multi.sh — FULL CAPABILITY MAP #
#  (parsed live from source: ~/restsift/libexec/ai-search)
############################################################

== INVOCATION FORMS ==
------------------------------------------------------------
AI_OUTPUT=json bash scripts/ai/ai-search.sh       MODE [QUERY] [root] [flags]
AI_OUTPUT=json bash scripts/ai/ai-search-multi.sh MODE QUERY [QUERY ...] [root] [flags]

- JSON output is activated by the AI_OUTPUT=json environment variable (no --json flag).
- Flags may appear in any position; the last non-flag positional is the root (default ".").

…
```

_Machine-readable (`AI_OUTPUT=json`):_

```json
{
  "activation": "AI_OUTPUT=json env var (or --json flag)",
  "describes": [
    "ai-search",
    "ai-search-multi"
  ],
  "env": [
    "AI_LANG",
    "AI_OUTPUT",
    "AI_SEARCH_MULTI_MAX",
    "AI_SEARCH_STRICT",
    "XDG_CONFIG_HOME"
  ],
  "envelope": {
    "always": [
      "schema",
      "status",
      "tool",
  …
```
<!-- /restsift:generated:ai-search-introspect -->

<!-- restsift:notes:ai-search-introspect -->
<!-- Add hand-written notes for `res search-introspect` here — caveats, gotchas, or
     real-world recipes. Everything between the notes markers is kept
     verbatim when scripts/gen-examples.sh reruns. -->
<!-- /restsift:notes:ai-search-introspect -->

<!-- restsift:generated:ai-search-multi -->
### `res search-multi`
Batch wrapper around ai-search.sh: run one safe search MODE against several
queries in a single approved invocation.

```bash
res search batch text foo bar .          # search two terms in one pass
res search batch files .                 # list files under root
res search batch changed-files .         # list files changed but not staged
```

_Output:_

```
./src/app.php:2:function export_data(array $rows): string {
---
./src/util.js:1:export function emitJson(value) {
```
<!-- /restsift:generated:ai-search-multi -->

<!-- restsift:notes:ai-search-multi -->
<!-- Add hand-written notes for `res search-multi` here — caveats, gotchas, or
     real-world recipes. Everything between the notes markers is kept
     verbatim when scripts/gen-examples.sh reruns. -->
<!-- /restsift:notes:ai-search-multi -->

<!-- restsift:generated:fd-files -->
### `res fd-files`
Repo-aware file discovery wrapper.
Finds files whose BASENAME contains QUERY as a literal substring (not a regex),
under an optional search root (default: the current directory), always skipping
vendor/, node_modules/, dist/, .git/, and .repomix-context/. The fd backend and
the ripgrep fallback present one identical contract. Exit code is 0 whenever the
search ran -- INCLUDING when zero files matched; a nonzero exit means bad usage
or a bad search root (e.g. it does not exist), never "no results".

```bash
res fd-files README .              # find files whose name contains "README"
res fd-files config docs --type md # find markdown files under docs/ matching "config"
```

_Output:_

```
docs/guide.md
```

_Machine-readable (`AI_OUTPUT=json`):_

```json
{
  "count": 1,
  "files": [
    "docs/guide.md"
  ],
  "query": "md",
  "root": "docs",
  "schema": "ai.fd-files/v1",
  "status": "ok",
  "tool": "fd-files"
}
```
<!-- /restsift:generated:fd-files -->

<!-- restsift:notes:fd-files -->
<!-- Add hand-written notes for `res fd-files` here — caveats, gotchas, or
     real-world recipes. Everything between the notes markers is kept
     verbatim when scripts/gen-examples.sh reruns. -->
<!-- /restsift:notes:fd-files -->

<!-- restsift:generated:rg-code -->
### `res rg-code`
Production-grade code search wrapper with repo-aware defaults.

```bash
res rg-code "TODO" .                 # find every TODO under the current directory
res rg-code "function" src --files   # list files under src/ that contain "function"
res rg-code "config" . --mode php    # search only PHP files for "config"
```

_Output:_

```
./src/app.php:2:function export_data(array $rows): string {
```
<!-- /restsift:generated:rg-code -->

<!-- restsift:notes:rg-code -->
<!-- Add hand-written notes for `res rg-code` here — caveats, gotchas, or
     real-world recipes. Everything between the notes markers is kept
     verbatim when scripts/gen-examples.sh reruns. -->
<!-- /restsift:notes:rg-code -->

<!-- restsift:handwritten:footer -->

<!-- Add hand-written sections below (guides, advanced usage, deep dives).
     Everything between the footer markers survives regeneration. -->
