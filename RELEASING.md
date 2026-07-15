# Releasing AgentKit

Step-by-step runbook for shipping a tagged AgentKit release across GitHub, npm,
and Homebrew. This is the "how to actually do it" companion to
[RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md), which is the gate list you must
clear first. Run the checklist, then follow this runbook in order.

Current state at time of writing: `VERSION` / `package.json` are at `0.1.0`,
no `v*` tag has been pushed yet, and `Formula/agent-kit.rb` only has a `head`
(main-branch) install block — there is no stable Homebrew release yet.

## Start here

Everything on `feat/project-local-install` has been verified clean and
release-ready as of this writing:

- `./scripts/check.sh` (655 passing test cases, 0 failures, across 27 files)
  and `./scripts/check-publishable.sh` both pass with no uncommitted changes
  in the working copy, and **again from a fresh clone** of this branch into
  an isolated directory (not just the working copy — a real `git clone` +
  full run).
- `install.sh` (global mode), `install.sh --project`, and `uninstall.sh` were
  each exercised in isolated temp `HOME`/prefix/bindir directories: install
  succeeds, the wrapper runs real commands, and uninstall removes everything
  it created, leaving nothing behind.
- `scripts/package-release.sh v0.1.0`'s generated `.tar.gz` was inspected file
  by file: it ships exactly the intended runtime + docs set (`bin`, `lib`,
  `libexec`, `share`, `hooks`, `docs`, the root `*.md` files, `LICENSE`,
  `NOTICE`, `VERSION`, `install.sh`, `uninstall.sh`) with **no** dev-only
  material (`test/`, `scripts/`, `.github/`, `Formula/`, `package.json`,
  `.git*`, `RELEASE*`, `coverage*`, `.repomix-context/`) leaking in. The `.zip`
  step itself couldn't be exercised in this sandbox (no `zip` binary here),
  but it packs the same staged directory as the tar step, and CI (which does
  have `zip`) runs this same script on every tag push — see step 3.
- `scripts/package-release.sh` now also refuses to build if `package.json`'s
  `"version"` doesn't match the tag (previously only `VERSION` was checked —
  a real gap, since a silent `package.json` drift would have let step 4
  (`npm publish`) ship under the wrong version with nothing catching it).
- The GitHub repo is **already renamed** to `agent-kit`, and its
  **description, topics, and "delete branch on merge" are now set** (applied
  via `gh repo edit`, confirmed live via `gh api`). Secret scanning + push
  protection were already on. **Still open, and needs your explicit
  go-ahead**, not just a general "do release prep" instruction: private
  vulnerability reporting, and branch protection on `main` — these are
  security/governance settings, and the auto-mode permission classifier
  correctly declined to flip them on its own initiative. See step 0 below for
  the exact commands and the proposed branch-protection config.

`feat/project-local-install` is `release/v0.1.0-prep` plus several commits
ahead, with nothing in the other direction (a clean fast-forward: `git log
--oneline release/v0.1.0-prep..feat/project-local-install`). **The next
action** is:

1. Decide on private vulnerability reporting + branch protection (step 0,
   items 3-4) — say the word and it's one command each.
2. Fast-forward (or PR-merge) `release/v0.1.0-prep` — and eventually `main` —
   up to `feat/project-local-install`'s tip, so the branch actually used for
   the release carries all of this prep work. Nothing has been pushed to
   `origin` beyond `main`'s original single commit yet. Note: if branch
   protection goes on *before* this merge, a direct `git push origin main`
   will be rejected and you'll need to go through a PR instead — sequence
   accordingly.

## 0. One-time repo setup

These only need to happen once, before the first tag:

1. ~~Rename the GitHub repository to `agent-kit`~~ — **already done.**
   `gh api repos/UtmostCreator/agent-kit` resolves correctly and the old name
   (`agent-repo-tools`) redirects. The local `origin` remote is already
   updated to match (`git remote -v`).
2. ~~Set the description and topics from [GITHUB_METADATA.md](GITHUB_METADATA.md)~~
   — **already done** via `gh repo edit --description ... --add-topic ...`;
   confirmed live (`gh api repos/UtmostCreator/agent-kit --jq
   '{description,topics}'`). ~~Enable automatic deletion of merged
   branches~~ — **already done** (`delete_branch_on_merge: true`).
3. **Still open, needs your go-ahead** — enable branch protection on `main`:
   require the `required` CI check, require PRs, block force-push and
   deletion. Proposed config (chosen so the sole-maintainer workflow doesn't
   get locked out): `enforce_admins: false`, `required_approving_review_count: 0`
   (forces changes through a PR without needing a second reviewer, since
   GitHub doesn't allow self-approval), `required_conversation_resolution: true`,
   `allow_force_pushes: false`, `allow_deletions: false`. One command once you
   confirm:
   ```bash
   gh api -X PUT repos/UtmostCreator/agent-kit/branches/main/protection \
     -f 'required_status_checks[strict]=true' \
     -f 'required_status_checks[contexts][]=required' \
     -F enforce_admins=false \
     -F 'required_pull_request_reviews[required_approving_review_count]=0' \
     -F required_conversation_resolution=true \
     -F allow_force_pushes=false \
     -F allow_deletions=false \
     -F 'restrictions='
   ```
4. **Still open, needs your go-ahead** — secret scanning and push protection
   are already enabled; private vulnerability reporting is confirmed off.
   One command once you confirm:
   ```bash
   gh api -X PUT repos/UtmostCreator/agent-kit/private-vulnerability-reporting
   ```
5. Log in to the tools you'll need locally: `gh auth login` (already done in
   this environment), `npm login` (npm account must have publish rights to
   the `@utmostcreator` scope).

## 1. Pre-flight (every release)

```bash
git status                       # worktree must be clean
./scripts/check.sh                # shellcheck + full test suite
./scripts/check-publishable.sh    # secrets / hygiene / required-files gate
```

Both must pass with no uncommitted changes before you tag. Walk
[RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md)'s "Blocking checks" section too —
it covers things `check.sh` can't (credential rotation, license review, clean
install/uninstall dry runs).

## 2. Finalize the version and changelog

1. Confirm `VERSION` and the `"version"` field in `package.json` match the
   release you intend (`0.1.0` for the first release). They must match exactly
   — `scripts/package-release.sh` refuses to build if they don't.
2. In `CHANGELOG.md`, move everything under `## [Unreleased]` into a dated
   entry for this version (e.g. `## [0.1.0] - 2026-07-15`, using today's real
   tag date). Leave a fresh empty `## [Unreleased]` heading above it for the
   next cycle. The existing `[0.1.0] - 2026-07-12` entry predates any actual
   tag/publish — fold its content into the real dated entry rather than
   keeping two `0.1.0` sections.
3. Commit these as a single "Prepare vX.Y.Z release" commit.

## 3. Tag and push

```bash
git tag -s v0.1.0 -m "AgentKit v0.1.0"
git push origin main
git push origin v0.1.0
```

Pushing the tag triggers `.github/workflows/release.yml`, which:

- checks out the exact tag,
- re-runs `check-publishable.sh` and `check.sh`,
- runs `scripts/package-release.sh v0.1.0` to build
  `dist/agent-kit-0.1.0.tar.gz`, `.zip`, and `SHA256SUMS`,
- publishes a GitHub release named `AgentKit v0.1.0` with those files attached
  and auto-generated notes.

Watch it: `gh run watch` (or the Actions tab). If it fails, fix forward with a
new commit and a new patch tag — don't force-push or delete the tag once
others may have fetched it.

## 4. npm

The first publish must use an authenticated token (Trusted Publishing/OIDC can
only be enabled after a package with this name exists on npm):

```bash
npm login                          # if not already
npm publish --access public        # required: @utmostcreator/agent-kit is scoped, private by default
```

Verify:

```bash
npm view @utmostcreator/agent-kit version
npx --yes @utmostcreator/agent-kit --list   # smoke test in a scratch dir
```

## 5. Homebrew

`Formula/agent-kit.rb` currently only ships a `head` block (`brew install
--HEAD`). After the GitHub release tarball exists, add a stable block so
`brew install agent-kit` (no `--HEAD`) works from the tagged release:

```bash
url="https://github.com/UtmostCreator/agent-kit/releases/download/v0.1.0/agent-kit-0.1.0.tar.gz"
curl -fsSL "$url" -o /tmp/agent-kit-0.1.0.tar.gz
shasum -a 256 /tmp/agent-kit-0.1.0.tar.gz
```

Add to the formula (alongside the existing `head` line), then commit:

```ruby
url "https://github.com/UtmostCreator/agent-kit/releases/download/v0.1.0/agent-kit-0.1.0.tar.gz"
sha256 "<checksum from above>"
version "0.1.0"
```

Then verify locally:

```bash
brew install --build-from-source ./Formula/agent-kit.rb
brew test agent-kit
brew uninstall agent-kit
```

Once satisfied, tag consumers install with:

```bash
brew tap utmostcreator/agent-kit https://github.com/UtmostCreator/agent-kit
brew install agent-kit          # stable, from this point on
brew install --HEAD agent-kit   # still available for main-branch installs
```

## 6. curl \| bash

Nothing to publish here beyond the tag itself — `web-install.sh` resolves the
newest `v*` tag by default. Confirm it on a clean machine (or container):

```bash
curl -fsSL https://raw.githubusercontent.com/UtmostCreator/agent-kit/main/web-install.sh | bash
agent-kit --list
```

## 7. Post-release verification

Run all three install paths in isolated `HOME`s (or containers) and confirm
each produces a working `agent-kit --list` and `agent-kit search doctor`:

```bash
HOME=$(mktemp -d) bash -c 'curl -fsSL https://raw.githubusercontent.com/UtmostCreator/agent-kit/main/web-install.sh | bash && "$HOME/.local/bin/agent-kit" --list'
```

Then:

- Confirm the GitHub release notes read well and link back to `CHANGELOG.md`.
- Update README badges if command/test counts changed (`./scripts/check.sh`
  prints the current pass count).
- Announce (Discussions, wherever else is relevant).

## Patch/minor releases after this point

Repeat steps 1-3 (and 4-6 only for the channels that need republishing —
npm and the Homebrew formula both need a version bump per release; the
`curl | bash` path needs nothing beyond the new tag existing).
