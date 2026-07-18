<!-- restsift:generated:_title -->
# Testing and verification

Commands: `res test`, `res verify`
<!-- /restsift:generated:_title -->

<!-- restsift:handwritten:header -->

> Hand-written intro for this category. Edit anything between the header
> markers (add prose, links, a diagram); it survives `bash scripts/gen-examples.sh`.
<!-- /restsift:handwritten:header -->

<!-- restsift:generated:ai-test -->
### `res test`
ai-test — canonical test-selection/execution command group (thin loader).

```bash
res test select changed          # list tests for your current changes (read-only)
res test run --filter FooTest    # run only tests matching FooTest
res test all --help              # see options and defaults before running (safe)
```

_Output:_

```
{
  "input_files": [
    "README.md"
  ],
  "candidate_tests": [],
  "recommended_commands": []
}
```
<!-- /restsift:generated:ai-test -->

<!-- restsift:notes:ai-test -->
<!-- Add hand-written notes for `res test` here — caveats, gotchas, or
     real-world recipes. Everything between the notes markers is kept
     verbatim when scripts/gen-examples.sh reruns. -->
<!-- /restsift:notes:ai-test -->

<!-- restsift:generated:ai-verify -->
### `res verify`
Project-aware verification gate for AI-driven changes (thin loader).

```bash
res verify --help                      # see accepted args before running (safe)
res verify .                           # verify the change in the current project
res verify . --json | jq .status       # parse the gate result (pass/fail) in CI
res verify docs links README.md        # check links in one doc file (read-only)
res verify refs docs --ext md           # find orphaned markdown docs under docs/
```

_Output:_

```
[WARN]  verify docs drift runs repo-wide validators and cannot filter by path; ignoring: README.md
==> docs ok
```
<!-- /restsift:generated:ai-verify -->

<!-- restsift:notes:ai-verify -->
<!-- Add hand-written notes for `res verify` here — caveats, gotchas, or
     real-world recipes. Everything between the notes markers is kept
     verbatim when scripts/gen-examples.sh reruns. -->
<!-- /restsift:notes:ai-verify -->

<!-- restsift:handwritten:footer -->

<!-- Add hand-written sections below (guides, advanced usage, deep dives).
     Everything between the footer markers survives regeneration. -->
