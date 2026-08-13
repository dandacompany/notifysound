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
#
# `ours` is not just startswith + endswith: those two alone let ANYTHING sit in
# between, including text that closes our quote and runs other commands
# (`bash 'a'; echo pwned; : ' claude; printf …  # notifysound`). The middle must
# be a single quoted token, so it may not contain a quote of its own.
#
# `legacy` recognises the 2.0.0 form, which wrote the player path unquoted.
# It exists ONLY so that upgrading replaces it instead of leaving a second live
# hook behind, and it is pinned to the exact tail 2.0.0 emitted.
ns_claude_strip() {
  local settings tmp
  settings="$(ns_real_file "$1")"
  tmp="$(mktemp)"
  jq --arg pre "$NS_CLAUDE_PREFIX" --arg suf "$NS_CLAUDE_SUFFIX" \
    "$NS_CLAUDE_JQ_OURS"'
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

# The same predicate as ns_claude_strip. Kept in one string so the two can
# never drift apart — a stripper and a counter that disagree is how a "success"
# gets reported for a hook that is still there.
# shellcheck disable=SC2016 # this is a jq filter, not shell; $pre/$suf are jq vars
NS_CLAUDE_JQ_OURS='
  def middle: .[($pre | length):(length - ($suf | length))];
  def exact: startswith($pre) and endswith($suf)
             and (length >= (($pre | length) + ($suf | length)))
             and (middle | index("\u0027") | not);
  def legacy: startswith("bash /") and endswith($suf | ltrimstr("\u0027"))
              and (contains("notifysound-play.sh"));
  def ours: (.command // "") | (exact or legacy);
'

ns_claude_signed_count() {
  local settings
  settings="$(ns_real_file "$1")"
  jq --arg pre "$NS_CLAUDE_PREFIX" --arg suf "$NS_CLAUDE_SUFFIX" \
    "$NS_CLAUDE_JQ_OURS"'[.hooks.Stop[]?.hooks[]? | select(ours)] | length' \
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

# The user's notify.sh is never interpreted. Our line lives at ONE position —
# immediately after the shebang — and that position is the only thing examined.
#
# 2.1.1 tried to be careful about shell context instead, tracking heredocs so it
# would not match inside one. The approximation was wrong in both directions: it
# deleted a line inside a `<<\EOF` body (bash's backslash-quoted delimiter form,
# which the tracker did not know), and it mistook the ordinary data line
# `printf '%s\n' '<<EOF'` for an unterminated heredoc, skipped the rest of the
# file, found no installation, and inserted a second hook on every retry.
# Approximating shell grammar cannot be made safe; an exact version is a shell
# parser. So the question is no longer asked. A heredoc body cannot be line 2.
ns_codex_anchor() {
  local first
  first="$(head -n 1 "$1" 2>/dev/null)"
  case "$first" in
    '#!'*) printf '2\n' ;;
    *)     printf '1\n' ;;
  esac
}

ns_codex_line_at() {
  sed -n "${2}p" "$1" 2>/dev/null
}

# Is this exactly the line we generate? Fixed prefix, fixed suffix, and a middle
# that is one quoted token (no quote of its own), so nothing can be smuggled in.
ns_codex_is_ours() {
  local line="$1" mid
  case "$line" in
    "$NS_CODEX_PREFIX"*"$NS_CODEX_SUFFIX") : ;;
    *) return 1 ;;
  esac
  mid="${line#"$NS_CODEX_PREFIX"}"
  mid="${mid%"$NS_CODEX_SUFFIX"}"
  case "$mid" in *"'"*) return 1 ;; esac
  return 0
}

# Installed means: the anchor line is ours. Nothing else in the file counts,
# which is also why a comment elsewhere mentioning codex-hook.sh can no longer
# block an uninstall.
ns_codex_signed_count() {
  local notify n
  notify="$(ns_real_file "$1")"
  [ -f "$notify" ] || { printf '0\n'; return 0; }
  n="$(ns_codex_anchor "$notify")"
  if ns_codex_is_ours "$(ns_codex_line_at "$notify" "$n")"; then
    printf '1\n'
  else
    printf '0\n'
  fi
}

# Drift is now a question about one line, not a search: the anchor holds a
# SOURCE of our hook that is not exactly the line we write — our own
# installation after somebody hand-edited it. Inserting above it would leave two
# live sources, and a later uninstall would take only ours.
#
# It has to be a sourcing line, not merely a mention. Matching anything that
# contains the filename meant a plain `# documentation mentions codex-hook.sh`
# on line 2 refused every install and every uninstall — the tool locked out of
# its own file by a comment.
ns_codex_drift_count() {
  local notify n line base
  notify="$(ns_real_file "$1")"
  [ -f "$notify" ] || { printf '0\n'; return 0; }
  n="$(ns_codex_anchor "$notify")"
  line="$(ns_codex_line_at "$notify" "$n")"
  base="$(basename "$NS_CODEX_HOOK")"
  if [ -n "$line" ] && ! ns_codex_is_ours "$line"; then
    case "$line" in
      ". "*"$base"*|"source "*"$base"*) printf '1\n'; return 0 ;;
    esac
  fi
  printf '0\n'
}

ns_codex_strip() {
  local notify tmp n
  notify="$(ns_real_file "$1")"
  n="$(ns_codex_anchor "$notify")"
  ns_codex_is_ours "$(ns_codex_line_at "$notify" "$n")" || return 0
  tmp="$(mktemp)"
  if ! { awk -v skip="$n" 'NR != skip' "$notify" > "$tmp" && mv "$tmp" "$notify"; }; then
    rm -f "$tmp"
    return 2
  fi
  chmod +x "$notify"
  return 0
}

# --- one-time migration from earlier layouts ------------------------------
#
# 2.0.x and 2.1.x both inserted immediately before the first top-level `exec `,
# followed by a blank line. That is a POSITION, so migration can be positional
# too — it never scans the file for lines that look like ours, which is what
# made the heredoc question unavoidable before.
#
# Honest about the limit: text that reproduces one of those exact arrangements
# directly above a top-level exec would also be removed. That is a narrow,
# one-time path for upgrading real installations, not a general recogniser.
# shellcheck disable=SC2016 # this is an awk program, not shell
NS_MIGRATE_AWK='
function is_old_line(l,   t) {
  t = "codex   # notifysound"
  return (length(l) > length(t)) && (substr(l, length(l) - length(t) + 1) == t) &&
         (index(l, "notifysound-play.sh") > 0) && (substr(l, 1, 7) == "  bash ")
}
function is_old_source(l,   n) {
  n = length(l)
  return (substr(l, 1, length(pre)) == pre) && (n >= length(pre) + length(suf)) &&
         (substr(l, n - length(suf) + 1) == suf)
}
BEGIN { pre = ENVIRON["NS_AWK_PRE"]; suf = ENVIRON["NS_AWK_SUF"] }
{ line[NR] = $0 }
END {
  anchor = 0
  for (i = 1; i <= NR; i++) if (substr(line[i], 1, 5) == "exec ") { anchor = i; break }
  for (i = 1; i <= NR; i++) drop[i] = 0
  if (anchor > 0) {
    # 2.1.x: <our line> <blank> exec
    if (anchor >= 3 && line[anchor - 1] == "" && is_old_source(line[anchor - 2])) {
      drop[anchor - 1] = 1; drop[anchor - 2] = 1
    }
    # 2.0.x: if / bash …/ fi / <blank> / exec
    else if (anchor >= 5 && line[anchor - 1] == "" && line[anchor - 2] == "fi" &&
             is_old_line(line[anchor - 3]) &&
             line[anchor - 4] == "if [[ \"$JSON\" == *\"agent-turn-complete\"* ]]; then") {
      for (j = 1; j <= 4; j++) drop[anchor - j] = 1
    }
  }
  for (i = 1; i <= NR; i++) if (!drop[i]) print line[i]
}
'

ns_codex_migrate() {
  local notify tmp
  notify="$(ns_real_file "$1")"
  tmp="$(mktemp)"
  if ! { NS_AWK_PRE="$NS_CODEX_PREFIX" NS_AWK_SUF="$NS_CODEX_SUFFIX" \
         awk "$NS_MIGRATE_AWK" "$notify" > "$tmp" && mv "$tmp" "$notify"; }; then
    rm -f "$tmp"
    return 2
  fi
  chmod +x "$notify"
  return 0
}

# Inserts the single source line at the anchor. No `exec` is required any more:
# the hook reads its payload from "$@", so it no longer has to run after the
# user's script has assigned anything.
ns_install_codex() {
  local notify tmp line n
  notify="$(ns_real_file "$1")"
  [ -f "$notify" ] || return 1
  ns_path_representable "$NS_CODEX_HOOK" || return 2
  [ "$(ns_codex_drift_count "$notify")" = "0" ] || return 2
  ns_backup "$notify" >/dev/null || return 2
  ns_codex_strip "$notify" || return 2
  ns_codex_migrate "$notify" || return 2

  line="$(ns_codex_line)"
  n="$(ns_codex_anchor "$notify")"
  tmp="$(mktemp)"
  if ! { NS_AWK_LINE="$line" awk -v at="$n" '
    BEGIN { line = ENVIRON["NS_AWK_LINE"]; if (at == 1) print line }
    { print; if (NR == 1 && at == 2) print line }
  ' "$notify" > "$tmp" && mv "$tmp" "$notify"; }; then
    rm -f "$tmp"
    return 2
  fi
  chmod +x "$notify"
  # Verify the OUTCOME: the anchor line is ours.
  [ "$(ns_codex_signed_count "$notify")" = "1" ] || return 2
  return 0
}

ns_uninstall_codex() {
  local notify
  notify="$(ns_real_file "$1")"
  [ -f "$notify" ] || return 1
  [ "$(ns_codex_drift_count "$notify")" = "0" ] || return 2
  ns_backup "$notify" >/dev/null || return 2
  ns_codex_strip "$notify" || return 2
  ns_codex_migrate "$notify" || return 2
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
