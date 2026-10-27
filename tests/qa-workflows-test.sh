#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2016  # t_* run through test_case; a $ in single quotes is the YAML's or eval's own
# Tests for the shape of the QA workflows and composite actions, which no offline test can run: the job that runs a
# pull request's code only reads caches, and its token can do nothing more; teardowns, their checks and deploys
# queue in the pull request's group, first in first out; no line whose loss makes a teardown a green no-op is
# missing; one wake runs at a time, after a teardown that freed a slot; every run step is bash with pipefail; the
# hand-over starts qa-up only for a plan the job token started, a failed build's too; the reaper holds no SSH key;
# and each composite action passes every input it declares to its steps, whose scripts exist. It reads the YAML as
# text, job by job, by its indentation.
set -euo pipefail
SUITE=qa-workflows
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

W="$ROOT/.github/workflows"
# job <workflow file> <job id>: the lines of that job, up to the next job.
job() { awk -v id="  $2:" '$0 == id { on = 1; next } on && /^  [a-z][a-z0-9-]*:$/ { exit } on' "$1"; }
has() { grep -qxF -- "$2" <<<"$1"; }

# block <job lines> <key>: the lines of a key's block in a job, as "permissions:" and its entries, up to the next key.
block() { awk -v key="    $2:" '$0 == key { on = 1; next } on && /^    [a-z]/ { exit } on' <<<"$1"; }

t_the_job_that_runs_pull_request_code_only_reads_caches() {
  local build
  build="$(job "$W/qa-plan.yml" build)"
  expect_true "qa-plan's build job may write caches" has "$build" "    cache-mode: read"
  # Its token may read the code and the pull request, and nothing else: no actions, no writes.
  expect_true "qa-plan's build job has other permissions than contents: read and pull-requests: read" \
    [ "$(block "$build" permissions)" = $'      contents: read\n      pull-requests: read' ]
  expect_true "qa-plan holds a secret" eval '! grep -q "secrets\." "$W/qa-plan.yml"'
  expect_true "qa-plan names an environment" eval '! grep -q "^    environment:" "$W/qa-plan.yml"'
}

t_teardowns_wait_their_turn_in_the_pull_requests_group() {
  local name lines
  # The check too: a pull request closed during its first deploy is checked once that deploy has made its sites.
  for name in down check; do
    lines="$(job "$W/qa-down.yml" "$name")"
    expect_true "the $name job's group is not the pull request's" has "$lines" '      group: mroom-qa-${{ inputs.pr }}'
    expect_true "the $name job can be cancelled by its group" has "$lines" "      cancel-in-progress: false"
    expect_true "a newer run can cancel a waiting $name job" has "$lines" "      queue: max"
  done
  expect_true "the reaper is not in a group of its own" has "$(job "$W/qa-reap.yml" reap)" "      group: mroom-qa-reap"
}

t_a_teardown_is_never_a_green_no_op() {
  local down check
  down="$(job "$W/qa-down.yml" down)" check="$(job "$W/qa-down.yml" check)"
  # Without !cancelled(), the down job is skipped whenever the check is: every dispatch.
  expect_true "the down job runs only when its needs succeeded" grep -qF "!cancelled() && (github.event_name == 'workflow_dispatch' ||" <<<"$down"
  # Without the qa environment, the check has no Forge server or token, and answers absent.
  expect_true "the check job names no qa environment" eval 'block "$check" environment | grep -qx "      name: qa"'
  expect_true "the down job names no qa environment" eval 'block "$down" environment | grep -qx "      name: qa"'
  # The down job gets the check's answer, so a re-run of it alone uses the first attempt's.
  expect_true "the check job gives no state" has "$(block "$check" outputs)" '      state: ${{ steps.check.outputs.state }}'
  expect_true "the down job is not given the check's state" has "$down" '          state: ${{ needs.check.outputs.state }}'
  # The reaper's reason reaches the comment as ttl.
  expect_true "a dispatch with reason ttl is not torn down as ttl" grep -qF "inputs.reason == 'ttl' && 'ttl' || 'hand'" <<<"$down"
}

t_one_wake_at_a_time_after_a_teardown_that_freed_a_slot() {
  local wake
  wake="$(job "$W/qa-down.yml" wake)"
  expect_true "the wake does not follow the teardown" has "$wake" "    needs: down"
  expect_true "the wake runs when no slot was freed" grep -qF "needs.down.outputs.freed == 'true'" <<<"$wake"
  expect_true "the wake is not in the one wake group" has "$wake" "      group: mroom-qa-wake"
  expect_true "a wake can be cancelled by its group" has "$wake" "      cancel-in-progress: false"
  expect_true "a newer wake can cancel a waiting one" has "$wake" "      queue: max"
  expect_true "the wake holds a secret or an environment" eval '! grep -qE "secrets\.|^    environment:" <<<"$wake"'
  expect_true "the down job gives no freed" has "$(block "$(job "$W/qa-down.yml" down)" outputs)" '      freed: ${{ steps.down.outputs.freed }}'
  expect_true "down.sh still wakes" eval '! grep -q "qa_wake" "$ROOT/actions/qa-down/down.sh"'
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
  # By the run's actor: a person's re-run of a woken plan still hands over.
  expect_true "the hand-over runs for a person's dispatch" grep -qF "github.actor == 'github-actions[bot]'" <<<"$hand"
  expect_true "the hand-over goes by who re-ran the plan" eval '! grep -q triggering_actor <<<"$hand"'
  expect_true "the hand-over is skipped for a failed build" grep -qF "(needs.build.result == 'success' || needs.build.result == 'failure')" <<<"$hand"
  expect_true "the hand-over names no run" grep -qF -- '-f plan_run_id="$GITHUB_RUN_ID"' <<<"$hand"
}

t_the_reaper_holds_no_ssh_key() {
  expect_true "qa-reap takes the SSH key" eval '! grep -q "SSH_KEY" "$W/qa-reap.yml" "$ROOT/actions/qa-reap/action.yml"'
}

t_deploys_queue_in_the_pull_requests_group_too() {
  local deploy
  deploy="$(job "$W/qa-up.yml" deploy)"
  expect_true "the deploy's group is not the pull request's" has "$deploy" '      group: mroom-qa-${{ needs.pr.outputs.number }}'
  expect_true "a deploy can be cancelled by its group" has "$deploy" "      cancel-in-progress: false"
  expect_true "a newer run can cancel a waiting deploy" has "$deploy" "      queue: max"
}

t_qa_up_takes_only_the_plan_runs_id_from_its_event() {
  local pr
  pr="$(job "$W/qa-up.yml" pr)"
  expect_true "the run id does not come from the dispatch or the workflow_run" grep -qF \
    "RUN_ID: \${{ github.event_name == 'workflow_dispatch' && github.event.inputs.plan_run_id || github.event.workflow_run.id }}" <<<"$pr"
  # Nothing else of the event is read: no branch, commit, title or pull request it claims.
  expect_true "qa-up reads more of the workflow_run event than the run's id and conclusion" \
    eval '! grep -o "github\.event\.workflow_run\.[a-z_]*" "$W/qa-up.yml" | grep -v -x -e "github.event.workflow_run.id" -e "github.event.workflow_run.conclusion"'
  expect_true "the deploy downloads from another run than the one resolve.sh checked" \
    has "$(job "$W/qa-up.yml" deploy)" '          plan-run-id: ${{ needs.pr.outputs.run-id }}'
  expect_true "the plan's build job is not named after the commit it built" \
    has "$(job "$W/qa-plan.yml" build)" '    name: QA build ${{ needs.pr.outputs.sha }}'
  expect_true "the plan's build job checks out another commit than its name says" \
    has "$(job "$W/qa-plan.yml" build)" '          ref: ${{ needs.pr.outputs.sha }}'
}

t_the_workflows_after_qa_up_are_started_only_for_a_run_the_job_token_started() {
  local next
  next="$(job "$W/qa-up.yml" next)"
  expect_true "the next job runs for more than a dispatch" grep -qF "github.event_name == 'workflow_dispatch'" <<<"$next"
  expect_true "the next job runs for a person's dispatch" grep -qF "github.actor == 'github-actions[bot]'" <<<"$next"
  expect_true "the next job goes by who re-ran qa-up" eval '! grep -q triggering_actor <<<"$next"'
  # Whenever the deploy ran, whatever it came to, as the workflow_run would have; not when it was skipped.
  expect_true "the next job runs only when the environment came up" eval '! grep -q app-url <<<"$next"'
  expect_true "the next job does not run whenever the deploy ran" \
    grep -qF "(needs.deploy.result == 'success' || needs.deploy.result == 'failure')" <<<"$next"
  expect_true "the next job runs when the run was cancelled" grep -qF '!cancelled() &&' <<<"$next"
  expect_true "the next job does not hand next.sh the pull request and the list" \
    has "$next" '        run: mroom/actions/qa-up/next.sh "$PR" "$NEXT"'
  expect_true "the next job runs another mroom's next.sh" has "$next" '          ref: ${{ job.workflow_sha }}'
}

t_the_comment_comes_from_a_step_that_always_runs() {
  local action="$ROOT/actions/qa-up/action.yml" report
  report="$(awk '/^    - id: report$/ { on = 1 } on' "$action")"
  expect_true "the report step does not always run" has "$report" "      if: always()"
  run grep -c -x '        MROOM_QA_STATUS: ${{ runner.temp }}/mroom-qa-up.status' "$action"; expect_out 3
  expect_true "the build is downloaded from another run" grep -qF 'run-id: ${{ inputs.plan-run-id }}' "$action"
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
test_case never-a-green-no-op t_a_teardown_is_never_a_green_no_op
test_case one-wake-at-a-time t_one_wake_at_a_time_after_a_teardown_that_freed_a_slot
test_case bash-pipefail t_every_run_step_is_bash_with_pipefail
test_case hand-over-guard t_the_hand_over_is_only_for_a_plan_the_job_token_started
test_case reaper-no-ssh t_the_reaper_holds_no_ssh_key
test_case deploys-queue t_deploys_queue_in_the_pull_requests_group_too
test_case event-values-ignored t_qa_up_takes_only_the_plan_runs_id_from_its_event
test_case next-guard t_the_workflows_after_qa_up_are_started_only_for_a_run_the_job_token_started
test_case comment-always t_the_comment_comes_from_a_step_that_always_runs
test_case action-inputs t_each_action_passes_its_inputs_and_runs_scripts_it_has
finish
