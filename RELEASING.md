# Releasing AgentKit

Step-by-step runbook for shipping a tagged AgentKit release across GitHub, npm,
and Homebrew. This is the "how to actually do it" companion to
[RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md), which is the gate list you must
clear first. Run the checklist, then follow this runbook in order.

Current state at time of writing: `VERSION` / `package.json` are at `0.1.0`,
no `v*` tag has been pushed yet, and `Formula/agent-kit.rb` only has a `head`
(main-branch) install block — there is no stable Homebrew release yet.

## 0. One-time repo setup

These only need to happen once, before the first tag:

1. **Rename the GitHub repository to `agent-kit`** (Settings → General →
   Repository name). Every doc, badge, install script, and the Homebrew
   formula already reference `github.com/UtmostCreator/agent-kit`; GitHub
   auto-redirects the old name (`agent-repo-tools`) for git clones and HTTP,
   but update anything hardcoded outside GitHub (CI secrets, bookmarks) by
   hand.
2. Update your local remote to match:
   ```bash
   git remote set-url origin git@github.com:UtmostCreator/agent-kit.git
   ```
3. Apply the description and topics from [GITHUB_METADATA.md](GITHUB_METADATA.md)
   (Settings → General, and the gear icon next to "About").
4. Enable branch protection on `main`: require the `required` CI check,
   require PRs with resolved conversations, block force-push and deletion,
   enable auto-delete of merged branches (see RELEASE_CHECKLIST.md).
5. Enable secret scanning and private vulnerability reporting (Settings →
   Security).
6. Log in to the tools you'll need locally: `gh auth login`, `npm login` (npm
   account must have publish rights to the `@utmostcreator` scope).

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
