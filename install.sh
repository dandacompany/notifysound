#!/usr/bin/env bash
# notifysound installer — turn-completion sounds for Claude Code and Codex CLI.
#
# Read this before running it. The script writes to:
#   ~/.local/share/notifysound              the install tree (replaced on every run)
#   ~/.local/bin/notifysound                CLI symlink
#   ~/.claude/hooks/notifysound-play.sh     player symlink
#   <each existing skills dir>/notifysound  symlink, into existing dirs only
#   ~/.claude/settings.json                 one Stop hook, tagged "# notifysound"
#   ~/.codex/hooks/notify.sh                one block, tagged "# notifysound"
#
# It never touches your sounds or settings under ~/.claude/notifysound.
# Re-running is how you update. --uninstall reverses everything except that state.
set -euo pipefail

NS_REPO="dandacompany/notifysound"
NS_PREFIX="${NOTIFYSOUND_PREFIX:-$HOME/.local/share/notifysound}"
NS_BIN_DIR="${NOTIFYSOUND_BIN_DIR:-$HOME/.local/bin}"
NS_HOOK_DIR="${NOTIFYSOUND_HOOK_DIR:-$HOME/.claude/hooks}"
NS_SRC="${NOTIFYSOUND_SRC:-}"

do_hooks=1
do_uninstall=0
version="main"
declare -a extra_skill_dirs=()

if [ -n "${NOTIFYSOUND_SKILL_DIRS:-}" ]; then
  IFS=: read -r -a skill_dirs <<< "$NOTIFYSOUND_SKILL_DIRS"
else
  skill_dirs=("$HOME/.claude/skills" "$HOME/.agents/skills" "$HOME/.codex/skills")
fi

say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
fail() { printf '%s\n' "$*" >&2; exit 2; }

usage() {
  cat <<'EOF'
Usage: install.sh [options]

  --no-hooks            deploy files and links, but do not edit host hooks
  --skills-dir <path>   also link into this skills directory (repeatable)
  --version <tag>       install a specific git tag or branch (default: main)
  --uninstall           remove links, hooks, and the install tree
  --help                show this message

Environment overrides (mostly for testing):
  NOTIFYSOUND_PREFIX, NOTIFYSOUND_BIN_DIR, NOTIFYSOUND_HOOK_DIR,
  NOTIFYSOUND_SKILL_DIRS (colon-separated), NOTIFYSOUND_SRC (install from a local tree)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --no-hooks)   do_hooks=0 ;;
    --uninstall)  do_uninstall=1 ;;
    --version)    shift; [ $# -gt 0 ] || fail "--version requires a tag"; version="$1" ;;
    --skills-dir) shift; [ $# -gt 0 ] || fail "--skills-dir requires a path"; extra_skill_dirs+=("$1") ;;
    --help|-h)    usage; exit 0 ;;
    *)            warn "unknown option: $1"; usage >&2; exit 2 ;;
  esac
  shift
done

if [ "${#extra_skill_dirs[@]}" -gt 0 ]; then
  skill_dirs+=("${extra_skill_dirs[@]}")
fi

check_prereqs() {
  local bad=0
  # deploy() runs `rm -rf "$NS_PREFIX/<item>"`. A trailing path component after
  # a symlink IS followed, so a symlinked prefix would delete directories in
  # whatever it points at — outside anything this installer owns.
  if [ -L "$NS_PREFIX" ]; then
    warn "the install prefix is a symlink: $NS_PREFIX -> $(readlink "$NS_PREFIX")"
    warn "Refusing, because replacing the tree through a symlink would delete files outside it."
    warn "Point NOTIFYSOUND_PREFIX at a real directory."
    bad=1
  fi
  # deploy() replaces the prefix wholesale on every run, which is what makes
  # re-running an update. State kept inside the prefix would be destroyed by
  # that. Refuse rather than silently delete somebody's sounds.
  local state="${NOTIFYSOUND_HOME:-$HOME/.claude/notifysound}"
  case "$state/" in
    "$NS_PREFIX"/*)
      warn "NOTIFYSOUND_HOME ($state) is inside the install prefix ($NS_PREFIX)."
      warn "Updating replaces the prefix, which would delete your sounds and settings."
      warn "Point NOTIFYSOUND_HOME somewhere outside it (default: ~/.claude/notifysound)."
      bad=1
      ;;
  esac
  if [ "$(uname -s)" != "Darwin" ]; then
    warn "notifysound currently supports macOS only (uname -s = $(uname -s))."
    warn "It plays sound through afplay; Linux/Windows support is not implemented."
    bad=1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    warn "jq is required. Install it with: brew install jq"
    bad=1
  fi
  if [ -z "$NS_SRC" ]; then
    command -v curl >/dev/null 2>&1 || { warn "curl is required to download the release."; bad=1; }
    command -v tar  >/dev/null 2>&1 || { warn "tar is required to unpack the release."; bad=1; }
  fi
  [ "$bad" -eq 0 ] || exit 2
}

# Replace a symlink atomically. `ln -sfn` has a trap: when the link already
# exists and points at a directory, it can create the new link INSIDE that
# directory. Creating under a temp name and mv-ing over avoids that entirely.
#
# A path that exists but is NOT a symlink is left completely alone. This script
# runs on other people's machines and must never delete a directory it did not
# create — most often that directory is a `skills add` copy, which is harmless.
link_force() {
  local target="$1" link="$2" dir tmp
  dir="$(dirname "$link")"
  mkdir -p "$dir"
  if [ -e "$link" ] && [ ! -L "$link" ]; then
    say "  found a real directory or file at $link — leaving it alone"
    say "  (probably a 'skills add' copy; the CLI and hooks will use $NS_PREFIX)"
    return 0
  fi
  tmp="$(mktemp -u "$dir/.notifysound-link.XXXXXX")"
  ln -s "$target" "$tmp"
  mv -f "$tmp" "$link"
}

# Download and unpack a release, printing the extracted root directory.
# `find` rather than fd, because this runs on machines that have neither.
fetch_src() {
  local tmp tarball root
  tmp="$(mktemp -d)"
  tarball="$tmp/notifysound.tar.gz"
  curl -fsSL "https://codeload.github.com/$NS_REPO/tar.gz/$version" -o "$tarball" \
    || fail "download failed: $NS_REPO@$version"
  tar -xzf "$tarball" -C "$tmp" || fail "could not unpack the downloaded archive"
  root="$(find "$tmp" -maxdepth 1 -type d -name 'notifysound-*' | head -1)"
  [ -n "$root" ] || fail "unexpected archive layout under $tmp"
  printf '%s\n' "$root"
}

# Only runtime assets are deployed. tests/, docs/ and git metadata stay in the
# repository. User state lives elsewhere and is deliberately not in this list.
deploy() {
  local src="$1" item
  # Validate everything BEFORE removing anything. Failing partway through would
  # leave new scripts sitting beside an old sounds directory — a half-applied
  # update is harder to diagnose than a clean refusal.
  for item in SKILL.md VERSION scripts sounds; do
    [ -e "$src/$item" ] || fail "source tree is missing $item (is $src a notifysound checkout?)"
  done
  mkdir -p "$NS_PREFIX"
  for item in SKILL.md VERSION scripts sounds; do
    rm -rf "${NS_PREFIX:?}/$item"
    cp -R "$src/$item" "$NS_PREFIX/$item"
  done
  chmod +x "$NS_PREFIX/scripts/notifysound.sh" "$NS_PREFIX/scripts/notifysound-play.sh"
}

do_links() {
  local dir
  say "links"
  link_force "$NS_PREFIX/scripts/notifysound.sh"      "$NS_BIN_DIR/notifysound"
  say "  $NS_BIN_DIR/notifysound"
  link_force "$NS_PREFIX/scripts/notifysound-play.sh" "$NS_HOOK_DIR/notifysound-play.sh"
  say "  $NS_HOOK_DIR/notifysound-play.sh"
  for dir in "${skill_dirs[@]}"; do
    if [ -d "$dir" ]; then
      link_force "$NS_PREFIX" "$dir/notifysound"
      say "  $dir/notifysound"
    else
      say "  skipped (no such directory): $dir"
    fi
  done
}

# Only removes symlinks it could have created. A real directory at one of these
# paths belongs to somebody else and is left in place.
uninstall() {
  local dir
  if [ -x "$NS_PREFIX/scripts/notifysound.sh" ]; then
    "$NS_PREFIX/scripts/notifysound.sh" uninstall || warn "hook removal reported a problem; continuing"
  fi
  for dir in "${skill_dirs[@]}"; do
    if [ -L "$dir/notifysound" ]; then rm -f "$dir/notifysound"; fi
  done
  if [ -L "$NS_BIN_DIR/notifysound" ]; then rm -f "$NS_BIN_DIR/notifysound"; fi
  if [ -L "$NS_HOOK_DIR/notifysound-play.sh" ]; then rm -f "$NS_HOOK_DIR/notifysound-play.sh"; fi
  rm -rf "${NS_PREFIX:?}"
  say "notifysound removed."
  say "Your sounds and settings were left in ${NOTIFYSOUND_HOME:-$HOME/.claude/notifysound}."
  say "Delete that directory yourself if you want them gone."
}

main() {
  if [ "$do_uninstall" -eq 1 ]; then
    uninstall
    return 0
  fi

  check_prereqs

  local src cleanup=0
  if [ -n "$NS_SRC" ]; then
    src="$NS_SRC"
  else
    src="$(fetch_src)"
    cleanup=1
  fi

  deploy "$src"
  do_links

  if [ "$do_hooks" -eq 1 ]; then
    say "hooks"
    "$NS_PREFIX/scripts/notifysound.sh" install \
      || warn "hook install reported a problem — run 'notifysound status' to see what landed"
  else
    say "hooks skipped (--no-hooks). Run 'notifysound install' when you want them."
  fi

  [ "$cleanup" -eq 0 ] || rm -rf "$(dirname "$src")"

  say ""
  say "notifysound $(cat "$NS_PREFIX/VERSION" 2>/dev/null || echo '?') installed to $NS_PREFIX"
  case ":$PATH:" in
    *":$NS_BIN_DIR:"*) : ;;
    *) say "NOTE: $NS_BIN_DIR is not on your PATH. Add it, or call $NS_BIN_DIR/notifysound directly." ;;
  esac
  say ""
  say "Next:"
  say "  notifysound status      see what is wired up"
  say "  notifysound list        see the 12 built-in sounds"
  say "  notifysound use glass   pick one"
  say "  notifysound test        hear it now"
}

main
