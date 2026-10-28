#!/usr/bin/env bash
# shellcheck disable=SC2317  # the t_* functions run indirectly, through test_case
# Tests for the comment a qa-up run leaves (actions/qa-up/report.sh), the action's last step, which runs always: what
# start.sh or up.sh said, and, when a step failed or was cancelled before it could say anything, what happened.
# Offline: GitHub is a fake.
set -euo pipefail
SUITE=qa-report
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/qa-world.sh
source "$(dirname "${BASH_SOURCE[0]}")/qa-world.sh"
skip_unless has_box_tools "this host lacks bash 5, flock or GNU date, which the QA actions need"

REPORT="$ROOT/actions/qa-up/report.sh"
SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

world() {
  qa_world
  export PR=7 SHA RUN_URL=https://github.example/runs/9 MROOM_QA_STATUS="$T/status"
  : >"$T/status"
}
# report <START> <DIST> <UP>: report.sh after steps with those outcomes; the comment it wrote, if any.
report() {
  : >"$GH_FAKE/gh.log"
  run env START="$1" DIST="$2" UP="$3" "$REPORT"
  expect_rc 0
  run sed -n 's/^\(POST\|PATCH\) [0-9]* //p' "$GH_FAKE/gh.log"
}

t_what_a_step_left_is_written() {
  world
  printf 'ready\n| | |\n|---|---|\n| API | https://%s |\n' "$(api_host 7)" >"$T/status"
  report success success success
  expect_out "### QA environment\n<!-- mroom-qa: ready -->\n\n| | |\n|---|---|\n| API | https://$(api_host 7) |"
  printf 'skipped\nNo QA environment yet.\n' >"$T/status"
  report success skipped skipped
  expect_out_has '<!-- mroom-qa: skipped -->\n\nNo QA environment yet.'
}

t_nothing_said_leaves_the_comment_alone() {
  world
  report success skipped skipped
  expect_out ""
}

t_a_step_that_failed_before_it_said_anything_is_said() {
  world
  report failure skipped skipped
  expect_out_has "mroom-qa: failed -->\n\nWhether to bring the QA environment up for \`$SHA\` could not be told: GitHub or Forge did not answer ([run](https://github.example/runs/9))."
  report success failure skipped
  expect_out_has "The QA plan's frontend build could not be had, so \`$SHA\` was not deployed ([run](https://github.example/runs/9))."
  report success success cancelled
  expect_out_has "The deploy of \`$SHA\` was cancelled, or ran out of time, partway ([run](https://github.example/runs/9))."
  report success skipped failure
  expect_out_has "The deploy of \`$SHA\` stopped before it could say why ([run](https://github.example/runs/9))."
  # A failure up.sh explained keeps its own words.
  printf 'failed\nThe deploy failed: the gate refused the code.\n' >"$T/status"
  report success skipped failure
  expect_out_has "mroom-qa: failed -->\n\nThe deploy failed: the gate refused the code."
  # A start that failed is said, whatever was left from before.
  report failure skipped skipped
  expect_out_has "could not be told"
}

t_a_comment_github_refuses_is_a_warning() {
  world
  printf 'ready\nUp.\n' >"$T/status"
  : >"$GH_FAKE/down"
  run env START=success DIST=skipped UP=success "$REPORT"
  expect_rc 0; expect_out_has "::warning::could not update the QA environment comment of pull request 7"
  run env PR=abc START=failure "$REPORT"; expect_rc 0; expect_out ""
}

test_case status-written t_what_a_step_left_is_written
test_case nothing-said t_nothing_said_leaves_the_comment_alone
test_case failed-before-saying t_a_step_that_failed_before_it_said_anything_is_said
test_case github-refuses t_a_comment_github_refuses_is_a_warning
finish
