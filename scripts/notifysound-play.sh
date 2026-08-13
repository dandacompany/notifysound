#!/usr/bin/env bash
# notifysound - turn-completion sound player
# Usage: notifysound-play.sh <host>   (host: claude | codex)
#
# Iron rule: exit 0 with no output, on every path we control.
#
# Precisely: for every failure the player can encounter — missing, corrupt or
# disabled config, an absent sound file, a missing library — it exits 0 and
# writes nothing. The one thing outside that guarantee is a NOTIFYSOUND_LIB
# pointed at a hostile script: an EXIT trap that signals the process can still
# change the exit code. That variable already grants arbitrary code execution,
# so guarding it would buy nothing; the honest statement is that it is trusted
# input, not that the contract is absolute.
#
# That rule is enforced STRUCTURALLY rather than by remembering to write
# `|| exit 0` after each step. The whole body runs in a subshell with both
# streams discarded, and the script exits 0 unconditionally afterwards. A
# sourced library that calls `exit 7`, prints to stdout, or is syntactically
# broken can therefore no longer break the contract — it only ends the subshell.
# Earlier versions guarded each path individually and a library `exit` slipped
# straight past them.

ns_main() {
  set -uo pipefail

  # The library is a sibling of this script inside the install tree. Resolving
  # it through our own symlink chain means the install location is not encoded
  # anywhere: the hook can point here from ~/.claude/hooks, ~/.codex/hooks, or
  # wherever the installer put it. NOTIFYSOUND_LIB still overrides, for tests.
  #
  # This duplicates the resolution loop that also lives in lib/config.sh. That
  # is unavoidable — the player has to find config.sh before it can use anything
  # from it. Do not "fix" the duplication by sourcing something else first.
  local ns_lib ns_self ns_target ns_hops=0
  ns_lib="${NOTIFYSOUND_LIB:-}"
  if [ -z "$ns_lib" ]; then
    ns_self="${BASH_SOURCE[0]}"
    while [ -L "$ns_self" ] && [ "$ns_hops" -lt 32 ]; do
      ns_target="$(readlink "$ns_self")" || break
      case "$ns_target" in
        /*) ns_self="$ns_target" ;;
        *)  ns_self="$(dirname "$ns_self")/$ns_target" ;;
      esac
      ns_hops=$((ns_hops + 1))
    done
    ns_lib="$(cd "$(dirname "$ns_self")" && pwd)/lib/config.sh"
  fi
  [ -r "$ns_lib" ] || return 0
  # shellcheck source=/dev/null
  source "$ns_lib" || return 0

  local host sound_path player lock_file lock_tmp child_pid
  host="${1:-}"
  [ -n "$host" ] || return 0

  ns_valid || return 0
  [ "$(ns_effective "$host" 2>/dev/null)" = "true" ] || return 0

  sound_path="$(ns_current_sound_path 2>/dev/null)" || return 0
  [ -n "$sound_path" ] || return 0

  player="${NOTIFYSOUND_PLAYER:-afplay}"
  lock_file="$(ns_home)/.playing.pid"

  # Duplicate-playback guard. It does not scan the system-wide process list by
  # filename (`pgrep -f` can match an editor holding the file open, an unrelated
  # grep, and so on). Instead this script records the PID of the process it just
  # started itself, and only treats that PID as "still playing" if it is alive
  # AND its command line still contains the same absolute sound_path. When in
  # doubt it fails open and plays — a rare double play beats silent failure.
  ns_already_playing() {
    local prev_pid args
    [ -f "$lock_file" ] || return 1
    prev_pid="$(cat "$lock_file" 2>/dev/null)" || return 1
    [[ "$prev_pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$prev_pid" 2>/dev/null || return 1
    args="$(ps -p "$prev_pid" -o args= 2>/dev/null)" || return 1
    [[ "$args" == *"$sound_path"* ]]
  }

  ns_already_playing && return 0

  nohup "$player" "$sound_path" </dev/null >/dev/null 2>&1 &
  child_pid=$!

  # Write the lock through a fresh temp file and rename it into place. A plain
  # `> "$lock_file"` redirection follows an existing symlink, so anything that
  # planted a link at this path would have its target overwritten with a PID.
  # mv replaces the link itself instead.
  lock_tmp="$(mktemp "$(ns_home)/.playing.XXXXXX" 2>/dev/null)" || lock_tmp=""
  if [ -n "$lock_tmp" ]; then
    if printf '%s\n' "$child_pid" > "$lock_tmp" 2>/dev/null; then
      mv -f "$lock_tmp" "$lock_file" 2>/dev/null || rm -f "$lock_tmp" 2>/dev/null
    else
      rm -f "$lock_tmp" 2>/dev/null
    fi
  fi
  return 0
}

( ns_main "$@" ) >/dev/null 2>&1

exit 0
