#!/usr/bin/env bash
# notifysound - host hook install/uninstall (idempotent)
# Paths are taken as arguments so tests never touch real configuration files.

NS_SIG="# notifysound"
NS_PLAY_PATH="${NOTIFYSOUND_PLAY:-$HOME/.claude/hooks/notifysound-play.sh}"

# "Is this line/command ours?" — anchored at the END of the line, not a bare
# substring search. A substring match also hits a user's own comment that merely
# mentions us (`say hi   # notifysound was here once`), and deleting somebody's
# hook because they wrote our name in a comment is the same class of bug as the
# hardcoded-filename heuristic this replaced. Everything we emit ends with the
# signature and nothing else does.
#
# Note what this deliberately does NOT require: the player's filename. An
# earlier version demanded `notifysound-play\.sh` in the same line, which tied
# the signature to a path the user can legitimately change (NOTIFYSOUND_PLAY) —
# the hook was written correctly but then failed its own verification, so
# install reported failure on a successful install.
NS_SIG_RE='# notifysound$'

# Single-quote a value for safe inclusion in generated shell source. Both hooks
# are shell text that the host will execute, so an unquoted path is a command
# injection: NOTIFYSOUND_PLAY (or merely a $HOME containing a shell
# metacharacter, or a space) would otherwise run as code at every turn end.
ns_shell_quote() {
  local s="$1"
  printf "'%s'" "${s//\'/\'\\\'\'}"
}

# A newline in the player path cannot be represented in either hook format —
# it would split the generated block. Refuse rather than emit broken shell.
ns_play_path_ok() {
  case "$NS_PLAY_PATH" in
    *"
"*) return 1 ;;
  esac
  return 0
}

# Follow a symlink chain to the real file. Configuration files are very often
# symlinks into a dotfiles repository; writing with the usual `tmp && mv` would
# replace the LINK with a regular file, silently detaching the user's managed
# original. Resolving first means we edit what they actually track.
ns_real_file() {
  local self="$1" target
  while [ -L "$self" ]; do
    target="$(readlink "$self")" || break
    case "$target" in
      /*) self="$target" ;;
      *)  self="$(dirname "$self")/$target" ;;
    esac
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

ns_claude_command() {
  printf 'bash %s claude; printf %s  %s\n' \
    "$(ns_shell_quote "$NS_PLAY_PATH")" "'{\"continue\":true}\\n'" "$NS_SIG"
}

# Removes ONLY entries carrying our signature. An earlier version also removed
# entries matching a hardcoded sound filename, as a one-off migration aid; on
# anybody else's machine that deletes a hook we never wrote, so it is gone.
#
# A jq/mv failure is propagated as rc 2 (environment error): the original file
# is not damaged (an empty tmp means mv is skipped by &&), but the caller still
# needs to know whether the removal actually happened.
ns_claude_strip() {
  local settings tmp
  settings="$(ns_real_file "$1")"
  tmp="$(mktemp)"
  jq --arg re "$NS_SIG_RE" '
    .hooks.Stop = ((.hooks.Stop // []) | map(
      (.hooks // []) as $orig
      | ($orig | map(select((.command // "") | test($re) | not))) as $kept
      | if ($orig | length) != ($kept | length) and ($kept | length) == 0
        then empty                 # a group we emptied ourselves: drop it
        else .hooks = $kept        # anything else keeps its shape, empty or not
        end
    ))
  ' "$settings" > "$tmp" 2>/dev/null && mv "$tmp" "$settings" && return 0
  rm -f "$tmp"
  return 2
}

# Confirms exactly one signed Stop hook is present. jq can succeed while doing
# nothing useful (a filter that matches zero entries in an unexpected document),
# so rather than trusting the exit status of awk/jq, count the result directly.
ns_claude_signed_count() {
  local settings
  settings="$(ns_real_file "$1")"
  jq --arg re "$NS_SIG_RE" \
    '[.hooks.Stop[]?.hooks[]? | select((.command // "") | test($re))] | length' \
    "$settings" 2>/dev/null
}

ns_install_claude() {
  local settings tmp cmd
  settings="$(ns_real_file "$1")"
  [ -f "$settings" ] || return 1
  ns_play_path_ok || return 2
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
  # jq/mv finishing with rc 0 is not itself evidence of installation (a filter
  # can quietly pass through an unexpected structure). Re-read the result and
  # count the signed hooks to confirm exactly one exists.
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

# Removes the legacy afplay block and any existing signed block, then inserts
# the signed block ahead of exec.
ns_install_codex() {
  local notify tmp
  notify="$(ns_real_file "$1")"
  [ -f "$notify" ] || return 1
  ns_play_path_ok || return 2
  ns_backup "$notify" >/dev/null || return 2
  ns_codex_strip "$notify" || return 2

  tmp="$(mktemp)"
  if ! { awk -v play="$(ns_shell_quote "$NS_PLAY_PATH")" '
    /^exec / && !done {
      print "if [[ \"$JSON\" == *\"agent-turn-complete\"* ]]; then"
      print "  bash " play " codex   # notifysound"
      print "fi"
      print ""
      done = 1
    }
    { print }
  ' "$notify" > "$tmp" && mv "$tmp" "$notify"; }; then
    rm -f "$tmp"
    return 2
  fi
  chmod +x "$notify"
  # awk finishing with rc 0 does not guarantee the insertion happened: with no
  # `^exec ` line to anchor on, awk quietly copies the file and never sets done.
  # Count the signed lines in the result — and require exactly one, so that a
  # duplicate is a failure rather than a pass (grep -q could not tell them
  # apart). Declaration and assignment are split because grep exits 1 on zero
  # matches and `local n="$(...)"` would swallow that.
  local n
  n="$(ns_codex_signed_count "$notify")"
  [ "${n:-0}" = "1" ] || return 2
  return 0
}

# One awk program serves both stripping and counting, so the definition of
# "our block" lives in exactly one place and the two can never disagree.
#
# It matches by EXACT SHAPE, not by "contains a signature somewhere". We always
# generate precisely three lines:
#
#     if [[ "$JSON" == *"agent-turn-complete"* ]]; then
#       bash '<player>' codex   # notifysound
#     fi
#
# so a block is ours only when it is exactly those three lines. Anything else —
# a user block with a signature-shaped line nested inside it, extra statements
# before or after, an unterminated block — is emitted verbatim.
#
# The previous version asked "did any line in this block look signed?", which
# let a signature nested inside somebody's own block condemn the whole block and
# destroy their code. Counting nesting depth was the obvious alternative and is
# the wrong tool: tracking every construct a bare `fi` might close is a shell
# parser, and getting that subtly wrong deletes user code again. Recognising
# only the exact text we emit cannot.
#
# A block start while already inside a block means the previous one was never
# terminated; its buffer is flushed verbatim first. An unterminated block at EOF
# is flushed by the END rule for the same reason.
# shellcheck disable=SC2016 # this is an awk program, not shell; $0/$JSON are awk's
NS_CODEX_AWK='
function flush(  i) { for (i = 0; i < n; i++) if (mode == "strip") print buf[i]; n = 0 }
function is_ours() { return (n == 3 && buf[1] ~ sig_re && buf[2] == "fi") }
/^if \[\[ "\$JSON" == \*"agent-turn-complete"\* \]\]; then$/ {
  if (inblock) flush()
  inblock = 1; n = 0
  buf[n++] = $0
  next
}
inblock {
  buf[n++] = $0
  if ($0 == "fi") {
    inblock = 0
    if (is_ours()) { count++; n = 0; blank_pending = 1 }
    else flush()
  }
  next
}
blank_pending && /^$/ { blank_pending = 0; next }
{ blank_pending = 0; if (mode == "strip") print }
END { if (inblock) flush(); if (mode == "count") print count + 0 }
'

ns_codex_strip() {
  local notify tmp
  notify="$(ns_real_file "$1")"
  tmp="$(mktemp)"
  if ! { awk -v mode=strip -v sig_re="$NS_SIG_RE" "$NS_CODEX_AWK" "$notify" > "$tmp" \
         && mv "$tmp" "$notify"; }; then
    rm -f "$tmp"
    return 2
  fi
  chmod +x "$notify"
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
# Writes nothing. Reuses $NS_SIG from above rather than hardcoding the
# signature string in a third place.

# Number of signed codex blocks. Returns 0 if the file is absent (the caller
# must decide about file existence first — "not installed" and "not applicable"
# mean different things).
# `grep -c` prints "0" on stdout and exits 1 when there are no matches. Taking
# that exit status directly with `||` would kill the script under set -e, so it
# is absorbed with `|| true` inside the command substitution and only the
# captured value is returned.
ns_codex_signed_count() {
  local notify n
  notify="$(ns_real_file "$1")"
  [ -f "$notify" ] || { printf '0\n'; return 0; }
  n="$(awk -v mode=count -v sig_re="$NS_SIG_RE" "$NS_CODEX_AWK" "$notify" 2>/dev/null)"
  printf '%s\n' "${n:-0}"
}

# Only checks that the player executable actually resolves (i.e. is not a
# dangling symlink). Installs nothing, repairs nothing.
ns_player_ok() {
  [ -x "$NS_PLAY_PATH" ]
}
