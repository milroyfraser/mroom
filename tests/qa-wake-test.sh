#!/usr/bin/env bash
# shellcheck disable=SC2317  # the t_* functions run indirectly, through test_case
# Tests for the wake and the comment it reads (lib/core/qa.sh, qa_wake and qa_comment): a freed slot goes to the pull
# request that has waited longest, by the time it started waiting, which the comment keeps across rewrites; it is
# marked woken before its plan starts, so a second wake close behind picks another; a woken one waits again after
# half an hour; drafts, other people's comments and other states are skipped; and the cost stays bounded.
set -euo pipefail
SUITE=qa-wake
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/qa-world.sh
source "$(dirname "${BASH_SOURCE[0]}")/qa-world.sh"
skip_unless has_box_tools "this host lacks bash 5, flock or GNU date, which the QA actions need"
skip_unless has_tomllib "python3 has no tomllib (needs 3.11+)"

# lib <shell code>: runs it with util.sh, forge.sh and qa.sh sourced, as an action script would.
lib() {
  run env MROOM_ROOT="$ROOT" bash -c ". '$ROOT/lib/core/util.sh'; . '$ROOT/lib/core/forge.sh'; . '$ROOT/lib/core/qa.sh'; $1"
}
dispatches() { grep '^dispatch' "$GH_FAKE/gh.log" 2>/dev/null || true; }
prs() { jq -n --argjson n "$1" '$n | map({number: ., isDraft: false})' >"$GH_FAKE/prs.json"; }
marker_of() { jq -r '.[-1].body' "$GH_FAKE/comments-$1.json" | sed -n 2p; }

t_the_longest_waiting_goes_first_by_when_it_started_waiting() {
  qa_world; export MROOM_QA_DEFAULT_BRANCH=main
  prs '[20, 21, 22]'
  # 21 has waited longest, though its comment was rewritten last.
  comment 20 401 'github-actions[bot]' "$(qa_body waiting since=2026-10-26T10:00:00Z)" 2026-10-26T10:00:00Z
  comment 21 402 'github-actions[bot]' "$(qa_body waiting since=2026-10-26T08:00:00Z)" 2026-10-27T11:00:00Z
  comment 22 403 'github-actions[bot]' "$(qa_body waiting since=2026-10-26T09:00:00Z)" 2026-10-26T09:00:00Z
  lib 'qa_wake 2'
  expect_rc 0
  run dispatches; expect_out $'dispatch qa-plan.yml main pr_number=21\ndispatch qa-plan.yml main pr_number=22'
}

t_a_woken_pull_request_is_marked_before_its_plan_starts() {
  qa_world; export MROOM_QA_DEFAULT_BRANCH=main
  prs '[20, 21]'
  comment 20 401 'github-actions[bot]' "$(qa_body waiting since=2026-10-26T10:00:00Z)"
  comment 21 402 'github-actions[bot]' "$(qa_body waiting since=2026-10-26T08:00:00Z)"
  lib 'qa_wake 1'
  run grep -E '^(PATCH|dispatch)' "$GH_FAKE/gh.log"
  expect_out_has $'PATCH 402 ### QA environment\\n<!-- mroom-qa: woken since=2026-10-26T08:00:00Z woken=2026-10-27T12:00:00Z -->'
  case "$out" in "PATCH 402"*$'\n'"dispatch qa-plan.yml main pr_number=21") ok ;; *) fail "the mark did not come before the dispatch" ;; esac
  # A second teardown close behind wakes the next one, not the same one twice.
  lib 'qa_wake 1'
  run dispatches; expect_out $'dispatch qa-plan.yml main pr_number=21\ndispatch qa-plan.yml main pr_number=20'
}

t_one_that_cannot_be_marked_is_left_for_the_next_wake() {
  qa_world; export MROOM_QA_DEFAULT_BRANCH=main
  prs '[20, 21]'
  comment 20 401 'github-actions[bot]' "$(qa_body waiting since=2026-10-26T10:00:00Z)"
  comment 21 402 'github-actions[bot]' "$(qa_body waiting since=2026-10-26T08:00:00Z)"
  : >"$GH_FAKE/patch-fails-402"
  lib 'qa_wake 1'
  expect_rc 0; expect_out_has "::warning::could not mark pull request 21 as woken, so it is left for the next wake"
  # Started unmarked, its plan could be started twice; the slot goes to the next one instead.
  run dispatches; expect_out "dispatch qa-plan.yml main pr_number=20"
}

t_a_woken_pull_request_waits_again_after_half_an_hour() {
  qa_world
  prs '[20, 21]'
  comment 20 401 'github-actions[bot]' "$(qa_body woken since=2026-10-26T08:00:00Z woken="$(ago 600)")"
  comment 21 402 'github-actions[bot]' "$(qa_body woken since=2026-10-26T09:00:00Z woken="$(ago 7200)")"
  lib 'qa_wake 2'
  run dispatches; expect_out "dispatch qa-plan.yml (default) pr_number=21"
  export MROOM_QA_WAKE_AGAIN=300
  : >"$GH_FAKE/gh.log"
  lib 'qa_wake 2'
  run dispatches; expect_out "dispatch qa-plan.yml (default) pr_number=20"
}

t_drafts_other_comments_and_other_states_wake_nothing() {
  qa_world
  jq -n '[{number: 20, isDraft: true}, {number: 21, isDraft: false}, {number: 22, isDraft: false}, {number: 23, isDraft: false}]' \
    >"$GH_FAKE/prs.json"
  comment 20 401 'github-actions[bot]' "$(qa_body waiting since=2026-10-26T08:00:00Z)"
  comment 21 402 'a-person' "$(qa_body waiting since=2026-10-26T08:00:00Z)"
  comment 22 403 'github-actions[bot]' "$(qa_body ready)"
  comment 23 404 'github-actions[bot]' "$(qa_body waiting since=2026-10-26T08:00:00Z)"
  comment 23 405 'github-actions[bot]' $'## Another check\n<!-- mroom-qa: waiting -->\n'
  comment 23 406 'github-actions[bot]' "$(qa_body idle)"
  lib 'qa_wake 5'
  expect_rc 0; expect_out_has "no pull request waits for a QA environment slot"
  run dispatches; expect_out ""
  lib 'qa_wake 0'; expect_rc 0
  run grep -c . "$GH_FAKE/reads.log"; expect_out 1
}

t_the_cost_is_bounded() {
  qa_world
  prs '[20]'
  lib 'qa_wake 1'
  run cat "$GH_FAKE/reads.log"; expect_out_has "pr list --repo example/shop --state open --limit 100"
}

t_waiting_keeps_its_start_across_rewrites() {
  qa_world
  lib 'qa_names 7 && qa_comment 7 waiting "Waits."'
  run marker_of 7; expect_out "<!-- mroom-qa: waiting since=2026-10-27T12:00:00Z -->"
  export MROOM_NOW=$((NOW + 3600))
  lib 'qa_names 7 && qa_comment 7 waiting "Waits still."'
  run marker_of 7; expect_out "<!-- mroom-qa: waiting since=2026-10-27T12:00:00Z -->"
  lib 'qa_names 7 && qa_comment 7 woken "Woken."'
  run marker_of 7; expect_out "<!-- mroom-qa: woken since=2026-10-27T12:00:00Z woken=2026-10-27T13:00:00Z -->"
  lib 'qa_names 7 && qa_comment 7 ready "Up."'
  run marker_of 7; expect_out "<!-- mroom-qa: ready -->"
  lib 'qa_names 7 && qa_comment 7 waiting "Waits again."'
  run marker_of 7; expect_out "<!-- mroom-qa: waiting since=2026-10-27T13:00:00Z -->"
  run grep -c '^POST' "$GH_FAKE/gh.log"; expect_out 1
}

test_case longest-waiting-first t_the_longest_waiting_goes_first_by_when_it_started_waiting
test_case marked-before-dispatch t_a_woken_pull_request_is_marked_before_its_plan_starts
test_case mark-fails t_one_that_cannot_be_marked_is_left_for_the_next_wake
test_case woken-waits-again t_a_woken_pull_request_waits_again_after_half_an_hour
test_case nothing-to-wake t_drafts_other_comments_and_other_states_wake_nothing
test_case cost-bounded t_the_cost_is_bounded
test_case since-kept t_waiting_keeps_its_start_across_rewrites
finish
