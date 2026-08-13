---
name: notifysound
description: Use when turning the agent turn-completion sound on or off, or registering and switching notification sounds, for Claude Code and Codex CLI. Responds to requests like "mute the notification sound", "turn the sound back on", "silence codex only", "change the notification sound", "register this file as the sound", "what sound is set", and their Korean equivalents (알림음 꺼줘, 알림음 켜줘, 코덱스만 조용히, 알림음 바꿔줘, 새 알림음 등록, 지금 알림음 뭐야).
argument-hint: "[on|off|reset|status|list|add|use|remove|test|install|uninstall|migrate] [--host claude|codex] [name] [file]"
---

# notifysound

Controls the sound that plays when an agent turn ends. All the decision logic
lives in the CLI, so this skill only has one job: **translate a request into the
right command**. Never edit the state files directly — always go through the CLI.

## First run

If notifysound was installed with `skills add`, only the skill files are in
place; the hooks are not. Skill managers deliberately do not edit home
configuration, so hook installation stays an explicit act. Run this once:

    notifysound install

That installs the Claude Code Stop hook and the Codex CLI notify hook, and
registers the 12 built-in sounds.

## Command mapping

| User request                                                      | Command                          |
| ----------------------------------------------------------------- | -------------------------------- |
| "mute the sound" / "알림음 꺼줘"                                  | `notifysound off`                |
| "turn the sound on" / "알림음 켜줘"                               | `notifysound on`                 |
| "silence codex only" / "코덱스만 조용히"                          | `notifysound off --host codex`   |
| "mute claude only" / "클로드만 꺼줘"                              | `notifysound off --host claude`  |
| "put codex back to default" / "코덱스 설정 원래대로"              | `notifysound reset --host codex` |
| "what is the sound state" / "지금 알림음 상태 어때"               | `notifysound status`             |
| "what sounds are registered" / "등록된 알림음 뭐 있어"            | `notifysound list`               |
| "register this file as the sound" / "이 파일 알림음으로 등록해줘" | `notifysound add <name> <file>`  |
| "switch to <name>" / "알림음 <이름>으로 바꿔줘"                   | `notifysound use <name>`         |
| "let me hear it" / "알림음 들려줘"                                | `notifysound test`               |
| "delete the <name> sound" / "알림음 <이름> 지워줘"                | `notifysound remove <name>`      |
| "reinstall the hooks" / "알림음 훅 다시 설치해줘"                 | `notifysound install`            |
| "remove notifysound" / "알림음 기능 제거해줘"                     | `notifysound uninstall`          |
| "upgraded but the codex hook is missing" / "업그레이드했는데 코덱스 훅이 안 붙어" | `notifysound migrate` then `notifysound install` |

## Rules

- If the user gives a file but no name, propose the filename (without its
  extension) as the default name and confirm before registering.
- If `add` is rejected for a duplicate name, do not silently add `--force` —
  ask whether to overwrite.
- If `remove` is rejected because the sound is currently in use, ask which sound
  to switch to first.
- After changing state, show the output of `notifysound status`.
- `remove` refuses built-in sounds. They are install assets and would come back
  on the next install, so removal would be meaningless. Offer `use` instead.
- `status` reports more than on/off and the current sound: it also **reports
  installation health** — whether each of Claude and Codex actually has a signed
  hook (`installed` / `not installed`), whether the target file exists at all
  (`n/a`, e.g. on a machine that does not use Codex), whether the player path is
  a dangling symlink (`ok` / `broken`), and whether each harness skill directory
  is linked. It is read-only. For any "I hear no sound" request, run
  `notifysound status` first.
- If `install` reports that the Codex hook still holds a pre-2.2 layout, do NOT
  edit `notify.sh` by hand to work around it. Tell the user what `migrate` does
  — it is the only command that decides where things sit in their script, it
  backs the file up first, and it is opt-in for that reason — and let them
  decide. Then run `notifysound install`.
- Never edit `~/.claude/settings.json`, `~/.codex/hooks/notify.sh`, or
  `~/.claude/notifysound/config.json` by hand. Use these CLI commands only.
- **`uninstall` does not restore a previously existing sound hook.** It strips
  the `# notifysound` signature and leaves no hook behind. That is intended. If
  the user expects "put my old sound back", say so first.
- **`add` copies the file, it does not reference it.** The source is copied into
  `~/.claude/notifysound/sounds/`, so moving or deleting the original afterwards
  does not affect playback.

## Layout

- State: `~/.claude/notifysound/config.json` — global `enabled`, per-host
  overrides (`null` means "follow the global switch"), the current `sound`, and
  the registered sound map.
- User sounds: `~/.claude/notifysound/sounds/`
- Built-in sounds: inside the install tree, registered on `install`
- Player: `notifysound-play.sh <host>` — the single entry point the hooks call.
  It exits 0 on every path and writes nothing to stdout, so a sound problem can
  never break an agent turn.
- CLI: `~/.local/bin/notifysound`
- Hooks: one entry in the `Stop` array of Claude Code's `settings.json`, and
  ONE line in `~/.codex/hooks/notify.sh` — immediately after the shebang —
  which sources our own `codex-hook.sh`. Both carry the `# notifysound`
  signature. All of the Codex-side logic lives in our file, not in theirs, and
  install/uninstall only ever touch that single line at that single position.

macOS only (depends on `afplay`). Supported extensions: `mp3 wav aiff m4a aac`.
Sound names accept `[A-Za-z0-9_-]` only.

Exit codes: `0` success, `1` user error, `2` environment error, `3` the Codex
hook is in a pre-2.2 layout and `notifysound migrate` is needed first.
