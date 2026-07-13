# Installation

## Requirements

- Linux or macOS with Bash 4.4 or newer
- Git
- `ripgrep` (`rg`)
- `jq`

Optional tools unlock additional commands: `fd`, `gh`, Node.js with Repomix, SCC, and ShellCheck.

> **macOS note:** macOS ships Bash 3.2, which AgentKit does not support. Install a
> modern Bash with `brew install bash`. The Homebrew formula installs that dependency
> automatically; npm, clone, and curl installs detect a capable Bash on `PATH` (set
> `TOOL_BASH=/path/to/bash` if it lives somewhere non-standard).

## Choose an install method

| Method | Best for | Command |
|---|---|---|
| One-line network install | Quick setup | `curl -fsSL https://raw.githubusercontent.com/UtmostCreator/agent-kit/main/web-install.sh \| bash` |
| Clone + `install.sh` | Reviewing before install | see below |
| Homebrew | macOS / Linuxbrew users | `brew tap` + `brew install --HEAD` |
| npm | Node-based agents / global CLI | `npm install -g @utmostcreator/agent-kit` |

All methods install the same `agent-kit` command.

## One-line network install (curl \| bash)

```bash
curl -fsSL https://raw.githubusercontent.com/UtmostCreator/agent-kit/main/web-install.sh | bash
```

By default this installs the **latest published release** (the newest `v*` tag),
not mutable `main` — the script prints the resolved ref and commit before
installing. Pin a specific ref or change locations with environment variables.
Put them on the **`bash` that runs the script** (a `VAR=x curl … | bash` prefix
would set the variable on `curl`, not on the script):

```bash
# a specific released tag
curl -fsSL https://raw.githubusercontent.com/UtmostCreator/agent-kit/main/web-install.sh \
  | AGENTKIT_REF=v0.1.0 AGENTKIT_BINDIR="$HOME/bin" bash

# the development version (explicit opt-in to main)
curl -fsSL https://raw.githubusercontent.com/UtmostCreator/agent-kit/main/web-install.sh \
  | AGENTKIT_REF=main bash
```

`web-install.sh` clones the toolkit into `${XDG_CACHE_HOME:-$HOME/.cache}/agent-kit/src` and then runs the atomic `install.sh`. Review the script before piping it to a shell.

## Homebrew

This repository doubles as its own tap:

```bash
brew tap utmostcreator/agent-kit https://github.com/UtmostCreator/agent-kit
brew install --HEAD agent-kit
```

A stable Homebrew formula will be available after the first tagged release tarball
and checksum are published.

## npm

```bash
npm install -g @utmostcreator/agent-kit
```

This installs the `agent-kit` command. Bash 4.4+, Git, `rg`, and `jq` must already be available; the npm package is a thin shim over the same Bash toolkit.

## Install from a clone

```bash
git clone https://github.com/UtmostCreator/agent-kit.git
cd agent-kit
./install.sh
```

The default installation paths are:

- application: `${XDG_DATA_HOME:-$HOME/.local/share}/agent-kit`
- command wrapper: `$HOME/.local/bin/agent-kit`

Add the command directory to `PATH` when required:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

## Install to a custom location

```bash
./install.sh --prefix "$HOME/tools/agent-kit" --bindir "$HOME/bin"
```

## Upgrade

Pull a reviewed release or commit, then run the installer again. Installation is staged before the active copy is replaced.

```bash
git pull --ff-only
./install.sh
```

## Verify

```bash
agent-kit --version
agent-kit --help
agent-kit search --help
```

## Optional: a shorter `akit` alias

`agent-kit` is the canonical command. For less typing, add an alias to your
shell rc and use `akit` everywhere:

```bash
echo "alias akit='agent-kit'" >> ~/.bashrc   # or ~/.zshrc
akit --list
akit search text "TODO" .
```

## Uninstall

```bash
./uninstall.sh
```

For a custom installation:

```bash
./uninstall.sh --prefix "$HOME/tools/agent-kit" --bindir "$HOME/bin"
```

The uninstaller refuses to remove a target that does not contain the toolkit installation marker.
