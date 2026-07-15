# Release checklist

Status as of `feat/project-local-install` @ `672db2c` (verified with real
commands, not just read-through — see [RELEASING.md](RELEASING.md) for the
full evidence trail and exact commands used).

## Blocking checks

- [ ] Confirm the repository contains no confidential code, copied proprietary material, or incompatible dependencies.
      _Not verified this session — needs a human/legal read, not a script._
- [x] Remove `.ai-logs/` and all generated session artifacts from the index and Git history.
      _Verified: `check-publishable.sh` rejects any tracked `.ai-logs` path
      (passes), and `git log --all --diff-filter=A --name-only` shows
      `.ai-logs` was never committed on any branch, ever._
- [ ] Rotate any credential that ever appeared in committed files or logs.
      _No evidence any real credential was ever committed (see above); nothing
      to rotate as far as this repo's history shows, but this is a standing
      manual check, not something a script can close out._
- [ ] Validate the declared Bash and dependency requirements on clean Linux environments.
      _Partially covered: `.github/workflows/ci.yml` runs the full suite on
      both `ubuntu-22.04` and `ubuntu-24.04` on every push/PR to `main`, but
      nothing has been pushed to `origin` beyond `main`'s original commit yet
      (`gh run list` returns zero runs), so this hasn't actually executed on
      GitHub's infra yet — only in this local sandbox._
- [x] Run every test from a clean clone.
      _Verified: cloned this branch into an isolated tmp directory with `git
      clone` and ran `./scripts/check.sh` there — 655 passed, 0 failed, across
      27 test files, exit 0._
- [x] Run ShellCheck and resolve or explicitly justify findings.
      _Verified: `check.sh` runs `shellcheck --severity=warning` across every
      shipped script; 0 findings at warning-or-above severity in both the
      working copy and the clean-clone run._
- [x] Run `./scripts/check-publishable.sh`.
      _Verified passing, including after fixing a real false-positive where
      two test fixtures' literal fake-RSA-key text tripped the script's own
      credential grep (see commit `fc2a202`)._
- [x] Review installation and uninstallation in isolated temporary HOME directories.
      _Verified: `install.sh` (global mode) and `install.sh --project` each
      installed cleanly into isolated temp `prefix`/`bindir`/`HOME`
      directories, the installed `agent-kit` wrapper ran real commands
      (`--list`, `search doctor`), and `uninstall.sh` removed every file it
      created, leaving both directories empty._
- [x] Review release archive contents before upload.
      _Verified: built `agent-kit-0.1.0.tar.gz` via `scripts/package-release.sh
      v0.1.0` and inspected it file-by-file — ships exactly the intended
      runtime+docs set, no dev-only material (`test/`, `scripts/`, `.github/`,
      `Formula/`, `package.json`, `.git*`, `coverage*`,
      `.repomix-context/`) leaked in. The `.zip` step couldn't be exercised
      locally (no `zip` binary in this sandbox) but packs the same staged
      directory as the tar step, and CI has `zip` installed._
- [ ] Confirm Apache-2.0 compatibility for all included code and dependencies.
      _Not verified this session — needs a license/dependency audit, not a
      script._

## GitHub configuration

Verified via `gh api repos/UtmostCreator/agent-kit` (and sub-paths):

- [x] Set the description and topics from `GITHUB_METADATA.md`.
      _Done: applied via `gh repo edit --description ... --add-topic ...`;
      confirmed live — description matches `GITHUB_METADATA.md` exactly and
      all 19 suggested topics are set._
- [ ] Upload a social preview image.
      _Still open — needs an actual branded image asset (none exists in this
      repo) and is normally done through Settings → General → Social preview
      in the browser; not something to script blind._
- [x] Enable private vulnerability reporting and secret scanning.
      _Done: secret scanning and push protection were already on; private
      vulnerability reporting was flipped on with explicit user go-ahead
      (`gh api -X PUT .../private-vulnerability-reporting`) and confirmed
      live (`enabled: true`)._
- [x] Protect `main` and require `CI / required`.
      _Done, with explicit user go-ahead: `required_status_checks` requires
      the `required` context (strict), confirmed live via `gh api
      repos/.../branches/main/protection`._
- [x] Require pull requests and resolved review conversations.
      _Done: `required_pull_request_reviews.required_approving_review_count:
      0` forces changes through a PR without needing a second reviewer
      (avoids locking out the sole maintainer — GitHub doesn't allow
      self-approval), plus `required_conversation_resolution: true`. Both
      confirmed live._
- [x] Block force pushes and branch deletion.
      _Done: `allow_force_pushes: false`, `allow_deletions: false`, both
      confirmed live. `enforce_admins: false` deliberately, so the repo owner
      isn't locked out before there are other maintainers to review PRs._
- [x] Enable automatic deletion of merged branches.
      _Done: `gh repo edit --delete-branch-on-merge`; confirmed live
      (`delete_branch_on_merge: true`)._

Note: the repository itself is **already named `agent-kit`**
(`UtmostCreator/agent-kit`, confirmed via `gh api`) — the one item this
checklist doesn't explicitly list but that RELEASING.md's step 0 used to
treat as still-open.

## Release

- [ ] Set `VERSION` and update `CHANGELOG.md`.
      _`VERSION` and `package.json` are both `0.1.0` and now kept consistent
      by `package-release.sh` (see below), but `CHANGELOG.md`'s
      `[Unreleased]` section still needs to move into a dated `[0.1.0]` entry
      at actual tag time — see RELEASING.md step 2._
- [ ] Create a signed `vX.Y.Z` tag.
      _Not done — no tags exist yet (`git tag -l` is empty)._
- [ ] Verify generated `.tar.gz`, `.zip`, and `SHA256SUMS` files.
      _Partially done: `.tar.gz` content verified file-by-file (see above).
      `.zip` and `SHA256SUMS` generation is blocked in this local sandbox only
      (`zip` binary not installed here) — `release.yml`'s CI runner installs
      `zip` explicitly and runs this exact script, so re-verify there on the
      first real tag push._
- [ ] Publish release notes with known limitations and upgrade instructions.
      _Not done — no release exists yet._
- [ ] Test installation from the published archive.
      _Not done — no published archive exists yet._

## Distribution channels

- [ ] **npm:** `npm publish --access public` (the package is scoped
      `@utmostcreator/agent-kit`; scoped packages are private by default and the
      publish fails without `--access public`). The first version must be
      published with a token; only then can OIDC/Trusted Publishing be enabled.
      _Not done — nothing published to npm yet._
- [ ] **Homebrew tap:** after the tag exists, add a stable `url`/`sha256`
      block to `Formula/agent-kit.rb` (it currently only has a `head` block —
      there is no placeholder `sha256` to replace, one needs to be added; see
      RELEASING.md step 5), then verify `brew install agent-kit`.
      _Not done — no tagged release exists yet to build the formula against._
- [ ] **curl | bash:** confirm `web-install.sh` clones the tag and installs the
      `agent-kit` command on a clean machine.
      _Not done — no tag has been pushed yet for it to resolve._
