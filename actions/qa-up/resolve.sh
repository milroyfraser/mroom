#!/usr/bin/env bash
# resolve.sh — which pull request and commit a qa-up run is for (.github/workflows/qa-up.yml; design 8.2). The QA
# plan run that started it ran the pull request's own code, so nothing that run wrote is trusted: the answer comes
# from GitHub's records, and from a run's name only when the default branch's workflow wrote it.
#
# Environment, from the workflow_run event:
#   EVENT           the plan run's event: pull_request or workflow_dispatch
#   LINKED          the pull request GitHub linked to the plan run (pull_request only; can be empty)
#   TITLE           the plan run's name: "PR #<N>" for one started by hand or by a wake (README, QA environments)
#   HEAD_BRANCH     the plan run's branch: the pull request's, or the one a dispatch ran on
#   HEAD_SHA        the plan run's commit: the head it built (pull_request only)
#   DEFAULT_BRANCH  the repository's default branch
#   RUN_ID          the plan run's id
#   LABEL           the label that forces an environment on (qa)
#   GH_TOKEN (pull-requests: read, actions: read), GITHUB_REPOSITORY
#
# Prints, for GITHUB_OUTPUT: go=true|false, and with go=true: number, sha, draft, forced (the label is on), built
# (the plan's QA build job succeeded) and dispatched. go=false, with a notice, when there is nothing to deploy: a
# build job that never ran (an unrelated label) or was cancelled, a dispatch that did not run on the default
# branch, a closed pull request or a fork's, or a build of a commit the pull request has since moved past, whose
# newer push brings its own run.
set -euo pipefail

repo="${GITHUB_REPOSITORY:?}"
label="${LABEL:-qa}"
stop() { echo "::notice::qa-up: $*" >&2; echo "go=false"; exit 0; }

# The build job's own conclusion, not the run's: a run whose job was skipped built nothing, whatever GitHub calls
# the run. A called workflow's job is named "<the caller's job> / QA build".
[[ "${RUN_ID:-}" =~ ^[0-9]+$ ]] || stop "no plan run id"
build="$(gh api "repos/$repo/actions/runs/$RUN_ID/jobs" \
  --jq '[.jobs[] | select(.name == "QA build" or (.name | endswith(" / QA build")))] | first | .conclusion // "missing"')"
case "$build" in
  success) built=true ;;
  failure) built=false ;;
  *) stop "the QA build job did not run to an end ($build)" ;;
esac

pr=""
case "${EVENT:-}" in
  pull_request)
    if [[ "${LINKED:-}" =~ ^[0-9]+$ ]]; then
      pr="$LINKED"
    else
      [[ "${HEAD_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || stop "the plan run names no commit"
      # GitHub leaves the link out at times: then the open pull request of this repository whose head is the commit
      # that was built.
      pr="$(gh api "repos/$repo/commits/$HEAD_SHA/pulls" | jq -r --arg repo "$repo" --arg sha "$HEAD_SHA" \
        '[.[] | select(.state == "open" and .head.repo.full_name == $repo and .head.sha == $sha) | .number] | first // empty')"
    fi
    dispatched=false
    ;;
  workflow_dispatch)
    # A dispatched plan's name is its input, as the default branch's workflow writes it. A dispatch on any other
    # branch ran that branch's copy of the workflow, so its name proves nothing.
    if [[ "${HEAD_BRANCH:-}" == "${DEFAULT_BRANCH:?}" && "${TITLE:-}" =~ ^PR\ \#([1-9][0-9]{0,8})$ ]]; then
      pr="${BASH_REMATCH[1]}"
    else
      stop "a QA plan started by hand counts only on the default branch, under the name 'PR #<N>'"
    fi
    dispatched=true
    ;;
  *) stop "a QA plan started by '${EVENT:-nothing}' deploys nothing" ;;
esac
[ -n "$pr" ] || stop "no open pull request of this repository has the built commit"

info="$(gh pr view "$pr" --repo "$repo" --json number,state,headRefOid,isDraft,isCrossRepository,labels)"
jq -e '.state == "OPEN"' <<<"$info" >/dev/null || stop "pull request $pr is not open"
jq -e '.isCrossRepository | not' <<<"$info" >/dev/null || stop "pull request $pr is from a fork"
sha="$(jq -r .headRefOid <<<"$info")"
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || stop "pull request $pr has no head commit GitHub names"
# A build of an older commit: deploying it would go backwards, and the newer push's build is on its way. A
# dispatched plan ran on the default branch, so it names no commit of the pull request to compare.
if [ "$EVENT" = pull_request ] && [ "$sha" != "${HEAD_SHA:-}" ]; then
  stop "pull request $pr has moved on from ${HEAD_SHA:0:9} to ${sha:0:9}; that push's own run deploys it"
fi
jq -r --arg built "$built" --arg dispatched "$dispatched" --arg label "$label" '"go=true", "number=\(.number)",
  "sha=\(.headRefOid)", "draft=\(.isDraft)", "forced=\([.labels[].name] | index($label) != null)", "built=\($built)",
  "dispatched=\($dispatched)"' <<<"$info"
