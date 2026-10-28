#!/usr/bin/env bash
# scope.sh <event.json> — whether the Claude review (actions/claude-review) runs on this pull request, and
# whether the app's review guide applies. Prints two outputs for $GITHUB_OUTPUT on stdout, and its reasons on
# stderr:
#
#   review=true|false   false for a fork's pull request (it gets no secret), and when no changed file
#                       matches MROOM_REVIEW_PATHS (empty: every file matches)
#   guide=true|false    true when MROOM_REVIEW_GUIDE is set and a changed file matches
#                       MROOM_REVIEW_GUIDE_PATHS (empty: every file matches)
#
# Patterns are matched as paths.jq says. It reads the pull request's number and repositories from the event
# file and its changed files from the API (a rename counts by both names). It holds no secret and runs no
# pull request code. Env: REPO (owner/repo), GH_TOKEN.
set -euo pipefail

HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVENT="${1:?usage: scope.sh <event.json>}"
REPO="${REPO:?REPO (owner/repo) is not set}"

fail() { echo "::error title=Claude review::$1" >&2; exit 1; }

{ pr="$(jq -r '.pull_request.number // empty' "$EVENT")" &&
  head_repo="$(jq -r '.pull_request.head.repo.full_name // empty' "$EVENT")"; } ||
  fail "Could not read the pull request from the event file; the error is above."
[[ "$pr" =~ ^[0-9]+$ ]] || fail "The event names no pull request: call the review from a pull_request or pull_request_target workflow."

# A fork's pull request never reaches the secret, whatever the caller's trigger: under pull_request_target
# GitHub would hand it over.
if [ "$head_repo" != "$REPO" ]; then
  echo "a pull request from another repository gets no review: it must not reach the secret" >&2
  printf 'review=false\nguide=false\n'
  exit 0
fi

files="$(gh api --paginate "repos/$REPO/pulls/$pr/files?per_page=100" \
  --jq '[.[] | .filename, (.previous_filename // empty)]' | jq -s 'add // []')" ||
  fail "Could not list the pull request's files; run the check again."

# Through stdin, never argv: a large pull request's file list is longer than one argument may be.
result="$(jq -c -L "$HERE" --arg paths "${MROOM_REVIEW_PATHS:-}" --arg guide_paths "${MROOM_REVIEW_GUIDE_PATHS:-}" '
  include "paths";
  . as $files
  | ($paths | patterns) as $p | ($guide_paths | patterns) as $g
  | [$files[] | select(($p | length) == 0 or matches_any($p))] as $in
  | {total: ($files | length), in: ($in | length),
     guide: ([$in[] | select(($g | length) == 0 or matches_any($g))] | length)}' <<<"$files")" ||
  fail "Could not match the files against the paths; the error is above."

total="$(jq -r .total <<<"$result")" in="$(jq -r .in <<<"$result")" in_guide="$(jq -r .guide <<<"$result")"
review=false guide=false
[ "$in" -gt 0 ] && review=true
[ "$review" = true ] && [ -n "${MROOM_REVIEW_GUIDE:-}" ] && [ "$in_guide" -gt 0 ] && guide=true
if [ -n "${MROOM_REVIEW_GUIDE:-}" ]; then
  echo "$in of $total changed files in the review's paths, $in_guide of them in the guide's" >&2
else
  echo "$in of $total changed files in the review's paths; no review guide" >&2
fi
printf 'review=%s\nguide=%s\n' "$review" "$guide"
