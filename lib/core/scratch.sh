# shellcheck shell=bash
# The scratch root, shared by `mroom scratch` (lib/scratch) and the guard (lib/guard), so both agree on where
# throwaway folders live. Sourced, never run. Bash 3.2 compatible (the guard runs on macOS too).
#
# The root is ${XDG_CACHE_HOME:-~/.cache}/mroom/scratch. An XDG_CACHE_HOME that is not an absolute path is
# ignored, as the XDG spec says.

# scratch_root: the root as configured (not resolved, and not checked).
scratch_root() {
  local base=${XDG_CACHE_HOME:-}
  case $base in
    /*) ;;
    *) base=${HOME:-}/.cache ;;
  esac
  printf '%s/mroom/scratch' "${base%/}"
}

# scratch_physical PATH: PATH's physical path (every link resolved), for a folder; fails for anything else.
# CDPATH is cleared so a relative PATH means the current folder's, and cd prints nothing.
scratch_physical() {
  (CDPATH='' cd -P -- "$1" 2>/dev/null && pwd -P)
}

# scratch_real_root: the root's physical path, when the root is safe to use: a folder this user owns that is
# not a link, under an `mroom` folder that is not a link either. A folder above those may be a link (a cache
# on another disk), so containment is always checked against this physical path. Fails otherwise, also when
# the root does not exist yet.
scratch_real_root() {
  local root real
  root=$(scratch_root)
  [ -n "${root%/mroom/scratch}" ] || return 1
  [ ! -L "$root" ] && [ ! -L "${root%/scratch}" ] && [ -d "$root" ] && [ -O "$root" ] || return 1
  real=$(scratch_physical "$root") || return 1
  [ "$real" != / ] || return 1
  printf '%s' "$real"
}

# scratch_inside REAL_ROOT PATH: does PATH resolve, physically, to a folder strictly inside REAL_ROOT?
# Prints that physical path.
scratch_inside() {
  local real
  real=$(scratch_physical "$2") || return 1
  case $real in
    "$1"/?*) printf '%s' "$real" ;;
    *) return 1 ;;
  esac
}
