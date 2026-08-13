#!/usr/bin/env bash
# notifysound installer — turn-completion sounds for Claude Code and Codex CLI.
#
# Read this before running it. The script writes to:
#   ~/.local/share/notifysound              the install tree (replaced on every run)
#   ~/.local/bin/notifysound                CLI symlink
#   ~/.claude/hooks/notifysound-play.sh     player symlink
#   ~/.claude/hooks/codex-hook.sh           codex hook symlink (sourced by notify.sh)
#   <each existing skills dir>/notifysound  symlink, into existing dirs only
#   ~/.claude/settings.json                 one Stop hook, tagged "# notifysound"
#   ~/.codex/hooks/notify.sh                ONE line, tagged "# notifysound",
#                                           which sources our own codex-hook.sh
#
# It never touches your sounds or settings under ~/.claude/notifysound.
# Re-running is how you update. --uninstall reverses everything except that state.
set -euo pipefail

NS_REPO="dandacompany/notifysound"
NS_PREFIX="${NOTIFYSOUND_PREFIX:-$HOME/.local/share/notifysound}"
NS_BIN_DIR="${NOTIFYSOUND_BIN_DIR:-$HOME/.local/bin}"
NS_HOOK_DIR="${NOTIFYSOUND_HOOK_DIR:-$HOME/.claude/hooks}"
NS_SRC="${NOTIFYSOUND_SRC:-}"

# Written into the prefix so a later run can prove the tree is ours to replace.
NS_MARKER=".notifysound-install"
NS_MARKER_HEADER="notifysound install tree — safe to delete"

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

# Is the existing prefix a notifysound tree we may replace? This gates an
# `rm -rf`, so "a file with the right name exists" is not good enough — an empty
# `touch .notifysound-install` in any directory would have handed us permission
# to delete it.
#
# The marker therefore carries content we can check: the absolute prefix it was
# written for. Forging it now means knowing and writing that exact path, which
# is a far cry from creating an empty file. It is not a security boundary
# against someone who can already write into the directory — nothing in a shell
# installer can be — but it stops an accident or a stray file from qualifying.
#
# Pre-marker trees (2.0.x) are recognised by CONTENT, not by filename: three
# plausible names would otherwise be enough, so we require the scripts to
# actually be ours.
prefix_is_ours() {
  local real
  if [ -f "$NS_PREFIX/$NS_MARKER" ]; then
    real="$(cd "$NS_PREFIX" 2>/dev/null && pwd -P)" || return 1
    # All three lines, not just one: a single `printf prefix=$(pwd -P) >` was
    # enough to pass before. This raises the cost of a forgery from one line to
    # reproducing our whole format — it is NOT a security boundary. Anyone who
    # can write into the directory can write the file, and a case-insensitive
    # filesystem, a bind mount, or a backup restored to the same physical path
    # are all indistinguishable from the real thing by construction.
    grep -qxF "$NS_MARKER_HEADER" "$NS_PREFIX/$NS_MARKER" 2>/dev/null \
      && grep -qE '^version=[0-9]+\.[0-9]+\.[0-9]+$' "$NS_PREFIX/$NS_MARKER" 2>/dev/null \
      && grep -qxF "prefix=$real" "$NS_PREFIX/$NS_MARKER" 2>/dev/null \
      && return 0
    # A marker that exists but does not verify is a refusal, not a reason to try
    # a weaker test. Falling through to the legacy check meant the strong check
    # FAILING still authorised a recursive delete.
    return 1
  fi
  [ -f "$NS_PREFIX/VERSION" ] \
    && [ -f "$NS_PREFIX/scripts/notifysound.sh" ] \
    && [ -f "$NS_PREFIX/scripts/notifysound-play.sh" ] \
    && grep -q 'notifysound - CLI for the agent turn-completion sound' \
         "$NS_PREFIX/scripts/notifysound.sh" 2>/dev/null \
    && grep -q 'notifysound - turn-completion sound player' \
         "$NS_PREFIX/scripts/notifysound-play.sh" 2>/dev/null
}

check_prereqs() {
  local bad=0
  # deploy() runs `rm -rf "$NS_PREFIX/<item>"`, and a path component after a
  # symlink IS followed, so the prefix must be somewhere we are entitled to
  # delete. Checking `[ -L "$NS_PREFIX" ]` only inspected the LAST component —
  # a symlinked PARENT walked straight past it.
  #
  # Rather than trying to prove a path is symlink-free (which would also reject
  # perfectly ordinary setups: /tmp is a symlink on macOS, and plenty of people
  # keep $HOME behind one), prove OWNERSHIP: we only replace a directory that is
  # empty, absent, or carries the marker file we wrote there ourselves.
  if [ -e "$NS_PREFIX" ] && ! prefix_is_ours; then
    if [ -n "$(ls -A "$NS_PREFIX" 2>/dev/null)" ]; then
      warn "$NS_PREFIX already exists, is not empty, and was not created by this installer."
      warn "Refusing: replacing it would delete files notifysound does not own."
      warn "(If this really is a stale notifysound tree, remove it yourself and re-run.)"
      bad=1
    fi
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

# Replace a symlink. NOT atomically — the claim that used to be here stopped
# being true when the old link had to be removed before the mv (see below), and
# a comment asserting a property the code does not have is worse than no
# comment. There is a brief window in which the link is absent.
#
# `ln -sfn` has a trap: when the link already exists and points at a directory,
# it can create the new link INSIDE that directory. Building under a temp name
# does not by itself avoid it, because `mv -f` follows such a link too.
#
# A path that exists but is NOT a symlink is left completely alone. This script
# runs on other people's machines and must never delete a directory it did not
# create — most often that directory is a `skills add` copy, which is harmless.
link_force() {
  local target="$1" link="$2" dir tmp
  dir="$(dirname "$link")"
  # Raw command statuses used to escape all the way out: an unwritable
  # ~/.local made mkdir return 1, which travelled to the process exit status
  # and claimed "user error" for what is plainly an environment failure. Every
  # such call is mapped onto the documented contract.
  mkdir -p "$dir" || fail "cannot create $dir (permission denied?)"
  if [ -e "$link" ] && [ ! -L "$link" ]; then
    say "  found a real directory or file at $link — leaving it alone"
    say "  (probably a 'skills add' copy; the CLI and hooks will use $NS_PREFIX)"
    return 0
  fi
  tmp="$(mktemp -u "$dir/.notifysound-link.XXXXXX")"
  ln -s "$target" "$tmp" || fail "cannot create a link in $dir"
  # `mv -f tmp link` FOLLOWS a symlink that points at a directory and moves the
  # temp INSIDE it — the very trap the temp+mv dance was introduced to avoid in
  # `ln -sfn`. Every reinstall then left a stray link in the target directory
  # and never refreshed the real one. Removing the old symlink first is the only
  # way to make mv land on the path rather than through it. The window between
  # the two is brief and a momentarily missing link is harmless; a silently
  # unrefreshed link is not.
  if [ -L "$link" ]; then
    rm -f "$link" || fail "cannot replace the existing link at $link"
  fi
  mv -f "$tmp" "$link" || { rm -f "$tmp"; fail "cannot place the link at $link"; }
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
  mkdir -p "$NS_PREFIX" || fail "cannot create $NS_PREFIX (permission denied?)"
  # The marker goes in first, so an interrupted first install still leaves a
  # tree the next run recognises as ours instead of refusing forever.
  {
    printf '%s\n' "$NS_MARKER_HEADER"
    printf 'version=%s\n' "$(cat "$src/VERSION" 2>/dev/null || echo '?')"
    # The prefix is recorded physically resolved, and prefix_is_ours compares it
    # against the resolved path on the next run. A marker copied elsewhere, or
    # created blind, will not match.
    printf 'prefix=%s\n' "$(cd "$NS_PREFIX" && pwd -P)"
  } > "$NS_PREFIX/$NS_MARKER" || fail "cannot write the install marker in $NS_PREFIX"
  for item in SKILL.md VERSION scripts sounds; do
    rm -rf "${NS_PREFIX:?}/$item"
    cp -R "$src/$item" "$NS_PREFIX/$item" || fail "cannot copy $item into $NS_PREFIX"
  done
  chmod +x "$NS_PREFIX/scripts/notifysound.sh" "$NS_PREFIX/scripts/notifysound-play.sh" \
    || fail "cannot make the scripts executable in $NS_PREFIX"
}

do_links() {
  local dir
  say "links"
  link_force "$NS_PREFIX/scripts/notifysound.sh"      "$NS_BIN_DIR/notifysound"
  say "  $NS_BIN_DIR/notifysound"
  link_force "$NS_PREFIX/scripts/notifysound-play.sh" "$NS_HOOK_DIR/notifysound-play.sh"
  say "  $NS_HOOK_DIR/notifysound-play.sh"
  # The Codex hook line sources this file. It must sit beside the player,
  # because that is where the line's path is derived from.
  link_force "$NS_PREFIX/scripts/codex-hook.sh" "$NS_HOOK_DIR/codex-hook.sh"
  say "  $NS_HOOK_DIR/codex-hook.sh"
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
  # The gate comes FIRST — before running anything out of the prefix and before
  # touching a single link. Running $NS_PREFIX/scripts/notifysound.sh and only
  # then checking whether the prefix is ours meant pointing --uninstall at
  # somebody else's directory executed their script: the delete gate was there,
  # but arbitrary code ran past it on the way.
  if [ -e "$NS_PREFIX" ] && ! prefix_is_ours; then
    warn "$NS_PREFIX was not created by this installer."
    warn "Refusing to run anything from it or to remove links that may not be ours."
    warn "If notifysound really is installed elsewhere, set NOTIFYSOUND_PREFIX to that path."
    exit 2
  fi
  # A failed hook cleanup must STOP us, not be noted while we carry on deleting.
  # Continuing left the user's notify.sh sourcing a file we then removed — a
  # broken hook produced by the very command meant to remove it.
  #
  # `|| rc=$?` rather than a bare call: under set -e a bare non-zero call would
  # abort before the status could be read, and inside an `if` condition it would
  # be invisible instead.
  local rc=0
  if [ -x "$NS_PREFIX/scripts/notifysound.sh" ]; then
    "$NS_PREFIX/scripts/notifysound.sh" uninstall || rc=$?
    if [ "$rc" -ne 0 ]; then
      warn ""
      warn "Nothing was removed: the hooks could not be cleaned up first (exit $rc)."
      warn "Deleting the install tree now would leave your hooks pointing at files"
      warn "that no longer exist. Resolve the hook problem above and try again."
      exit "$rc"
    fi
  fi
  for dir in "${skill_dirs[@]}"; do
    if [ -L "$dir/notifysound" ]; then rm -f "$dir/notifysound"; fi
  done
  if [ -L "$NS_BIN_DIR/notifysound" ]; then rm -f "$NS_BIN_DIR/notifysound"; fi
  if [ -L "$NS_HOOK_DIR/notifysound-play.sh" ]; then rm -f "$NS_HOOK_DIR/notifysound-play.sh"; fi
  if [ -L "$NS_HOOK_DIR/codex-hook.sh" ]; then rm -f "$NS_HOOK_DIR/codex-hook.sh"; fi
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

  local hook_rc=0
  if [ "$do_hooks" -eq 1 ]; then
    say "hooks"
    # Same reason as in uninstall(): capture the status instead of letting it
    # dissolve into a warning. Reporting a successful install while a host was
    # refused is the failure mode this exists to prevent.
    "$NS_PREFIX/scripts/notifysound.sh" install || hook_rc=$?
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

  if [ "$hook_rc" -ne 0 ]; then
    say ""
    warn "The files are in place, but the hooks are NOT fully installed (exit $hook_rc)."
    warn "See the messages above, then run: notifysound status"
    return "$hook_rc"
  fi
}

# Explicit rather than relying on set -e to carry main's status out: the whole
# point of this round is that a status must not depend on a subtlety to survive.
main
exit $?
