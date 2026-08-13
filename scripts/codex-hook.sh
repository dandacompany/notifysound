# shellcheck shell=bash
# notifysound - Codex CLI turn-completion hook.
#
# This file is SOURCED from the user's ~/.codex/hooks/notify.sh by a single
# generated line:
#
#     . '<install>/scripts/codex-hook.sh'  # notifysound
#
# Everything notifysound does on the Codex side lives here, in a file we own,
# rather than as a block of our shell inside a file the user owns. That is the
# whole point of the arrangement: updates never rewrite their script, and
# finding our own installation again is a full-line exact match on one line we
# generated instead of a guess about which lines of their file are ours.
#
# Sourced, not executed, so `$JSON` from notify.sh is visible. Nothing here may
# exit, set shell options, or write to stdout — it runs inside somebody else's
# script, and the host parses that script's output.

# Resolve the player as a sibling of this file, through our own symlink chain,
# so the install location is not encoded anywhere.
if [ -z "${NOTIFYSOUND_PLAY:-}" ]; then
  ns_codex_hook_self="${BASH_SOURCE[0]}"
  ns_codex_hook_hops=0
  while [ -L "$ns_codex_hook_self" ] && [ "$ns_codex_hook_hops" -lt 32 ]; do
    ns_codex_hook_target="$(readlink "$ns_codex_hook_self")" || break
    case "$ns_codex_hook_target" in
      /*) ns_codex_hook_self="$ns_codex_hook_target" ;;
      *)  ns_codex_hook_self="$(dirname "$ns_codex_hook_self")/$ns_codex_hook_target" ;;
    esac
    ns_codex_hook_hops=$((ns_codex_hook_hops + 1))
  done
  ns_codex_hook_play="$(cd "$(dirname "$ns_codex_hook_self")" 2>/dev/null && pwd)/notifysound-play.sh"
else
  ns_codex_hook_play="$NOTIFYSOUND_PLAY"
fi

# The payload comes from our own arguments. `source` inherits the caller's
# positional parameters, so this works wherever the line sits — which is what
# lets the installer put it at a fixed position (right after the shebang)
# instead of having to run after the user's script assigns JSON. Reading $JSON
# as well keeps an already-installed 2.1.x line working until it is migrated.
case "$*${JSON:-}" in
  *agent-turn-complete*)
    if [ -x "$ns_codex_hook_play" ] || [ -r "$ns_codex_hook_play" ]; then
      bash "$ns_codex_hook_play" codex >/dev/null 2>&1
    fi
    ;;
esac

unset ns_codex_hook_self ns_codex_hook_target ns_codex_hook_hops ns_codex_hook_play
