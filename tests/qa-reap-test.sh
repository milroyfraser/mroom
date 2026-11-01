#!/usr/bin/env bash
# shellcheck disable=SC2317  # the t_* functions run indirectly, through test_case
# Tests for the QA reaper (actions/qa-reap/reap.sh): every environment past qa.ttl_days, found by its API's or its
# frontend's site, gets a teardown of its own (the app's qa-down workflow, reason ttl); one whose time Forge does not
# give counts as past it; one Forge is removing is skipped, and a site of it stuck removing gets the delete again,
# with a warning; a Forge that cannot be read fails the run; it needs no SSH key. Offline: Forge and GitHub are
# fakes.
set -euo pipefail
SUITE=qa-reap
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/qa-world.sh
source "$(dirname "${BASH_SOURCE[0]}")/qa-world.sh"
skip_unless has_box_tools "this host lacks bash 5, flock or GNU date, which the QA actions need"
skip_unless has_tomllib "python3 has no tomllib (needs 3.11+)"

REAP="$ROOT/actions/qa-reap/reap.sh"
DAY=86400
dispatches() { grep '^dispatch' "$GH_FAKE/gh.log" 2>/dev/null || true; }
# reaper_world: the world, as the reaper gets it: no SSH key, and the default branch.
reaper_world() {
  qa_world
  unset MROOM_QA_SSH_HOST MROOM_QA_SSH_KEY MROOM_QA_SSH_KNOWN_HOSTS
  export MROOM_QA_DEFAULT_BRANCH=main
}

t_each_environment_past_its_time_gets_a_teardown() {
  reaper_world
  site 1 "$(api_host 1)" installed "$(ago $((9 * DAY)))"
  site 2 "$(web_host 1)" installed "$(ago $((9 * DAY)))"
  site 3 "$(api_host 3)" installed "$(ago "$DAY")"
  site 4 s3.qa.example.dev installed "$(ago $((90 * DAY)))"
  site 5 "$(api_host 8 qa.other.example.dev)" installed "$(ago $((9 * DAY)))"
  site 6 "$(api_host 09)" installed "$(ago $((9 * DAY)))"
  # Only its frontend's site is left, after a teardown that stopped halfway.
  site 7 "$(web_host 12)" installed "$(ago $((9 * DAY)))"
  # Forge gives no time for it.
  site 8 "$(api_host 13)" installed
  forge_set '.sites[-1].created_at = null'
  run "$REAP"
  expect_rc 0; expect_out_has "started the teardown of 3 environment(s)"
  expect_out_has "::warning::environment 13: Forge gives no readable created_at for its sites, so it counts as past its time"
  run dispatches
  expect_out $'dispatch qa-down.yml main pr_number=1 reason=ttl\ndispatch qa-down.yml main pr_number=12 reason=ttl
dispatch qa-down.yml main pr_number=13 reason=ttl'
  run cat "$GITHUB_OUTPUT"; expect_out "started=3"
  # The reaper itself tears nothing down.
  run forge_writes; expect_out ""
  expect_no_file "$GATE/gate.log"
}

t_an_environment_of_the_old_names_is_reaped_too() {
  reaper_world
  # Environments brought up before mroom 0.5.0, as api-<N> and go-<N>.
  site 1 "$(old_api_host 4)" installed "$(ago $((9 * DAY)))"
  site 2 "$(old_web_host 5)" installed "$(ago $((9 * DAY)))"
  site 3 "$(old_api_host 6)" installed "$(ago "$DAY")"
  site 4 "$(old_api_host 7)" removing "$(ago $((9 * DAY)))" "$(ago 10800)"
  site 5 "$(old_api_host 8 qa.other.example.dev)" installed "$(ago $((9 * DAY)))"
  forge_set '.remove_reads = -1'
  run "$REAP"
  expect_rc 0; expect_out_has "started the teardown of 2 environment(s)"
  expect_out_has "environment 7: Forge is already removing it; skipped"
  run dispatches
  expect_out $'dispatch qa-down.yml main pr_number=4 reason=ttl\ndispatch qa-down.yml main pr_number=5 reason=ttl'
  # A site of the old names stuck removing gets the delete again too.
  run forge_writes; expect_out "DELETE /sites/4"
}

t_an_environment_forge_is_removing_is_skipped_and_a_stuck_site_deleted_again() {
  reaper_world
  site 2 "$(api_host 2)" removing "$(ago $((9 * DAY)))"
  site 6 "$(api_host 6)" removing "$(ago $((9 * DAY)))" "$(ago 10800)"
  site 7 "$(api_host 7)" removing "$(ago $((9 * DAY)))" "$(ago 300)"
  site 9 "$(web_host 9)" removing "$(ago $((9 * DAY)))" "$(ago 7200)"
  forge_set '.remove_reads = -1'
  run "$REAP"
  expect_rc 0; expect_out_has "environment 2: Forge is already removing it; skipped"
  # Removing for 3 hours, or 2 for a frontend's site, gets the delete again; for 5 minutes, or with no time to tell,
  # it does not.
  expect_out_has "::warning::environment 6: $(api_host 6) had been removing for 180 minutes, so the delete went again"
  expect_out_has "::warning::environment 9: $(web_host 9) had been removing for 120 minutes"
  expect_true "a site removing for 5 minutes was warned about" lacks "$out" "environment 7: $(api_host 7)"
  run forge_writes; expect_out $'DELETE /sites/6\nDELETE /sites/9'
  run dispatches; expect_out ""
}

t_three_environments_past_their_time_get_three_teardowns() {
  reaper_world
  site 1 "$(api_host 1)" installed "$(ago $((9 * DAY)))"
  site 2 "$(api_host 2)" installed "$(ago $((8 * DAY)))"
  site 3 "$(api_host 3)" installed "$(ago $((7 * DAY)))"
  run "$REAP"
  expect_rc 0
  run dispatches
  expect_out $'dispatch qa-down.yml main pr_number=1 reason=ttl\ndispatch qa-down.yml main pr_number=2 reason=ttl
dispatch qa-down.yml main pr_number=3 reason=ttl'
}

t_an_environments_age_is_its_oldest_sites() {
  reaper_world
  # A frontend's site made 9 days ago, and an api site made again yesterday: the environment is 9 days old.
  site 1 "$(api_host 4)" installed "$(ago "$DAY")"
  site 2 "$(web_host 4)" installed "$(ago $((9 * DAY)))"
  run "$REAP"
  expect_rc 0
  run dispatches; expect_out "dispatch qa-down.yml main pr_number=4 reason=ttl"
}

t_the_time_comes_from_mroom_toml() {
  reaper_world
  printf 'ttl_days = 2\n' >>"$MROOM_CONFIG"
  site 1 "$(api_host 1)" installed "$(ago $((3 * DAY)))"
  site 3 "$(api_host 3)" installed "$(ago "$DAY")"
  export MROOM_QA_DOWN_WORKFLOW=qa-teardown.yml
  run "$REAP"
  expect_rc 0
  run dispatches; expect_out "dispatch qa-teardown.yml main pr_number=1 reason=ttl"
}

t_a_teardown_that_cannot_start_fails_the_run() {
  reaper_world
  site 1 "$(api_host 1)" installed "$(ago $((9 * DAY)))"
  : >"$GH_FAKE/dispatch-fails"
  run "$REAP"
  expect_rc 1; expect_err_has "could not start the teardown of environment(s) 1; the next reap tries again"
  run cat "$GITHUB_OUTPUT"; expect_out "started=0"
}

t_a_forge_that_cannot_be_read_fails_the_run() {
  reaper_world
  site 1 "$(api_host 1)" installed "$(ago $((9 * DAY)))"
  forge_set '.fail["GET /sites"] = 503'
  run "$REAP"
  expect_rc 1; expect_err_has "Forge's sites could not be read 3 times"
  run dispatches; expect_out ""
  expect_no_file "$GITHUB_OUTPUT"
}

t_a_qa_environment_not_set_up_has_nothing_to_reap() {
  reaper_world
  unset MROOM_FORGE_SERVER
  run "$REAP"
  expect_rc 0; expect_out "::warning::the qa environment has no MROOM_FORGE_SERVER yet, so there is nothing to reap"
  expect_no_file "$FORGE_LOG"
  export MROOM_FORGE_SERVER=42
  local name
  # A name gh would read as an option, or one that is not a file name, is refused.
  for name in 'qa down.yml' '-x.yml' '--help.yml' 'qa-down' '../qa-down.yml'; do
    run env MROOM_QA_DOWN_WORKFLOW="$name" "$REAP"; expect_rc 2; expect_err_has "MROOM_QA_DOWN_WORKFLOW is not a workflow file name"
  done
  run env MROOM_QA_DOWN_WORKFLOW=_qa-down.yaml "$REAP"; expect_rc 0
}

test_case each-past-its-time t_each_environment_past_its_time_gets_a_teardown
test_case old-names-reaped t_an_environment_of_the_old_names_is_reaped_too
test_case removing-and-stuck t_an_environment_forge_is_removing_is_skipped_and_a_stuck_site_deleted_again
test_case three-teardowns t_three_environments_past_their_time_get_three_teardowns
test_case age-of-oldest-site t_an_environments_age_is_its_oldest_sites
test_case ttl-from-config t_the_time_comes_from_mroom_toml
test_case teardown-cannot-start t_a_teardown_that_cannot_start_fails_the_run
test_case forge-unreadable t_a_forge_that_cannot_be_read_fails_the_run
test_case not-set-up t_a_qa_environment_not_set_up_has_nothing_to_reap
finish
