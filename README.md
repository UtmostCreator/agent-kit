<div align="center">

# 🧰 AgentKit

**Safety-first repository operations for AI coding agents — and the humans who review them.**

<p align="center">
  <img alt="License" src="https://img.shields.io/badge/License-Apache_2.0-2ea44f?style=for-the-badge"/>
  <img alt="Bash" src="https://img.shields.io/badge/Bash-4.4%2B-4EAA25?style=for-the-badge&logo=gnubash&logoColor=white"/>
  <img alt="Platform" src="https://img.shields.io/badge/Linux%20%7C%20macOS-333?style=for-the-badge&logo=linux&logoColor=white"/>
  <img alt="No telemetry" src="https://img.shields.io/badge/telemetry-none-success?style=for-the-badge"/>
  <br/>
  <a href="https://github.com/UtmostCreator/agent-kit/actions/workflows/ci.yml"><img alt="CI" src="https://img.shields.io/github/actions/workflow/status/UtmostCreator/agent-kit/ci.yml?style=for-the-badge&label=CI&logo=github"/></a>
  <a href="https://www.npmjs.com/package/@utmostcreator/agent-kit"><img alt="npm" src="https://img.shields.io/npm/v/@utmostcreator/agent-kit?style=for-the-badge&logo=npm&color=cb3837"/></a>
  <a href="https://github.com/UtmostCreator/agent-kit/stargazers"><img alt="Stars" src="https://img.shields.io/github/stars/UtmostCreator/agent-kit?style=for-the-badge&color=ffcc00"/></a>
</p>

A curated collection of dependency-light **Bash** scripts for working inside a repository —
scoped search, context packing, guarded edits, rollback, test selection, and
evidence-based verification. One agent-agnostic `agent-kit` command; every script
is **self-documenting** via `--help` / `--introspect` and runs **100% on your machine**.

`Search · Context · Edit · Rollback · Test · Verify`

</div>

---

## ⚡ Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/UtmostCreator/agent-kit/main/web-install.sh | bash

agent-kit --list                # discover every command
agent-kit search text "TODO" .  # your first search
```

## 🤔 Why AgentKit? (vs. running `rg` / `git` / `grep` yourself)

|                          | Raw shell tools                    | 🧰 AgentKit                                                   |
| ------------------------ | ---------------------------------- | ------------------------------------------------------------ |
| **Structured output**    | text you parse by hand             | JSON envelopes (`--introspect`, `AI_OUTPUT=json`)            |
| **One interface**        | remember each tool's flags         | `agent-kit search` over ripgrep + git-grep + ast-grep        |
| **Guarded edits**        | none — a bad `sed` is forever      | plan-first edits with scope checks, snapshots, and rollback  |
| **Test selection**       | manual                             | `agent-kit test-select changed`                              |
| **Proof of completion**  | manual                             | `agent-kit verify` — an evidence gate before you say "done"  |
| **Self-documenting**     | man pages vary wildly              | every command: `--help` + a runnable example, `--introspect` |
| **Agent-agnostic**       | —                                  | one surface for Claude Code, Copilot, OpenCode, or a human   |
| **Runtime**              | —                                  | Bash + Git + `rg` + `jq`. No PHP, no Node required, no telemetry |

## ✨ What's inside

- 🔍 **Search** — `search` unifies ripgrep, git-grep, and ast-grep behind one command with scoped modes (text, files, docs, tests, diff, history, symbols…) and a JSON envelope.
- 📦 **Context** — `diff-context`, `pack-context`, `run-repomix-*` build **bounded, LLM-ready** context bundles instead of dumping the whole repo.
- ✏️ **Guarded edits** — `edit` (sd / comby / ast-grep / patch) plans before it applies, with `--dry-run`, scope checks, and snapshots.
- ↩️ **Rollback** — `rollback` restores any guarded-edit snapshot.
- 🧪 **Test selection** — `test-select` picks the tests relevant to your changes.
- ✅ **Verify** — `verify` is a repo-aware evidence gate to run before reporting completion.
- 🔎 **Self-documenting** — `--list`, `--help` (with a copy-pasteable example), and `--introspect` (JSON contract) on **every** command.
- 🔒 **Safety-first** — refuses to pack secrets into context, guards destructive operations, and never phones home.

<details>
<summary><b>See every command</b></summary>

Run `agent-kit --list` for the live list with one-line summaries, browse a
runnable example per command in [docs/EXAMPLES.md](docs/EXAMPLES.md), or read the
[command map](docs/COMMANDS.md). Groups: search & discovery (`search`,
`search-multi`, `search-introspect`, `rg-code`, `fd-files`, `preview-file`) ·
context (`diff-context`, `pack-context`, `run-repomix-*`, `repomix-*`) · edits &
safety (`edit`, `rollback`, `session-checkpoint`) · testing & verification
(`test-select`, `run-repo-tests`, `verify`, `verify-*`, `doc-check`) · git & PRs
(`git-forensics`, `git-branch-origin`, `gh-pr-context`) · meta (`sh-introspect`,
`repo-tool-inventory`, `query-usage`).

</details>

## 🚀 Install

Pick whichever fits your setup — all install the same `agent-kit` command:

```bash
# One-line network install (stable: newest release tag)
curl -fsSL https://raw.githubusercontent.com/UtmostCreator/agent-kit/main/web-install.sh | bash

# Homebrew (this repo is its own tap; --HEAD until the first tagged release)
brew tap utmostcreator/agent-kit https://github.com/UtmostCreator/agent-kit
brew install --HEAD agent-kit

# npm (for Node-based agents; installs the `agent-kit` command)
npm install -g @utmostcreator/agent-kit

# From a clone (review before installing)
git clone https://github.com/UtmostCreator/agent-kit.git
cd agent-kit && ./install.sh
```

Ensure `~/.local/bin` is in `PATH`. See **[INSTALL.md](INSTALL.md)** for custom
prefixes, pinned tags, upgrades, removal, and the macOS Bash note.

> 💡 **Prefer a shorter command?** Add `alias akit='agent-kit'` to your shell rc
> and use `akit` everywhere — [docs/EXAMPLES.md](docs/EXAMPLES.md) already shows
> every command in the short form.

## 🎯 Use

```bash
agent-kit search text "TODO" .        # find every TODO comment in the tree
agent-kit diff-context unstaged       # build a context bundle around your changes
agent-kit test-select changed         # pick the tests relevant to changed files
agent-kit verify .                    # run repository-aware verification
```

Every command explains itself, so you never have to guess:

```bash
agent-kit --list                  # every command with a one-line summary
agent-kit <command> --help        # description, usage, and a copy-pasteable example
agent-kit <command> --introspect  # the same contract as machine-readable JSON
```

### 🧩 Use it à la carte (no install required)

Every command is a standalone script under `libexec/`, so you can browse and run
them without a global install — handy for trying one out or wiring one into your
own tooling:

```bash
git clone https://github.com/UtmostCreator/agent-kit.git && cd agent-kit
bash bin/agent-kit --list                 # discover everything, with summaries
bash bin/agent-kit search text "TODO" .   # run any command via the dispatcher
bash libexec/ai-search doctor             # …or invoke a script file directly
```

Scripts that source `lib/` need the repo layout intact — run them through
`bin/agent-kit` or from a clone rather than copying a single file in isolation.

## 🤖 For coding agents

Read **[AGENTS.md](AGENTS.md)** and **[docs/AI_USAGE.md](docs/AI_USAGE.md)**, then use
`agent-kit` as the preferred repository-operations interface: respect command
scopes and guardrails, prefer structured (`AI_OUTPUT=json`) output, and run
`agent-kit verify` before claiming a task is complete.

## 🔒 Safety & privacy

- **Runs entirely on your machine** — no telemetry, no analytics, no cloud sync. Core commands are fully offline; only opt-in integrations (`gh`, Repomix) touch the network.
- **Guardrails, not a sandbox** — AgentKit reduces accidental repository damage, but it is *not* an OS sandbox. Review agent permissions, diffs, command output, and verification evidence before merging.
- **Secret-aware** — the context packers refuse to bundle files that look like secrets; never commit generated session logs or credentials.

## 🛠️ Runtime

**Core (required for basically every command):** Bash 4.4+, Git, `ripgrep` (`rg`), and `jq`.

**Optional (unlock specific commands):**

| Package(s) | Unlocks |
|---|---|
| `fd`/`fdfind`, `ast-grep`/`sg`, `sd`, `comby` | `search files`/`struct`/`symbols`, `edit ast-grep`/`sd`/`comby` |
| `repomix` (Node), `files-to-prompt`, `code2prompt` | `context pack`/`file`/`generate`/`tree` |
| `yq`, `mlr`/`csvcut`, `xmllint` | `structured yaml`/`csv`/`xml`, `inspect data` |
| GitHub CLI (`gh`) | `git pr-context` |
| `lychee`, `markdownlint`, `phpunit`/`paratest`, `bats` | `verify docs`, `test run`/`all` (consumer project's own tests) |
| `watchexec` or `entr`, `tar` | `session watch`/`watch-loop`, `session checkpoint` (untracked-file archive) |
| `bat`, `just`, SCC, ShellCheck | Prettier `preview-file`, `repo tasks` justfile detection, dev-only checks |

See **[docs/PACKAGES.md](docs/PACKAGES.md)** for exactly which package each of
the 24 commands uses, why, and a real captured example.

## 🧪 Development

```bash
./scripts/check.sh              # shellcheck + full test suite (the CI gate)
./scripts/check-publishable.sh  # secret / hygiene boundary checks
bash scripts/gen-examples.sh > docs/EXAMPLES.md   # regenerate the examples doc
```

See **[CONTRIBUTING.md](CONTRIBUTING.md)**. Report vulnerabilities privately via
GitHub Security Advisories — see **[SECURITY.md](SECURITY.md)**.

## 📣 Support

- **Questions / usage** — [GitHub Discussions](https://github.com/UtmostCreator/agent-kit/discussions)
- **Bugs** — [GitHub Issues](https://github.com/UtmostCreator/agent-kit/issues)
- **Security** — [SECURITY.md](SECURITY.md)

## ⚖️ License

Apache-2.0 © Utmost Creator. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

<div align="center">
<sub>Pure Bash. Self-documenting. Agent-agnostic. No telemetry.</sub>
</div>
