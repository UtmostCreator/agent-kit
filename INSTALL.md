# Installation

## Requirements

- Linux or macOS with Bash 4.4 or newer
- Git
- `ripgrep` (`rg`)
- `jq`

Optional tools unlock additional commands: `fd`, `gh`, Node.js with Repomix, SCC, and ShellCheck.

> **macOS note:** macOS ships Bash 3.2, which RestSift does not support. Install a
> modern Bash with `brew install bash`. The Homebrew formula installs that dependency
> automatically; npm, clone, and curl installs detect a capable Bash on `PATH` (set
> `TOOL_BASH=/path/to/bash` if it lives somewhere non-standard).

## Choose an install method

| Method | Best for | Command |
|---|---|---|
| One-line network install | Quick setup | `curl -fsSL https://raw.githubusercontent.com/UtmostCreator/restsift/main/web-install.sh \| bash` |
| Clone + `install.sh` | Reviewing before install | see below |
| Homebrew | macOS / Linuxbrew users | `brew tap` + `brew install --HEAD` |
| npm | Node-based agents / global CLI | `npm install -g @utmostcreator/restsift` |

All methods install the same `restsift` command.

Want proof a release archive was really built by this repo's CI, not
tampered with in transit? Every tagged release is cryptographically
attested to its source commit:

```bash
gh attestation verify restsift-<version>.tar.gz --repo UtmostCreator/restsift
sha256sum --check SHA256SUMS
```

## Project-local install (vendor the toolkit inside a repo)

To make a single repository self-contained — so every checkout and CI job has the
toolkit without a global install — install it **project-locally**:

```bash
# from anywhere inside the target repo (installs into <repo-root>/.restsift/)
/path/to/restsift/install.sh --project

# or point at a specific project directory
./install.sh --project /path/to/repo
```

This creates:

```
<repo-root>/.restsift/
├── toolkit/   # the RestSift install (bin, lib, libexec, share, …)
└── bin/
    └── restsift   # wrapper; invoke tools as .restsift/bin/restsift <command>
```

**Configurable folder name.** The default vendored folder is `.restsift`. Rename it
in one place with `RESTSIFT_DIR_NAME` (the installer and any consuming repo can agree
on the same variable):

```bash
RESTSIFT_DIR_NAME=.tools ./install.sh --project        # -> <repo>/.tools/{toolkit,bin}
RESTSIFT_PROJECT_DIR=/path/to/repo ./install.sh         # env form of --project
```

An explicit `--prefix` always overrides project mode. Recommended default for
consuming repos: keep `.restsift/` and reference `.restsift/toolkit/libexec/<name>`
(or the `.restsift/bin/restsift <command>` dispatcher) through a single config value
so the folder can be moved/renamed without touching every caller.

## One-line network install (curl \| bash)

```bash
curl -fsSL https://raw.githubusercontent.com/UtmostCreator/restsift/main/web-install.sh | bash
```

By default this installs the **latest published release** (the newest `v*` tag),
not mutable `main` — the script prints the resolved ref and commit before
installing. Pin a specific ref or change locations with environment variables.
Put them on the **`bash` that runs the script** (a `VAR=x curl … | bash` prefix
would set the variable on `curl`, not on the script):

```bash
# a specific released tag
curl -fsSL https://raw.githubusercontent.com/UtmostCreator/restsift/main/web-install.sh \
  | RESTSIFT_REF=v0.1.0 RESTSIFT_BINDIR="$HOME/bin" bash

# the development version (explicit opt-in to main)
curl -fsSL https://raw.githubusercontent.com/UtmostCreator/restsift/main/web-install.sh \
  | RESTSIFT_REF=main bash
```

`web-install.sh` clones the toolkit into `${XDG_CACHE_HOME:-$HOME/.cache}/restsift/src` and then runs the atomic `install.sh`. Review the script before piping it to a shell.

## Homebrew

This repository doubles as its own tap:

```bash
brew tap utmostcreator/restsift https://github.com/UtmostCreator/restsift
brew install --HEAD restsift
```

A stable Homebrew formula will be available after the first tagged release tarball
and checksum are published.

## npm

```bash
npm install -g @utmostcreator/restsift
```

This installs the `restsift` command. Bash 4.4+, Git, `rg`, and `jq` must already be available; the npm package is a thin shim over the same Bash toolkit.

## Install from a clone

```bash
git clone https://github.com/UtmostCreator/restsift.git
cd restsift
./install.sh
```

The default installation paths are:

- application: `${XDG_DATA_HOME:-$HOME/.local/share}/restsift`
- command wrapper: `$HOME/.local/bin/restsift`

Add the command directory to `PATH` when required:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

## Install to a custom location

```bash
./install.sh --prefix "$HOME/tools/restsift" --bindir "$HOME/bin"
```

## Upgrade

Pull a reviewed release or commit, then run the installer again. Installation is staged before the active copy is replaced.

```bash
git pull --ff-only
./install.sh
```

## Verify

```bash
restsift --version
res --version          # the short alias, installed alongside restsift
res --help
res s TODO             # short search: default text mode, repo root auto-detected
```

## The short `res` alias

Every installer creates a short **`res`** command next to the canonical
`restsift` — same dispatcher, less typing. Prefer `res` interactively and keep
`restsift` in scripts and documentation for readability.

```bash
res --list
res s TODO                     # == restsift search text TODO <repo-root>
res s export --changed         # search only changed files
res doctor                     # install + environment health check
```

`res s QUERY` defaults to text mode and auto-detects the search root (explicit
`ROOT` > Git top-level > current dir), so the common case needs no mode word and
no trailing `.`. Mode flags (`--tracked`, `--changed`, `--staged`, `--diff`,
`--history`, `--docs`, `--tests`, `--config`, `--deps`) switch families.

> Want an even shorter or differently-named alias too? Add one to your shell rc,
> e.g. `echo "alias akit='restsift'" >> ~/.bashrc`.

## Shell completion

`restsift completion SHELL` prints a generated, non-mutating completion
definition for `bash`, `zsh`, or `fish` (both `restsift` and `res` complete
identically); `auto` detects your running shell.

```bash
source <(restsift completion bash)                                    # this session only
echo 'source <(restsift completion zsh)' >> ~/.zshrc                  # persistent, zsh
restsift completion fish > ~/.config/fish/completions/restsift.fish  # persistent, fish
```

Homebrew installs wire this into `bash_completion`/`zsh_completion`/
`fish_completion` automatically. `./install.sh` does the same for Fish
(`~/.config/fish/completions/restsift.fish`, autoloaded — no rc edit needed)
and, if the `bash-completion` package is set up, for Bash too; Zsh always
needs the `source` line above added to `~/.zshrc`.

## Uninstall

```bash
./uninstall.sh
```

For a custom installation:

```bash
./uninstall.sh --prefix "$HOME/tools/restsift" --bindir "$HOME/bin"
```

The uninstaller refuses to remove a target that does not contain the toolkit installation marker.
