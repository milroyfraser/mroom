#!/usr/bin/env bash
# shellcheck disable=SC2317  # the t_* functions run indirectly, through test_case
# Tests for actions/qa-up/resolve.sh: a qa-up run deploys only the pull request GitHub linked to the QA plan run,
# or the one a plan started on the default branch names; never one a branch's own copy of the workflow named, a
# closed pull request or a fork's, or a build of a commit the pull request has moved past. Offline: gh is a fake.
set -euo pipefail
SUITE=qa-resolve
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/qa-world.sh
source "$(dirname "${BASH_SOURCE[0]}")/qa-world.sh"
skip_unless has_box_tools "this host lacks bash 5, flock or GNU date, which the QA actions need"

RESOLVE="$ROOT/actions/qa-up/resolve.sh"
HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
NEWER=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

# world: the fake GitHub, with plan runs whose QA build job, run by the app's job qa, succeeded (100), failed (101),
# was skipped (102) or was cancelled (103), and one whose job has its own name (104).
world() {
  qa_world
  local run
  for run in 100:success 101:failure 102:skipped 103:cancelled; do
    jq -n --arg c "${run#*:}" '{jobs: [{name: "qa / QA build", conclusion: $c}]}' >"$GH_FAKE/jobs-${run%%:*}.json"
  done
  jq -n '{jobs: [{name: "QA build", conclusion: "success"}]}' >"$GH_FAKE/jobs-104.json"
  export DEFAULT_BRANCH=main
}
# pr <number> <state> <head> <draft> <fork> <labels as JSON>: a pull request the fake knows.
pr() {
  jq -n --argjson n "$1" --arg state "$2" --arg sha "$3" --argjson draft "$4" --argjson cross "$5" --argjson labels "$6" \
    '{number: $n, state: $state, headRefOid: $sha, isDraft: $draft, isCrossRepository: $cross,
      labels: ($labels | map({name: .}))}' >"$GH_FAKE/pr-$1.json"
}
resolve() { run env "$@" "$RESOLVE"; out="$(tr '\n' ' ' <<<"$out")"; }

t_a_linked_pull_request_at_the_built_commit() {
  world
  pr 7 OPEN "$HEAD" false false '["type:feature"]'
  resolve EVENT=pull_request LINKED=7 HEAD_SHA="$HEAD" HEAD_BRANCH=feat/x RUN_ID=100
  expect_rc 0; expect_out "go=true number=7 sha=$HEAD draft=false forced=false built=true dispatched=false "
  resolve EVENT=pull_request LINKED=7 HEAD_SHA="$HEAD" HEAD_BRANCH=feat/x RUN_ID=101
  expect_out "go=true number=7 sha=$HEAD draft=false forced=false built=false dispatched=false "
  # A plan called without a job of the app's own around it names its job plainly.
  resolve EVENT=pull_request LINKED=7 HEAD_SHA="$HEAD" HEAD_BRANCH=feat/x RUN_ID=104
  expect_out "go=true number=7 sha=$HEAD draft=false forced=false built=true dispatched=false "
}

t_an_unlinked_build_is_found_by_its_commit_not_its_name() {
  world
  pr 7 OPEN "$HEAD" false false '[]'
  jq -n --arg sha "$HEAD" '[{number: 7, state: "open", head: {sha: $sha, repo: {full_name: "example/shop"}}},
    {number: 9, state: "open", head: {sha: $sha, repo: {full_name: "fork/shop"}}}]' >"$GH_FAKE/pulls.json"
  resolve EVENT=pull_request LINKED= TITLE="PR #8" HEAD_SHA="$HEAD" HEAD_BRANCH=feat/x RUN_ID=100
  expect_out "go=true number=7 sha=$HEAD draft=false forced=false built=true dispatched=false "
  echo '[]' >"$GH_FAKE/pulls.json"
  resolve EVENT=pull_request LINKED= HEAD_SHA="$HEAD" HEAD_BRANCH=feat/x RUN_ID=100
  expect_out "go=false "; expect_err_has "no open pull request of this repository has the built commit"
}

t_a_build_job_that_never_ended_deploys_nothing() {
  world
  pr 7 OPEN "$HEAD" false false '[]'
  resolve EVENT=pull_request LINKED=7 HEAD_SHA="$HEAD" HEAD_BRANCH=feat/x RUN_ID=102
  expect_out "go=false "; expect_err_has "the QA build job did not run to an end (skipped)"
  resolve EVENT=pull_request LINKED=7 HEAD_SHA="$HEAD" HEAD_BRANCH=feat/x RUN_ID=103
  expect_out "go=false "
  jq -n '{jobs: [{name: "lint", conclusion: "success"}]}' >"$GH_FAKE/jobs-105.json"
  resolve EVENT=pull_request LINKED=7 HEAD_SHA="$HEAD" HEAD_BRANCH=feat/x RUN_ID=105
  expect_out "go=false "; expect_err_has "(missing)"
}

t_an_older_build_and_closed_or_fork_pull_requests_deploy_nothing() {
  world
  pr 7 OPEN "$NEWER" false false '[]'
  resolve EVENT=pull_request LINKED=7 HEAD_SHA="$HEAD" HEAD_BRANCH=feat/x RUN_ID=100
  expect_out "go=false "; expect_err_has "has moved on from aaaaaaaaa to bbbbbbbbb"
  pr 7 CLOSED "$HEAD" false false '[]'
  resolve EVENT=pull_request LINKED=7 HEAD_SHA="$HEAD" HEAD_BRANCH=feat/x RUN_ID=100
  expect_out "go=false "; expect_err_has "pull request 7 is not open"
  pr 7 OPEN "$HEAD" false true '[]'
  resolve EVENT=pull_request LINKED=7 HEAD_SHA="$HEAD" HEAD_BRANCH=feat/x RUN_ID=100
  expect_out "go=false "; expect_err_has "pull request 7 is from a fork"
}

t_the_label_and_a_draft() {
  world
  pr 7 OPEN "$HEAD" true false '["qa"]'
  resolve EVENT=pull_request LINKED=7 HEAD_SHA="$HEAD" HEAD_BRANCH=feat/x RUN_ID=100
  expect_out "go=true number=7 sha=$HEAD draft=true forced=true built=true dispatched=false "
  resolve EVENT=pull_request LINKED=7 HEAD_SHA="$HEAD" HEAD_BRANCH=feat/x RUN_ID=100 LABEL=preview
  expect_out "go=true number=7 sha=$HEAD draft=true forced=false built=true dispatched=false "
}

t_a_dispatch_counts_only_on_the_default_branch() {
  world
  pr 12 OPEN "$NEWER" false false '[]'
  resolve EVENT=workflow_dispatch TITLE="PR #12" HEAD_BRANCH=main HEAD_SHA="$HEAD" RUN_ID=100
  expect_out "go=true number=12 sha=$NEWER draft=false forced=false built=true dispatched=true "
  resolve EVENT=workflow_dispatch TITLE="PR #12" HEAD_BRANCH=feat/x HEAD_SHA="$HEAD" RUN_ID=100
  expect_out "go=false "; expect_err_has "counts only on the default branch"
  resolve EVENT=workflow_dispatch TITLE="PR #12; rm -rf /" HEAD_BRANCH=main HEAD_SHA="$HEAD" RUN_ID=100
  expect_out "go=false "
  expect_true "the name was echoed" lacks "$err" "rm -rf"
  resolve EVENT=push LINKED=7 HEAD_SHA="$HEAD" HEAD_BRANCH=main RUN_ID=100
  expect_out "go=false "
}

test_case linked t_a_linked_pull_request_at_the_built_commit
test_case unlinked t_an_unlinked_build_is_found_by_its_commit_not_its_name
test_case build-never-ended t_a_build_job_that_never_ended_deploys_nothing
test_case older-closed-fork t_an_older_build_and_closed_or_fork_pull_requests_deploy_nothing
test_case label-and-draft t_the_label_and_a_draft
test_case dispatch t_a_dispatch_counts_only_on_the_default_branch
finish
