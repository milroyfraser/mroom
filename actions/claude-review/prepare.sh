#!/usr/bin/env bash
# prepare.sh <dir> — what the Claude review (actions/claude-review) reads besides the diff, written into <dir>,
# a folder in the workspace where the reviewer can read it. Prints mode=full or mode=follow-up for
# $GITHUB_OUTPUT on stdout.
#
# One full review, then follow-ups. The first review marks every finding blocking or optional. A later push
# gets a follow-up that only re-checks the earlier blocking findings and looks for new blocking ones in what
# changed since: no new nits, nothing the author already answered. Reviewing every push from scratch gave a
# fresh set of nits each round and kept pull requests in review for 4 or 5 rounds.
#
#   <dir>/comments.json            the pull request's comments (hide.sh reads them too)
#   <dir>/previous-review.md       the last review: MROOM_REVIEWER's latest comment with the review marker
#   <dir>/conversation-since.md    the comments and review comments posted after it
#   <dir>/since-last-review.diff   what changed since the commit it reviewed
#   <dir>/pr-files.txt             the pull request's own files: the rest of that diff came from the base
#
# The last four only for a follow-up. No previous review, or a diff GitHub cannot give (the reviewed commit is
# gone after a force-push, or the diff is past GitHub's size limit), means a full review. Everything here is
# read through the API as data. Env: REPO, PR, HEAD_SHA, MROOM_REVIEWER, GH_TOKEN.
set -euo pipefail

DIR="${1:?usage: prepare.sh <dir>}"
REPO="${REPO:?REPO (owner/repo) is not set}"
fail() { echo "::error title=Claude review::$1" >&2; exit 1; }
[[ "${PR:-}" =~ ^[0-9]+$ ]] || fail "PR must be a pull request number."
[[ "${HEAD_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || fail "HEAD_SHA must be a 40-hex commit."
[[ "${MROOM_REVIEWER:-}" =~ ^[A-Za-z0-9][A-Za-z0-9-]*(\[bot\])?$ ]] || fail "reviewer must be a GitHub login, such as claude[bot]."

mkdir -p "$DIR"
gh api --paginate "repos/$REPO/issues/$PR/comments?per_page=100" --jq '.[]' | jq -s . >"$DIR/comments.json" ||
  fail "Could not read the pull request's comments; run the check again."

prev="$(jq -c --arg r "$MROOM_REVIEWER" '[.[] | select(.user.login == $r and (.body // "" | test("<!-- claude-review sha=[0-9a-f]{40} -->")))]
  | sort_by(.created_at) | last // empty' "$DIR/comments.json")"
mode=full
if [ -n "$prev" ]; then
  prev_sha="$(jq -r '[.body | scan("<!-- claude-review sha=([0-9a-f]{40}) -->")] | last | .[0]' <<<"$prev")"
  prev_at="$(jq -r .created_at <<<"$prev")"
  if gh api "repos/$REPO/compare/$prev_sha...$HEAD_SHA" -H 'Accept: application/vnd.github.diff' \
    >"$DIR/since-last-review.diff" 2>/dev/null &&
    gh api --paginate "repos/$REPO/pulls/$PR/files?per_page=100" --jq '.[].filename' >"$DIR/pr-files.txt" 2>/dev/null &&
    gh api --paginate "repos/$REPO/pulls/$PR/comments?per_page=100" --jq '.[]' | jq -s . >"$DIR/review-comments.json" 2>/dev/null; then
    mode=follow-up
    jq -r .body <<<"$prev" >"$DIR/previous-review.md"
    { jq -r --arg at "$prev_at" '.[] | select(.created_at > $at) | "### \(.user.login) (\(.created_at))\n\(.body)\n"' "$DIR/comments.json"
      jq -r --arg at "$prev_at" '.[] | select(.created_at > $at) | "### \(.user.login) on \(.path) (\(.created_at))\n\(.body)\n"' "$DIR/review-comments.json"
    } >"$DIR/conversation-since.md"
  else
    echo "the diff since the last review is not available: a full review" >&2
    rm -f "$DIR/since-last-review.diff" "$DIR/pr-files.txt"
  fi
  rm -f "$DIR/review-comments.json"
fi
echo "review mode: $mode" >&2
echo "mode=$mode"
