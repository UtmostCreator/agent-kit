# Support

RestSift is a safety-first, pure-Bash CLI that you install once and
run as `restsift <command>` inside any repository (or `akit <command>` if you
set the optional alias `alias akit='restsift'`). This page explains what is
supported, what is not, and where to ask.

## What Is Supported

- The `restsift` dispatcher (`bin/restsift`) and every shipped command under `libexec/`.
- The installers and their documented flags: `install.sh`, `uninstall.sh`, the
  `curl | bash` bootstrap, the Homebrew formula, and the npm wrapper.
- Shared library modules under `lib/`, optional hooks under `hooks/`, and the
  config under `share/`.
- Discovery and introspection: `restsift --list`, `restsift <command> --help`, and
  `restsift <command> --introspect` (machine-readable JSON contract).
- Linux and macOS with the documented runtime: **Bash 4.4+, Git, ripgrep (`rg`),
  and `jq`**. Optional capabilities may use `fd`, GitHub CLI, Node.js/Repomix,
  `scc`, and ShellCheck. See [INSTALL.md](INSTALL.md) for prerequisites.

## What Is Not Supported

- The external AI tools and models themselves (Claude Code, GitHub Copilot,
  OpenCode, ChatGPT). Report those to their vendors.
- Native Windows without WSL, and minimal shells that are not Bash.
- Changes you make to installed files after installation.
- This toolkit is a guardrail layer, **not** an operating-system sandbox. You
  remain responsible for reviewing diffs, output, and verification evidence
  before merging agent changes.

## Where to Ask

- **Questions and usage help:** open a GitHub Discussion or issue on this
  repository.
- **Bugs:** open a GitHub issue with your OS, tool versions (`bash --version`,
  `git --version`, `rg --version`, `jq --version`), the exact command you ran,
  and its output.
- **Security issues:** do not open a public issue — follow [SECURITY.md](SECURITY.md)
  and report privately through GitHub Security Advisories.

## Before You Open an Issue

1. Read [INSTALL.md](INSTALL.md) and the [command map](docs/COMMANDS.md).
2. Run `restsift <command> --help` to confirm the exact supported contract.
3. Re-run the failing command and capture the full output.
4. Confirm your core dependencies resolve: `restsift search doctor` reports which
   tools are available or missing.
