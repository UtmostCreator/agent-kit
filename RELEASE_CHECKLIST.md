# Release checklist

## Blocking checks

- [ ] Confirm the repository contains no confidential code, copied proprietary material, or incompatible dependencies.
- [ ] Remove `.ai-logs/` and all generated session artifacts from the index and Git history.
- [ ] Rotate any credential that ever appeared in committed files or logs.
- [ ] Validate the declared Bash and dependency requirements on clean Linux environments.
- [ ] Run every test from a clean clone.
- [ ] Run ShellCheck and resolve or explicitly justify findings.
- [ ] Run `./scripts/check-publishable.sh`.
- [ ] Review installation and uninstallation in isolated temporary HOME directories.
- [ ] Review release archive contents before upload.
- [ ] Confirm Apache-2.0 compatibility for all included code and dependencies.

## GitHub configuration

- [ ] Set the description and topics from `GITHUB_METADATA.md`.
- [ ] Upload a social preview image.
- [ ] Enable private vulnerability reporting and secret scanning.
- [ ] Protect `main` and require `CI / required`.
- [ ] Require pull requests and resolved review conversations.
- [ ] Block force pushes and branch deletion.
- [ ] Enable automatic deletion of merged branches.

## Release

- [ ] Set `VERSION` and update `CHANGELOG.md`.
- [ ] Create a signed `vX.Y.Z` tag.
- [ ] Verify generated `.tar.gz`, `.zip`, and `SHA256SUMS` files.
- [ ] Publish release notes with known limitations and upgrade instructions.
- [ ] Test installation from the published archive.

## Distribution channels

- [ ] **npm:** `npm publish --access public` (the package is scoped
      `@utmostcreator/agent-kit`; scoped packages are private by default and the
      publish fails without `--access public`). The first version must be
      published with a token; only then can OIDC/Trusted Publishing be enabled.
- [ ] **Homebrew tap:** after the tag exists, replace the placeholder `sha256`
      in `Formula/agent-kit.rb` with the real archive checksum
      (`brew fetch agent-kit` prints it), then verify `brew install agent-kit`.
- [ ] **curl | bash:** confirm `web-install.sh` clones the tag and installs the
      `agent-kit` command on a clean machine.
