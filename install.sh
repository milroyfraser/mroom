#!/usr/bin/env bash
# install.sh — install the mroom box CLI for this user.
#
#   ./install.sh                     install from the checkout this script is in
#   ./install.sh --version v0.1.0    install that tagged release (its GitHub release tarball)
#   ./install.sh --uninstall         remove every installed version and the mroom and forge-api links
#
# Options:
#   --prefix <dir>   install under <dir> instead of ~/.local: <dir>/share/mroom/<version>, <dir>/bin/mroom
#   --force          replace a <dir>/bin/mroom (or <dir>/bin/forge-api) that is not an mroom install
#
# It installs into ~/.local/share/mroom/<version> and links ~/.local/bin/mroom to it, and
# ~/.local/bin/forge-api too unless a forge-api that is not mroom's is already there. Running it again
# replaces that version in place, so it is safe to repeat. It never touches ~/.config/mroom.
# A tagged release is downloaded with `gh release download` when gh is signed in (the repository may be
# private), and with curl from GitHub's archive URL otherwise.
#
# It checks what mroom needs today: Linux, bash >= 5, python3 >= 3.11, jq and git. Later phases add more.
set -euo pipefail

REPO="${MROOM_REPO:-milroyfraser/mroom}"
RELEASE_BASE="${MROOM_RELEASE_BASE:-}"
UNAME="${MROOM_UNAME:-$(uname -s)}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

prefix="$HOME/.local"
version=""
uninstall=0
force=0

say() { echo "install.sh: $*"; }
die() { echo "install.sh: $*" >&2; exit 1; }

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)
      [ "$#" -ge 2 ] || die "--version needs a tag, for example --version v0.1.0"
      version="$2"
      shift 2
      ;;
    --prefix)
      [ "$#" -ge 2 ] || die "--prefix needs a folder"
      prefix="$2"
      shift 2
      ;;
    --uninstall) uninstall=1; shift ;;
    --force) force=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown option $1 (--help lists them)" ;;
  esac
done

# An absolute prefix with single slashes and no trailing one, so the link never points somewhere relative.
case "$prefix" in /*) ;; *) prefix="$PWD/$prefix" ;; esac
slash=/ double=//
while [[ "$prefix" == *//* ]]; do prefix="${prefix//$double/$slash}"; done
[ "$prefix" = / ] || prefix="${prefix%/}"

share="$prefix/share/mroom"
bindir="$prefix/bin"
link="$bindir/mroom"
# Commands linked beside mroom when the name is free or already ours. One that belongs to something else
# is left alone (--force replaces it): it must not stop mroom itself from installing.
extra_links=(forge-api)

# canon <path>: the absolute path with symlinks, "." and ".." resolved; the last parts need not exist.
canon() {
  readlink -m -- "$1" 2>/dev/null && return 0
  python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1" 2>/dev/null
}

# is_ours [<link>]: the link (default: the mroom link) resolves into $share, compared canonically, so
# another spelling of the same install counts. When either side cannot be resolved, it is not ours.
is_ours() {
  local l="${1:-$link}" target t s
  [ -L "$l" ] || return 1
  target="$(readlink "$l")" || return 1
  case "$target" in /*) ;; *) target="$bindir/$target" ;; esac
  t="$(canon "$target")" || return 1
  s="$(canon "$share")" || return 1
  if [ -z "$t" ] || [ -z "$s" ]; then return 1; fi
  case "$t" in "$s"/*) return 0 ;; *) return 1 ;; esac
}

if [ "$uninstall" = 1 ]; then
  remove_share=1
  for name in "${extra_links[@]}"; do
    if is_ours "$bindir/$name"; then
      rm -f "$bindir/$name"
      say "removed $bindir/$name"
    fi
  done
  if is_ours; then
    rm -f "$link"
    say "removed $link"
  elif [ -e "$link" ] || [ -L "$link" ]; then
    say "left $link alone: it is not an mroom install"
    remove_share=0
  fi
  if [ -d "$share" ]; then
    if [ "$remove_share" = 1 ]; then
      rm -rf "$share"
      say "removed $share"
    else
      say "left $share alone too, since $link is not ours; remove it by hand if nothing uses it"
    fi
  fi
  say "uninstalled (~/.config/mroom is kept)"
  exit 0
fi

# ---- host requirements --------------------------------------------------------------------------

missing=()
[ "$UNAME" = Linux ] || missing+=("Linux (this is $UNAME; mroom runs on a Linux box)")
if ! command -v bash >/dev/null 2>&1; then
  missing+=("bash >= 5 (none on PATH)")
else
  bash_major="$(bash -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null || echo 0)"
  if [ "$bash_major" -lt 5 ]; then
    missing+=("bash >= 5 (the bash on PATH is $(bash -c 'echo "$BASH_VERSION"' || true))")
  fi
fi
if ! command -v python3 >/dev/null 2>&1; then
  missing+=("python3 >= 3.11 (none on PATH)")
elif ! python3 -c 'import sys; sys.exit(sys.version_info < (3, 11))'; then
  missing+=("python3 >= 3.11 (the python3 on PATH is $(python3 -c 'import platform; print(platform.python_version())' 2>/dev/null || true))")
fi
command -v jq >/dev/null 2>&1 || missing+=("jq")
command -v git >/dev/null 2>&1 || missing+=("git")

if [ "${#missing[@]}" -gt 0 ]; then
  echo "install.sh: this host is missing what mroom needs:" >&2
  for m in "${missing[@]}"; do echo "  - $m" >&2; done
  echo "On Ubuntu: sudo apt-get install -y bash python3 jq git (Ubuntu 24.04 ships python3 3.12)" >&2
  exit 1
fi

# ---- fetch --------------------------------------------------------------------------------------

work="$(mktemp -d)"
stage=""
trap 'rm -rf "$work" ${stage:+"$stage"}' EXIT

if [ -n "$version" ]; then
  [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "--version takes a tag like v0.1.0 (got $version)"
  tarball="$work/mroom.tar.gz"
  if [ -z "$RELEASE_BASE" ] && command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    gh release download "$version" --repo "$REPO" --archive tar.gz --output "$tarball" \
      || die "could not download release $version of $REPO with gh"
  else
    command -v curl >/dev/null 2>&1 || die "installing a release needs curl (or gh, signed in)"
    url="${RELEASE_BASE:-https://github.com/$REPO/archive/refs/tags}/$version.tar.gz"
    curl -fsSL "$url" -o "$tarball" \
      || die "could not download $url (a private repository needs gh, signed in)"
  fi
  mkdir "$work/src"
  tar -xzf "$tarball" -C "$work/src" --strip-components=1 || die "the $version tarball did not unpack"
  from="$work/src"
  source_note="release $version of $REPO"
else
  from="$SRC"
  sha="$(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  if [ -n "$(git -C "$SRC" status --porcelain 2>/dev/null)" ]; then sha="$sha-dirty"; fi
  source_note="checkout $SRC at $sha"
fi

if [ ! -f "$from/VERSION" ] || [ ! -x "$from/bin/mroom" ]; then
  die "$from does not look like mroom (no VERSION or bin/mroom)"
fi
have="$(tr -d '[:space:]' <"$from/VERSION")"
[[ "$have" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "$from/VERSION is not a version: $have"
if [ -n "$version" ] && [ "v$have" != "$version" ]; then
  die "release $version carries VERSION $have; refusing to install a mismatched release"
fi

# ---- install ------------------------------------------------------------------------------------

if { [ -e "$link" ] || [ -L "$link" ]; } && ! is_ours && [ "$force" != 1 ]; then
  die "$link exists and is not an mroom install ($(readlink "$link" 2>/dev/null || echo 'a file')); move it or rerun with --force"
fi

dest="$share/$have"
mkdir -p "$share" "$bindir"
stage="$(mktemp -d "$share/.stage.XXXXXX")"
for part in bin lib reverb-host VERSION LICENSE NOTICE README.md; do
  if [ -e "$from/$part" ]; then cp -R "$from/$part" "$stage/"; fi
done
echo "$source_note" >"$stage/SOURCE"
chmod 755 "$stage"
# Swap: the old copy moves aside, the new one moves in, and only then is the old one removed. If the new
# one cannot move in, the old one goes back, so a failed reinstall leaves the working install in place.
old=""
if [ -e "$dest" ]; then
  old="$share/.old.$have.$$"
  mv "$dest" "$old" || die "could not move the installed $have aside; nothing changed"
fi
if ! mv "$stage" "$dest"; then
  if [ -n "$old" ]; then
    mv "$old" "$dest" || die "could not move the new $have in, nor the old one back; it is at $old"
  fi
  die "could not move the new $have into place; the previous install is unchanged"
fi
stage=""
if [ -n "$old" ]; then rm -rf "$old"; fi
ln -sfn "$dest/bin/mroom" "$link"

say "installed mroom $have from $source_note"
say "  $dest"
say "  $link -> $dest/bin/mroom"
for name in "${extra_links[@]}"; do
  extra="$bindir/$name"
  if [ ! -x "$dest/bin/$name" ]; then
    # This version has no such command (an older release): a link of ours would point at another version.
    if is_ours "$extra"; then
      rm -f "$extra"
      say "  removed $extra: mroom $have has no $name"
    fi
    continue
  fi
  if { [ -e "$extra" ] || [ -L "$extra" ]; } && ! is_ours "$extra"; then
    if [ "$force" != 1 ]; then
      say "  left $extra alone: it is not mroom's (mroom's is $dest/bin/$name; --force replaces it)"
      continue
    fi
    # --force: keep what was there, beside the new link, rather than delete it.
    aside="$extra.before-mroom"
    if [ -e "$aside" ] || [ -L "$aside" ]; then aside="$extra.before-mroom.$$"; fi
    mv "$extra" "$aside" || die "could not move $extra aside"
    say "  moved $extra to $aside"
  fi
  ln -sfn "$dest/bin/$name" "$extra"
  say "  $extra -> $dest/bin/$name"
done
case ":$PATH:" in
  *":$bindir:"*) ;;
  *) say "note: $bindir is not on PATH; add it, for example: export PATH=\"$bindir:\$PATH\"" ;;
esac
