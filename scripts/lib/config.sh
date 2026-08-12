# shellcheck shell=bash
# notifysound - config access library
# Sourced by both the CLI and the player. Never executed directly.

# Follow a symlink chain to the real file and print its directory. macOS ships
# BSD readlink (no -f) and neither realpath nor greadlink is guaranteed, so the
# loop is hand-rolled. Circular chains are stopped by the kernel's ELOOP on the
# first readlink.
ns_resolve_dir() {
  local self="$1" target
  while [ -L "$self" ]; do
    target="$(readlink "$self")" || break
    case "$target" in
      /*) self="$target" ;;
      *)  self="$(dirname "$self")/$target" ;;
    esac
  done
  (cd "$(dirname "$self")" && pwd)
}

# This file lives at <install-root>/scripts/lib/config.sh, so the root is two
# levels up. Computed once at source time; the CLI and the player both get the
# install location for free just by sourcing this file, which is why neither of
# them has to know where it was installed.
NS_LIB_DIR="$(ns_resolve_dir "${BASH_SOURCE[0]}")"

ns_install_dir() {
  (cd "$NS_LIB_DIR/../.." && pwd)
}

# Built-in sounds ship inside the install tree, kept separate from the user's
# own library under NOTIFYSOUND_HOME so that reinstalling never touches it.
ns_builtin_dir() {
  printf '%s/sounds\n' "$(ns_install_dir)"
}

# Built-in-ness is decided by PATH, not by name. That makes `add --force
# <builtin-name>` self-consistent: the overriding copy lands in the user's own
# sounds directory, so from that moment the name is an ordinary, removable user
# sound. Deciding by name would leave that case ambiguous.
ns_is_builtin_path() {
  local path="$1" bdir udir
  udir="$(ns_sounds_dir)"
  # The user's own library wins outright. Without this precedence, a
  # NOTIFYSOUND_HOME pointed inside the install tree would make every sound the
  # user added look built-in, and `remove` would refuse to delete their files.
  case "$path" in
    "$udir"/*) return 1 ;;
  esac
  bdir="$(ns_builtin_dir)"
  case "$path" in
    /System/Library/Sounds/*) return 0 ;;
    "$bdir"/*)                return 0 ;;
  esac
  return 1
}

# Registers every manifest entry that is not registered yet. `//=` assigns only
# when the current value is null or absent, so a user's own entry of the same
# name always wins and reinstalling never clobbers it.
ns_register_builtins() {
  local manifest bdir name rel path
  bdir="$(ns_builtin_dir)"
  manifest="$bdir/builtin.tsv"
  [ -f "$manifest" ] || return 0
  while IFS=$'\t' read -r name rel; do
    [ -n "${name:-}" ] || continue
    case "$name" in \#*) continue ;; esac
    [ -n "${rel:-}" ] || continue
    case "$rel" in
      /*) path="$rel" ;;
      *)  path="$bdir/$rel" ;;
    esac
    # shellcheck disable=SC2016 # $n/$p are jq --arg variables; bash must not expand them
    ns_set '.sounds[$n] //= $p' n "$name" p "$path" || return 2
  done < "$manifest"
  return 0
}

ns_home() {
  printf '%s\n' "${NOTIFYSOUND_HOME:-$HOME/.claude/notifysound}"
}

ns_config_path() {
  printf '%s/config.json\n' "$(ns_home)"
}

ns_sounds_dir() {
  printf '%s/sounds\n' "$(ns_home)"
}

ns_init() {
  local config
  config="$(ns_config_path)"
  mkdir -p "$(ns_sounds_dir)"
  if [ ! -f "$config" ]; then
    cat > "$config" <<'JSON'
{
  "enabled": true,
  "sound": null,
  "hosts": { "claude": null, "codex": null },
  "sounds": {}
}
JSON
  fi
  return 0
}

ns_valid() {
  local config
  config="$(ns_config_path)"
  [ -f "$config" ] || return 2
  jq -e . "$config" >/dev/null 2>&1 || return 2
  return 0
}

# ns_get <filter> [argname argvalue]...
# Values are passed with --arg instead of being spliced into the filter text.
# User input (a sound name, say) spliced into the filter can rewrite the jq
# syntax itself — that was the jq injection fixed in v1 Task 4 round 1. --arg
# always treats a value as string data, so no character can alter the filter's
# structure.
ns_get() {
  local filter="$1"; shift
  local -a jqargs=()
  while [ $# -ge 2 ]; do
    jqargs+=(--arg "$1" "$2")
    shift 2
  done
  ns_valid || return 2
  local config
  config="$(ns_config_path)"
  jq -r "${jqargs[@]+"${jqargs[@]}"}" "$filter" "$config"
}

# ns_set <filter> [argname argvalue]... — same --arg rule as ns_get.
ns_set() {
  local filter="$1"; shift
  local -a jqargs=()
  while [ $# -ge 2 ]; do
    jqargs+=(--arg "$1" "$2")
    shift 2
  done
  ns_valid || return 2
  local config tmp
  config="$(ns_config_path)"
  tmp="$(mktemp "$(ns_home)/.config.XXXXXX")"
  if jq "${jqargs[@]+"${jqargs[@]}"}" "$filter" "$config" > "$tmp" 2>/dev/null && mv "$tmp" "$config"; then
    return 0
  fi
  rm -f "$tmp"
  return 2
}

ns_effective() {
  local host="$1" override global
  # shellcheck disable=SC2016 # $h is a jq --arg variable; bash must not expand it
  override="$(ns_get '.hosts[$h]' h "$host")" || return 2
  if [ "$override" = "true" ] || [ "$override" = "false" ]; then
    printf '%s\n' "$override"
    return 0
  fi
  global="$(ns_get '.enabled')" || return 2
  if [ "$global" = "true" ]; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
  return 0
}

ns_current_sound_path() {
  local name path
  name="$(ns_get '.sound')" || return 2
  [ -n "$name" ] && [ "$name" != "null" ] || return 1
  # shellcheck disable=SC2016 # $n is a jq --arg variable; bash must not expand it
  path="$(ns_get '.sounds[$n] // empty' n "$name")" || return 2
  [ -n "$path" ] || return 1
  [ -f "$path" ] || return 1
  printf '%s\n' "$path"
  return 0
}
