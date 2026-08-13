#!/usr/bin/env bash
# notifysound - host hook install/uninstall (idempotent)
# Paths are taken as arguments so tests never touch real configuration files.
#
# DESIGN (2.1.0). Two adversarial review rounds kept producing the same class of
# defect, in both directions: a loose recogniser deleted hooks the user wrote,
# and a strict one failed to find our own installation and left duplicates. Both
# came from the same root — we used to put our LOGIC inside a file somebody else
# owns and then guess, by content, which parts were ours.
#
# So we stopped doing that:
#
#   * Codex gets exactly ONE generated line, which sources a file we own
#     (scripts/codex-hook.sh). All the behaviour lives on our side of the fence.
#   * Both recognisers match the FULL text we generate, anchored at both ends,
#     with only the path varying. Never a substring search.
#
# What that buys: an update never rewrites the user's script, the recogniser has
# one fixed shape to look for instead of a multi-line block to delimit, and a
# line that merely mentions notifysound cannot be mistaken for ours.

NS_SIG="# notifysound"
NS_PLAY_PATH="${NOTIFYSOUND_PLAY:-$HOME/.claude/hooks/notifysound-play.sh}"

# The sourced hook file, a sibling of the player inside the install tree.
NS_CODEX_HOOK="${NOTIFYSOUND_CODEX_HOOK:-$(dirname "$NS_PLAY_PATH")/codex-hook.sh}"

# --- exact shapes we generate ---------------------------------------------
# Recognition is "does this text equal what we would have written, apart from
# the path?" — expressed as a fixed prefix plus a fixed suffix, so there is no
# regex to mis-escape and no substring to over-match.

NS_CLAUDE_PREFIX="bash '"
NS_CLAUDE_SUFFIX="' claude; printf '{\"continue\":true}\\n'  $NS_SIG"
NS_CODEX_PREFIX=". '"
NS_CODEX_SUFFIX="'  $NS_SIG"

ns_claude_command() {
  printf '%s%s%s\n' "$NS_CLAUDE_PREFIX" "$(ns_shell_escape "$NS_PLAY_PATH")" "$NS_CLAUDE_SUFFIX"
}

ns_codex_line() {
  printf '%s%s%s\n' "$NS_CODEX_PREFIX" "$(ns_shell_escape "$NS_CODEX_HOOK")" "$NS_CODEX_SUFFIX"
}

# Escape a value for use INSIDE the single quotes of the shapes above. Both
# hooks are shell text the host executes, so an unquoted path is a command
# injection — NOTIFYSOUND_PLAY, or merely a $HOME containing a metacharacter or
# a space, would otherwise run as code at every turn end.
ns_shell_escape() {
  local s="$1"
  printf '%s' "${s//\'/\'\\\'\'}"
}

# A path containing a newline or a single quote cannot be represented in the
# fixed shapes above without breaking the exact-match property that everything
# else here depends on. Refuse, and refuse BEFORE anything is written.
ns_path_representable() {
  case "$1" in
    *"
"*|*"'"*) return 1 ;;
  esac
  return 0
}

# Follow a symlink chain to the real file. Configuration files are very often
# symlinks into a dotfiles repository; writing with the usual `tmp && mv` would
# replace the LINK with a regular file, detaching the user's tracked original.
#
# The hop counter is not decoration: readlink reads ONE level at a time, so the
# kernel's ELOOP never fires and a cycle (a -> b -> a) spins forever. On giving
# up we return what we have; callers treat it as an ordinary path and the usual
# existence checks reject it.
ns_real_file() {
  local self="$1" target hops=0
  while [ -L "$self" ] && [ "$hops" -lt 32 ]; do
    target="$(readlink "$self")" || break
    case "$target" in
      /*) self="$target" ;;
      *)  self="$(dirname "$self")/$target" ;;
    esac
    hops=$((hops + 1))
  done
  printf '%s\n' "$self"
}

ns_backup() {
  local target stamp backup
  target="$(ns_real_file "$1")"
  [ -f "$target" ] || return 0
  stamp="$(date +%Y%m%d%H%M%S)"
  # A second-resolution timestamp alone makes repeated calls within the same
  # second (the idempotency test runs install three times in a row) produce the
  # same filename, silently overwriting the previous backup. mktemp's XXXXXX
  # suffix guarantees a unique name per call. The prefix
  # (<path>.notifysound-bak-<stamp>) is kept so the .gitignore pattern
  # (*.notifysound-bak-*) and the backup-detection logic still match.
  backup="$(mktemp "$target.notifysound-bak-$stamp-XXXXXX")" || return 2
  cp "$target" "$backup" || { rm -f "$backup"; return 2; }
  printf '%s\n' "$backup"
}

# --- Claude Code ---------------------------------------------------------

# Removes only commands that match our full generated shape. A bare substring
# search for the marker also matches `echo user # notifysound`, and deleting
# somebody's hook because they wrote our name in it is exactly the defect this
# whole design exists to prevent.
#
# startswith/endswith rather than a regex: the command contains {, }, \n and
# quotes, all of which are regex-significant, and one mis-escape here silently
# widens or narrows what we delete.
ns_claude_strip() {
  local settings tmp
  settings="$(ns_real_file "$1")"
  tmp="$(mktemp)"
  jq --arg pre "$NS_CLAUDE_PREFIX" --arg suf "$NS_CLAUDE_SUFFIX" '
    def ours: (.command // "") | (startswith($pre) and endswith($suf));
    .hooks.Stop = ((.hooks.Stop // []) | map(
      (.hooks // []) as $orig
      | ($orig | map(select(ours | not))) as $kept
      | if ($orig | length) != ($kept | length) and ($kept | length) == 0
        then empty                 # a group we emptied ourselves: drop it
        else .hooks = $kept        # anything else keeps its shape, empty or not
        end
    ))
  ' "$settings" > "$tmp" 2>/dev/null && mv "$tmp" "$settings" && return 0
  rm -f "$tmp"
  return 2
}

ns_claude_signed_count() {
  local settings
  settings="$(ns_real_file "$1")"
  jq --arg pre "$NS_CLAUDE_PREFIX" --arg suf "$NS_CLAUDE_SUFFIX" \
    '[.hooks.Stop[]?.hooks[]? | select((.command // "") | (startswith($pre) and endswith($suf)))] | length' \
    "$settings" 2>/dev/null
}

ns_install_claude() {
  local settings tmp cmd
  settings="$(ns_real_file "$1")"
  [ -f "$settings" ] || return 1
  ns_path_representable "$NS_PLAY_PATH" || return 2
  ns_backup "$settings" >/dev/null || return 2
  ns_claude_strip "$settings" || return 2
  cmd="$(ns_claude_command)"
  tmp="$(mktemp)"
  if ! { jq --arg cmd "$cmd" '
    .hooks = (.hooks // {})
    | .hooks.Stop = ((.hooks.Stop // []) + [{
        matcher: "",
        hooks: [{ type: "command", command: $cmd, timeout: 5 }]
      }])
  ' "$settings" > "$tmp" 2>/dev/null && mv "$tmp" "$settings"; }; then
    rm -f "$tmp"
    return 2
  fi
  # jq/mv finishing with rc 0 is not itself evidence of installation. Re-read
  # the result and count.
  [ "$(ns_claude_signed_count "$settings")" = "1" ] || return 2
  return 0
}

ns_uninstall_claude() {
  local settings
  settings="$(ns_real_file "$1")"
  [ -f "$settings" ] || return 1
  ns_backup "$settings" >/dev/null || return 2
  ns_claude_strip "$settings" || return 2
  [ "$(ns_claude_signed_count "$settings")" = "0" ] || return 2
  return 0
}

# --- Codex CLI -----------------------------------------------------------

# One awk program serves both stripping and counting, so "is this line ours?"
# has a single definition that the two cannot disagree about.
#
# A line is ours when it starts with `. '` AND ends with `'  # notifysound` —
# the full text of the one line we generate, with only the quoted path varying.
# The path is passed through ENVIRON, not `awk -v`: -v processes escape
# sequences, so a path containing a literal backslash-n arrived as a real
# newline and corrupted the file before the failure was noticed.
#
# Residual, documented rather than papered over: a heredoc body containing that
# exact line would still be matched. The surface is one line instead of a
# multi-line block, and distinguishing shell from heredoc text requires a shell
# parser — which is what kept deleting user code when we tried to be clever.
# shellcheck disable=SC2016 # this is an awk program, not shell
NS_CODEX_AWK='
function ours(line,   n) {
  n = length(line)
  return (substr(line, 1, length(pre)) == pre) &&
         (n >= length(pre) + length(suf)) &&
         (substr(line, n - length(suf) + 1) == suf)
}
BEGIN { pre = ENVIRON["NS_AWK_PRE"]; suf = ENVIRON["NS_AWK_SUF"] }
ours($0) { count++; skip_blank = 1; next }
skip_blank && /^$/ { skip_blank = 0; next }
{ skip_blank = 0; if (mode == "strip") print }
END { if (mode == "count") print count + 0 }
'

ns_codex_strip() {
  local notify tmp
  notify="$(ns_real_file "$1")"
  tmp="$(mktemp)"
  if ! { NS_AWK_PRE="$NS_CODEX_PREFIX" NS_AWK_SUF="$NS_CODEX_SUFFIX" \
         awk -v mode=strip "$NS_CODEX_AWK" "$notify" > "$tmp" \
         && mv "$tmp" "$notify"; }; then
    rm -f "$tmp"
    return 2
  fi
  chmod +x "$notify"
  return 0
}

ns_codex_signed_count() {
  local notify n
  notify="$(ns_real_file "$1")"
  [ -f "$notify" ] || { printf '0\n'; return 0; }
  n="$(NS_AWK_PRE="$NS_CODEX_PREFIX" NS_AWK_SUF="$NS_CODEX_SUFFIX" \
       awk -v mode=count "$NS_CODEX_AWK" "$notify" 2>/dev/null)"
  printf '%s\n' "${n:-0}"
}

# Lines that reference our hook file but are NOT the exact line we generate:
# our own installation after somebody hand-edited it, most likely by adding a
# space or re-indenting.
#
# Widening the recogniser to cover them is the trap both review rounds walked
# into — a looser match starts deleting things we do not own. Instead we detect
# the situation and refuse, leaving the file untouched and saying what to fix.
# The alternative is a silent success that leaves two live source lines.
ns_codex_drift_count() {
  local notify base n
  notify="$(ns_real_file "$1")"
  [ -f "$notify" ] || { printf '0\n'; return 0; }
  base="$(basename "$NS_CODEX_HOOK")"
  n="$(NS_AWK_PRE="$NS_CODEX_PREFIX" NS_AWK_SUF="$NS_CODEX_SUFFIX" NS_AWK_BASE="$base" awk '
    function ours(line,   n) {
      n = length(line)
      return (substr(line, 1, length(pre)) == pre) &&
             (n >= length(pre) + length(suf)) &&
             (substr(line, n - length(suf) + 1) == suf)
    }
    BEGIN { pre = ENVIRON["NS_AWK_PRE"]; suf = ENVIRON["NS_AWK_SUF"]; base = ENVIRON["NS_AWK_BASE"] }
    index($0, base) > 0 && !ours($0) { count++ }
    END { print count + 0 }
  ' "$notify" 2>/dev/null)"
  printf '%s\n' "${n:-0}"
}

# Inserts the single source line ahead of the exec handoff. The line is passed
# through ENVIRON for the same escape-processing reason as above.
ns_install_codex() {
  local notify tmp line
  notify="$(ns_real_file "$1")"
  [ -f "$notify" ] || return 1
  ns_path_representable "$NS_CODEX_HOOK" || return 2
  # Refuse BEFORE the backup, so a drifted line leaves the file byte-identical.
  [ "$(ns_codex_drift_count "$notify")" = "0" ] || return 2
  ns_backup "$notify" >/dev/null || return 2
  ns_codex_strip "$notify" || return 2

  line="$(ns_codex_line)"
  tmp="$(mktemp)"
  if ! { NS_AWK_LINE="$line" awk '
    BEGIN { line = ENVIRON["NS_AWK_LINE"] }
    /^exec / && !done { print line; print ""; done = 1 }
    { print }
  ' "$notify" > "$tmp" && mv "$tmp" "$notify"; }; then
    rm -f "$tmp"
    return 2
  fi
  chmod +x "$notify"
  # awk finishing with rc 0 does not guarantee the insertion happened: with no
  # `^exec ` line to anchor on, awk quietly copies the file and never sets done.
  local n
  n="$(ns_codex_signed_count "$notify")"
  [ "${n:-0}" = "1" ] || return 2
  return 0
}

ns_uninstall_codex() {
  local notify
  notify="$(ns_real_file "$1")"
  [ -f "$notify" ] || return 1
  ns_backup "$notify" >/dev/null || return 2
  ns_codex_strip "$notify" || return 2
  [ "$(ns_codex_signed_count "$notify")" = "0" ] || return 2
  return 0
}

# --- Diagnostics (read-only, reused by status) ---------------------------
# Writes nothing, repairs nothing.

# Only checks that the player executable actually resolves (i.e. is not a
# dangling symlink).
ns_player_ok() {
  [ -x "$NS_PLAY_PATH" ]
}

# The codex line is only useful if the file it sources actually resolves.
# Counting the line and calling that "installed" was a lie: a shipped release
# wrote a line pointing at a file the installer never linked, and status
# reported it healthy.
ns_codex_hook_ok() {
  [ -r "$NS_CODEX_HOOK" ]
}
