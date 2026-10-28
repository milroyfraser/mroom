#!/usr/bin/env bash
# review-findings.sh — the review findings check run on a pull request's head commit (actions/review-findings):
# red while the latest Claude review has open 🔴 blocking findings, or while a "Review findings and how each
# was resolved" table has an unresolved row (evaluate.jq says exactly when).
#
#   review-findings.sh --event <event.json>   the pull request(s) the event is about; what the action runs
#   review-findings.sh <pr>                   one pull request, by number
#   review-findings.sh --pr-for-sha <sha>     prints the open pull request(s) whose head is <sha>
#
# Every run rereads the pull request's comments, so which event woke it does not matter. It reads them through
# the API, as data, and runs no pull request code. Comment text in the summary is escaped (evaluate.jq, safe).
# Env: GH_TOKEN (checks: write to post), REPO or GITHUB_REPOSITORY (owner/repo), MROOM_REVIEWER (default
# claude[bot]), MROOM_CHECK_NAME (default "Review findings"). REVIEW_FINDINGS_DRY_RUN=1 prints the check run's
# JSON instead of posting it, so it is safe to run by hand.
set -euo pipefail

HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
NAME="${MROOM_CHECK_NAME:-Review findings}"
REVIEWER="${MROOM_REVIEWER:-claude[bot]}"

fail() { echo "::error title=review findings::$1" >&2; exit "${2:-1}"; }
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "REPO (owner/repo) is not set." 2
[[ "$REVIEWER" =~ ^[A-Za-z0-9][A-Za-z0-9-]*(\[bot\])?$ ]] || fail "reviewer must be a GitHub login, such as claude[bot]." 2
[[ "$NAME" =~ ^[^[:cntrl:]]{1,100}$ ]] || fail "check-name must be one line of 1 to 100 characters." 2

# prs_for_sha <sha>: the open pull requests whose head is <sha>. A workflow_run of the review lists no pull
# request for a fork's; its head commit still finds it.
prs_for_sha() {
  gh api "repos/$REPO/commits/$1/pulls" --jq '.[] | [.state, .head.sha, .number] | @tsv' |
    awk -F '\t' -v sha="$1" '$1 == "open" && $2 == sha { print $3 }'
}

# check <pr>: evaluates one pull request and posts (or prints) its check run.
check() {
  local pr="$1" pull head_sha author result payload
  # The head is read now, not taken from the event: issue_comment events carry none, and after a push since the
  # event the check belongs on the newer commit. The author's findings table counts (evaluate.jq).
  pull="$(gh api "repos/$REPO/pulls/$pr" --jq '"\(.head.sha) \(.user.login)"')" ||
    fail "Could not read pull request $pr; run the check again."
  head_sha="${pull%% *}" author="${pull#* }"
  [[ "$head_sha" =~ ^[0-9a-f]{40}$ ]] || fail "No head commit for pull request $pr."
  # Through stdin and pipes, never argv: a pull request's comments can be larger than one argument may be.
  result="$(gh api --paginate "repos/$REPO/issues/$pr/comments?per_page=100" \
    --jq '.[] | {login: .user.login, association: .author_association, body, html_url, created_at}' |
    jq -s --arg head "$head_sha" --arg author "${author:-}" '{head_sha: $head, pr_author: $author, comments: .}' |
    jq -L "$HERE" --arg reviewer "$REVIEWER" -f "$HERE/evaluate.jq")" ||
    fail "Could not read the comments of pull request $pr; run the check again."
  payload="$(jq --arg name "$NAME" --arg sha "$head_sha" '{
    name: $name, head_sha: $sha, status: "completed", conclusion,
    output: {title, summary}}' <<<"$result")"
  if [ "${REVIEW_FINDINGS_DRY_RUN:-}" = 1 ]; then
    echo "$payload"
    return
  fi
  # A new, completed check run per evaluation: GitHub shows the latest one with this name.
  gh api -X POST "repos/$REPO/check-runs" --input - --jq '"\(.conclusion): \(.html_url)"' <<<"$payload" ||
    fail "Could not post the check run for pull request $pr; run the check again."
}

case "${1:-}" in
  --pr-for-sha)
    [[ "${2:-}" =~ ^[0-9a-f]{40}$ ]] || fail "usage: review-findings.sh --pr-for-sha <40-hex sha>" 2
    prs_for_sha "$2"
    ;;
  --event)
    event="${2:?usage: review-findings.sh --event <event.json>}"
    # A pull request event, a pull request's comment (an issue's comment has no pull_request), or a completed
    # review run, which names its pull request, or only its head commit for a fork's.
    pr="$(jq -r '.pull_request.number // (if .issue.pull_request then .issue.number else null end)
      // .workflow_run.pull_requests[0].number // empty' "$event")" ||
      fail "Could not read the event file; the error is above."
    sha="$(jq -r '.workflow_run.head_sha // empty' "$event")"
    prs="$pr"
    if [ -z "$prs" ] && [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
      prs="$(prs_for_sha "$sha")" || fail "Could not find the pull request of commit $sha; run the check again."
    fi
    if [ -z "$prs" ]; then
      echo "::notice title=review findings::no open pull request for this event; nothing to check"
      exit 0
    fi
    for pr in $prs; do
      [[ "$pr" =~ ^[0-9]+$ ]] || fail "Not a pull request number: $pr"
      check "$pr"
    done
    ;;
  *)
    [[ "${1:-}" =~ ^[0-9]+$ ]] || fail "usage: review-findings.sh <pr number> | --event <event.json> | --pr-for-sha <sha>" 2
    check "$1"
    ;;
esac
