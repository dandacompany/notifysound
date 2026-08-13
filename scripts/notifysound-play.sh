#!/usr/bin/env bash
# notifysound - turn-completion sound player
# Usage: notifysound-play.sh <host>   (host: claude | codex)
# Iron rule: exit 0 on every failure, with no stdout.

set -uo pipefail

# The library is a sibling of this script inside the install tree. Resolving it
# through our own symlink chain means the install location is not encoded
# anywhere: the hook can point here from ~/.claude/hooks, ~/.codex/hooks, or
# anywhere else, and the tree can live wherever the installer put it.
#
# This duplicates the resolution loop that also lives in lib/config.sh. That is
# unavoidable — the player has to find config.sh before it can use anything
# from it. Do not "fix" the duplication by sourcing something else first.
NS_LIB="${NOTIFYSOUND_LIB:-}"
if [ -z "$NS_LIB" ]; then
  ns_self="${BASH_SOURCE[0]}"
  while [ -L "$ns_self" ]; do
    ns_target="$(readlink "$ns_self")" || break
    case "$ns_target" in
      /*) ns_self="$ns_target" ;;
      *)  ns_self="$(dirname "$ns_self")/$ns_target" ;;
    esac
  done
  NS_LIB="$(cd "$(dirname "$ns_self")" && pwd)/lib/config.sh"
fi
[ -r "$NS_LIB" ] || exit 0
# stdout is redirected for the duration of the source so that "silent on every
# path" holds literally: a library that prints while being sourced would
# otherwise leak into the hook's stdout, where the host parses it.
# shellcheck source=/dev/null
source "$NS_LIB" >/dev/null || exit 0

host="${1:-}"
[ -n "$host" ] || exit 0

ns_valid || exit 0
[ "$(ns_effective "$host" 2>/dev/null)" = "true" ] || exit 0

sound_path="$(ns_current_sound_path 2>/dev/null)" || exit 0
[ -n "$sound_path" ] || exit 0

player="${NOTIFYSOUND_PLAYER:-afplay}"
lock_file="$(ns_home)/.playing.pid"

# Duplicate-playback guard. It does not scan the system-wide process list by
# filename (`pgrep -f` can match an editor holding the file open, an unrelated
# grep, and so on). Instead this script records the PID of the process it just
# started itself, and only treats that PID as "still playing" if it is alive
# AND its command line still contains the same absolute sound_path. When in
# doubt it fails open and plays — a rare double play beats silent failure.
already_playing() {
  local prev_pid args
  [ -f "$lock_file" ] || return 1
  prev_pid="$(cat "$lock_file" 2>/dev/null)" || return 1
  [[ "$prev_pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$prev_pid" 2>/dev/null || return 1
  args="$(ps -p "$prev_pid" -o args= 2>/dev/null)" || return 1
  [[ "$args" == *"$sound_path"* ]]
}

already_playing && exit 0

nohup "$player" "$sound_path" </dev/null >/dev/null 2>&1 &
child_pid=$!

# Write the lock through a fresh temp file and rename it into place. A plain
# `> "$lock_file"` redirection follows an existing symlink, so anything that
# planted a link at this path would have its target overwritten with a PID.
# mv replaces the link itself instead. Every step stays quiet and non-fatal —
# a missing lock only costs us the duplicate-play guard.
lock_tmp="$(mktemp "$(ns_home)/.playing.XXXXXX" 2>/dev/null)" || lock_tmp=""
if [ -n "$lock_tmp" ]; then
  if printf '%s\n' "$child_pid" > "$lock_tmp" 2>/dev/null; then
    mv -f "$lock_tmp" "$lock_file" 2>/dev/null || rm -f "$lock_tmp" 2>/dev/null
  else
    rm -f "$lock_tmp" 2>/dev/null
  fi
fi

exit 0
