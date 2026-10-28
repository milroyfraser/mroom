#!/usr/bin/env bash
# shellcheck disable=SC2317  # the t_* functions run indirectly, through test_case
# Tests for whether a qa-up run brings the environment up (actions/qa-up/start.sh): GitHub is read first, so a pull
# request that closed or moved on gets nothing; then Forge; the label and the draft state as they are now; a plan a
# person started is a yes, one a freed slot started decides as a push does; a failed build, broadcast = "same" and a
# pull request whose mroom.toml puts the frontend elsewhere say why in the comment, and keep the job green; a
# pull request that waited and no longer needs an environment stops waiting. Offline: Forge and GitHub are fakes.
set -euo pipefail
SUITE=qa-start
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/qa-world.sh
source "$(dirname "${BASH_SOURCE[0]}")/qa-world.sh"
skip_unless has_box_tools "this host lacks bash 5, flock or GNU date, which the QA actions need"
skip_unless has_tomllib "python3 has no tomllib (needs 3.11+)"

START="$ROOT/actions/qa-up/start.sh"
SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
NEWER=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
TOML='[app]
name = "shop"
backend_dir = "api"
frontend_dir = "web"

[app.build]
frontend = "npm run build"

[qa]
zone = "qa.example.dev"

[qa.parity]
broadcast = "log"'

# world: pull request 7 open at $SHA, its mroom.toml the default branch's, and a status file for the comment.
world() {
  qa_world
  printf '%s\n' "$TOML" >"$MROOM_CONFIG"
  pr_now 7 OPEN "$SHA"
  pr_toml "$SHA"
  export PR=7 SHA REASON="1 of 1 paths could reach the app: 1 frontend" MROOM_QA_STATUS="$T/status"
  : >"$T/status"
}
# start [VAR=value...]: start.sh's start and why, as "start|why".
start() {
  run env "$@" "$START"
  out="$(sed -n 's/^\(start\|why\)=//p' <<<"$out" | paste -sd'|' -)"
}
status() { cat "$T/status"; }

t_what_decides_whether_it_comes_up() {
  world
  start SCOPE=maybe BUILT=true; expect_out "true|a user could notice it: 1 of 1 paths could reach the app: 1 frontend"
  start SCOPE=none BUILT=true REASON="only paths no user can see changed: 2 docs"
  expect_out "false|no user could notice it: only paths no user can see changed: 2 docs"
  start SCOPE=none BUILT=true DISPATCHED=true; expect_out "true|started by hand"
  pr_now 7 OPEN "$SHA" true
  start SCOPE=maybe BUILT=true; expect_out "false|a draft, which gets an environment once it is ready for review"
  start SCOPE=none BUILT=true DISPATCHED=true; expect_out "true|a draft started by hand"
  pr_now 7 OPEN "$SHA" true '["qa"]'
  start SCOPE=none BUILT=true; expect_out "true|the qa label forces it on"
  pr_now 7 OPEN "$SHA" true
  site 1 "$(api_host 7)" installed
  start SCOPE=none BUILT=true; expect_out "true|a draft whose environment is refreshed, so it serves the head"
  pr_now 7 OPEN "$SHA"
  start SCOPE=none BUILT=true; expect_out "true|its environment is refreshed, so it serves the head"
  run env SCOPE=maybe BUILT=true "$START"; expect_out_has $'exists=true\ndist=true'
  run status; expect_out ""
}

t_github_is_read_first_and_a_newer_head_wins() {
  world
  site 1 "$(api_host 7)" installed
  # The pull request moved on while this run waited its turn: that push's own run deploys it.
  pr_now 7 OPEN "$NEWER"
  start SCOPE=maybe BUILT=true; expect_out "false|the pull request has moved on from aaaaaaaaa to bbbbbbbbb; that push's own run deploys it"
  expect_no_file "$FORGE_LOG"
  # A deploy that waited behind a teardown brings no closed pull request's environment back.
  pr_now 7 CLOSED "$SHA"
  start SCOPE=maybe BUILT=true; expect_out "false|the pull request is no longer open"
  expect_no_file "$FORGE_LOG"
  # GitHub that cannot be read fails the step; Forge, the same.
  : >"$GH_FAKE/down"
  run env SCOPE=maybe BUILT=true "$START"; expect_rc 1; expect_err_has "could not read pull request 7 from GitHub"
  rm "$GH_FAKE/down"
  pr_now 7 OPEN "$SHA"
  forge_set '.fail["GET /sites"] = 500'
  run env SCOPE=maybe BUILT=true "$START"; expect_rc 1
}

t_a_woken_plan_decides_as_a_push_does() {
  world
  # Its label came off, and its change reaches no user: no environment, and it no longer waits.
  comment 7 301 'github-actions[bot]' "$(qa_body woken since=2026-10-26T08:00:00Z woken=2026-10-27T11:00:00Z)"
  start SCOPE=none BUILT=true DISPATCHED=true WOKEN=true REASON="only paths no user can see changed: 2 docs"
  expect_out "false|no user could notice it: only paths no user can see changed: 2 docs"
  run status
  expect_out $'idle\nNo longer waiting for a QA environment: no user could notice this change (only paths no user can see changed: 2 docs). A push that needs one, or the qa label, brings it back.'
  # With the label, or a change users could notice, it comes up.
  pr_now 7 OPEN "$SHA" false '["qa"]'
  start SCOPE=none BUILT=true DISPATCHED=true WOKEN=true; expect_out "true|the qa label forces it on"
  pr_now 7 OPEN "$SHA"
  start SCOPE=maybe BUILT=true DISPATCHED=true WOKEN=true; expect_out_has "true|a user could notice it"
  # A pull request that never waited keeps its comment as it is.
  : >"$T/status"
  comment 7 302 'github-actions[bot]' "$(qa_body removed)"
  start SCOPE=none BUILT=true
  run status; expect_out ""
}

t_a_failed_build_says_so_and_deploys_nothing() {
  world
  start SCOPE=maybe BUILT=false PLAN_RUN_URL=https://github.example/runs/1
  expect_out "false|the QA build failed, so there is nothing to deploy"
  run status
  expect_out $'failed\nThe QA build of `'"$SHA"'` failed, so nothing was deployed ([run](https://github.example/runs/1)). The next push tries again.'
}

t_broadcast_same_is_skipped_with_a_comment() {
  world
  printf '%s\n' "${TOML/broadcast = \"log\"/broadcast = \"same\"}" >"$MROOM_CONFIG"
  pr_toml "$SHA"
  start SCOPE=maybe BUILT=true; expect_rc 0
  expect_out 'false|qa.parity.broadcast is "same", which qa-up does not wire in yet'
  run status
  expect_out_has $'skipped\nNo QA environment yet: this app\'s mroom.toml sets qa.parity.broadcast = "same", which needs mroom\'s Reverb host. The host exists, but qa-up does not wire environments into it yet.'
  # A change no user could notice gets no comment about it.
  : >"$T/status"
  start SCOPE=none BUILT=true
  run status; expect_out ""
  # It defaults to same.
  printf '[app]\nname = "shop"\n\n[qa]\nzone = "qa.example.dev"\n' >"$MROOM_CONFIG"
  start SCOPE=maybe BUILT=true; expect_out_has 'false|qa.parity.broadcast is "same"'
}

t_a_pull_request_that_moves_the_frontend_is_skipped() {
  world
  local key
  for key in 'frontend_dir = "web"/frontend_dir = "client"' 'backend_dir = "api"/backend_dir = "server"' \
    'frontend = "npm run build"/frontend = ""'; do
    : >"$T/status"
    pr_toml "$SHA" "${TOML/${key%%/*}/${key#*/}}"
    start SCOPE=maybe BUILT=true
    expect_out "false|the pull request's mroom.toml puts the frontend elsewhere than the default branch's"
    run status; expect_out_has $'skipped\nNo QA environment for `'"$SHA"'`: this pull request changes where mroom.toml says the frontend is built'
  done
  # frontend_dist too, and any other change of mroom.toml is the pull request's own business.
  pr_toml "$SHA" "${TOML/frontend = \"npm run build\"/frontend = \"npm run build\"
frontend_dist = \"out\"}"
  start SCOPE=maybe BUILT=true; expect_out_has "false|the pull request's mroom.toml puts the frontend elsewhere"
  pr_toml "$SHA" "$TOML"$'\nttl_days = 2'
  start SCOPE=maybe BUILT=true; expect_out_has "true|"
  # One GitHub cannot give fails the step, and one that does not parse is no match.
  rm "$GH_FAKE/contents-$SHA/mroom.toml"
  run env SCOPE=maybe BUILT=true "$START"; expect_rc 1; expect_err_has "could not read the pull request's mroom.toml from GitHub"
  pr_toml "$SHA" 'broken = ['
  start SCOPE=maybe BUILT=true; expect_out_has "false|the pull request's mroom.toml puts the frontend elsewhere"
}

t_usage() {
  world
  run env PR=07 "$START"; expect_rc 2
  run env SHA=abc "$START"; expect_rc 2
  expect_no_file "$FORGE_LOG"
}

test_case decisions t_what_decides_whether_it_comes_up
test_case github-first t_github_is_read_first_and_a_newer_head_wins
test_case woken-like-a-push t_a_woken_plan_decides_as_a_push_does
test_case build-failed t_a_failed_build_says_so_and_deploys_nothing
test_case broadcast-same t_broadcast_same_is_skipped_with_a_comment
test_case frontend-moved t_a_pull_request_that_moves_the_frontend_is_skipped
test_case usage t_usage
finish
