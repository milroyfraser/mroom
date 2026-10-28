#!/usr/bin/env bash
# tag.sh [<repository folder>] — the auto-tag (actions/auto-tag). Tags the checked-out commit of the default
# branch with the next version, <prefix>X.Y.Z, from the titles merged since the last version tag:
#
#   feat           a minor bump: 1.4.2 to 1.5.0
#   fix            a patch bump: 1.4.2 to 1.4.3
#   any !          a breaking change: MROOM_TAG_BREAKING_BUMP, major (2.0.0) by default, or minor
#   any other      MROOM_TAG_OTHER_BUMP: none (no tag) by default, or patch
#
# The biggest bump of all the merges since the last tag wins, so a run that was cancelled or skipped loses no
# change. It reads each merge's title as GitHub writes it (a squash merge's first line, or the line after a merge
# commit's "Merge pull request" line), following only the first parent. With no version tag yet, it starts from
# 0.0.0. A commit that already has a version tag, or comes before one, is left as it is, so a re-run tags nothing.
#
# It pushes an annotated tag to origin, unless MROOM_TAG_DRY_RUN is true, and writes tag, previous and bump to
# $GITHUB_OUTPUT when that is set. A tag pushed with the job token starts no workflow.
#
# Env: MROOM_TAG_PREFIX (default v; letters, digits, _ and -, starting with a letter, or empty),
# MROOM_TAG_BREAKING_BUMP (major | minor), MROOM_TAG_OTHER_BUMP (none | patch), MROOM_TAG_DRY_RUN (true | false).
set -euo pipefail

HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=actions/pr-title/title.sh
source "$HERE/../pr-title/title.sh"
PREFIX="${MROOM_TAG_PREFIX-v}"
BREAKING_BUMP="${MROOM_TAG_BREAKING_BUMP:-major}"
OTHER_BUMP="${MROOM_TAG_OTHER_BUMP:-none}"
DRY_RUN="${MROOM_TAG_DRY_RUN:-false}"

fail() { echo "::error title=auto-tag::$1"; exit 1; }

[[ "$PREFIX" =~ ^([A-Za-z][A-Za-z0-9_-]{0,31})?$ ]] ||
  fail "tag-prefix must be letters, digits, _ and -, starting with a letter, at most 32, or empty."
case "$BREAKING_BUMP" in major | minor) ;; *) fail "breaking-bump must be major or minor." ;; esac
case "$OTHER_BUMP" in none | patch) ;; *) fail "other-bump must be none or patch." ;; esac
case "$DRY_RUN" in true | false) ;; *) fail "dry-run must be true or false." ;; esac
[ "$#" -le 1 ] || fail "usage: tag.sh [<repository folder>]"
[ "$#" = 0 ] || cd "$1"

[ "$(git rev-parse --is-shallow-repository)" = false ] ||
  fail "The checkout is shallow; check it out with fetch-depth: 0, so every tag and merge is there."
VERSION_RE="^${PREFIX}(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$"

output() { [ -z "${GITHUB_OUTPUT:-}" ] || printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"; }

# versions <git tag arguments...>: the version tags git lists, as "X Y Z tag", highest first.
versions() {
  local tag
  git tag "$@" | while IFS= read -r tag; do
    if [[ "$tag" =~ $VERSION_RE ]]; then
      printf '%s %s %s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "$tag"
    fi
  done | sort -k1,1nr -k2,2nr -k3,3nr
}

head="$(git rev-parse HEAD)"
here="$(versions --points-at "$head" | sed -n 1p)"
if [ -n "$here" ]; then
  echo "${here##* } already tags this commit: nothing to do"
  output tag "${here##* }"
  output bump none
  exit 0
fi

# A re-run of an older push, after a newer run tagged a later commit: that tag counts this commit's merges, and a
# tag here would come after it.
later="$(versions --contains "$head" | sed -n 1p)"
if [ -n "$later" ]; then
  echo "${later##* }, on a later commit, already counts this one: nothing to do"
  output tag "${later##* }"
  output bump none
  exit 0
fi

read -r major minor patch previous <<<"$(versions --merged "$head" | sed -n 1p)" || true
range="$head"
since="${previous:-the first commit}"
if [ -n "${previous:-}" ]; then range="refs/tags/$previous..$head"; else major=0 minor=0 patch=0 previous=""; fi

# rank: none 0, patch 1, minor 2, major 3.
rank() { case "$1" in none) echo 0 ;; patch) echo 1 ;; minor) echo 2 ;; major) echo 3 ;; esac; }
best=0 count=0
messages="$(mktemp)"
trap 'rm -f "$messages"' EXIT
git log -z --first-parent --format=%B "$range" >"$messages" || fail "Could not read the merges since $since."
while IFS= read -r -d '' message; do
  count=$((count + 1))
  bump="$OTHER_BUMP"
  if cc_parse "$(cc_commit_title "$message")"; then
    if [ -n "$CC_BREAKING" ]; then bump="$BREAKING_BUMP"
    elif [ "$CC_TYPE" = feat ]; then bump=minor
    elif [ "$CC_TYPE" = fix ]; then bump="patch"
    fi
  fi
  r="$(rank "$bump")"
  [ "$r" -le "$best" ] || best="$r"
done <"$messages"

output previous "$previous"
case "$best" in
  0)
    echo "$count merge(s) since $since, none that releases: no tag"
    output bump none
    exit 0
    ;;
  1) bump=patch patch=$((patch + 1)) ;;
  2) bump=minor minor=$((minor + 1)) patch=0 ;;
  3) bump=major major=$((major + 1)) minor=0 patch=0 ;;
esac
tag="$PREFIX$major.$minor.$patch"
[[ "$tag" =~ $VERSION_RE ]] || fail "The next version, $tag, is out of range."
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  fail "$tag already exists on another commit; tag this one by hand, or remove the stray tag."
fi

if [ "$DRY_RUN" = true ]; then
  echo "$count merge(s) since $since, a $bump bump: would tag $tag (dry run)"
else
  git -c user.name='github-actions[bot]' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
    tag -a "$tag" -m "$tag" "$head"
  git push origin "refs/tags/$tag" || fail "Could not push $tag; it may exist on origin already."
  echo "$count merge(s) since $since, a $bump bump: tagged $tag"
fi
output tag "$tag"
output bump "$bump"
