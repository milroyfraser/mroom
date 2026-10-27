#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2016  # t_* run through test_case; a $ in single quotes is the YAML's or eval's own
# Tests for the shape of the QA workflows and composite actions, which no offline test can run: the job that runs a
# pull request's code only reads caches; teardowns and deploys queue in the pull request's group, first in first
# out; every run step is bash with pipefail; the hand-over starts qa-up only for a plan the job token started; the
# reaper holds no SSH key; and each composite action passes every input it declares to its steps, whose scripts
# exist. It reads the YAML as text, job by job, by its indentation.
set -euo pipefail
SUITE=qa-workflows
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

W="$ROOT/.github/workflows"
# job <workflow file> <job id>: the lines of that job, up to the next job.
job() { awk -v id="  $2:" '$0 == id { on = 1; next } on && /^  [a-z][a-z0-9-]*:$/ { exit } on' "$1"; }
has() { grep -qxF -- "$2" <<<"$1"; }

t_the_job_that_runs_pull_request_code_only_reads_caches() {
  local build
  build="$(job "$W/qa-plan.yml" build)"
  expect_true "qa-plan's build job may write caches" has "$build" "    cache-mode: read"
  expect_true "qa-plan holds a secret" eval '! grep -q "secrets\." "$W/qa-plan.yml"'
  expect_true "qa-plan names an environment" eval '! grep -q "^    environment:" "$W/qa-plan.yml"'
}

t_teardowns_wait_their_turn_in_the_pull_requests_group() {
  local down
  down="$(job "$W/qa-down.yml" down)"
  expect_true "the teardown's group is not the pull request's" has "$down" '      group: mroom-qa-${{ inputs.pr }}'
  expect_true "a teardown can be cancelled by its group" has "$down" "      cancel-in-progress: false"
  expect_true "a newer run can cancel a waiting teardown" has "$down" "      queue: max"
  expect_true "the check job is in a group" eval '! job "$W/qa-down.yml" check | grep -q concurrency'
  expect_true "the reaper is not in a group of its own" has "$(job "$W/qa-reap.yml" reap)" "      group: mroom-qa-reap"
}

t_every_run_step_is_bash_with_pipefail() {
  local file
  for file in "$W"/qa-*.yml; do
    expect_true "$(basename "$file") runs its steps without pipefail" \
      eval 'grep -A2 -x "defaults:" "$file" | grep -qx "    shell: bash"'
  done
}

t_the_hand_over_is_only_for_a_plan_the_job_token_started() {
  local hand
  hand="$(job "$W/qa-plan.yml" hand-over)"
  expect_true "the hand-over runs for more than a dispatch" grep -qF "github.event_name == 'workflow_dispatch'" <<<"$hand"
  expect_true "the hand-over runs for a person's dispatch" grep -qF "github.triggering_actor == 'github-actions[bot]'" <<<"$hand"
  expect_true "the hand-over names no run" grep -qF -- '-f plan_run_id="$GITHUB_RUN_ID"' <<<"$hand"
}

t_the_reaper_holds_no_ssh_key() {
  expect_true "qa-reap takes the SSH key" eval '! grep -q "SSH_KEY" "$W/qa-reap.yml" "$ROOT/actions/qa-reap/action.yml"'
}

t_each_action_passes_its_inputs_and_runs_scripts_it_has() {
  local action input script
  for action in "$ROOT"/actions/qa-*/action.yml; do
    while IFS= read -r input; do
      expect_true "$(basename "$(dirname "$action")") declares $input but never uses it" \
        grep -qE "inputs\.$input([^a-z0-9-]|\$)" "$action"
    done < <(awk '/^inputs:$/ { on = 1; next } on && /^[a-z]/ { exit } on && /^  [a-z][a-z0-9-]*:$/ { sub(/^  /, ""); sub(/:$/, ""); print }' "$action")
    while IFS= read -r script; do
      expect_true "$action runs $script, which is not an executable of its own" test -x "$(dirname "$action")/$script"
    done < <(grep -o '\$GITHUB_ACTION_PATH/[a-z.-]*' "$action" | sed 's|^\$GITHUB_ACTION_PATH/||' | sort -u)
  done
}

test_case caches-read-only t_the_job_that_runs_pull_request_code_only_reads_caches
test_case teardowns-queue t_teardowns_wait_their_turn_in_the_pull_requests_group
test_case bash-pipefail t_every_run_step_is_bash_with_pipefail
test_case hand-over-guard t_the_hand_over_is_only_for_a_plan_the_job_token_started
test_case reaper-no-ssh t_the_reaper_holds_no_ssh_key
test_case action-inputs t_each_action_passes_its_inputs_and_runs_scripts_it_has
finish
