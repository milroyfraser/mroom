#!/usr/bin/env bash
# shellcheck disable=SC2317  # the t_* functions run indirectly, through test_case
# Tests for actions/qa-up/merge-build, which puts Vite's build into GitHub's tarball of a commit on the runner, for
# a Laravel app that serves its build from its own tree: the tarball's members, its one top folder, its global header
# and their modes stay as they came; what the commit had at the build's path goes, and the build's files and folders
# take its place with ordinary modes and no owner of the runner's; a build that holds anything but files and folders,
# a path that leaves the tree and an empty tarball are refused.
set -euo pipefail
SUITE=qa-merge-build
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
skip_unless has_tomllib "python3 has no tomllib (needs 3.11+)"

MERGE="$ROOT/actions/qa-up/merge-build"
TOP=example-shop-aaaaaaa

# tarball: GitHub's tarball of a commit in $T/code.tgz: a global header naming the commit, one top folder, an
# executable artisan, and a build committed at public/build; and a build in $T/dist.
tarball() {
  mkdir -p "$T/src/$TOP/public/build" "$T/dist/assets"
  printf 'php\n' >"$T/src/$TOP/artisan"
  chmod 755 "$T/src/$TOP/artisan"
  printf 'old\n' >"$T/src/$TOP/public/build/old.js"
  printf 'index\n' >"$T/src/$TOP/public/index.php"
  chmod 755 "$T/src/$TOP" "$T/src/$TOP/public" "$T/src/$TOP/public/build"
  chmod 644 "$T/src/$TOP/public/build/old.js" "$T/src/$TOP/public/index.php"
  python3 -I - "$T/src" "$T/code.tgz" <<'PY'
import os, sys, tarfile
src, dst = sys.argv[1:]
with tarfile.open(dst, "w:gz", format=tarfile.PAX_FORMAT, pax_headers={"comment": "a" * 40}) as tf:
    tf.add(os.path.join(src, "example-shop-aaaaaaa"), arcname="example-shop-aaaaaaa")
PY
  printf '<html></html>\n' >"$T/dist/index.html"
  printf 'console.log(1)\n' >"$T/dist/assets/app.js"
  chmod 600 "$T/dist/assets/app.js"
}
merged() { python3 -I "$MERGE" "$T/code.tgz" "$T/dist" "$@" >"$T/out.tgz"; }
# listing: each member of the merged tarball as "<name> <mode> <uid>:<gid>".
listing() {
  python3 -I -c 'import sys, tarfile
for m in tarfile.open(sys.argv[1]):
    print(m.name, oct(m.mode), f"{m.uid}:{m.gid}")' "$T/out.tgz" | sort
}

t_the_build_takes_its_place_in_the_tree() {
  tarball
  run merged public/build
  expect_rc 0
  run listing
  expect_out "$TOP 0o755 $(id -u):$(id -g)
$TOP/artisan 0o755 $(id -u):$(id -g)
$TOP/public 0o755 $(id -u):$(id -g)
$TOP/public/build 0o755 0:0
$TOP/public/build/assets 0o755 0:0
$TOP/public/build/assets/app.js 0o644 0:0
$TOP/public/build/index.html 0o644 0:0
$TOP/public/index.php 0o644 $(id -u):$(id -g)"
  run python3 -I -c 'import sys, tarfile; print(tarfile.open(sys.argv[1]).pax_headers.get("comment"))' "$T/out.tgz"
  expect_out "$(printf 'a%.0s' {1..40})"
  run tar -xzOf "$T/out.tgz" "$TOP/public/build/assets/app.js"; expect_out "console.log(1)"
}

t_a_path_inside_a_backend_folder_works_and_one_outside_the_tree_is_refused() {
  tarball
  run merged ./public/build/
  expect_rc 0
  run listing; expect_out_has "$TOP/public/build/index.html"
  local bad
  for bad in "" / ../x public/../../x; do
    run merged "$bad"; expect_rc 2; expect_err_has "is not a path inside the tree"
  done
}

t_a_build_with_a_link_or_a_fifo_is_refused() {
  tarball
  ln -s /etc/hostname "$T/dist/assets/leak.txt"
  run merged public/build
  expect_rc 1; expect_err_has "the build holds something other than files and folders"
  rm "$T/dist/assets/leak.txt"
  mkfifo "$T/dist/pipe"
  run merged public/build
  expect_rc 1; expect_err_has "the build holds something other than files and folders"
}

t_an_empty_tarball_is_refused() {
  tarball
  python3 -I -c 'import sys, tarfile; tarfile.open(sys.argv[1], "w:gz").close()' "$T/code.tgz"
  run merged public/build
  expect_rc 1; expect_err_has "the tarball is empty"
  run python3 -I "$MERGE" "$T/code.tgz"; expect_rc 2
}

test_case build-in-place t_the_build_takes_its_place_in_the_tree
test_case paths t_a_path_inside_a_backend_folder_works_and_one_outside_the_tree_is_refused
test_case links-refused t_a_build_with_a_link_or_a_fifo_is_refused
test_case empty-tarball t_an_empty_tarball_is_refused
finish
