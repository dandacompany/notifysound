# notifysound

**A sound when your agent finishes its turn — for Claude Code and Codex CLI, from one switch.**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

한국어 문서: [README.ko.md](./README.ko.md)

Most terminal-notification setups are per-tool: a hook here, a shell alias there,
each with its own on/off ritual and its own idea of where the sound file lives.
notifysound takes the opposite approach — one CLI owns the state, and every
harness hook is a thin call into the same player. Muting Codex while leaving
Claude Code audible is one command, not a config-file edit.

The player is deliberately the dumbest part of the system: it exits 0 and writes
nothing to stdout on every failure path, so a missing file, a corrupt config or a
broken symlink can never block or corrupt an agent turn. All the judgment lives
in the CLI.

## Requirements

- **macOS.** Playback goes through `afplay`. Linux and Windows are not supported;
  abstracting over `paplay`/`aplay` is a separate piece of work.
- `bash` and [`jq`](https://jqlang.github.io/jq/) (`brew install jq`).
- Claude Code, Codex CLI, or both. Neither is required — notifysound installs a
  hook only where it finds one.

## Install

### Option A — `skills add`

```bash
skills add dandacompany/notifysound@notifysound -g --copy -a claude-code
notifysound install
```

The second line is not optional. A skill manager places skill files and
deliberately does not edit your home configuration, so hook installation stays an
explicit act. `notifysound install` writes the hooks and registers the built-in
sounds.

### Option B — one-liner

```bash
curl -fsSL https://raw.githubusercontent.com/dandacompany/notifysound/main/install.sh | bash
```

Piping a script into `bash` means running code you have not read, and this script
edits files in your home directory. The two-step form is the better habit:

```bash
curl -fsSL https://raw.githubusercontent.com/dandacompany/notifysound/main/install.sh -o install.sh
less install.sh
bash install.sh
```

Options: `--no-hooks`, `--skills-dir <path>` (repeatable), `--version <tag>`,
`--uninstall`.

### What the installer touches

| Path                                                      | What happens                                                     |
| --------------------------------------------------------- | ---------------------------------------------------------------- |
| `~/.local/share/notifysound`                              | the install tree — replaced on every run                         |
| `~/.local/bin/notifysound`                                | CLI symlink                                                      |
| `~/.claude/hooks/notifysound-play.sh`                     | player symlink                                                   |
| `~/.claude/skills`, `~/.agents/skills`, `~/.codex/skills` | a symlink into each, **only where the directory already exists** |
| `~/.claude/settings.json`                                 | one `Stop` hook, tagged `# notifysound`                          |
| `~/.codex/hooks/notify.sh`                                | one block, tagged `# notifysound`                                |

It never touches `~/.claude/notifysound/`, where your own sounds and settings
live. Re-running the installer is how you update. `--uninstall` reverses
everything except that state directory, which it leaves for you to delete.

Directories that do not exist are not created — a machine that has never run
Codex does not get an empty `~/.codex/skills`. A path that exists but is a real
directory rather than a symlink (typically a `skills add` copy) is left alone
rather than deleted.

## Usage

```bash
notifysound list            # what is registered
notifysound use crystal     # switch
notifysound test            # hear it now
notifysound off --host codex   # silence Codex, leave Claude Code audible
notifysound status          # what is on, what is installed, what is linked
```

| Command                               | What it does                                               |
| ------------------------------------- | ---------------------------------------------------------- |
| `on` / `off` `[--host claude\|codex]` | global switch, or one host                                 |
| `reset --host claude\|codex`          | clear a host override, follow the global switch            |
| `status`                              | state, hook health, player health, skill links (read-only) |
| `list`                                | registered sounds, built-in and user                       |
| `add <name> <file> [--force]`         | copy a file into the library and register it               |
| `use <name>`                          | switch the current sound                                   |
| `remove <name>`                       | unregister a user sound and delete its file                |
| `test [name]`                         | play immediately, ignoring the enabled switch              |
| `install` / `uninstall`               | write or remove the host hooks                             |

Per-host state is an override, not a second switch: `null` means "follow the
global one". `off` then `reset --host codex` puts Codex back under global
control rather than turning it on.

`add` copies, it does not reference. The file lands in
`~/.claude/notifysound/sounds/`, so moving or deleting the original afterwards
does not affect playback.

Exit codes: `0` success, `1` user error, `2` environment error.

## Built-in sounds

Twelve are registered by `notifysound install`. Six are macOS system sounds,
referenced in place; six are CC0 files bundled with this repository.

|                  |                                                        |                                           |
| ---------------- | ------------------------------------------------------ | ----------------------------------------- |
| **macOS**        | `glass` `ping` `hero` `pop` `submarine` `tink`         | referenced from `/System/Library/Sounds/` |
| **Kenney (CC0)** | `confirm` `bong` `pluck` `crystal` `question` `switch` | bundled, 0.11–0.34 s each                 |

Registration never overwrites a name you already use, and never changes your
current selection. Built-ins cannot be removed — they are install assets and
would return on the next install — but `add --force <name>` overrides one with
your own file, and from that point the name is an ordinary, removable user sound.

Provenance for every file, including the original Kenney filenames and the
selection criteria, is in [`sounds/CREDITS.md`](sounds/CREDITS.md).

## Where things live

```
~/.local/share/notifysound/     install tree (replaced on update)
  scripts/                      CLI, player, libraries
  sounds/                       built-in manifest and bundled CC0 files

~/.claude/notifysound/          your state (never touched by an install)
  config.json                   switches, current sound, registered sounds
  sounds/                       files you added
```

Set `NOTIFYSOUND_HOME` to move the state directory. The default lives under
`~/.claude/` for compatibility with earlier versions even though nothing about it
is Claude-specific; a future version may move it to `~/.local/state/notifysound/`.

The player finds its library relative to itself, through its own symlink chain,
so the install location is not encoded anywhere. You can move the tree and
re-point the symlinks and it keeps working.

## How it fails

By design, quietly. `notifysound-play.sh` exits 0 with no output when the config
is missing, corrupt, disabled, or points at a file that no longer exists. A sound
problem is never allowed to become an agent problem.

Two consequences worth knowing:

- `uninstall` does not restore a notification hook that existed before
  notifysound. It removes what carries the `# notifysound` signature and leaves
  no hook behind.
- Conversely, `install` and `uninstall` **only** touch signed entries. A
  `Stop` hook or an `agent-turn-complete` block you wrote yourself survives both,
  byte for byte.

Every edit to `settings.json` or `notify.sh` writes a timestamped backup
alongside the original (`<file>.notifysound-bak-<timestamp>-XXXXXX`).

## Credits

Bundled sounds are from Kenney's [Interface Sounds](https://kenney.nl/assets/interface-sounds)
and [UI Audio](https://kenney.nl/assets/ui-audio) packs, released under CC0 1.0.

## License

[MIT](./LICENSE) © Dante Labs

---

<div align="center">

**Dante Labs** · **YouTube** [@dante-labs](https://youtube.com/@dante-labs) · **Email** [dante@dante-labs.com](mailto:dante@dante-labs.com) · **Discord** [Dante Labs Community](https://discord.com/invite/rXyy5e9ujs) · **Support** [Buy Me a Coffee](https://buymeacoffee.com/dante.labs)

</div>
