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

Run focused tests during development:

```bash
bash test/test-<command>.sh
```

## Pull-request requirements

- Explain the problem and user-visible change.
- Add or update tests for behavior changes.
- List exact verification commands and results.
- Identify compatibility, security, and output-schema implications.
- Preserve unrelated worktree changes.

By contributing, you agree that your contribution is licensed under Apache-2.0.
