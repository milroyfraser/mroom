#!/usr/bin/env bash
# shellcheck disable=SC2317  # the t_* functions run indirectly, through test_case
# Tests for the QA teardown (actions/qa-down: check.sh and down.sh) and what it shares (lib/core/qa.sh): the check
# reads Forge and changes nothing; the teardown runs every step, skipping what is gone, so a run again finishes one
# that stopped; daemons go first and are waited for, then user-clean, then the sites, then the box's side; a failed
# user-clean keeps the sites; the comment says removing, removed, or which step failed; ssh never reads a loop's
# input; and the SSH key never reaches a command line. Offline: Forge, GitHub and the gate are fakes.
set -euo pipefail
SUITE=qa-down
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/qa-world.sh
source "$(dirname "${BASH_SOURCE[0]}")/qa-world.sh"
skip_unless has_box_tools "this host lacks bash 5, flock or GNU date, which the QA actions need"
skip_unless has_tomllib "python3 has no tomllib (needs 3.11+)"

DOWN="$ROOT/actions/qa-down/down.sh"
CHECK="$ROOT/actions/qa-down/check.sh"
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
# waiting_prs: two open pull requests that wait for a slot, 21 the longer.
waiting_prs() {
  jq -n '[{number: 20, isDraft: false}, {number: 21, isDraft: false}]' >"$GH_FAKE/prs.json"
  comment 20 401 'github-actions[bot]' "$(qa_body waiting since=2026-10-26T10:00:00Z)"
  comment 21 402 'github-actions[bot]' "$(qa_body waiting since=2026-10-26T08:00:00Z)"
  export MROOM_QA_DEFAULT_BRANCH=main
}
dispatches() { grep '^dispatch' "$GH_FAKE/gh.log" 2>/dev/null || true; }

t_an_environment_comes_down_in_order() {
  qa_world; environment_7
  forge_set '.process_remove_reads = 1'
  comment 7 301 'github-actions[bot]' "$(qa_body ready)"
  comment 7 302 'github-actions[bot]' $'## Another check\n\nNot this one.'
  run "$DOWN" 7 --reason closed --state present
  expect_rc 0; expect_out_has "environment 7: removed"
  # Daemons first, and gone before user-clean; the sites right after it; then the box's side.
  run order
  expect_out $'forge DELETE /background-processes/5\nforge DELETE /background-processes/6\ngate user-clean 7
forge DELETE /sites/11\nforge DELETE /sites/12\ngate db-drop 7\ngate redis-user-remove 7\ngate redis-clear 7
gate mail-user-remove 7\ngate mail-clear 7\ngate bucket-drop 7'
  run grep -c '^GET /background-processes' "$FORGE_LOG"; expect_out 3
  # The comment says it is being removed before anything goes, then that it was removed.
  run gh_log
  expect_out $'PATCH 301 ### QA environment\\n<!-- mroom-qa: removing -->\\n\\nBeing removed: the pull request closed.
PATCH 301 ### QA environment\\n<!-- mroom-qa: removed -->\\n\\nRemoved: the pull request closed.'
  run jq -r '[.sites[] | "\(.id) \(.status)"] | join(",")' "$FORGE_STATE"; expect_out "11 removing,12 removing,13 installed"
  run jq -r '[.processes[].id] | join(",")' "$FORGE_STATE"; expect_out "7"
}

t_the_ssh_key_stays_off_every_command_line() {
  qa_world; environment_7
  run "$DOWN" 7
  expect_rc 0
  expect_true "the key reached ssh's command line" lacks "$(cat "$GATE/ssh.argv")" "not-a-real-key"
  # Batch mode, no config file, no agent, the pinned host key, and no stdin for any of these requests.
  run grep -c -x -e 'BatchMode=yes' -e 'StrictHostKeyChecking=yes' -e 'IdentitiesOnly=yes' -e 'IdentityAgent=none' \
    -e 'GlobalKnownHostsFile=/dev/null' "$GATE/ssh.argv"
  expect_out 35
  run grep -c -x -e '-n' "$GATE/ssh.argv"; expect_out 7
  run grep -c -x 'forge@box.example.dev' "$GATE/ssh.argv"; expect_out 7
  expect_true "the key folder was left in TMPDIR" tmp_empty
  expect_true "the Forge token was printed" lacks "$out$err" fake-forge-token
}

t_a_loop_of_teardowns_loses_none_of_its_input() {
  qa_world
  site 1 api-1.qa.example.dev installed
  site 2 api-2.qa.example.dev installed
  site 3 api-3.qa.example.dev installed
  forge_set '.remove_reads = -1'
  # As OpenSSH does, the gate's stand-in reads stdin unless told not to (-n): in a loop, that would eat the list.
  run bash -c 'while read -r n; do "$0" "$n" --reason hand || exit 1; done <<<"$(printf "1\n2\n3\n")"' "$DOWN"
  expect_rc 0
  run grep '^user-clean' "$GATE/gate.log"; expect_out $'user-clean 1\nuser-clean 2\nuser-clean 3'
  run jq -r '[.sites[].status] | join(",")' "$FORGE_STATE"; expect_out "removing,removing,removing"
}

t_with_no_site_every_step_still_runs() {
  qa_world
  waiting_prs
  run "$DOWN" 7 --reason hand --wake
  expect_rc 0; expect_out_has "environment 7: Forge has it absent; tearing down whatever of it is left"
  run gate_log; expect_out $'user-clean 7\n'"$BOX_SIDE"
  run forge_writes; expect_out ""
  # Nothing held a slot, so nobody is woken.
  run dispatches; expect_out ""
  run grep -c '^POST 7 ' "$GH_FAKE/gh.log"; expect_out 1
}

t_a_run_again_finishes_a_teardown_whose_box_side_failed() {
  qa_world; environment_7; waiting_prs
  forge_set '.remove_reads = 0'
  echo 1 >"$GATE/redis-user-remove.rc"
  echo 1 >"$GATE/bucket-drop.rc"
  export RUN_URL=https://github.example/runs/5
  run "$DOWN" 7 --reason closed --state present --wake
  expect_rc 1; expect_err_has "environment 7: its sites are gone, but not the box's Redis user, buckets"
  run gh_log
  expect_out_has 'mroom-qa: failed -->\n\nThe teardown stopped at the box'"'"'s Redis user, buckets, so part of the environment is left. Re-run the failed job ([run](https://github.example/runs/5)) to finish it'
  run dispatches; expect_out ""
  # "Re-run failed jobs" runs the teardown again with the check's first answer, though Forge has no site now.
  rm "$GATE/redis-user-remove.rc" "$GATE/bucket-drop.rc"
  : >"$GATE/gate.log"
  run "$DOWN" 7 --reason closed --state present --wake
  expect_rc 0
  run gate_log; expect_out $'user-clean 7\n'"$BOX_SIDE"
  run gh_log; expect_out_has 'mroom-qa: removed -->\n\nRemoved: the pull request closed.'
  run dispatches; expect_out "dispatch qa-plan.yml main pr_number=21"
}

t_a_site_stuck_removing_gets_the_delete_again_and_wakes_nobody() {
  qa_world; waiting_prs
  site 11 api-7.qa.example.dev removing "$(ago 864000)" "$(ago 7200)"
  site 12 go-7.qa.example.dev removing "$(ago 864000)" "$(ago 300)"
  forge_set '.remove_reads = -1'
  run "$DOWN" 7 --wake
  expect_rc 0; expect_out_has "environment 7: Forge has it removing"
  expect_out_has "had been removing for 120 minutes; sent the delete again"
  expect_out_has "Forge is removing it"
  run forge_writes; expect_out "DELETE /sites/11"
  run gate_log; expect_out $'user-clean 7\n'"$BOX_SIDE"
  # A slot Forge was already freeing is no slot this teardown freed.
  run dispatches; expect_out ""
}

t_a_failed_user_clean_keeps_the_sites() {
  qa_world; environment_7
  echo 1 >"$GATE/user-clean.rc"
  run "$DOWN" 7
  expect_rc 1; expect_err_has "user-clean failed, so the sites stay"
  run gate_log; expect_out "user-clean 7"
  run forge_writes; expect_out $'DELETE /background-processes/5\nDELETE /background-processes/6'
  run gh_log; expect_out_has "The teardown stopped at user-clean"
}

t_daemons_that_never_go_keep_everything_else() {
  qa_world; environment_7
  forge_set '.process_remove_reads = -1'
  export MROOM_QA_DAEMON_WAIT=10
  run "$DOWN" 7
  expect_rc 1; expect_err_has "Forge still lists daemons 5, 6 10s after deleting them, so the sites stay"
  run gate_log; expect_out ""
  run forge_writes; expect_out $'DELETE /background-processes/5\nDELETE /background-processes/6'
}

t_one_box_step_failing_leaves_the_others_to_run() {
  qa_world; environment_7
  echo 1 >"$GATE/redis-user-remove.rc"
  run "$DOWN" 7
  expect_rc 1; expect_err_has "its sites are gone, but not the box's Redis user"
  run gate_log; expect_out $'user-clean 7\n'"$BOX_SIDE"
}

t_a_delete_that_finds_nothing_counts_as_done() {
  qa_world; environment_7
  forge_set '.fail["DELETE /sites/11"] = 404'
  run "$DOWN" 7
  expect_rc 0
  run gate_log; expect_out $'user-clean 7\n'"$BOX_SIDE"
  # Any other answer still fails the step.
  site 21 api-8.qa.example.dev installed
  forge_set '.fail["DELETE /sites/21"] = 500'
  run "$DOWN" 8
  expect_rc 1; expect_err_has "DELETE /sites/21 -> HTTP 500"
}

t_services_qa_does_not_use_are_left_alone() {
  qa_world; environment_7
  printf '\n[qa.parity]\nmail = "log"\nfiles = "local"\n' >>"$MROOM_CONFIG"
  run "$DOWN" 7
  expect_rc 0
  run gate_log; expect_out $'user-clean 7\ndb-drop 7\nredis-user-remove 7\nredis-clear 7'
  printf 'broken = [\n' >>"$MROOM_CONFIG"
  run "$DOWN" 7
  expect_rc 1; expect_err_has "not valid TOML"
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

t_the_check_reads_forge_and_changes_nothing() {
  qa_world; environment_7
  run "$CHECK" 7; expect_rc 0; expect_out "state=present"
  run "$CHECK" 70 --reason label; expect_out "state=present"
  forge_set '.sites[0].status = "removing" | .sites[1].status = "removing"'
  run "$CHECK" 7; expect_out "state=removing"
  run "$CHECK" 8; expect_out "state=absent"
  # The go site alone is an environment too.
  forge_set '.sites[1].status = "installed"'
  run "$CHECK" 7; expect_out "state=present"
  run forge_writes; expect_out ""
  run gate_log; expect_out ""
  forge_set '.fail["GET /sites"] = 500'
  run "$CHECK" 7; expect_rc 1; expect_out ""
}

t_a_label_off_a_waiting_pull_request_stops_its_wait() {
  qa_world
  comment 8 501 'github-actions[bot]' "$(qa_body waiting since=2026-10-26T08:00:00Z)"
  comment 9 502 'github-actions[bot]' "$(qa_body waiting since=2026-10-26T08:00:00Z)"
  run "$CHECK" 8 --reason label
  expect_rc 0; expect_out "state=absent"
  run gh_log; expect_out_has 'PATCH 501 ### QA environment\n<!-- mroom-qa: idle -->\n\nNo longer waiting for a QA environment: its qa label came off.'
  # A pull request that closed is woken no more anyway.
  run "$CHECK" 9 --reason closed
  run grep -c '^PATCH 502' "$GH_FAKE/gh.log"; expect_out 0
  # A comment GitHub cannot give leaves the answer as it is.
  : >"$GH_FAKE/down"
  run "$CHECK" 9 --reason label
  expect_rc 0; expect_out "state=absent"
}

t_a_qa_environment_not_set_up_has_nothing_to_tear_down() {
  qa_world; environment_7
  unset MROOM_FORGE_SERVER
  run "$DOWN" 7; expect_rc 0; expect_out "the qa environment has no MROOM_FORGE_SERVER yet, so there is nothing to tear down"
  run "$CHECK" 7; expect_rc 0; expect_out "state=absent"
  expect_no_file "$FORGE_LOG"
}

t_usage() {
  qa_world
  local args
  for args in "" "07" "0" "7 --nope" "7 --reason" "abc" "7 --reason because" "7 --state gone"; do
    # shellcheck disable=SC2086  # each case is words
    run "$DOWN" $args
    expect_rc 2; expect_err_has "usage: down.sh <N>"
  done
  run "$CHECK" 7 --reason ttl; expect_rc 2
  run forge_writes; expect_out ""
}

test_case comes-down-in-order t_an_environment_comes_down_in_order
test_case ssh-key-off-command-lines t_the_ssh_key_stays_off_every_command_line
test_case loop-loses-no-input t_a_loop_of_teardowns_loses_none_of_its_input
test_case no-site-every-step t_with_no_site_every_step_still_runs
test_case run-again-finishes t_a_run_again_finishes_a_teardown_whose_box_side_failed
test_case stuck-removing t_a_site_stuck_removing_gets_the_delete_again_and_wakes_nobody
test_case user-clean-fails t_a_failed_user_clean_keeps_the_sites
test_case daemons-never-go t_daemons_that_never_go_keep_everything_else
test_case one-box-step-fails t_one_box_step_failing_leaves_the_others_to_run
test_case delete-404-is-done t_a_delete_that_finds_nothing_counts_as_done
test_case parity-swaps t_services_qa_does_not_use_are_left_alone
test_case forge-unreadable t_a_forge_that_cannot_be_read_stops_it
test_case check t_the_check_reads_forge_and_changes_nothing
test_case label-stops-wait t_a_label_off_a_waiting_pull_request_stops_its_wait
test_case not-set-up t_a_qa_environment_not_set_up_has_nothing_to_tear_down
test_case usage t_usage
finish
