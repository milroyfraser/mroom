#!/usr/bin/env bash
# resolve.sh — which pull request and commit a qa-up run is for (.github/workflows/qa-up.yml; design 8.2), from
# GitHub's record of the QA plan run alone. That run ran the pull request's own code, so nothing it wrote is
# trusted, and neither is anything the event that started qa-up says about it: only the run's id is taken from it.
#
# Environment:
#   RUN_ID          the plan run: the workflow_run event's, or the plan_run_id the plan's hand-over passed
#   DISPATCHED_PR   for a qa-up the hand-over started, the pull request it named, which the plan run's name must
#                   match; empty for a qa-up started on workflow_run
#   PLAN_WORKFLOW   the app's QA plan workflow file (qa-plan.yml): a run of any other workflow deploys nothing
#   DEFAULT_BRANCH  the repository's default branch
#   LABEL           the label that forces an environment on (qa)
#   GH_TOKEN (pull-requests: read, actions: read), GITHUB_REPOSITORY
#
# The run must be of this repository's QA plan workflow. One started on pull_request is for the one open pull
# request of this repository whose head is the commit the run is for: among those GitHub links to the run, or, when
# it links none, among those it finds by that commit. One started on workflow_dispatch counts only on the default
# branch, under the name "PR #<N>" its workflow gives it there (README, QA environments), and is for the commit its
# build job is named after, which only that workflow wrote. A qa-up the hand-over started takes only such a run.
# The build job's own conclusion says whether there is a build: a run whose build was skipped built nothing,
# whatever GitHub calls the run. A called workflow's job is named "<the caller's job> / QA build <commit>".
#
# Prints, for GITHUB_OUTPUT: go=true|false, and with go=true: number, sha (the commit the plan built, which is the
# pull request's head), draft, forced (the label is on), built (the build job succeeded), dispatched (the plan was
# started by hand or by a wake), woken (first started by the job token: a wake), run_id and run_url (the plan run
# checked here, whose build qa-up deploys). go=false, with a notice, when there is nothing to deploy: no plan of this
# repository, a build job that never ran to an end, a dispatch that did not run on the default branch or names
# another pull request, a closed pull request or a fork's, or a build of a commit the pull request has since moved
# past, whose newer push brings its own run. Exits 1 when GitHub cannot be read.
set -euo pipefail

repo="${GITHUB_REPOSITORY:?}"
label="${LABEL:-qa}"
plan="${PLAN_WORKFLOW:-qa-plan.yml}"
stop() { echo "::notice::qa-up: $*" >&2; echo "go=false"; exit 0; }
broke() { echo "::error::qa-up: $*" >&2; exit 1; }
# literal <text>: the text as an extended regex that matches it alone.
# shellcheck disable=SC2001,SC2016  # sed is clearer here than ${//}, and $ in the brackets is sed's own
literal() { sed 's/[][\.*^$()+?{}|]/\\&/g' <<<"$1"; }

[[ "${RUN_ID:-}" =~ ^[1-9][0-9]{0,19}$ ]] || stop "no plan run id"
[[ "$plan" =~ ^[A-Za-z0-9._-]+\.ya?ml$ ]] || broke "PLAN_WORKFLOW is not a workflow file name"
run="$(gh api "repos/$repo/actions/runs/$RUN_ID")" || broke "GitHub gave no plan run $RUN_ID"
get() { jq -r "$1 | if . == null then \"\" else tostring end" <<<"$run"; }

[ "$(get .repository.full_name)" = "$repo" ] || stop "run $RUN_ID is not of this repository"
# GitHub writes the path as .github/workflows/<file>, or with the repository before it and a ref after it.
[[ "$(get .path)" =~ ^($(literal "$repo")/)?\.github/workflows/$(literal "$plan")(@[^[:space:]]+)?$ ]] \
  || stop "run $RUN_ID is not of the QA plan workflow, .github/workflows/$plan"
event="$(get .event)" head_sha="$(get .head_sha)" run_url="$(get .html_url)"
if [ -n "${DISPATCHED_PR:-}" ] && [ "$event" != workflow_dispatch ]; then
  stop "the hand-over named run $RUN_ID, which was started on $event, not by a dispatch"
fi

# The build job, by its name, which carries the commit it built: its conclusion, and that commit.
jobs="$(gh api "repos/$repo/actions/runs/$RUN_ID/jobs" --jq '[.jobs[] | {name, conclusion}]')" \
  || broke "GitHub gave no jobs of plan run $RUN_ID"
build="$(jq -r '[.[] | select(.name | test("(\\A|\\A.* / )QA build [0-9a-f]{40}\\z"))] | first // empty
  | "\(.conclusion // "unfinished") \(.name | .[-40:])"' <<<"$jobs")"
read -r conclusion built_sha <<<"${build:-missing -}"
case "$conclusion" in
  success) built=true ;;
  failure) built=false ;;
  *) stop "the QA build job did not run to an end ($conclusion)" ;;
esac

pr="" dispatched=false woken=false
case "$event" in
  pull_request)
    [ "$(get .head_repository.full_name)" = "$repo" ] || stop "run $RUN_ID is for a fork's commit"
    [[ "$head_sha" =~ ^[0-9a-f]{40}$ ]] || stop "run $RUN_ID names no commit"
    # GitHub's links: open pull requests whose head matches the run, not necessarily the one that started it. Only
    # one of this repository's own, at the run's commit, counts.
    pr="$(jq -r --arg sha "$head_sha" '.repository.id as $id | [(.pull_requests // [])[]
        | select(.head.sha == $sha and .head.repo.id == $id and .base.repo.id == $id) | .number]
      | if length == 1 then .[0] elif length == 0 then "" else "many" end' <<<"$run")"
    if [ -z "$pr" ]; then
      # GitHub leaves the links out at times: then the open pull requests of this repository at that commit.
      pr="$(gh api "repos/$repo/commits/$head_sha/pulls" | jq -r --arg repo "$repo" --arg sha "$head_sha" \
        '[.[] | select(.state == "open" and .head.repo.full_name == $repo and .base.repo.full_name == $repo
          and .head.sha == $sha) | .number] | if length == 1 then .[0] elif length == 0 then "" else "many" end')" \
        || broke "GitHub gave no pull requests of commit ${head_sha:0:9}"
    fi
    [ "$pr" != many ] || stop "more than one open pull request has the commit ${head_sha:0:9}, so which one is not known"
    [ -n "$pr" ] || stop "no open pull request of this repository has the commit ${head_sha:0:9}"
    [ "$built_sha" = "$head_sha" ] || stop "run $RUN_ID built ${built_sha:0:9}, not its own commit ${head_sha:0:9}"
    ;;
  workflow_dispatch)
    # Only the default branch's workflow names a dispatched run, and its build job; a dispatch on another branch
    # ran that branch's copy, whose names prove nothing.
    [ "$(get .head_branch)" = "${DEFAULT_BRANCH:?}" ] \
      || stop "a QA plan started by hand counts only on the default branch"
    [[ "$(get .display_title)" =~ ^PR\ \#([1-9][0-9]{0,8})$ ]] \
      || stop "a QA plan started by hand counts only under the name 'PR #<N>'"
    pr="${BASH_REMATCH[1]}"
    [ -z "${DISPATCHED_PR:-}" ] || [ "$DISPATCHED_PR" = "$pr" ] \
      || stop "the hand-over named pull request ${DISPATCHED_PR:0:12}, but run $RUN_ID is for pull request $pr"
    dispatched=true
    # By who started the run first (actor), not who re-ran it (triggering_actor): a person's re-run of a woken plan
    # is still the wake's, as the plan's hand-over takes it.
    [ "$(get .actor.login)" != "github-actions[bot]" ] || woken=true
    ;;
  *) stop "a QA plan started by '${event:-nothing}' deploys nothing" ;;
esac
[[ "$built_sha" =~ ^[0-9a-f]{40}$ ]] || stop "run $RUN_ID's build job names no commit"

info="$(gh pr view "$pr" --repo "$repo" --json number,state,headRefOid,isDraft,isCrossRepository,labels)" \
  || broke "GitHub gave no pull request $pr"
jq -e '.state == "OPEN"' <<<"$info" >/dev/null || stop "pull request $pr is not open"
jq -e '.isCrossRepository | not' <<<"$info" >/dev/null || stop "pull request $pr is from a fork"
sha="$(jq -r .headRefOid <<<"$info")"
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || stop "pull request $pr has no head commit GitHub names"
# A build of an older commit: deploying it would go backwards, and the newer push's run deploys that one.
if [ "$sha" != "$built_sha" ]; then
  stop "pull request $pr has moved on from ${built_sha:0:9} to ${sha:0:9}; that push's own run deploys it"
fi
jq -r --arg built "$built" --arg dispatched "$dispatched" --arg woken "$woken" --arg label "$label" \
  --arg run_id "$RUN_ID" --arg run_url "$run_url" '"go=true", "number=\(.number)", "sha=\(.headRefOid)",
  "draft=\(.isDraft)", "forced=\([.labels[].name] | index($label) != null)", "built=\($built)",
  "dispatched=\($dispatched)", "woken=\($woken)", "run_id=\($run_id)", "run_url=\($run_url)"' <<<"$info"
