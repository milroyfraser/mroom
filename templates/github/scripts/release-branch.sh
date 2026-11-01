#!/usr/bin/env bash
# release-branch.sh — points the release branch at a release tag's commit, so the host deploys the tag and never a
# branch tip (mroom design 10, pattern 8). The deploy-production workflow runs it from a checkout of the tag, in the
# job of the production environment, whose deploy key alone may push the release branch.
#
# It refuses a run that is not from a tag, a tag that does not match TAG_PATTERN, a release whose tag is not the
# run's, and a tag whose commit is not on the default branch. The branch may move forward (a release), back (a
# rollback, started by a person from an older tag) or stay (a re-run). Only this script moves it, so when it is at a
# commit off the default branch, or at one neither before nor after the tag, someone else moved it: the script stops
# for a person. It stops too while the remote has a tag named like the branch, which git takes over the branch when a
# host fetches the branch by its short name.
#
# Environment: EVENT (github.event_name), REF_TYPE and REF_NAME (github.ref_type, github.ref_name), RELEASE_TAG
# (github.event.release.tag_name, for a release), DEFAULT_BRANCH, TAG_PATTERN (a bash regular expression) and,
# optionally, RELEASE_BRANCH (release). Prints tag=, commit=, previous= (the branch's commit before, or none) and
# direction= (new, forward, rollback or same) for GITHUB_OUTPUT; messages go to stderr. It prints no credential:
# the push uses the key the checkout set up.
set -euo pipefail

fail() { echo "::error::$*" >&2; exit 1; }

branch="${RELEASE_BRANCH:-release}"
[ "${REF_TYPE:-}" = tag ] || fail "a production deploy runs from a release tag, not the ${REF_TYPE:-unknown} ${REF_NAME:-}: gh workflow run <this workflow> --ref <tag>"
tag="${REF_NAME:-}"
[[ "$tag" =~ ${TAG_PATTERN:?TAG_PATTERN is not set} ]] || fail "$tag is not a release tag (it does not match $TAG_PATTERN)"
if [ "${EVENT:-}" = release ] && [ "${RELEASE_TAG:-}" != "$tag" ]; then
  fail "the release is for ${RELEASE_TAG:-no tag}, but the run is for $tag"
fi
[ -n "${DEFAULT_BRANCH:-}" ] || fail "DEFAULT_BRANCH is not set"

commit="$(git rev-parse --verify --quiet "refs/tags/$tag^{commit}")" || fail "no tag $tag in this checkout"
[ "$(git rev-parse HEAD)" = "$commit" ] || fail "the checkout is not at $tag's commit $commit"

git fetch --quiet --no-tags origin "+refs/heads/$DEFAULT_BRANCH:refs/remotes/origin/$DEFAULT_BRANCH"
git merge-base --is-ancestor "$commit" "refs/remotes/origin/$DEFAULT_BRANCH" \
  || fail "$tag ($commit) is not on $DEFAULT_BRANCH: production deploys only commits that went through $DEFAULT_BRANCH"

# git ranks refs/tags above refs/heads, so a host whose deploy script fetches the branch by its short name (git pull
# origin release) takes a tag of that name instead, and anyone with Write can push one. The branch's own ruleset does
# not cover a tag.
shadow="$(git ls-remote --refs --tags origin "$branch" | awk -v ref="refs/tags/$branch" '$2 == ref')"
[ -z "$shadow" ] \
  || fail "origin has the tag $branch, which a fetch of $branch by its short name takes over the branch: a person removes it, since the host could deploy it instead of $tag"

previous=""
if git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
  git fetch --quiet --no-tags origin "+refs/heads/$branch:refs/remotes/origin/$branch"
  previous="$(git rev-parse "refs/remotes/origin/$branch")"
fi

if [ -n "$previous" ] && ! git merge-base --is-ancestor "$previous" "refs/remotes/origin/$DEFAULT_BRANCH"; then
  fail "$branch is at $previous, which is not on $DEFAULT_BRANCH: someone else moved it, so a person checks before a deploy moves it again"
fi
if [ -z "$previous" ]; then
  direction=new
elif [ "$previous" = "$commit" ]; then
  direction=same
elif git merge-base --is-ancestor "$previous" "$commit"; then
  direction=forward
elif git merge-base --is-ancestor "$commit" "$previous"; then
  direction=rollback
else
  fail "$branch is at $previous, which is neither before nor after $tag ($commit): someone else moved it, so a person checks before a deploy moves it again"
fi

# The lease names the commit read above, so a branch someone moved in between is not overwritten.
case "$direction" in
  same) echo "$branch is already at $tag ($commit): nothing to push; the host deploys only on a push or its deploy hook" >&2 ;;
  new) git push --quiet origin "$commit:refs/heads/$branch" ;;
  forward) git push --quiet --force-with-lease="refs/heads/$branch:$previous" origin "$commit:refs/heads/$branch" ;;
  rollback)
    echo "::warning::rolling $branch back from $previous to $tag ($commit)" >&2
    git push --quiet --force-with-lease="refs/heads/$branch:$previous" origin "+$commit:refs/heads/$branch" ;;
esac
[ "$direction" = same ] || echo "$branch now at $tag ($commit), $direction from ${previous:-nothing}" >&2

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  # shellcheck disable=SC2016  # the backticks are Markdown
  printf '### Release branch\n\n`%s` points at %s (`%s`): %s, from `%s`.\n' \
    "$branch" "$tag" "$commit" "$direction" "${previous:-none}" >>"$GITHUB_STEP_SUMMARY"
fi
printf 'tag=%s\ncommit=%s\nprevious=%s\ndirection=%s\n' "$tag" "$commit" "${previous:-none}" "$direction"
