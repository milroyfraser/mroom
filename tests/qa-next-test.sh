#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2016  # t_* run through test_case; a $ in single quotes is a name, never expanded
# Tests for actions/qa-up/next.sh, which starts the app's workflows that follow qa-up after a qa-up run the job token
# started: each name in next-workflows is dispatched on the default branch with the pull request and this run's id;
# a name that is not a workflow file's, one starting with - among them, is refused, and never globbed; the others
# still start; a dispatch GitHub refuses fails the step after the rest were tried.
set -euo pipefail
SUITE=qa-next
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/qa-world.sh
source "$(dirname "${BASH_SOURCE[0]}")/qa-world.sh"
skip_unless has_box_tools "this host lacks bash 5, flock or GNU date, which the QA actions need"

NEXT="$ROOT/actions/qa-up/next.sh"
world() { qa_world; export GITHUB_RUN_ID=777 MROOM_QA_DEFAULT_BRANCH=main; }
dispatches() { grep '^dispatch' "$GH_FAKE/gh.log" 2>/dev/null || true; }

t_each_workflow_is_started_with_the_pull_request_and_this_run() {
  world
  run "$NEXT" 12 "qa-browser.yml  e2e.yaml"
  expect_rc 0
  expect_out_has "started qa-browser.yml for pull request 12"
  run dispatches
  expect_out $'dispatch qa-browser.yml main pr=12 up_run_id=777\ndispatch e2e.yaml main pr=12 up_run_id=777'
  # Nothing to start is no failure.
  rm -f "$GH_FAKE/gh.log"
  run "$NEXT" 12 ""
  expect_rc 0; expect_out ""
  run dispatches; expect_out ""
}

t_a_name_that_is_not_a_workflow_file_is_refused_and_the_rest_still_start() {
  world
  local name
  for name in -x.yml --help.yml .hidden.yml x/y.yml ../up.yml qa-browser.yml.sh qa-browser yml '$(id).yml'; do
    rm -f "$GH_FAKE/gh.log"
    run "$NEXT" 12 "$name qa-browser.yml"
    expect_rc 1; expect_out_has "::error::next-workflows holds a name that is not a workflow file's"
    run dispatches; expect_out "dispatch qa-browser.yml main pr=12 up_run_id=777"
  done
  # A pattern is a name like any other, never a list of the files it matches.
  mkdir -p "$T/cwd"; : >"$T/cwd/a.yml"
  rm -f "$GH_FAKE/gh.log"
  run bash -c 'cd "$1" && "$2" 12 "*.yml"' _ "$T/cwd" "$NEXT"
  expect_rc 1; expect_out_has "::error::next-workflows holds a name that is not a workflow file's"
  run dispatches; expect_out ""
}

t_a_dispatch_github_refuses_fails_after_the_rest_were_tried() {
  world
  : >"$GH_FAKE/dispatch-fails"
  run "$NEXT" 12 "qa-browser.yml e2e.yml"
  expect_rc 1
  expect_out_has "::error::could not start qa-browser.yml for pull request 12"
  expect_out_has "::error::could not start e2e.yml for pull request 12"
}

t_usage() {
  world
  run "$NEXT" 012 "qa-browser.yml"; expect_rc 2
  run "$NEXT" 12; expect_rc 2
  run "$NEXT" 12 qa-browser.yml e2e.yml; expect_rc 2
  run env GITHUB_RUN_ID=abc "$NEXT" 12 qa-browser.yml; expect_rc 2
  run env -u GITHUB_REPOSITORY "$NEXT" 12 qa-browser.yml; expect_rc 2
  run dispatches; expect_out ""
}

test_case starts-each t_each_workflow_is_started_with_the_pull_request_and_this_run
test_case refuses-names t_a_name_that_is_not_a_workflow_file_is_refused_and_the_rest_still_start
test_case dispatch-fails t_a_dispatch_github_refuses_fails_after_the_rest_were_tried
test_case usage t_usage
finish
