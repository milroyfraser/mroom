#!/usr/bin/env bash
# shellcheck disable=SC2317  # the t_* functions run indirectly, through test_case
# Tests for `mroom scratch new|ls|rm|prune|root`: folders and repositories under one root, and removal that
# never reaches outside it, through a link, `..` or a path beside it.
set -euo pipefail
SUITE=scratch
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Every world gets its own cache folder, so the root is $T/cache/mroom/scratch.
scratch_world() {
  export XDG_CACHE_HOME="$T/cache"
  ROOTDIR="$(cd "$T" && pwd -P)/cache/mroom/scratch"
}

t_root() {
  scratch_world
  run "$MROOM" scratch root; expect_rc 0; expect_out "$T/cache/mroom/scratch"
  unset XDG_CACHE_HOME
  run "$MROOM" scratch root; expect_out "$HOME/.cache/mroom/scratch"
  # A relative XDG_CACHE_HOME is ignored, as the XDG spec says.
  XDG_CACHE_HOME=rel run "$MROOM" scratch root; expect_out "$HOME/.cache/mroom/scratch"
  # Without an absolute XDG_CACHE_HOME or HOME there is no root, rather than one relative to here.
  HOME=rel run "$MROOM" scratch new; expect_rc 1; expect_err_has "no scratch root"
  HOME="" run "$MROOM" scratch ls; expect_rc 1
}

t_new_kinds() {
  scratch_world
  run "$MROOM" scratch new; expect_rc 0
  plain=$out
  case "$plain" in "$ROOTDIR"/*) ok ;; *) fail "new is not under the root" ;; esac
  expect_true "plain is an empty folder" test -d "$plain"
  run "$MROOM" scratch new --git; expect_rc 0
  expect_true "--git makes a work tree" test -d "$out/.git"
  run "$MROOM" scratch new --bare; expect_rc 0
  bare=$out
  expect_true "--bare makes a bare repository" test -f "$bare/HEAD" -a -d "$bare/objects" -a ! -e "$bare/.git"
  run "$MROOM" scratch new --git --bare; expect_rc 2
  run "$MROOM" scratch new --other; expect_rc 2
  run "$MROOM" scratch ls; expect_rc 0
  expect_out_has $'\tplain\t'; expect_out_has $'\tgit\t'; expect_out_has $'\tbare\t'
}

t_rm_by_id_and_path() {
  scratch_world
  a=$("$MROOM" scratch new --git)
  b=$("$MROOM" scratch new --bare)
  # git's objects are read-only, which rm must cope with.
  git -C "$a" -c user.name=t -c user.email=t@t commit -q --allow-empty -m x
  run "$MROOM" scratch rm "${a##*/}" "$b"; expect_rc 0
  expect_out_has "removed ${a##*/}"; expect_out_has "removed ${b##*/}"
  expect_no_file "$a"; expect_no_file "$b"
  run "$MROOM" scratch rm "${a##*/}"; expect_rc 1; expect_err_has "no scratch folder"
}

t_rm_refuses_outside() {
  scratch_world
  a=$("$MROOM" scratch new)
  mkdir -p "$T/outside/keep"
  touch "$T/outside/keep/file"
  for target in "$T/outside" "$T/outside/keep" "$a/../../../../outside" "$ROOTDIR" "$ROOTDIR/" "/" "$a/sub"; do
    run "$MROOM" scratch rm "$target"; expect_rc 1
  done
  for id in .. . ../outside .hidden "a b" ""; do
    run "$MROOM" scratch rm "$id"; expect_rc 1
  done
  expect_file "$T/outside/keep/file"; expect_file "$a"
  run "$MROOM" scratch rm; expect_rc 2
}

t_rm_refuses_links_out() {
  scratch_world
  "$MROOM" scratch new >/dev/null
  mkdir -p "$T/outside"
  touch "$T/outside/file"
  ln -s "$T/outside" "$ROOTDIR/evil"
  run "$MROOM" scratch rm evil; expect_rc 1; expect_err_has "is a link"
  run "$MROOM" scratch rm "$ROOTDIR/evil"; expect_rc 1
  expect_file "$T/outside/file"; expect_file "$ROOTDIR/evil"
  run "$MROOM" scratch ls; expect_out_has $'evil\tlink'
  # A link inside a folder is removed as a link; what it points at stays.
  a=$("$MROOM" scratch new)
  ln -s "$T/outside" "$a/inner"
  run "$MROOM" scratch rm "${a##*/}"; expect_rc 0
  expect_no_file "$a"; expect_file "$T/outside/file"
}

t_root_through_a_link_is_refused() {
  scratch_world
  mkdir -p "$T/cache/mroom" "$T/elsewhere"
  ln -s "$T/elsewhere" "$T/cache/mroom/scratch"
  run "$MROOM" scratch new; expect_rc 1; expect_err_has "link"
  run "$MROOM" scratch rm x; expect_rc 1
  rm "$T/cache/mroom/scratch"
  rmdir "$T/cache/mroom"
  ln -s "$T/elsewhere" "$T/cache/mroom"
  run "$MROOM" scratch new; expect_rc 1; expect_err_has "link"
  expect_no_file "$T/elsewhere/scratch"
}

t_prune() {
  scratch_world
  old=$("$MROOM" scratch new --bare)
  new=$("$MROOM" scratch new)
  touch -t 202001010000 "$old"
  mkdir -p "$T/outside"
  touch -t 202001010000 "$T/outside"
  ln -s "$T/outside" "$ROOTDIR/evil"
  run "$MROOM" scratch prune --older-than 24; expect_rc 0
  expect_out_has "removed ${old##*/}"; expect_err_has "left evil alone"
  expect_no_file "$old"; expect_file "$new"; expect_file "$T/outside"; expect_file "$ROOTDIR/evil"
  run "$MROOM" scratch prune --older-than x; expect_rc 2
  run "$MROOM" scratch prune; expect_rc 2
}

t_no_root_yet() {
  scratch_world
  run "$MROOM" scratch ls; expect_rc 0; expect_out_has "no scratch folders"
  run "$MROOM" scratch prune --older-than 1; expect_rc 0
  run "$MROOM" scratch rm x; expect_rc 1
  expect_no_file "$T/cache/mroom/scratch"
}

test_case root t_root
test_case new-kinds t_new_kinds
test_case rm-by-id-and-path t_rm_by_id_and_path
test_case rm-refuses-outside t_rm_refuses_outside
test_case rm-refuses-links-out t_rm_refuses_links_out
test_case root-through-a-link t_root_through_a_link_is_refused
test_case prune t_prune
test_case no-root-yet t_no_root_yet
finish
