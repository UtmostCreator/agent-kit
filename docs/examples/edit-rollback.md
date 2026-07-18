<!-- restsift:generated:_title -->
# Guarded edits and rollback

Commands: `res edit`, `res rollback`, `res session-checkpoint`
<!-- /restsift:generated:_title -->

<!-- restsift:handwritten:header -->

> Hand-written intro for this category. Edit anything between the header
> markers (add prose, links, a diagram); it survives `bash scripts/gen-examples.sh`.
<!-- /restsift:handwritten:header -->

<!-- restsift:generated:ai-edit -->
### `res edit`
Guarded edit wrapper for broad repository modifications (thin loader).

```bash
res edit --help                                 # see every mode and flag, safely
res edit sd OldName NewName . --dry-run          # preview a rename, changing nothing
res edit apply sd OldName NewName . --dry-run    # same, with explicit "apply" prefix
res edit rollback list                           # list rollback snapshots (routes to ai-rollback)
```

_Output:_

```

Dry-run only. Re-run with --apply or APPLY=1 to modify files.
```
<!-- /restsift:generated:ai-edit -->

<!-- restsift:notes:ai-edit -->
<!-- Add hand-written notes for `res edit` here — caveats, gotchas, or
     real-world recipes. Everything between the notes markers is kept
     verbatim when scripts/gen-examples.sh reruns. -->
<!-- /restsift:notes:ai-edit -->

<!-- restsift:generated:ai-rollback -->
### `res rollback`
Review and apply repository-local rollback snapshots created by AI tooling sessions.

```bash
res rollback list                       # list restore points (read-only, safe)
res rollback show SNAPSHOT_ID           # preview one snapshot's files (id from `list`)
res rollback list --json                # machine-readable envelope for agents
res rollback show 1                      # select by the "index" field from `list --json`
AI_OUTPUT=json res rollback show 1      # env form of the JSON envelope
```

_Output:_

```
SNAPSHOT                                                      TYPE          SIZE        DATE
====================================================================================================

0 snapshot artifact(s) found
```

_Machine-readable (`AI_OUTPUT=json`):_

```json
{
  "count": 0,
  "mode": "list",
  "schema": "ai.rollback/v1",
  "snapshot_dir": ".ai-logs/snapshots",
  "snapshots": [],
  "status": "ok",
  "tool": "ai-rollback"
}
```
<!-- /restsift:generated:ai-rollback -->

<!-- restsift:notes:ai-rollback -->
<!-- Add hand-written notes for `res rollback` here — caveats, gotchas, or
     real-world recipes. Everything between the notes markers is kept
     verbatim when scripts/gen-examples.sh reruns. -->
<!-- /restsift:notes:ai-rollback -->

<!-- restsift:generated:session-checkpoint -->
### `res session-checkpoint`
Create a repository-local checkpoint using the shared snapshot system.
Exit codes: 0 = checkpoint created; 1 = not a git repository, the repository
  has no commits yet, or the snapshot manifest could not be written.

```bash
res session-checkpoint                 # save a snapshot into .ai-logs/snapshots/
res session-checkpoint before-refactor # save a labelled snapshot you can find later
AI_OUTPUT=json res session-checkpoint  # machine-readable envelope for agents
```

_Output:_

```
checkpoint created: .ai-logs/snapshots/session-checkpoint-<stamp>-demo-label-<t>.manifest.json
restore with: restsift ai-rollback apply .ai-logs/snapshots/session-checkpoint-<stamp>-demo-label-<t>.manifest.json
```

_Machine-readable (`AI_OUTPUT=json`):_

```json
{
  "base_ref": "<hash>",
  "has_untracked_archive": true,
  "label": "demo",
  "manifest": ".ai-logs/snapshots/session-checkpoint-<stamp>-demo-<t>.manifest.json",
  "restore_command": "restsift ai-rollback apply .ai-logs/snapshots/session-checkpoint-<stamp>-demo-<t>.manifest.json",
  "schema": "ai.session-checkpoint/v1",
  "status": "ok",
  "tool": "session-checkpoint",
  "warnings": []
}
```
<!-- /restsift:generated:session-checkpoint -->

<!-- restsift:notes:session-checkpoint -->
<!-- Add hand-written notes for `res session-checkpoint` here — caveats, gotchas, or
     real-world recipes. Everything between the notes markers is kept
     verbatim when scripts/gen-examples.sh reruns. -->
<!-- /restsift:notes:session-checkpoint -->

<!-- restsift:handwritten:footer -->

<!-- Add hand-written sections below (guides, advanced usage, deep dives).
     Everything between the footer markers survives regeneration. -->
