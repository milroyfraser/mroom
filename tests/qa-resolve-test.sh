#!/usr/bin/env bash
# shellcheck disable=SC2317  # the t_* functions run indirectly, through test_case
# Tests for actions/qa-up/resolve.sh: a qa-up run deploys only what GitHub's record of the QA plan run says, whatever
# the event that started it claims: a run of this repository's plan workflow; for one started on pull_request, the
# one open pull request of this repository at the run's commit, among those GitHub links or, failing that, finds by
# the commit; for one started on workflow_dispatch, the default branch's run named "PR #<N>", at the commit its build
# job is named after, which counts as much as a pull_request run, the newest of a pull request's runs included; and
# never a closed pull request, a fork's, or a build of a commit the pull request has moved past. Offline: gh is a fake.
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

world() { qa_world; export DEFAULT_BRANCH=main; }
# plan_run <id> <event> <commit> [<jq change>...]: GitHub's record of a QA plan run of this repository, by a person.
plan_run() {
  local id="$1" file="$GH_FAKE/run-$1.json" change
  jq -n --argjson id "$id" --arg event "$2" --arg sha "$3" '{id: $id, event: $event, head_sha: $sha,
    head_branch: "feat/x", path: ".github/workflows/qa-plan.yml", display_title: "QA plan · PR #7",
    html_url: "https://github.example/runs/\($id)", repository: {id: 1, full_name: "example/shop"},
    head_repository: {id: 1, full_name: "example/shop"}, actor: {login: "a-person"}, triggering_actor: {login: "a-person"}, pull_requests: []}' >"$file"
  shift 3
  for change in "$@"; do jq "$change" "$file" >"$file.new" && mv "$file.new" "$file"; done
}
# linked <N> <commit> [<head repository id>]: a pull request GitHub links to the run, as its pull_requests list it.
linked() { printf '.pull_requests += [{number: %s, head: {sha: "%s", repo: {id: %s}}, base: {repo: {id: 1}}}]' "$1" "$2" "${3:-1}"; }
# build_job <run id> <conclusion> <commit> [<the caller's job>]: the run's jobs, its build job named after the commit.
build_job() {
  jq -n --arg c "$2" --arg name "${4-qa / }QA build $3" \
    '{jobs: [{name: "qa / QA pull request", conclusion: "success"}, {name: $name, conclusion: $c}]}' >"$GH_FAKE/jobs-$1.json"
}
resolve() { run env "$@" "$RESOLVE"; out="$(tr '\n' ' ' <<<"$out")"; }
GO7="go=true number=7 sha=$HEAD draft=false forced=false"

t_a_linked_pull_request_at_the_built_commit() {
  world
  pr_now 7 OPEN "$HEAD" false '["type:feature"]'
  plan_run 100 pull_request "$HEAD" "$(linked 7 "$HEAD")"
  build_job 100 success "$HEAD"
  resolve RUN_ID=100
  expect_rc 0; expect_out "$GO7 built=true dispatched=false woken=false run_id=100 run_url=https://github.example/runs/100 "
  build_job 100 failure "$HEAD"
  resolve RUN_ID=100; expect_out_has "built=false"
  # A plan called without a job of the app's own around it names its job plainly.
  build_job 100 success "$HEAD" ""
  resolve RUN_ID=100; expect_out_has "$GO7 built=true"
}

t_only_one_pull_request_of_this_repository_at_the_commit_counts() {
  world
  pr_now 7 OPEN "$HEAD"
  build_job 100 success "$HEAD"
  # A fork's pull request at the same commit, among GitHub's links, does not count.
  plan_run 100 pull_request "$HEAD" "$(linked 9 "$HEAD" 2)" "$(linked 7 "$HEAD")"
  resolve RUN_ID=100; expect_out_has "$GO7"
  # Two of this repository's: which one is not known.
  plan_run 100 pull_request "$HEAD" "$(linked 7 "$HEAD")" "$(linked 8 "$HEAD")"
  resolve RUN_ID=100; expect_out "go=false "; expect_err_has "more than one open pull request has the commit aaaaaaaaa"
  # A run for a fork's commit deploys nothing, whatever it links.
  plan_run 100 pull_request "$HEAD" "$(linked 7 "$HEAD")" '.head_repository.full_name = "fork/shop"'
  resolve RUN_ID=100; expect_out "go=false "; expect_err_has "run 100 is for a fork's commit"
}

t_an_unlinked_build_is_found_by_its_commit_exactly_once() {
  world
  pr_now 7 OPEN "$HEAD"
  plan_run 100 pull_request "$HEAD"
  build_job 100 success "$HEAD"
  jq -n --arg sha "$HEAD" '[{number: 7, state: "open", head: {sha: $sha, repo: {full_name: "example/shop"}}, base: {repo: {full_name: "example/shop"}}},
    {number: 9, state: "open", head: {sha: $sha, repo: {full_name: "fork/shop"}}, base: {repo: {full_name: "example/shop"}}}]' \
    >"$GH_FAKE/pulls.json"
  resolve RUN_ID=100; expect_out_has "$GO7"
  jq -n --arg sha "$HEAD" '[{number: 7, state: "open", head: {sha: $sha, repo: {full_name: "example/shop"}}, base: {repo: {full_name: "example/shop"}}},
    {number: 8, state: "open", head: {sha: $sha, repo: {full_name: "example/shop"}}, base: {repo: {full_name: "example/shop"}}}]' \
    >"$GH_FAKE/pulls.json"
  resolve RUN_ID=100; expect_out "go=false "; expect_err_has "more than one open pull request has the commit"
  echo '[]' >"$GH_FAKE/pulls.json"
  resolve RUN_ID=100; expect_out "go=false "; expect_err_has "no open pull request of this repository has the commit aaaaaaaaa"
}

t_a_build_job_that_never_ended_deploys_nothing() {
  world
  pr_now 7 OPEN "$HEAD"
  plan_run 100 pull_request "$HEAD" "$(linked 7 "$HEAD")"
  local c
  for c in skipped cancelled; do
    build_job 100 "$c" "$HEAD"
    resolve RUN_ID=100; expect_out "go=false "; expect_err_has "the QA build job did not run to an end ($c)"
  done
  jq -n '{jobs: [{name: "lint", conclusion: "success"}, {name: "qa / QA build", conclusion: "success"}]}' >"$GH_FAKE/jobs-100.json"
  resolve RUN_ID=100; expect_out "go=false "; expect_err_has "(missing)"
  # A pull_request run whose build job names another commit than the run's.
  build_job 100 success "$NEWER"
  resolve RUN_ID=100; expect_out "go=false "; expect_err_has "run 100 built bbbbbbbbb, not its own commit aaaaaaaaa"
}

t_an_older_build_and_closed_or_fork_pull_requests_deploy_nothing() {
  world
  plan_run 100 pull_request "$HEAD" "$(linked 7 "$HEAD")"
  build_job 100 success "$HEAD"
  pr_now 7 OPEN "$NEWER"
  resolve RUN_ID=100; expect_out "go=false "; expect_err_has "has moved on from aaaaaaaaa to bbbbbbbbb"
  pr_now 7 CLOSED "$HEAD"
  resolve RUN_ID=100; expect_out "go=false "; expect_err_has "pull request 7 is not open"
  pr_now 7 OPEN "$HEAD"
  jq '.isCrossRepository = true' "$GH_FAKE/pr-7.json" >"$GH_FAKE/pr-7.new" && mv "$GH_FAKE/pr-7.new" "$GH_FAKE/pr-7.json"
  resolve RUN_ID=100; expect_out "go=false "; expect_err_has "pull request 7 is from a fork"
}

t_the_label_and_a_draft() {
  world
  plan_run 100 pull_request "$HEAD" "$(linked 7 "$HEAD")"
  build_job 100 success "$HEAD"
  pr_now 7 OPEN "$HEAD" true '["qa"]'
  resolve RUN_ID=100; expect_out_has "go=true number=7 sha=$HEAD draft=true forced=true"
  resolve RUN_ID=100 LABEL=preview; expect_out_has "draft=true forced=false"
}

t_a_dispatch_counts_only_on_the_default_branch() {
  world
  pr_now 12 OPEN "$NEWER"
  plan_run 101 workflow_dispatch "$HEAD" '.head_branch = "main" | .display_title = "PR #12"'
  build_job 101 success "$NEWER"
  resolve RUN_ID=101
  expect_out "go=true number=12 sha=$NEWER draft=false forced=false built=true dispatched=true woken=false run_id=101 run_url=https://github.example/runs/101 "
  # The job token's dispatch is a wake's, and a person's re-run of it still is: the run's first starter counts.
  plan_run 101 workflow_dispatch "$HEAD" '.head_branch = "main" | .display_title = "PR #12" | .actor.login = "github-actions[bot]" | .triggering_actor.login = "github-actions[bot]"'
  resolve RUN_ID=101; expect_out_has "dispatched=true woken=true"
  plan_run 101 workflow_dispatch "$HEAD" '.head_branch = "main" | .display_title = "PR #12" | .actor.login = "github-actions[bot]"'
  resolve RUN_ID=101; expect_out_has "dispatched=true woken=true"
  plan_run 101 workflow_dispatch "$HEAD" '.head_branch = "main" | .display_title = "PR #12" | .triggering_actor.login = "github-actions[bot]"'
  resolve RUN_ID=101; expect_out_has "dispatched=true woken=false"
  plan_run 101 workflow_dispatch "$HEAD" '.display_title = "PR #12"'
  resolve RUN_ID=101; expect_out "go=false "; expect_err_has "counts only on the default branch"
  plan_run 101 workflow_dispatch "$HEAD" '.head_branch = "main" | .display_title = "PR #12; rm -rf /"'
  resolve RUN_ID=101; expect_out "go=false "
  expect_true "the name was echoed" lacks "$err" "rm -rf"
  # The commit its build job is named after must still be the pull request's head.
  plan_run 101 workflow_dispatch "$HEAD" '.head_branch = "main" | .display_title = "PR #12"'
  build_job 101 success "$HEAD"
  resolve RUN_ID=101; expect_out "go=false "; expect_err_has "pull request 12 has moved on from aaaaaaaaa to bbbbbbbbb"
  plan_run 101 push "$HEAD" '.head_branch = "main"'
  resolve RUN_ID=101; expect_out "go=false "; expect_err_has "a QA plan started by 'push' deploys nothing"
}

t_the_newest_run_of_a_pull_request_may_be_a_dispatched_one() {
  world
  # Pull request 12 pushed at HEAD, then moved to NEWER; a freed slot started its plan, which built NEWER. That
  # dispatched run is the newest, and the one that deploys; the older pull_request run stops.
  pr_now 12 OPEN "$NEWER"
  plan_run 101 pull_request "$HEAD" "$(linked 12 "$HEAD")"
  build_job 101 success "$HEAD"
  plan_run 102 workflow_dispatch "$HEAD" '.head_branch = "main" | .display_title = "PR #12" | .actor.login = "github-actions[bot]"'
  build_job 102 success "$NEWER"
  resolve RUN_ID=102 DISPATCHED_PR=12; expect_out_has "go=true number=12 sha=$NEWER"; expect_out_has "woken=true run_id=102"
  resolve RUN_ID=101; expect_out "go=false "; expect_err_has "has moved on"
}

t_the_hand_over_names_a_dispatched_run_of_its_pull_request() {
  world
  pr_now 12 OPEN "$NEWER"
  plan_run 102 workflow_dispatch "$HEAD" '.head_branch = "main" | .display_title = "PR #12"'
  build_job 102 success "$NEWER"
  resolve RUN_ID=102 DISPATCHED_PR=12; expect_out_has "go=true number=12"
  resolve RUN_ID=102 DISPATCHED_PR=13; expect_out "go=false "; expect_err_has "the hand-over named pull request 13, but run 102 is for pull request 12"
  plan_run 103 pull_request "$NEWER" "$(linked 12 "$NEWER")"
  build_job 103 success "$NEWER"
  resolve RUN_ID=103 DISPATCHED_PR=12; expect_out "go=false "; expect_err_has "was started on pull_request, not by a dispatch"
}

t_only_this_repositorys_plan_workflow_counts() {
  world
  pr_now 7 OPEN "$HEAD"
  build_job 100 success "$HEAD"
  plan_run 100 pull_request "$HEAD" "$(linked 7 "$HEAD")" '.path = ".github/workflows/evil.yml"'
  resolve RUN_ID=100; expect_out "go=false "; expect_err_has "run 100 is not of the QA plan workflow, .github/workflows/qa-plan.yml"
  plan_run 100 pull_request "$HEAD" "$(linked 7 "$HEAD")" '.path = "example/shop/.github/workflows/qa-plan.yml@refs/heads/main"'
  resolve RUN_ID=100; expect_out_has "$GO7"
  plan_run 100 pull_request "$HEAD" "$(linked 7 "$HEAD")" '.path = ".github/workflows/qa-plan.yml" | .repository.full_name = "other/shop"'
  resolve RUN_ID=100; expect_out "go=false "; expect_err_has "run 100 is not of this repository"
  plan_run 100 pull_request "$HEAD" "$(linked 7 "$HEAD")" '.path = ".github/workflows/preview.yml"'
  resolve RUN_ID=100 PLAN_WORKFLOW=preview.yml; expect_out_has "$GO7"
}

t_github_that_cannot_be_read_fails_the_job() {
  world
  resolve RUN_ID=404; expect_rc 1; expect_err_has "GitHub gave no plan run 404"
  resolve RUN_ID=; expect_rc 0; expect_out "go=false "
  resolve RUN_ID=100 PLAN_WORKFLOW='qa plan.yml'; expect_rc 1
}

test_case linked t_a_linked_pull_request_at_the_built_commit
test_case one-pull-request t_only_one_pull_request_of_this_repository_at_the_commit_counts
test_case unlinked t_an_unlinked_build_is_found_by_its_commit_exactly_once
test_case build-never-ended t_a_build_job_that_never_ended_deploys_nothing
test_case older-closed-fork t_an_older_build_and_closed_or_fork_pull_requests_deploy_nothing
test_case label-and-draft t_the_label_and_a_draft
test_case dispatch t_a_dispatch_counts_only_on_the_default_branch
test_case newest-dispatched t_the_newest_run_of_a_pull_request_may_be_a_dispatched_one
test_case hand-over t_the_hand_over_names_a_dispatched_run_of_its_pull_request
test_case plan-workflow-only t_only_this_repositorys_plan_workflow_counts
test_case github-unreadable t_github_that_cannot_be_read_fails_the_job
finish
