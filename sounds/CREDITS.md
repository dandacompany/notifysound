# Built-in sound credits

## macOS system sounds (referenced, not bundled)

`glass`, `ping`, `hero`, `pop`, `submarine` and `tink` are registered as
absolute paths into `/System/Library/Sounds/`. No file is copied and nothing is
redistributed. If a future macOS release removes one, playback falls back to
silence and `notifysound status` reports the sound as missing.

| name        | path                                    |
| ----------- | --------------------------------------- |
| `glass`     | `/System/Library/Sounds/Glass.aiff`     |
| `ping`      | `/System/Library/Sounds/Ping.aiff`      |
| `hero`      | `/System/Library/Sounds/Hero.aiff`      |
| `pop`       | `/System/Library/Sounds/Pop.aiff`       |
| `submarine` | `/System/Library/Sounds/Submarine.aiff` |
| `tink`      | `/System/Library/Sounds/Tink.aiff`      |

## Kenney (CC0 1.0, bundled)

From [Kenney Interface Sounds](https://kenney.nl/assets/interface-sounds) and
[Kenney UI Audio](https://kenney.nl/assets/ui-audio), released under
[CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) — public domain,
no attribution required. Thanks to Kenney for releasing them that way, and to
the [Calinou](https://github.com/Calinou) mirrors that make individual files
fetchable.

| name       | bundled file                  | original file          | pack             | duration |
| ---------- | ----------------------------- | ---------------------- | ---------------- | -------- |
| `confirm`  | `kenney/confirmation_001.wav` | `confirmation_001.wav` | Interface Sounds | 0.295 s  |
| `bong`     | `kenney/bong_001.wav`         | `bong_001.wav`         | Interface Sounds | 0.132 s  |
| `pluck`    | `kenney/pluck_001.wav`        | `pluck_001.wav`        | Interface Sounds | 0.112 s  |
| `crystal`  | `kenney/glass_001.wav`        | `glass_001.wav`        | Interface Sounds | 0.292 s  |
| `question` | `kenney/question_002.wav`     | `question_002.wav`     | Interface Sounds | 0.338 s  |
| `switch`   | `kenney/switch2.wav`          | `switch2.wav`          | UI Audio         | 0.318 s  |

Chosen from a 20-file candidate pool by measured duration (`afinfo`, 2026-08-13):
long enough to register (the shortest candidate, `click_002.wav` at 0.012 s, is
effectively inaudible) and short enough not to wear on you at every turn. Error,
glitch and scratch families were excluded as semantically wrong for a completed
turn, and one representative was taken per timbre family so the twelve built-ins
stay distinguishable from each other.

`crystal` rather than `glass` for `glass_001.wav`, because `glass` is already
taken by the macOS system sound.

## Not bundled

Sounds you register yourself with `notifysound add` are copied into
`$NOTIFYSOUND_HOME/sounds/` (default `~/.claude/notifysound/sounds/`) and are
never part of this repository.
