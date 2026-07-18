<!-- restsift:generated:_title -->
# Git and repository inspection

Commands: `res file-freshness`, `res git`, `res repo`, `res repo-stats`, `res repo-tool-inventory`
<!-- /restsift:generated:_title -->

<!-- restsift:handwritten:header -->

> Hand-written intro for this category. Edit anything between the header
> markers (add prose, links, a diagram); it survives `bash scripts/gen-examples.sh`.
<!-- /restsift:handwritten:header -->

<!-- restsift:generated:ai-file-freshness -->
### `res file-freshness`
Show which docs/config files have uncommitted changes (git status of key paths).

```bash
res file-freshness             # list uncommitted changes under docs/, .github/, AGENTS.md
res file-freshness --exit-code # fail a pre-commit/CI check if agent-facing docs are dirty
res file-freshness --json | jq -r .state   # clean | stale | not-a-repo
```

_Output:_

```
# (no output)
```

_Machine-readable (`AI_OUTPUT=json`):_

```json
{
  "count": 0,
  "entries": [],
  "paths": [
    "docs",
    ".github",
    ".opencode",
    "AGENTS.md"
  ],
  "schema": "ai.file-freshness/v1",
  "state": "clean",
  "status": "ok",
  "tool": "file-freshness"
}
```
<!-- /restsift:generated:ai-file-freshness -->

<!-- restsift:notes:ai-file-freshness -->
<!-- Add hand-written notes for `res file-freshness` here — caveats, gotchas, or
     real-world recipes. Everything between the notes markers is kept
     verbatim when scripts/gen-examples.sh reruns. -->
<!-- /restsift:notes:ai-file-freshness -->

<!-- restsift:generated:ai-git -->
### `res git`
ai-git — canonical git-inspection command group (thin loader).

```bash
res git origin                          # print the branch your branch was created from
res git history S "TODO" README.md      # find commits that added/removed "TODO"
res git blame 1,20 README.md            # annotate who last changed lines 1-20
res git pr-context 123 --checks         # show PR #123 metadata plus CI check status
res git files --staged --name-only      # list staged paths, one per line
res git conflicts --fail-on-findings     # scan for <<<<<<< / ======= / >>>>>>> markers
```

_Output:_

```
commit <hash>
Author: demo <demo@example.com>
Date:   <date>

    init demo fixture

diff --git a/README.md b/README.md
new file mode 100644
index 0000000..c90c874
--- /dev/null
+++ b/README.md
@@ -0,0 +1,6 @@
+# Demo project
+
…
```
<!-- /restsift:generated:ai-git -->

<!-- restsift:notes:ai-git -->
<!-- Add hand-written notes for `res git` here — caveats, gotchas, or
     real-world recipes. Everything between the notes markers is kept
     verbatim when scripts/gen-examples.sh reruns. -->
<!-- /restsift:notes:ai-git -->

<!-- restsift:generated:ai-repo -->
### `res repo`
Canonical repository-metadata command group (thin router).

```bash
res repo tasks list    # list every task this project already defines
res repo stats         # count files Git currently tracks
res repo tools         # see every command and what it does
res repo status        # list uncommitted changes under docs/, .github/, AGENTS.md
```

_Output:_

```
6
```

_Machine-readable (`AI_OUTPUT=json`):_

```json
{
  "schema": "ai.repo-stats/v1",
  "status": "ok",
  "tool": "repo-stats",
  "tracked_files": 6
}
```
<!-- /restsift:generated:ai-repo -->

<!-- restsift:notes:ai-repo -->
<!-- Add hand-written notes for `res repo` here — caveats, gotchas, or
     real-world recipes. Everything between the notes markers is kept
     verbatim when scripts/gen-examples.sh reruns. -->
<!-- /restsift:notes:ai-repo -->

<!-- restsift:generated:repo-stats -->
### `res repo-stats`
Count the files Git currently tracks in this repository.

```bash
res repo-stats            # print how many files Git currently tracks
res repo-stats --json     # same count, machine-readable envelope
```

_Output:_

```
6
```

_Machine-readable (`AI_OUTPUT=json`):_

```json
{
  "schema": "ai.repo-stats/v1",
  "status": "ok",
  "tool": "repo-stats",
  "tracked_files": 6
}
```
<!-- /restsift:generated:repo-stats -->

<!-- restsift:notes:repo-stats -->
<!-- Add hand-written notes for `res repo-stats` here — caveats, gotchas, or
     real-world recipes. Everything between the notes markers is kept
     verbatim when scripts/gen-examples.sh reruns. -->
<!-- /restsift:notes:repo-stats -->

<!-- restsift:generated:repo-tool-inventory -->
### `res repo-tool-inventory`
List every toolkit command with its one-line summary (a discoverable map).
Exits 0 on success and 2 on a usage error (unknown flag or unexpected argument).

```bash
res repo-tool-inventory                 # see every command and what it does
res repo-tool-inventory --json | jq .   # feed the catalog to an agent
```

_Output:_

```
  ai-completion            Print a generated shell-completion definition for restsift (and its short
  ai-context               ai-context — canonical context-building command group (thin loader).
  ai-doctor                Report restsift installation and environment health for bug triage.
  ai-edit                  Guarded edit wrapper for broad repository modifications (thin loader).
  ai-file-freshness        Show which docs/config files have uncommitted changes (git status of key paths).
  ai-git                   ai-git — canonical git-inspection command group (thin loader).
  ai-inspect               Canonical read-only inspection command group (thin router).
  ai-refactor-scan         Flag refactor candidates: rank files by scc complexity and functions by lizard NLOC.
  ai-repo                  Canonical repository-metadata command group (thin router).
  ai-rollback              Review and apply repository-local rollback snapshots created by AI tooling sessions.
  ai-s                     Short repository search: default to text mode and auto-detect the search root.
  ai-search                ai-search.sh — unified repository search entrypoint (thin facade).
  ai-search-introspect     ai-search-introspect.sh — print 100% of the modes, flags, env vars, and
  ai-search-multi          Batch wrapper around ai-search.sh: run one safe search MODE against several
…
```

_Machine-readable (`AI_OUTPUT=json`):_

```json
{
  "commands": [
    {
      "name": "ai-completion",
      "summary": "Print a generated shell-completion definition for restsift (and its short"
    },
    {
      "name": "ai-context",
      "summary": "ai-context — canonical context-building command group (thin loader)."
    },
    {
      "name": "ai-doctor",
      "summary": "Report restsift installation and environment health for bug triage."
    },
    {
      "name": "ai-edit",
      "summary": "Guarded edit wrapper for broad repository modifications (thin loader)."
    },
  …
```
<!-- /restsift:generated:repo-tool-inventory -->

<!-- restsift:notes:repo-tool-inventory -->
<!-- Add hand-written notes for `res repo-tool-inventory` here — caveats, gotchas, or
     real-world recipes. Everything between the notes markers is kept
     verbatim when scripts/gen-examples.sh reruns. -->
<!-- /restsift:notes:repo-tool-inventory -->

<!-- restsift:handwritten:footer -->

<!-- Add hand-written sections below (guides, advanced usage, deep dives).
     Everything between the footer markers survives regeneration. -->
