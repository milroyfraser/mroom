#!/usr/bin/env bash
# shellcheck disable=SC2317  # the t_* functions run indirectly, through test_case
# Tests for the QA reaper (actions/qa-reap/reap.sh) and the wake it shares with qa-down (lib/core/qa.sh): every
# environment past qa.ttl_days comes down and counts as a freed slot; one Forge is removing is skipped, and gets the
# delete again once it is stuck, with a warning; a Forge that cannot be read fails the run; one failed teardown does
# not stop the others; each freed slot goes to the longest-waiting pull request. Offline: Forge, GitHub, the gate
# and, in most tests, the teardown itself are fakes.
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

# fake_down: a teardown that only says what it was asked; it fails for N when $T/down-fails-N exists.
fake_down() {
  cat >"$T/bin/fake-down" <<'FAKE'
#!/usr/bin/env bash
echo "down $*" >>"$T/down.log"
[ ! -f "$T/down-fails-$1" ]
FAKE
  chmod +x "$T/bin/fake-down"
  export MROOM_QA_DOWN="$T/bin/fake-down"
}
downs() { cut -d' ' -f2 "$T/down.log" 2>/dev/null | tr '\n' ' ' || true; }

t_environments_past_their_time_come_down() {
  qa_world; fake_down
  site 1 api-1.qa.example.dev installed "$(ago $((9 * DAY)))"
  site 2 api-2.qa.example.dev removing "$(ago $((9 * DAY)))"
  site 3 api-3.qa.example.dev installed "$(ago "$DAY")"
  site 4 go-1.qa.example.dev installed "$(ago $((9 * DAY)))"
  site 5 api.qa.example.dev installed "$(ago $((90 * DAY)))"
  site 6 api-6.qa.example.dev removing "$(ago $((9 * DAY)))" "$(ago 10800)"
  site 7 api-7.qa.example.dev removing "$(ago $((9 * DAY)))" "$(ago 300)"
  site 8 api-8.qa.other.dev installed "$(ago $((9 * DAY)))"
  site 9 api-09.qa.example.dev installed "$(ago $((9 * DAY)))"
  run "$REAP"
  expect_rc 0; expect_out_has "reaped 1 environment(s)"
  expect_out_has "environment 2: Forge is already removing it; skipped"
  # Removing for 3 hours gets the delete again; for 5 minutes, or with no time to tell, it does not.
  expect_out_has "::warning::environment 6: api-6.qa.example.dev had been removing for 180 minutes, so the delete went again"
  expect_true "a site removing for 5 minutes was warned about" lacks "$out" "environment 7: api-7"
  run forge_writes; expect_out "DELETE /sites/6"
  run cat "$T/down.log"; expect_out "down 1 --why it was older than 5 days. The next push that needs one brings it back"
  run cat "$GITHUB_OUTPUT"; expect_out "reaped=1"
}

t_the_time_comes_from_mroom_toml() {
  qa_world; fake_down
  printf 'ttl_days = 2\n' >>"$MROOM_CONFIG"
  site 1 api-1.qa.example.dev installed "$(ago $((3 * DAY)))"
  site 3 api-3.qa.example.dev installed "$(ago "$DAY")"
  run "$REAP"
  expect_rc 0
  run downs; expect_out "1 "
}

t_one_failed_teardown_does_not_stop_the_rest() {
  qa_world; fake_down
  site 1 api-1.qa.example.dev installed "$(ago $((9 * DAY)))"
  site 2 api-2.qa.example.dev installed "$(ago $((8 * DAY)))"
  : >"$T/down-fails-1"
  run "$REAP"
  expect_rc 1; expect_err_has "the teardown of environment(s) 1 failed; the next reap tries again"
  run downs; expect_out "1 2 "
  run cat "$GITHUB_OUTPUT"; expect_out "reaped=1"
}

t_a_forge_that_cannot_be_read_fails_the_run() {
  qa_world; fake_down
  site 1 api-1.qa.example.dev installed "$(ago $((9 * DAY)))"
  forge_set '.fail["GET /sites"] = 503'
  run "$REAP"
  expect_rc 1; expect_err_has "Forge's sites could not be read 3 times"
  expect_no_file "$T/down.log"
  expect_no_file "$GITHUB_OUTPUT"
}

t_each_freed_slot_wakes_the_longest_waiting() {
  qa_world; fake_down
  site 1 api-1.qa.example.dev installed "$(ago $((9 * DAY)))"
  site 2 api-2.qa.example.dev installed "$(ago $((8 * DAY)))"
  jq -n '[range(20; 26) | {number: ., isDraft: (. == 24)}]' >"$GH_FAKE/prs.json"
  comment 20 401 'github-actions[bot]' "$(qa_body waiting)" 2026-10-26T10:00:00Z
  comment 21 402 'github-actions[bot]' "$(qa_body waiting)" 2026-10-26T08:00:00Z
  comment 22 403 'github-actions[bot]' "$(qa_body ready)" 2026-10-26T07:00:00Z
  comment 23 404 'a-person' "$(qa_body waiting)" 2026-10-26T06:00:00Z
  comment 24 405 'github-actions[bot]' "$(qa_body waiting)" 2026-10-26T05:00:00Z
  comment 25 406 'github-actions[bot]' "$(qa_body waiting)" 2026-10-26T09:00:00Z
  comment 25 407 'github-actions[bot]' $'## Something else\n\n<!-- mroom-qa: ready -->\n' 2026-10-26T11:00:00Z
  export MROOM_QA_DEFAULT_BRANCH=main MROOM_QA_PLAN_WORKFLOW=qa-build.yml
  run "$REAP"
  expect_rc 0
  run grep dispatch "$GH_FAKE/gh.log"; expect_out $'dispatch qa-build.yml main 21\ndispatch qa-build.yml main 25'
}

t_no_free_slot_and_no_waiting_pull_request_wake_nobody() {
  qa_world; fake_down
  jq -n '[{number: 20, isDraft: false}]' >"$GH_FAKE/prs.json"
  comment 20 401 'github-actions[bot]' "$(qa_body waiting)"
  run "$REAP"
  expect_rc 0; expect_out_has "reaped 0 environment(s)"
  run gh_log; expect_out ""
  site 1 api-1.qa.example.dev installed "$(ago $((9 * DAY)))"
  echo '[]' >"$GH_FAKE/comments-20.json"
  run "$REAP"
  expect_rc 0; expect_out_has "no pull request waits for a QA environment slot"
  run gh_log; expect_out ""
}

t_a_reap_runs_the_teardown_for_each() {
  qa_world
  site 1 api-1.qa.example.dev installed "$(ago $((9 * DAY)))"
  site 2 go-1.qa.example.dev installed "$(ago $((9 * DAY)))"
  run "$REAP"
  expect_rc 0
  run order
  expect_out $'gate user-clean 1\nforge DELETE /sites/1\nforge DELETE /sites/2\ngate db-drop 1\ngate redis-user-remove 1\ngate redis-clear 1\ngate mail-user-remove 1\ngate mail-clear 1\ngate bucket-drop 1'
  run gh_log
  expect_out 'POST 1 ### QA environment\n<!-- mroom-qa: removed -->\n\nRemoved: it was older than 5 days. The next push that needs one brings it back.'
}

t_a_qa_environment_not_set_up_has_nothing_to_reap() {
  qa_world; fake_down
  unset MROOM_FORGE_SERVER
  run "$REAP"
  expect_rc 0; expect_out "the qa environment has no MROOM_FORGE_SERVER yet, so there is nothing to reap"
  expect_no_file "$FORGE_LOG"
}

test_case past-their-time t_environments_past_their_time_come_down
test_case ttl-from-config t_the_time_comes_from_mroom_toml
test_case one-failure-continues t_one_failed_teardown_does_not_stop_the_rest
test_case forge-unreadable t_a_forge_that_cannot_be_read_fails_the_run
test_case wake-per-slot t_each_freed_slot_wakes_the_longest_waiting
test_case wake-nobody t_no_free_slot_and_no_waiting_pull_request_wake_nobody
test_case real-teardown t_a_reap_runs_the_teardown_for_each
test_case not-set-up t_a_qa_environment_not_set_up_has_nothing_to_reap
finish
