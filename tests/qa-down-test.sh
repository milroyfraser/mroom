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
  site 11 "$(api_host 7)" installed
  site 12 "$(web_host 7)" installed
  site 13 "$(api_host 70)" installed
  process 5 "$(site_user 7)" "/home/$(site_user 7)/$(api_host 7)/."
  process 6 forge "/home/$(site_user 7)/$(api_host 7)/."
  process 7 "$(site_user 70)" "/home/$(site_user 70)/$(api_host 70)/."
}
# freed: what the teardown said about its slot, for qa-down's wake job.
freed() { output_of freed; }
# marker_of <PR>: the hidden line of the pull request's newest comment.
marker_of() { jq -r '.[-1].body' "$GH_FAKE/comments-$1.json" | sed -n 2p; }

t_an_environment_comes_down_in_order() {
  qa_world; environment_7
  forge_set '.process_remove_reads = 1'
  comment 7 301 'github-actions[bot]' "$(qa_body ready)"
  comment 7 302 'github-actions[bot]' $'## Another check\n\nNot this one.'
  run "$DOWN" 7 --reason closed --state present
  expect_rc 0; expect_out_has "environment 7: removed"
  # The names of before mroom 0.5.0 are looked for, and said only when Forge has a site by one.
  expect_true "the teardown said a name Forge has no site by" lacks "$out" "==> Site $(old_api_host 7)"
  expect_true "the teardown said a name Forge has no site by" lacks "$out" "==> Site $(old_web_host 7)"
  # Daemons first, and gone before user-clean; the sites right after it; then the box's side.
  run order
  expect_out $'forge DELETE /background-processes/5\nforge DELETE /background-processes/6\ngate user-clean 7
forge DELETE /sites/11\nforge DELETE /sites/12\ngate db-drop 7\ngate redis-user-remove 7\ngate redis-clear 7
gate mail-user-remove 7\ngate mail-clear 7\ngate bucket-drop 7'
  run grep -c '^GET /background-processes' "$FORGE_LOG"; expect_out 3
  # The comment says it is being removed before anything goes, then that it was removed.
  run gh_log
  expect_out $'PATCH 301 ### QA environment\\n<!-- mroom-qa: removing was=present -->\\n\\nBeing removed: the pull request closed.
PATCH 301 ### QA environment\\n<!-- mroom-qa: removed -->\\n\\nRemoved: the pull request closed.'
  # Environment 7's sites are removing, or gone already; environment 70's stays.
  run jq -r '[.sites[] | select(.status != "removing") | .id] | join(",")' "$FORGE_STATE"; expect_out "13"
  run jq -r '[.processes[].id] | join(",")' "$FORGE_STATE"; expect_out "7"
  # It held a slot, which the wake job gives on.
  run freed; expect_out true
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
  site 1 "$(api_host 1)" installed
  site 2 "$(api_host 2)" installed
  site 3 "$(api_host 3)" installed
  forge_set '.remove_reads = -1'
  # As OpenSSH does, the gate's stand-in reads stdin unless told not to (-n): in a loop, that would eat the list.
  run bash -c 'while read -r n; do "$0" "$n" --reason hand || exit 1; done <<<"$(printf "1\n2\n3\n")"' "$DOWN"
  expect_rc 0
  run grep '^user-clean' "$GATE/gate.log"; expect_out $'user-clean 1\nuser-clean 2\nuser-clean 3'
  run jq -r '[.sites[].status] | join(",")' "$FORGE_STATE"; expect_out "removing,removing,removing"
}

t_with_no_site_every_step_still_runs() {
  qa_world
  run "$DOWN" 7 --reason hand
  expect_rc 0; expect_out_has "environment 7: absent when this teardown started; tearing down whatever of it is left"
  run gate_log; expect_out $'user-clean 7\n'"$BOX_SIDE"
  run forge_writes; expect_out ""
  # Nothing held a slot, so nobody is woken.
  run freed; expect_out false
  run grep -c '^POST 7 ' "$GH_FAKE/gh.log"; expect_out 1
}

t_a_run_again_finishes_a_teardown_whose_box_side_failed() {
  qa_world; environment_7
  forge_set '.remove_reads = 0'
  echo 1 >"$GATE/redis-user-remove.rc"
  echo 1 >"$GATE/bucket-drop.rc"
  export RUN_URL=https://github.example/runs/5
  run "$DOWN" 7 --reason closed --state present
  expect_rc 1; expect_err_has "environment 7: its sites are gone, but not the box's Redis user, buckets"
  run gh_log
  expect_out_has 'mroom-qa: failed was=present -->\n\nThe teardown stopped at the box'"'"'s Redis user, buckets, so part of the environment is left. Re-run the failed job ([run](https://github.example/runs/5)) to finish it'
  # Its sites went, so its slot is free, whatever the box's side came to: the wake job gives it on.
  run freed; expect_out true
  # "Re-run failed jobs" runs the teardown again with the check's first answer, though Forge has no site now.
  rm "$GATE/redis-user-remove.rc" "$GATE/bucket-drop.rc"
  : >"$GATE/gate.log"
  : >"$GITHUB_OUTPUT"
  run "$DOWN" 7 --reason closed --state present
  expect_rc 0
  run gate_log; expect_out $'user-clean 7\n'"$BOX_SIDE"
  run gh_log; expect_out_has 'mroom-qa: removed -->\n\nRemoved: the pull request closed.'
  run freed; expect_out true
}

t_re_run_all_jobs_finishes_it_too() {
  qa_world; environment_7
  forge_set '.remove_reads = 0'
  comment 7 301 'github-actions[bot]' "$(qa_body ready)"
  echo 1 >"$GATE/db-drop.rc"
  run "$DOWN" 7 --reason closed --state present
  expect_rc 1
  run marker_of 7; expect_out "<!-- mroom-qa: failed was=present -->"
  run freed; expect_out true
  : >"$GITHUB_OUTPUT"
  # "Re-run all jobs" runs the check again: Forge has no site now, but the comment says a teardown stopped partway,
  # from present, so the teardown runs again, and frees the slot.
  rm "$GATE/db-drop.rc"
  run "$CHECK" 7 --reason closed
  expect_rc 0; expect_out "state=present"
  expect_err_has "its last teardown stopped partway, from present: it runs again"
  run "$DOWN" 7 --reason closed --state present
  expect_rc 0
  run freed; expect_out true
  # Once it is done, the check finds nothing to do.
  run "$CHECK" 7 --reason closed; expect_out "state=absent"
  # A failed deploy's comment, which names no state a teardown started from, is no teardown to finish.
  comment 7 302 'github-actions[bot]' "$(qa_body failed)"
  run "$CHECK" 7 --reason closed; expect_out "state=absent"
}

t_a_dispatched_teardown_run_again_frees_its_slot() {
  qa_world
  site 11 "$(api_host 7)" installed
  forge_set '.remove_reads = 0'
  comment 7 301 'github-actions[bot]' "$(qa_body ready)"
  echo 1 >"$GATE/bucket-drop.rc"
  # The reaper's teardown has no check job, so no --state: it reads Forge, and its comment keeps what it read.
  run "$DOWN" 7 --reason ttl
  expect_rc 1
  run marker_of 7; expect_out "<!-- mroom-qa: failed was=present -->"
  run freed; expect_out true
  : >"$GITHUB_OUTPUT"
  rm "$GATE/bucket-drop.rc"
  run "$DOWN" 7 --reason ttl
  expect_rc 0; expect_out_has "environment 7: present when this teardown started"
  run freed; expect_out true
}

t_a_site_stuck_removing_gets_the_delete_again_and_wakes_nobody() {
  qa_world
  site 11 "$(api_host 7)" removing "$(ago 864000)" "$(ago 7200)"
  site 12 "$(web_host 7)" removing "$(ago 864000)" "$(ago 300)"
  forge_set '.remove_reads = -1'
  run "$DOWN" 7
  expect_rc 0; expect_out_has "environment 7: removing when this teardown started"
  expect_out_has "had been removing for 120 minutes; sent the delete again"
  expect_out_has "Forge is removing it"
  run forge_writes; expect_out "DELETE /sites/11"
  run gate_log; expect_out $'user-clean 7\n'"$BOX_SIDE"
  # A slot Forge was already freeing is no slot this teardown freed.
  run freed; expect_out false
}

t_the_comment_offers_a_push_only_to_an_open_pull_request() {
  qa_world
  site 11 "$(api_host 7)" installed "$(ago $((9 * 86400)))"
  echo '{"state": "OPEN"}' >"$GH_FAKE/pr-7.json"
  run "$DOWN" 7 --reason ttl
  expect_rc 0
  run gh_log; expect_out_has 'Being removed: it was older than 5 days; the next push that needs one brings it back.'
  # A closed pull request gets no push, so the comment offers none.
  : >"$GH_FAKE/gh.log"
  echo '{"state": "CLOSED"}' >"$GH_FAKE/pr-7.json"
  run "$DOWN" 7 --reason ttl
  run gh_log; expect_out_has 'Being removed: it was older than 5 days.'
  expect_true "a closed pull request was offered a push" lacks "$out" "next push"
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

t_a_daemon_found_by_its_command_goes_too() {
  qa_world; environment_7
  # forge's own daemon, from forge's home, that runs environment 7's artisan, goes; environment 70's stays.
  process 8 forge /home/forge running "php8.4 /home/$(site_user 7)/$(api_host 7)/artisan horizon"
  process 9 forge /home/forge running "php8.4 /home/$(site_user 70)/$(api_host 70)/artisan horizon"
  run "$DOWN" 7 --reason closed --state present
  expect_rc 0
  run jq -r '[.processes[].id] | join(",")' "$FORGE_STATE"; expect_out "7,9"
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
  # Any other answer still fails the step: a refusal (403) and a server's fault (500) alike.
  site 21 "$(api_host 8)" installed
  forge_set '.fail["DELETE /sites/21"] = 500'
  run "$DOWN" 8
  expect_rc 1; expect_err_has "DELETE /sites/21 -> HTTP 500"
  site 31 "$(api_host 9)" installed
  forge_set '.fail["DELETE /sites/31"] = 403'
  run "$DOWN" 9
  expect_rc 1; expect_err_has "DELETE /sites/31 -> HTTP 403"
  run gate_log; expect_true "the box side ran after a refused delete" lacks "$out" "db-drop 9"
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
  # The frontend's site alone is an environment too.
  forge_set '.sites[1].status = "installed"'
  run "$CHECK" 7; expect_out "state=present"
  run forge_writes; expect_out ""
  run gate_log; expect_out ""
  forge_set '.fail["GET /sites"] = 500'
  run "$CHECK" 7; expect_rc 1; expect_out ""
}

t_an_environment_of_the_old_names_comes_down_too() {
  qa_world
  # Brought up before mroom 0.5.0, as api-7 and go-7, with a worker of its own and a daemon of forge's that runs
  # from its old frontend's folder.
  site 11 "$(old_api_host 7)" installed
  site 12 "$(old_web_host 7)" installed
  site 13 "$(api_host 70)" installed
  process 5 "$(site_user 7)" "/home/$(site_user 7)/$(old_api_host 7)/."
  process 6 forge "/var/www/$(old_web_host 7)"
  run "$CHECK" 7; expect_rc 0; expect_out "state=present"
  run "$DOWN" 7 --reason closed --state present
  expect_rc 0; expect_out_has "environment 7: removed"
  expect_out_has "==> Site $(old_api_host 7)"$'\n'"    deleted site 11"
  expect_out_has "==> Site $(old_web_host 7)"$'\n'"    deleted site 12"
  run order
  expect_out $'forge DELETE /background-processes/5\nforge DELETE /background-processes/6\ngate user-clean 7
forge DELETE /sites/11\nforge DELETE /sites/12\n'"gate ${BOX_SIDE//$'\n'/$'\ngate '}"
  run jq -r '[.sites[] | select(.status != "removing") | .id] | join(",")' "$FORGE_STATE"; expect_out "13"
  run freed; expect_out true
  # Its frontend's site alone, as a teardown that stopped halfway leaves it, is the environment still; and once Forge
  # is removing that, the environment is being removed.
  qa_world
  site 12 "$(old_web_host 7)" installed
  run "$CHECK" 7; expect_rc 0; expect_out "state=present"
  forge_set '.sites[0].status = "removing"'
  run "$CHECK" 7; expect_rc 0; expect_out "state=removing"
}

t_an_environment_on_a_later_page_is_found() {
  qa_world
  # Forge lists at most 30 at a time, whatever page[size] asks: here 1, with environment 7 on the third page.
  forge_set '.page_size = 1'
  site 1 "$(api_host 1)" installed
  site 2 "$(api_host 2)" installed
  site 11 "$(api_host 7)" installed
  run "$CHECK" 7; expect_out "state=present"
  run "$DOWN" 7
  expect_rc 0; expect_out_has "environment 7: present when this teardown started"
  run forge_writes; expect_out "DELETE /sites/11"
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
  run "$DOWN" 7; expect_rc 0; expect_out "::warning::the qa environment has no MROOM_FORGE_SERVER yet, so there is nothing to tear down"
  run "$CHECK" 7; expect_rc 0; expect_out "state=absent"
  expect_err_has "::warning::the qa environment has no MROOM_FORGE_SERVER yet"
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
test_case re-run-all-jobs t_re_run_all_jobs_finishes_it_too
test_case dispatched-run-again t_a_dispatched_teardown_run_again_frees_its_slot
test_case stuck-removing t_a_site_stuck_removing_gets_the_delete_again_and_wakes_nobody
test_case push-only-if-open t_the_comment_offers_a_push_only_to_an_open_pull_request
test_case user-clean-fails t_a_failed_user_clean_keeps_the_sites
test_case daemon-by-command t_a_daemon_found_by_its_command_goes_too
test_case daemons-never-go t_daemons_that_never_go_keep_everything_else
test_case one-box-step-fails t_one_box_step_failing_leaves_the_others_to_run
test_case delete-404-is-done t_a_delete_that_finds_nothing_counts_as_done
test_case parity-swaps t_services_qa_does_not_use_are_left_alone
test_case forge-unreadable t_a_forge_that_cannot_be_read_stops_it
test_case check t_the_check_reads_forge_and_changes_nothing
test_case old-names-come-down t_an_environment_of_the_old_names_comes_down_too
test_case later-page t_an_environment_on_a_later_page_is_found
test_case label-stops-wait t_a_label_off_a_waiting_pull_request_stops_its_wait
test_case not-set-up t_a_qa_environment_not_set_up_has_nothing_to_tear_down
test_case usage t_usage
finish
