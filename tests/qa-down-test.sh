#!/usr/bin/env bash
# shellcheck disable=SC2317  # the t_* functions run indirectly, through test_case
# Tests for the QA teardown (actions/qa-down/down.sh) and what it shares (lib/core/qa.sh): Forge decides whether
# there is an environment; daemons go first and are waited for, then user-clean, then the sites, then the box's
# side through the gate; a failed user-clean keeps the sites; a site stuck removing gets the delete again; the
# comment and the wake; and the SSH key never on a command line. Offline: Forge, GitHub and the gate are fakes.
set -euo pipefail
SUITE=qa-down
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/qa-world.sh
source "$(dirname "${BASH_SOURCE[0]}")/qa-world.sh"
skip_unless has_box_tools "this host lacks bash 5, flock or GNU date, which the QA actions need"
skip_unless has_tomllib "python3 has no tomllib (needs 3.11+)"

DOWN="$ROOT/actions/qa-down/down.sh"
BOX_SIDE=$'db-drop 7\nredis-user-remove 7\nredis-clear 7\nmail-user-remove 7\nmail-clear 7\nbucket-drop 7'

# environment_7: pull request 7's two sites and its daemon, beside environment 70's.
environment_7() {
  site 11 api-7.qa.example.dev installed
  site 12 go-7.qa.example.dev installed
  site 13 api-70.qa.example.dev installed
  process 5 shop_qa_7 /home/shop_qa_7/api-7.qa.example.dev/.
  process 6 forge /home/shop_qa_7/api-7.qa.example.dev/.
  process 7 shop_qa_70 /home/shop_qa_70/api-70.qa.example.dev/.
}

t_an_environment_comes_down_in_order() {
  qa_world; environment_7
  forge_set '.process_remove_reads = 1'
  comment 7 301 'github-actions[bot]' "$(qa_body ready)"
  comment 7 302 'github-actions[bot]' $'## Another check\n\nNot this one.'
  run "$DOWN" 7 --why "the pull request closed"
  expect_rc 0; expect_out_has "environment 7: removed"
  # Daemons first, and gone before user-clean; the sites right after it; then the box's side.
  run order
  expect_out $'forge DELETE /background-processes/5\nforge DELETE /background-processes/6\ngate user-clean 7
forge DELETE /sites/11\nforge DELETE /sites/12\ngate db-drop 7\ngate redis-user-remove 7\ngate redis-clear 7
gate mail-user-remove 7\ngate mail-clear 7\ngate bucket-drop 7'
  run grep -c '^GET /background-processes' "$FORGE_LOG"; expect_out 3
  run cat "$GITHUB_OUTPUT"; expect_out "freed=true"
  run gh_log
  expect_out 'PATCH 301 ### QA environment\n<!-- mroom-qa: removed -->\n\nRemoved: the pull request closed.'
  run jq -r '[.sites[] | "\(.id) \(.status)"] | join(",")' "$FORGE_STATE"; expect_out "11 removing,12 removing,13 installed"
  run jq -r '[.processes[].id] | join(",")' "$FORGE_STATE"; expect_out "7"
}

t_the_ssh_key_stays_off_every_command_line() {
  qa_world; environment_7
  run "$DOWN" 7
  expect_rc 0
  expect_true "the key reached ssh's command line" lacks "$(cat "$GATE/ssh.argv")" "not-a-real-key"
  run grep -c -x -e 'BatchMode=yes' -e 'StrictHostKeyChecking=yes' -e 'IdentitiesOnly=yes' -e 'GlobalKnownHostsFile=/dev/null' \
    "$GATE/ssh.argv"
  expect_out 28
  run grep -c -x 'forge@box.example.dev' "$GATE/ssh.argv"; expect_out 7
  expect_true "the key folder was left in TMPDIR" tmp_empty
  expect_true "the Forge token was printed" lacks "$out$err" fake-forge-token
}

t_no_environment_is_left_alone() {
  qa_world
  site 13 api-70.qa.example.dev installed
  run "$DOWN" 7 --wake
  expect_rc 0; expect_out_has "environment 7: Forge has no site of it, so there is nothing to tear down"
  run gate_log; expect_out ""
  run forge_writes; expect_out ""
  run gh_log; expect_out ""
  run cat "$GITHUB_OUTPUT"; expect_out "freed=false"
}

t_a_teardown_by_hand_clears_the_box_side_anyway() {
  qa_world
  run "$DOWN" 7 --always --why "torn down by hand" --wake
  expect_rc 0; expect_out_has "clearing the box's side anyway"
  run gate_log; expect_out $'user-clean 7\n'"$BOX_SIDE"
  run forge_writes; expect_out ""
  # The comment says so, but no slot was freed, so nobody is woken.
  run gh_log; expect_out 'POST 7 ### QA environment\n<!-- mroom-qa: removed -->\n\nRemoved: torn down by hand.'
}

t_a_site_stuck_removing_gets_the_delete_again() {
  qa_world
  site 11 api-7.qa.example.dev removing "$(ago 864000)" "$(ago 7200)"
  site 12 go-7.qa.example.dev removing "$(ago 864000)" "$(ago 300)"
  forge_set '.remove_reads = -1'
  run "$DOWN" 7 --wake
  expect_rc 0; expect_out_has "environment 7: Forge is removing its sites; finishing the rest"
  expect_out_has "had been removing for 120 minutes; sent the delete again"
  expect_out_has "Forge is removing it"
  run forge_writes; expect_out "DELETE /sites/11"
  run gate_log; expect_out $'user-clean 7\n'"$BOX_SIDE"
  run cat "$GITHUB_OUTPUT"; expect_out "freed=false"
  run grep -c dispatch "$GH_FAKE/gh.log"; expect_out 0
}

t_a_failed_user_clean_keeps_the_sites() {
  qa_world; environment_7
  echo 1 >"$GATE/user-clean.rc"
  run "$DOWN" 7
  expect_rc 1; expect_err_has "user-clean failed, so the sites stay until the next teardown tries again"
  run gate_log; expect_out "user-clean 7"
  run forge_writes; expect_out $'DELETE /background-processes/5\nDELETE /background-processes/6'
  run gh_log; expect_out ""
}

t_daemons_that_never_go_keep_everything_else() {
  qa_world; environment_7
  forge_set '.process_remove_reads = -1'
  export MROOM_QA_DAEMON_WAIT=10
  run "$DOWN" 7
  expect_rc 1; expect_err_has "Forge still lists daemons 5, 6 10s after deleting them"
  run gate_log; expect_out ""
  run forge_writes; expect_out $'DELETE /background-processes/5\nDELETE /background-processes/6'
}

t_one_box_step_failing_leaves_the_others_to_run() {
  qa_world; environment_7
  echo 1 >"$GATE/redis-user-remove.rc"
  run "$DOWN" 7
  expect_rc 1; expect_err_has "environment 7 is down, but these are left: Redis user"
  run gate_log; expect_out $'user-clean 7\n'"$BOX_SIDE"
  run gh_log; expect_out ""
}

t_services_qa_does_not_use_are_left_alone() {
  qa_world; environment_7
  printf '\n[qa.parity]\nmail = "log"\nfiles = "local"\n' >>"$MROOM_CONFIG"
  run "$DOWN" 7
  expect_rc 0
  run gate_log; expect_out $'user-clean 7\ndb-drop 7\nredis-user-remove 7\nredis-clear 7'
}

t_a_forge_that_cannot_be_read_stops_it() {
  qa_world; environment_7
  forge_set '.fail["GET /sites"] = 500'
  run "$DOWN" 7
  expect_rc 1; expect_err_has "Forge's sites could not be read 3 times"
  run grep -c "^GET /sites" "$FORGE_LOG"; expect_out 3
  run gate_log; expect_out ""
  run forge_writes; expect_out ""
}

t_a_wake_goes_to_the_longest_waiting() {
  qa_world; environment_7
  jq -n '[{number: 20, isDraft: false}, {number: 21, isDraft: false}, {number: 22, isDraft: true}]' >"$GH_FAKE/prs.json"
  comment 20 401 'github-actions[bot]' "$(qa_body waiting)" 2026-10-26T10:00:00Z
  comment 21 402 'github-actions[bot]' "$(qa_body waiting)" 2026-10-26T08:00:00Z
  comment 22 403 'github-actions[bot]' "$(qa_body waiting)" 2026-10-26T07:00:00Z
  export MROOM_QA_DEFAULT_BRANCH=main
  run "$DOWN" 7 --wake
  expect_rc 0; expect_out_has "starting the QA plan for pull request 21, which waited for a slot"
  run grep dispatch "$GH_FAKE/gh.log"; expect_out "dispatch qa-plan.yml main 21"
}

t_usage() {
  qa_world
  local args
  for args in "" "07" "0" "7 --nope" "7 --why" "abc"; do
    # shellcheck disable=SC2086  # each case is words
    run "$DOWN" $args
    expect_rc 2; expect_err_has "usage: down.sh <N>"
  done
  run forge_writes; expect_out ""
}

test_case comes-down-in-order t_an_environment_comes_down_in_order
test_case ssh-key-off-command-lines t_the_ssh_key_stays_off_every_command_line
test_case no-environment t_no_environment_is_left_alone
test_case by-hand t_a_teardown_by_hand_clears_the_box_side_anyway
test_case stuck-removing t_a_site_stuck_removing_gets_the_delete_again
test_case user-clean-fails t_a_failed_user_clean_keeps_the_sites
test_case daemons-never-go t_daemons_that_never_go_keep_everything_else
test_case one-box-step-fails t_one_box_step_failing_leaves_the_others_to_run
test_case parity-swaps t_services_qa_does_not_use_are_left_alone
test_case forge-unreadable t_a_forge_that_cannot_be_read_stops_it
test_case wake-longest-waiting t_a_wake_goes_to_the_longest_waiting
test_case usage t_usage
finish
