#!/usr/bin/env bash
# notifysound - host hook install/uninstall (idempotent)
# Paths are taken as arguments so tests never touch real configuration files.

NS_SIG="# notifysound"
NS_PLAY_PATH="${NOTIFYSOUND_PLAY:-$HOME/.claude/hooks/notifysound-play.sh}"

# "Is this line/command ours?" — deliberately narrow. A bare substring search for
# "# notifysound" also matches a user's own comment that merely mentions us
# (e.g. `say hi   # notifysound was here once`), and deleting somebody's hook
# because they wrote our name in a comment is the same class of bug as the
# hardcoded-filename heuristic this replaced. Ours always both invokes
# notifysound-play.sh and ends with the signature, so require both.
NS_SIG_RE='notifysound-play\.sh.*# notifysound$'

ns_backup() {
  local target="$1" stamp backup
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
    "$NS_PLAY_PATH" "'{\"continue\":true}\\n'" "$NS_SIG"
}

# Removes ONLY entries carrying our signature. An earlier version also removed
# entries matching a hardcoded sound filename, as a one-off migration aid; on
# anybody else's machine that deletes a hook we never wrote, so it is gone.
#
# A jq/mv failure is propagated as rc 2 (environment error): the original file
# is not damaged (an empty tmp means mv is skipped by &&), but the caller still
# needs to know whether the removal actually happened.
ns_claude_strip() {
  local settings="$1" tmp
  tmp="$(mktemp)"
  jq --arg re "$NS_SIG_RE" '
    (.hooks.Stop // []) as $stop
    | .hooks.Stop = (
        $stop
        | map(
            .hooks = ((.hooks // []) | map(
              select((.command // "") | test($re) | not)
            ))
          )
        | map(select((.hooks | length) > 0))
      )
  ' "$settings" > "$tmp" 2>/dev/null && mv "$tmp" "$settings" && return 0
  rm -f "$tmp"
  return 2
}

# Confirms exactly one signed Stop hook is present. jq can succeed while doing
# nothing useful (a filter that matches zero entries in an unexpected document),
# so rather than trusting the exit status of awk/jq, count the result directly.
ns_claude_signed_count() {
  local settings="$1"
  jq --arg re "$NS_SIG_RE" \
    '[.hooks.Stop[]?.hooks[]? | select((.command // "") | test($re))] | length' \
    "$settings" 2>/dev/null
}

ns_install_claude() {
  local settings="$1" tmp cmd
  [ -f "$settings" ] || return 1
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
  local settings="$1"
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
  local notify="$1" tmp
  [ -f "$notify" ] || return 1
  ns_backup "$notify" >/dev/null || return 2
  ns_codex_strip "$notify" || return 2

  tmp="$(mktemp)"
  if ! { awk -v play="$NS_PLAY_PATH" '
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

# Removes agent-turn-complete blocks ONLY when they carry our signature. An
# unsigned block belongs to the user and is emitted verbatim — v1 removed every
# such block, which on someone else's machine silently deletes notification
# logic they wrote themselves.
#
# The block has to be buffered because the decision (signed?) depends on lines
# inside it. `$0 == "fi"` closes the block without tracking nesting, which is
# safe here: a mis-detected early close makes the remaining lines fall through
# to the plain print rule, so they are still preserved. Only our own generated
# block is ever deleted, and it contains no nested if.
#
# Meeting a block start while already inside a block means the previous one was
# never terminated. Its buffer is flushed verbatim before the new block begins.
# Without that, our own inserted block gets absorbed into the user's unterminated
# block, and the first `fi` then marks the whole buffer signed — deleting their
# code along with ours. An unterminated block at EOF is flushed by the END rule
# for the same reason.
ns_codex_strip() {
  local notify="$1" tmp
  tmp="$(mktemp)"
  if ! { awk -v sig_re="$NS_SIG_RE" '
    function flush(  i) { for (i = 0; i < n; i++) print buf[i]; n = 0 }
    /^if \[\[ "\$JSON" == \*"agent-turn-complete"\* \]\]; then$/ {
      if (inblock) flush()
      inblock = 1; n = 0; signed = 0
      buf[n++] = $0
      next
    }
    inblock {
      buf[n++] = $0
      if ($0 ~ sig_re) signed = 1
      if ($0 == "fi") {
        inblock = 0
        if (signed) {
          blank_pending = 1
          n = 0
        } else {
          flush()
        }
      }
      next
    }
    blank_pending && /^$/ { blank_pending = 0; next }
    { blank_pending = 0; print }
    END { if (inblock) flush() }
  ' "$notify" > "$tmp" && mv "$tmp" "$notify"; }; then
    rm -f "$tmp"
    return 2
  fi
  chmod +x "$notify"
  return 0
}

ns_uninstall_codex() {
  local notify="$1"
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
  local notify="$1" n
  [ -f "$notify" ] || { printf '0\n'; return 0; }
  n="$(grep -cE "$NS_SIG_RE" "$notify" 2>/dev/null || true)"
  printf '%s\n' "${n:-0}"
}

# Only checks that the player executable actually resolves (i.e. is not a
# dangling symlink). Installs nothing, repairs nothing.
ns_player_ok() {
  [ -x "$NS_PLAY_PATH" ]
}
