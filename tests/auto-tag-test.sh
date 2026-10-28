#!/usr/bin/env bash
# shellcheck disable=SC2317  # the t_* functions run indirectly, through test_case
# Tests for the auto-tag (actions/auto-tag/tag.sh): the next version from the titles merged since the last version
# tag, pushed as an annotated tag. Offline: a real git repository with a bare one in $T as its origin.
set -euo pipefail
SUITE=auto-tag
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TAG="$ROOT/actions/auto-tag/tag.sh"

# world: an app at $T/app, its origin at $T/origin.git, with one first commit.
world() {
  export GIT_AUTHOR_NAME=dev GIT_AUTHOR_EMAIL=dev@example.dev GIT_COMMITTER_NAME=dev GIT_COMMITTER_EMAIL=dev@example.dev
  export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
  git config --global init.defaultBranch main
  git init -q --bare "$T/origin.git"
  git init -q "$T/app"
  git -C "$T/app" remote add origin "$T/origin.git"
  merge "Initial commit"
  export GITHUB_OUTPUT="$T/output"
  : >"$GITHUB_OUTPUT"
}

# merge <message>: a commit on main, as a squash merge leaves it.
merge() { git -C "$T/app" commit -q --allow-empty -m "$1"; }
# tag_here <tag>: a version tag on the last commit, in the app and its origin.
tag_here() { git -C "$T/app" tag -a "$1" -m "$1" && git -C "$T/app" push -q origin "refs/tags/$1"; }
tag() { : >"$GITHUB_OUTPUT"; run "$TAG" "$T/app"; }
origin_tags() { git -C "$T/origin.git" tag | sort | tr '\n' ' '; }
output() { cat "$GITHUB_OUTPUT"; }

t_feat_bumps_the_minor() {
  world
  tag_here v1.4.2
  merge "fix: keep the filter (#3)"
  merge "feat(export): add a CSV export (#4)"
  merge "docs: say how (#5)"
  tag; expect_rc 0; expect_out_has "3 merge(s) since v1.4.2, a minor bump: tagged v1.5.0"
  expect_true "origin lacks v1.5.0" [ "$(origin_tags)" = "v1.4.2 v1.5.0 " ]
  expect_true "v1.5.0 is not on the last commit" [ "$(git -C "$T/app" rev-parse 'v1.5.0^{commit}')" = "$(git -C "$T/app" rev-parse HEAD)" ]
  expect_true "v1.5.0 is not annotated" [ "$(git -C "$T/app" cat-file -t v1.5.0)" = tag ]
  expect_true "the outputs are wrong" [ "$(output)" = $'previous=v1.4.2\ntag=v1.5.0\nbump=minor' ]
}

t_fix_bumps_the_patch() {
  world
  tag_here v1.4.2
  merge "fix: keep the filter (#3)"
  tag; expect_rc 0; expect_out_has "a patch bump: tagged v1.4.3"
}

t_a_breaking_change_bumps_the_major() {
  world
  tag_here v1.4.2
  merge "chore(deps)!: drop Node 18 (#3)"
  merge "feat: add (#4)"
  tag; expect_rc 0; expect_out_has "a major bump: tagged v2.0.0"
  merge "feat!: a new API (#5)"
  MROOM_TAG_BREAKING_BUMP=minor tag; expect_rc 0; expect_out_has "a minor bump: tagged v2.1.0"
}

t_other_types_release_nothing_by_default() {
  world
  tag_here v1.4.2
  merge "docs: say how (#3)"
  merge "Update README.md"
  tag; expect_rc 0; expect_out "2 merge(s) since v1.4.2, none that releases: no tag"
  expect_true "the outputs are wrong" [ "$(output)" = $'previous=v1.4.2\nbump=none' ]
  expect_true "pushed a tag" [ "$(origin_tags)" = "v1.4.2 " ]
  MROOM_TAG_OTHER_BUMP="patch" tag; expect_rc 0; expect_out_has "a patch bump: tagged v1.4.3"
}

t_merge_commits_are_read_by_their_title() {
  world
  tag_here v0.4.0
  git -C "$T/app" switch -q -c topic
  merge "feat!: a commit on the branch that the merge's title outranks"
  git -C "$T/app" switch -q main
  git -C "$T/app" merge -q --no-ff topic -m $'Merge pull request #7 from me/topic\n\nfeat(qa): bring QA up'
  tag; expect_rc 0; expect_out_has "1 merge(s) since v0.4.0, a minor bump: tagged v0.5.0"
}

t_the_first_tag_counts_from_zero() {
  world
  merge "fix: one (#1)"
  merge "feat: two (#2)"
  tag; expect_rc 0; expect_out_has "3 merge(s) since the first commit, a minor bump: tagged v0.1.0"
  expect_true "the outputs are wrong" [ "$(output)" = $'previous=\ntag=v0.1.0\nbump=minor' ]
}

t_a_tagged_commit_is_left_alone() {
  world
  merge "feat: two (#2)"
  tag_here v3.0.0
  tag; expect_rc 0; expect_out "v3.0.0 already tags this commit: nothing to do"
  expect_true "the outputs are wrong" [ "$(output)" = $'tag=v3.0.0\nbump=none' ]
  # A re-run after a tag it pushed itself.
  merge "fix: three (#3)"
  tag; expect_out_has "tagged v3.0.1"
  tag; expect_rc 0; expect_out "v3.0.1 already tags this commit: nothing to do"
}

t_a_later_tag_covers_a_re_run() {
  world
  tag_here v1.0.0
  merge "feat: add (#1)"
  local older
  older="$(git -C "$T/app" rev-parse HEAD)"
  merge "fix: keep it (#2)"
  tag; expect_out_has "tagged v1.1.0"
  # The older push's run, run again: v1.1.0 is on a later commit and counts its merge.
  git -C "$T/app" switch -q --detach "$older"
  tag; expect_rc 0; expect_out "v1.1.0, on a later commit, already counts this one: nothing to do"
  expect_true "the outputs are wrong" [ "$(output)" = $'previous=v1.0.0\ntag=v1.1.0\nbump=none' ]
}

t_the_highest_merged_version_counts() {
  world
  tag_here v1.9.0
  merge "fix: a (#1)"
  tag_here v1.10.0
  merge "fix: b (#2)"
  # Other tags, and versions that are not on the default branch, do not count.
  git -C "$T/app" tag nightly
  git -C "$T/app" tag v1.2
  git -C "$T/app" tag release-v9.0.0
  git -C "$T/app" switch -q -c side HEAD~2
  merge "feat: on a side branch"
  git -C "$T/app" tag v5.0.0
  git -C "$T/app" switch -q main
  tag; expect_rc 0; expect_out_has "1 merge(s) since v1.10.0, a patch bump: tagged v1.10.1"
}

t_a_prefix() {
  world
  tag_here release-1.0.0
  git -C "$T/app" tag v7.0.0
  git -C "$T/app" tag 4.0.0
  merge "feat: add (#2)"
  MROOM_TAG_PREFIX=release- tag; expect_rc 0; expect_out_has "1 merge(s) since release-1.0.0, a minor bump: tagged release-1.1.0"
  merge "fix: keep it (#3)"
  MROOM_TAG_PREFIX="" tag; expect_rc 0; expect_out_has "2 merge(s) since 4.0.0, a minor bump: tagged 4.1.0"
}

t_bad_settings_are_refused() {
  world
  merge "feat: add (#2)"
  local bad
  # shellcheck disable=SC2016 # a literal $(id) is the point: it must be refused, never run
  for bad in 'v.' 'v/' '1v' 'v$(id)' 'v;id' $'v\nx' '-v' 'abcdefghijklmnopqrstuvwxyzabcdefg'; do
    MROOM_TAG_PREFIX="$bad" tag; expect_rc 1; expect_out_has "tag-prefix must be letters, digits"
  done
  MROOM_TAG_BREAKING_BUMP="patch" tag; expect_rc 1; expect_out_has "breaking-bump must be major or minor."
  MROOM_TAG_OTHER_BUMP=minor tag; expect_rc 1; expect_out_has "other-bump must be none or patch."
  MROOM_TAG_DRY_RUN=yes tag; expect_rc 1; expect_out_has "dry-run must be true or false."
  expect_true "pushed a tag" [ -z "$(origin_tags)" ]
}

t_a_dry_run_pushes_nothing() {
  world
  tag_here v1.0.0
  merge "feat: add (#2)"
  MROOM_TAG_DRY_RUN=true tag; expect_rc 0; expect_out_has "a minor bump: would tag v1.1.0 (dry run)"
  expect_true "the outputs are wrong" [ "$(output)" = $'previous=v1.0.0\ntag=v1.1.0\nbump=minor' ]
  expect_true "tagged in a dry run" [ "$(git -C "$T/app" tag)" = v1.0.0 ]
  expect_true "pushed in a dry run" [ "$(origin_tags)" = "v1.0.0 " ]
}

t_a_shallow_checkout_is_refused() {
  world
  merge "feat: add (#2)"
  git -C "$T/app" push -q origin main
  git clone -q --depth 1 "file://$T/origin.git" "$T/shallow"
  run "$TAG" "$T/shallow"; expect_rc 1; expect_out_has "The checkout is shallow; check it out with fetch-depth: 0"
}

t_a_taken_tag_is_an_error() {
  world
  tag_here v1.0.0
  git -C "$T/app" switch -q -c side
  merge "fix: elsewhere"
  git -C "$T/app" tag v1.1.0
  git -C "$T/app" switch -q main
  merge "feat: add (#2)"
  tag; expect_rc 1; expect_out_has "v1.1.0 already exists on another commit"
  # One pushed to origin since the checkout.
  git -C "$T/app" tag -d v1.1.0 >/dev/null
  git -C "$T/app" push -q origin main
  git clone -q "$T/origin.git" "$T/other"
  git -C "$T/other" tag v1.1.0 && git -C "$T/other" push -q origin v1.1.0
  tag; expect_rc 1; expect_out_has "Could not push v1.1.0; it may exist on origin already."
}

test_case feat-minor t_feat_bumps_the_minor
test_case fix-patch t_fix_bumps_the_patch
test_case breaking-major t_a_breaking_change_bumps_the_major
test_case other-types-nothing t_other_types_release_nothing_by_default
test_case merge-commits t_merge_commits_are_read_by_their_title
test_case first-tag t_the_first_tag_counts_from_zero
test_case tagged-commit t_a_tagged_commit_is_left_alone
test_case later-tag-covers t_a_later_tag_covers_a_re_run
test_case highest-merged t_the_highest_merged_version_counts
test_case prefix t_a_prefix
test_case bad-settings t_bad_settings_are_refused
test_case dry-run t_a_dry_run_pushes_nothing
test_case shallow t_a_shallow_checkout_is_refused
test_case taken-tag t_a_taken_tag_is_an_error
finish
