# Contributing

## Before opening a change

1. Search existing issues and pull requests.
2. Keep the change focused on one behavior or concern.
3. Do not include `.ai-logs`, local context packs, credentials, or generated session artifacts.

## Development

```bash
./scripts/check.sh
./scripts/check-publishable.sh
```

`check.sh` runs the test files **serially** (one at a time, in order) so a
failure points at a single file; only ShellCheck is sharded across cores for
speed. To verify correctness with fully deterministic, non-interleaved output,
serialize the lint too, or run a single suite in isolation:

```bash
CHECK_SHELLCHECK_JOBS=1 ./scripts/check.sh   # lint + tests both fully serial
bash test/test-<command>.sh                  # run exactly one suite in isolation
```

## Pull-request requirements

- Explain the problem and user-visible change.
- Add or update tests for behavior changes.
- List exact verification commands and results.
- Identify compatibility, security, and output-schema implications.
- Preserve unrelated worktree changes.

By contributing, you agree that your contribution is licensed under Apache-2.0.
