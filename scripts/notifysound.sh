#!/usr/bin/env bash
# notifysound - CLI for the agent turn-completion sound
set -euo pipefail

# This script may be invoked through a symlink (e.g. ~/.local/bin/notifysound),
# so follow the link chain to find where the real script lives. macOS ships BSD
# readlink, which has no -f, and neither realpath nor greadlink is guaranteed,
# hence the hand-rolled portable loop.
ns_self="${BASH_SOURCE[0]}"
while [ -L "$ns_self" ]; do
  ns_target="$(readlink "$ns_self")"
  case "$ns_target" in
    /*) ns_self="$ns_target" ;;
    *)  ns_self="$(dirname "$ns_self")/$ns_target" ;;
  esac
done
NS_SCRIPT_DIR="$(cd "$(dirname "$ns_self")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/config.sh
source "$NS_SCRIPT_DIR/lib/config.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/install.sh
source "$NS_SCRIPT_DIR/lib/install.sh"

NS_HOSTS="claude codex"

die() { printf '%s\n' "$*" >&2; exit 1; }

require_jq() {
  command -v jq >/dev/null 2>&1 || { printf 'jq is required. Install it with: brew install jq\n' >&2; exit 2; }
}

usage() {
  cat <<'EOF'
Usage: notifysound <command> [options]

State
  on  [--host claude|codex]      turn the sound on (host-scoped if --host given)
  off [--host claude|codex]      turn the sound off
  reset --host claude|codex      clear a host override (follow the global switch)
  status                         show current state, hook health, and skill links

Sounds
  list                           list registered sounds (built-in and user)
  add <name> <file> [--force]    copy a file into the library and register it
  use <name>                     switch the current sound
  remove <name>                  unregister a user sound and delete its file
  test [name]                    play immediately (ignores the enabled switch)

Install
  install                        install Claude/Codex hooks and register built-ins (idempotent)
  uninstall                      remove the hooks
  migrate                        move an installation from an older layout (opt-in)
EOF
}

parse_host() {
  local host=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --host)
        shift
        [ $# -gt 0 ] || die "--host requires a host name."
        host="$1"
        ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done
  if [ -n "$host" ]; then
    case " $NS_HOSTS " in
      *" $host "*) : ;;
      *) die "unknown host: $host (available: $NS_HOSTS)" ;;
    esac
  fi
  printf '%s' "$host"
}

cmd_toggle() {
  local value="$1"; shift
  local host
  host="$(parse_host "$@")" || exit 1
  if [ -n "$host" ]; then
    # $value is an internal true/false literal, never user input, so it stays in
    # the filter text. $host is passed with --arg to keep it out of the filter
    # structure entirely.
    ns_set ".hosts[\$h] = $value" h "$host"
    printf '%s sound: %s\n' "$host" "$([ "$value" = true ] && echo on || echo off)"
  else
    ns_set ".enabled = $value"
    printf 'global sound: %s\n' "$([ "$value" = true ] && echo on || echo off)"
  fi
}

cmd_reset() {
  local host
  host="$(parse_host "$@")" || exit 1
  [ -n "$host" ] || die "reset requires --host."
  # shellcheck disable=SC2016 # $h is a jq --arg variable; bash must not expand it
  ns_set '.hosts[$h] = null' h "$host"
  printf '%s override cleared (follows the global switch)\n' "$host"
}

cmd_status() {
  local global sound sound_path host override eff
  global="$(ns_get '.enabled')"
  sound="$(ns_get '.sound')"
  printf 'global: %s\n' "$([ "$global" = true ] && echo on || echo off)"
  for host in $NS_HOSTS; do
    # shellcheck disable=SC2016 # $h is a jq --arg variable; bash must not expand it
    override="$(ns_get '.hosts[$h]' h "$host")"
    eff="$(ns_effective "$host")"
    if [ "$override" = "null" ]; then
      printf '  %-7s %s\n' "$host" "$([ "$eff" = true ] && echo on || echo off)"
    else
      printf '  %-7s %s  (override)\n' "$host" "$([ "$eff" = true ] && echo on || echo off)"
    fi
  done
  if sound_path="$(ns_current_sound_path 2>/dev/null)"; then
    printf 'sound: %s (%s)\n' "$sound" "$sound_path"
  else
    printf 'sound: %s (not registered or file missing)\n' "$sound"
  fi
  printf 'hooks\n'
  report_hook_install claude "$NS_CLAUDE_SETTINGS" ns_claude_signed_count
  report_hook_install codex  "$NS_CODEX_NOTIFY"     ns_codex_signed_count ns_codex_hook_ok
  report_player_install
  report_skill_links
}

# Read-only diagnosis. Creates nothing and repairs nothing — a missing link is
# information, not a failure (plenty of people run only one harness), so this
# never affects the exit code.
report_skill_links() {
  printf 'skills\n'
  local dir link state
  for dir in "${NS_SKILL_DIRS[@]}"; do
    link="$dir/notifysound"
    if [ ! -d "$dir" ]; then
      state="n/a (dir absent)"
    elif [ -L "$link" ]; then
      if [ -e "$link" ]; then state="linked"; else state="broken link"; fi
    elif [ -d "$link" ]; then
      state="present (copy)"
    else
      state="not linked"
    fi
    printf '  %-44s %s\n' "$link" "$state"
  done
}

# report_hook_install <label> <target-file> <count-fn>
# Read-only diagnosis: it installs nothing and repairs nothing. <count-fn> is
# the name of a function taking <target-file> and printing the number of signed
# entries (ns_claude_signed_count / ns_codex_signed_count, lib/install.sh).
report_hook_install() {
  local label="$1" target="$2" count_fn="$3" reach_fn="${4:-}" n
  if [ ! -f "$target" ]; then
    printf '  %-7s n/a (%s missing)\n' "$label" "$target"
    return 0
  fi
  n="$("$count_fn" "$target")" || n=""
  if [ -z "$n" ]; then
    printf '  %-7s unreadable (%s)\n' "$label" "$target"
  elif [ "$n" -eq 0 ]; then
    printf '  %-7s not installed\n' "$label"
  elif [ "$n" -eq 1 ]; then
    if [ -n "$reach_fn" ] && ! "$reach_fn"; then
      printf '  %-7s broken (hook line present, but %s is missing)\n' "$label" "$NS_CODEX_HOOK"
    else
      printf '  %-7s installed\n' "$label"
    fi
  else
    printf '  %-7s installed (warning: %s duplicate signed hooks)\n' "$label" "$n"
  fi
}

report_player_install() {
  if ns_player_ok; then
    printf '  %-7s ok (%s)\n' player "$NS_PLAY_PATH"
  elif [ -L "$NS_PLAY_PATH" ]; then
    printf '  %-7s broken (dangling symlink: %s)\n' player "$NS_PLAY_PATH"
  else
    printf '  %-7s broken (not executable: %s)\n' player "$NS_PLAY_PATH"
  fi
}

NS_EXTS="mp3 wav aiff m4a aac"

sound_path_of() {
  local name="$1"
  # shellcheck disable=SC2016 # $n is a jq --arg variable; bash must not expand it
  ns_get '.sounds[$n] // empty' n "$name"
}

cmd_add() {
  [ $# -ge 2 ] || die "usage: notifysound add <name> <file> [--force]"
  local name="$1" src="$2"; shift 2
  local force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1 ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done

  case "$name" in
    ''|*[!A-Za-z0-9_-]*) die "name may contain only letters, digits, hyphen and underscore: $name" ;;
  esac
  [ -f "$src" ] || die "file not found: $src"

  local ext="${src##*.}"
  ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"
  case " $NS_EXTS " in
    *" $ext "*) : ;;
    *) die "unsupported extension: .$ext (allowed: $NS_EXTS)" ;;
  esac

  local existing
  existing="$(sound_path_of "$name")"
  if [ -n "$existing" ] && [ "$force" -eq 0 ]; then
    die "name already registered: $name (use --force to overwrite)"
  fi

  # Copy the new file to its destination under a temporary name and confirm the
  # copy succeeded BEFORE deleting the old file and updating the registration.
  # The other order (delete first) leaves the config pointing at a file that no
  # longer exists if cp fails halfway, which silently breaks playback.
  local dest tmp_dest
  dest="$(ns_sounds_dir)/$name.$ext"
  tmp_dest="$(mktemp "$(ns_sounds_dir)/.${name}.XXXXXX")" || die "could not create a temporary file."
  if ! cp "$src" "$tmp_dest" 2>/dev/null; then
    rm -f "$tmp_dest"
    die "could not copy the file: $src"
  fi
  mv "$tmp_dest" "$dest"

  # Delete the file the old registration pointed at — but only after proving it
  # is one of ours. The path comes out of config.json, which is untrusted input:
  # a hand-edited or corrupted entry would otherwise make --force delete an
  # arbitrary file. This also covers built-ins, whose files live in the install
  # tree or /System/Library/Sounds and must survive an override.
  if [ -n "$existing" ] && [ "$existing" != "$dest" ] && [ -f "$existing" ] \
     && ns_is_managed_sound_path "$existing"; then
    ns_delete_managed_sound "$existing"
  fi
  # shellcheck disable=SC2016 # $n/$d are jq --arg variables; bash must not expand them
  ns_set '.sounds[$n] = $d' n "$name" d "$dest"

  local current
  current="$(ns_get '.sound')"
  if [ "$current" = "null" ] || [ -z "$current" ]; then
    # shellcheck disable=SC2016 # $n is a jq --arg variable; bash must not expand it
    ns_set '.sound = $n' n "$name"
    printf 'registered and set as current: %s -> %s\n' "$name" "$dest"
  else
    printf 'registered: %s -> %s\n' "$name" "$dest"
  fi
}

cmd_list() {
  local current names name path kind
  current="$(ns_get '.sound')"
  names="$(ns_get '.sounds | keys[]?')"
  if [ -z "$names" ]; then
    printf 'no sounds registered. notifysound add <name> <file>\n'
    return 0
  fi
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    path="$(sound_path_of "$name")"
    if ns_is_builtin_path "$path"; then kind=builtin; else kind=user; fi
    if [ "$name" = "$current" ]; then
      printf '* %-12s %-7s %s\n' "$name" "$kind" "$path"
    else
      printf '  %-12s %-7s %s\n' "$name" "$kind" "$path"
    fi
  done <<< "$names"
}

cmd_use() {
  [ $# -eq 1 ] || die "usage: notifysound use <name>"
  local name="$1" path
  path="$(sound_path_of "$name")"
  if [ -z "$path" ]; then
    printf 'not a registered name: %s\n\nregistered sounds:\n' "$name" >&2
    cmd_list >&2
    exit 1
  fi
  # shellcheck disable=SC2016 # $n is a jq --arg variable; bash must not expand it
  ns_set '.sound = $n' n "$name"
  printf 'current sound: %s (%s)\n' "$name" "$path"
}

cmd_remove() {
  [ $# -eq 1 ] || die "usage: notifysound remove <name>"
  local name="$1" path current
  path="$(sound_path_of "$name")"
  [ -n "$path" ] || die "not a registered name: $name"
  # Refuse before anything is deleted or written, so a rejected remove leaves
  # the config byte-identical.
  if ns_is_builtin_path "$path"; then
    die "'$name' is a built-in sound and cannot be removed (reinstalling would bring it back). Pick a different sound instead: notifysound use <name>"
  fi
  current="$(ns_get '.sound')"
  if [ "$name" = "$current" ]; then
    die "that is the current sound. Pick another first: notifysound use <name>"
  fi
  # The registered path is untrusted input. Unregistering is always safe, but
  # deleting is only allowed once the file is proven to live in our own sounds
  # directory — otherwise a corrupted config turns `remove` into a delete-any-
  # file primitive.
  if ns_is_managed_sound_path "$path"; then
    ns_delete_managed_sound "$path"
    # shellcheck disable=SC2016 # $n is a jq --arg variable; bash must not expand it
    ns_set 'del(.sounds[$n])' n "$name"
    printf 'removed: %s\n' "$name"
  else
    # shellcheck disable=SC2016 # $n is a jq --arg variable; bash must not expand it
    ns_set 'del(.sounds[$n])' n "$name"
    printf 'unregistered: %s\n' "$name"
    printf 'left the file in place, it is outside the managed sound library: %s\n' "$path"
  fi
}

cmd_test() {
  local name path player
  if [ $# -eq 1 ]; then
    name="$1"
    path="$(sound_path_of "$name")"
    [ -n "$path" ] || die "not a registered name: $name"
  else
    path="$(ns_current_sound_path)" || die "no sound to play. Register one with: notifysound add <name> <file>"
  fi
  [ -f "$path" ] || die "file missing: $path"
  player="${NOTIFYSOUND_PLAYER:-afplay}"
  "$player" "$path" || die "playback failed: $path"
  printf 'playing: %s\n' "$path"
}

NS_CLAUDE_SETTINGS="${NOTIFYSOUND_CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
NS_CODEX_NOTIFY="${NOTIFYSOUND_CODEX_NOTIFY:-$HOME/.codex/hooks/notify.sh}"

# Colon-separated (PATH-style) and kept in an array rather than a space-
# separated string, so a directory name containing a space still works.
if [ -n "${NOTIFYSOUND_SKILL_DIRS:-}" ]; then
  IFS=: read -r -a NS_SKILL_DIRS <<< "$NOTIFYSOUND_SKILL_DIRS"
else
  NS_SKILL_DIRS=("$HOME/.claude/skills" "$HOME/.agents/skills" "$HOME/.codex/skills")
fi

# The two hooks are independent: a failure on one side does not roll back the
# other. Each reports its own result, and the command exits non-zero if any of
# them failed (printing a success line on failure was the core defect fixed in
# v1 Task 5).
# Exit status contract, written down because this is the third time in this
# project that a status stopped meaning anything as it crossed a layer:
#
#   0  everything asked for happened
#   1  user error (bad argument, unknown name)
#   2  environment error, or a step meant to change something did not
#   3  nothing was changed on the Codex side, because it holds a pre-2.2 layout
#      and `notifysound migrate` is needed first
#
# 3 has to survive to the process exit status: install.sh distinguishes
# "refused, nothing touched" from "tried and broke". When both happen, 2 wins —
# the more severe fact is the one the caller must act on.
cmd_install() {
  local failed=0 need_migrate=0 codex_rc
  # Registration runs before the hooks, so that a hook failure still leaves a
  # usable sound library behind.
  local picked pick_rc
  if ns_register_builtins; then
    printf 'built-in sounds registered\n'
    # A fresh install would otherwise be registered, wired up, and completely
    # silent until the user happened to run `use`. Only fills a null selection.
    #
    # pick_rc is captured rather than tested inline: inside an `if` condition a
    # non-zero return is invisible to set -e and then discarded, so a failed
    # config write here used to be reported as a successful install.
    pick_rc=0
    picked="$(ns_pick_default_sound)" || pick_rc=$?
    if [ "$pick_rc" -ne 0 ]; then
      printf 'could not choose a default sound (is the config writable?)\n' >&2
      failed=1
    elif [ -n "$picked" ]; then
      printf 'current sound: %s (nothing was selected yet)\n' "$picked"
    fi
  else
    printf 'could not register built-in sounds\n' >&2
    failed=1
  fi
  if [ -f "$NS_CLAUDE_SETTINGS" ]; then
    if ns_install_claude "$NS_CLAUDE_SETTINGS"; then
      printf 'Claude Code hook installed: %s\n' "$NS_CLAUDE_SETTINGS"
    else
      printf 'Claude Code hook install failed: %s\n' "$NS_CLAUDE_SETTINGS" >&2
      failed=1
    fi
  else
    printf 'skipped (file not found): %s\n' "$NS_CLAUDE_SETTINGS"
  fi
  if [ -f "$NS_CODEX_NOTIFY" ]; then
    # `|| rc=$?` rather than a bare call followed by `case $?`: under set -e a
    # bare non-zero call aborts the shell right there, so the status escaped
    # correctly but the explanation never printed. The status surviving is not
    # the same as its meaning surviving.
    codex_rc=0
    ns_install_codex "$NS_CODEX_NOTIFY" || codex_rc=$?
    case $codex_rc in
      0) printf 'Codex CLI hook installed: %s\n' "$NS_CODEX_NOTIFY" ;;
      3) report_needs_migrate "$NS_CODEX_NOTIFY"; need_migrate=1 ;;
      *) printf 'Codex CLI hook install failed: %s\n' "$NS_CODEX_NOTIFY" >&2; failed=1 ;;
    esac
  else
    printf 'skipped (file not found): %s\n' "$NS_CODEX_NOTIFY"
  fi
  [ "$failed" -eq 0 ] || exit 2
  [ "$need_migrate" -eq 0 ] || exit 3
}

# rc 3 from the codex functions means an installation from an older layout is
# sitting somewhere in the file. We refuse rather than add a second hook beside
# one we cannot see, and we do not rewrite their file uninvited.
report_needs_migrate() {
  printf 'Codex CLI hook not changed: %s\n' "$1" >&2
  printf 'It still holds a notifysound hook in the pre-2.2 layout.\n' >&2
  printf "Run: notifysound migrate   (then run install again)\n" >&2
  printf '(migrate is the only command that edits your script by position; it is\n' >&2
  printf ' opt-in for that reason. Back the file up first if you want to be sure.)\n' >&2
}

# The one command that reasons about where things sit in the user's file.
cmd_migrate() {
  local failed=0 before after
  if [ -f "$NS_CODEX_NOTIFY" ]; then
    before="$(ns_codex_legacy_present "$NS_CODEX_NOTIFY")"
    if [ "$before" = "0" ]; then
      printf 'nothing to migrate: %s\n' "$NS_CODEX_NOTIFY"
    else
      ns_backup "$NS_CODEX_NOTIFY" >/dev/null || { printf 'could not back up %s\n' "$NS_CODEX_NOTIFY" >&2; exit 2; }
      if ns_codex_migrate "$NS_CODEX_NOTIFY"; then
        after="$(ns_codex_legacy_present "$NS_CODEX_NOTIFY")"
        if [ "$after" = "0" ]; then
          printf 'migrated: %s\n' "$NS_CODEX_NOTIFY"
          printf 'now run: notifysound install\n'
        else
          printf 'migration did not clear the old layout in %s\n' "$NS_CODEX_NOTIFY" >&2
          printf 'Edit it by hand: remove the notifysound line or block, then run install.\n' >&2
          failed=1
        fi
      else
        printf 'migration failed: %s\n' "$NS_CODEX_NOTIFY" >&2
        failed=1
      fi
    fi
  else
    printf 'skipped (file not found): %s\n' "$NS_CODEX_NOTIFY"
  fi
  [ "$failed" -eq 0 ] || exit 2
}

cmd_uninstall() {
  local failed=0 need_migrate=0 codex_rc
  if [ -f "$NS_CLAUDE_SETTINGS" ]; then
    if ns_uninstall_claude "$NS_CLAUDE_SETTINGS"; then
      printf 'Claude Code hook removed\n'
    else
      printf 'Claude Code hook removal failed: %s\n' "$NS_CLAUDE_SETTINGS" >&2
      failed=1
    fi
  fi
  if [ -f "$NS_CODEX_NOTIFY" ]; then
    codex_rc=0
    ns_uninstall_codex "$NS_CODEX_NOTIFY" || codex_rc=$?
    case $codex_rc in
      0) printf 'Codex CLI hook removed\n' ;;
      3) report_needs_migrate "$NS_CODEX_NOTIFY"; need_migrate=1 ;;
      *) printf 'Codex CLI hook removal failed: %s\n' "$NS_CODEX_NOTIFY" >&2; failed=1 ;;
    esac
  fi
  [ "$failed" -eq 0 ] || exit 2
  [ "$need_migrate" -eq 0 ] || exit 3
  return 0
}

main() {
  require_jq
  ns_init
  [ $# -gt 0 ] || { usage; exit 1; }
  local sub="$1"; shift
  case "$sub" in
    on)     cmd_toggle true "$@" ;;
    off)    cmd_toggle false "$@" ;;
    reset)  cmd_reset "$@" ;;
    status) cmd_status ;;
    list)   cmd_list ;;
    add)    cmd_add "$@" ;;
    use)    cmd_use "$@" ;;
    remove) cmd_remove "$@" ;;
    test)   cmd_test "$@" ;;
    install)   cmd_install ;;
    uninstall) cmd_uninstall ;;
    migrate)   cmd_migrate ;;
    help|-h|--help) usage ;;
    *)      printf 'unknown command: %s\n\n' "$sub" >&2; usage >&2; exit 1 ;;
  esac
}

# When sourced (so tests can exercise individual functions) main must not run.
# It only runs on direct execution, so normal CLI use is unaffected.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
