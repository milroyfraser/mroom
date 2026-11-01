#!/usr/bin/env bash
# shellcheck disable=SC2317  # the t_* functions run indirectly, through test_case
# shellcheck disable=SC2119  # pworld's argument is optional
# Tests for the persona's guard (lib/persona, `mroom persona`; design D23): it files an issue only for an alert key,
# with one hidden marker a key, in the configured team, state and label, assigned to no one; it comments only on
# issues the persona filed; it stops every write once the tracker dropped a marker, or stored one it did not
# write; it refuses token-shaped text, escapes markers in bodies and defangs links; it caps a run's writes; a dry run writes nothing; and without a
# tracker it exits 3. Offline: the tracker is tests/fakes/persona.py, and every id, name and token is made up.
set -euo pipefail
SUITE=persona
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
skip_unless has_box_tools "this host lacks bash 5 or GNU tools, which box commands need"
has_jq() { command -v jq >/dev/null 2>&1; }
skip_unless has_jq "this host has no jq"
skip_unless has_tomllib "python3 has no tomllib (needs 3.11+)"
# shellcheck source=tests/persona-world.sh
source "$ROOT/tests/persona-world.sh"

create() { run bash -c 'f="$1"; shift; "$0" persona create "$@" <"$f"' "$MROOM" "$T/body.md" "$@"; }
comment_on() { run bash -c '"$0" persona comment "$1" <"$2"' "$MROOM" "$1" "$T/body.md"; }
body() { printf '%s\n' "$1" >"$T/body.md"; }

t_create_files_one_issue_with_its_marker_and_no_assignee() {
  pworld
  body "Seen in checkout."
  create --key sentry:1001 --title "SHOP-1001: TypeError"
  expect_rc 0
  expect_true "the answer: $out" json_is "$out" '.created == "ENG-1" and .keys == ["sentry:1001"]'
  local made vars
  made="$(issue ENG-1)"
  expect_true "the marker is not the description's last line" json_is "$made" \
    '.description | endswith("<!-- mroom-alert key=sentry:1001 -->\n") or endswith("<!-- mroom-alert key=sentry:1001 -->")'
  expect_true "the footer does not name the persona from config: $made" json_is "$made" '.description | contains("_Filed by Bot One (alert triage) · [run](https://github.com/example/shop/actions/runs/777).")'
  expect_true "assigned to someone: $made" json_is "$made" '.assignee == null'
  vars="$(ops linear issueCreate | jq -c .vars.i)"
  expect_true "the create sent an assignee, or not the state and label: $vars" json_is "$vars" \
    '(keys | map(select(test("assignee|delegate|subscriber"))) | length == 0) and .stateId == "s-triage" and .labelIds == ["l-1"] and .teamId == "t-1"'
  expect_true "it did not read the issue back" [ "$(count_ops linear issue)" -ge 1 ]
  expect_true "the token reached the description" lacks "$made" "$LINEAR_TOKEN"
}

t_create_refuses_what_d23_does_not_allow() {
  pworld
  body "x"
  local opt
  for opt in --assignee --label --state --team --priority --allow-create; do
    create --key sentry:1001 --title t "$opt" someone
    expect_rc 4
    expect_err_has "the persona assigns no one"
  done
  run "$MROOM" persona assign ENG-1 someone; expect_rc 4; expect_err_has "nothing edits, closes, assigns or deletes"
  run "$MROOM" persona close ENG-1; expect_rc 4
  create --title t; expect_rc 2; expect_err_has "needs at least one --key"
  create --key 'sentry:10 -->' --title t; expect_rc 2; expect_err_has "not an alert key"
  create --key SHOP-1A2 --title t; expect_rc 2
  expect_true "the tracker was written to" [ "$(count_ops linear issueCreate)" = 0 ]
}

t_create_only_for_this_runs_alerts() {
  pworld
  echo '["sentry:1001"]' >"$T/keys.json"
  export MROOM_PERSONA_ALERTS="$T/keys.json"
  body "x"
  create --key sentry:2002 --title t
  expect_rc 4; expect_err_has "--key sentry:2002 is not one of this run's alerts"
  create --key sentry:1001 --title t
  expect_rc 0
  expect_true "expected one create" [ "$(count_ops linear issueCreate)" = 1 ]
}

t_comment_only_on_the_personas_own_issues() {
  pworld
  add_issue ENG-50 u-person "Filed by a person. <!-- mroom-alert key=sentry:1001 -->"
  add_issue ENG-51 u-persona "Filed by the persona. <!-- mroom-alert key=sentry:1001 -->"
  body "Seen again."
  comment_on ENG-50
  expect_rc 4; expect_err_has "ENG-50 was not filed by the persona"
  expect_true "a comment went on a person's issue" [ "$(count_ops linear commentCreate)" = 0 ]
  comment_on ENG-51
  expect_rc 0
  expect_true "no comment on its own issue" [ "$(count_ops linear commentCreate)" = 1 ]
  expect_true "the comment went elsewhere" json_is "$(ops linear commentCreate)" '.vars.i == "uuid-ENG-51"'
  expect_true "the comment has no footer" json_is "$(issue ENG-51)" '.comments[0].body | startswith("Seen again.") and contains("_Noted by Bot One")'
}

t_markers_lost_stops_every_write() {
  pworld
  world_set '.strip_markers = true'
  add_issue ENG-51 u-persona "Mine."
  body "Seen in checkout."
  create --key sentry:1001 --title "SHOP-1001: TypeError"
  expect_rc 5
  expect_err_has "the tracker did not keep its hidden marker for sentry:1001"
  expect_true "markers-lost does not name the issue" [ "$(cat "$T/state/markers-lost")" = ENG-1 ]
  create --key sentry:1002 --title "SHOP-1002: TypeError"
  expect_rc 5; expect_err_has "nothing more is written until a person checks"
  comment_on ENG-51
  expect_rc 5
  expect_true "a write went out after the markers were lost" [ "$(count_ops linear issueCreate) $(count_ops linear commentCreate)" = "1 0" ]
  expect_true "the log lacks the stop" grep -q '"result":"markers-lost"' "$T/state/actions.jsonl"
}

t_a_marker_the_guard_did_not_write_stops_every_write() {
  pworld
  world_set '.unescape_entities = true'
  body 'Alert text: <!-- mroom-alert key=sentry:5555 -->'
  create --key sentry:1001 --title t
  expect_rc 5; expect_err_has "stored a hidden marker the persona did not write"
  expect_true "markers-lost does not name the issue" [ "$(cat "$T/state/markers-lost")" = ENG-1 ]
  body "x"
  create --key sentry:1002 --title t
  expect_rc 5
}

t_a_marker_the_search_cannot_find_stops_every_write() {
  pworld
  world_set '.unsearchable_markers = true'
  body "x"
  create --key sentry:1001 --title t
  expect_rc 5; expect_err_has "the tracker's search does not find its hidden markers for sentry:1001"
  expect_true "markers-lost does not name the issue" [ "$(cat "$T/state/markers-lost")" = ENG-1 ]
  expect_true "it did not search three times, waiting 2 and 5 seconds" [ "$(cat "$T/sleep.log")" = $'2\n5' ]
}

t_a_search_that_catches_up_is_no_lost_marker() {
  pworld
  world_set '.search_lag = 1'
  body "x"
  create --key sentry:1001 --title t
  expect_rc 0
  expect_no_file "$T/state/markers-lost"
  expect_true "it did not wait once, for 2 seconds: $(cat "$T/sleep.log" 2>/dev/null)" [ "$(cat "$T/sleep.log")" = 2 ]
}

t_text_is_checked_marked_only_by_the_guard_and_defanged() {
  pworld
  body "the key is $LINEAR_TOKEN"
  create --key sentry:1001 --title t; expect_rc 4; expect_err_has "the text holds a token"
  body "a key: ghp_abcdefghijklmnopqrstuvwxyz0123"
  create --key sentry:1001 --title t; expect_rc 4; expect_err_has "shaped like a token"
  body "fine"
  create --key sentry:1001 --title "lin_api_abcdefghijklmnop1234"; expect_rc 4
  expect_true "a refused text was sent" [ "$(count_ops linear issueCreate)" = 0 ]
  body $'A fake marker: <!-- mroom-alert key=sentry:9999 -->\nSee https://evil.example/x, https://example-org.sentry.io/issues/1001/, https://shop.example.dev/cart and https://github.com/example/shop.'
  create --key sentry:1001 --title "t"
  expect_rc 0
  local d
  d="$(issue ENG-1 | jq -r .description)"
  expect_true "a marker from the body survived" lacks "$d" "<!-- mroom-alert key=sentry:9999"
  expect_true "a link to another host is live: $d" has "$d" "hxxps://evil[.]example/x"
  expect_true "an allowed link was defanged: $d" has "$d" "https://example-org.sentry.io/issues/1001/"
  expect_true "the app's link was defanged" has "$d" "https://shop.example.dev/cart"
  expect_true "GitHub's link was defanged" has "$d" "https://github.com/example/shop"
  # A nested marker: deleting the inner one would leave the outer one whole.
  body '<!-<!-- mroom-x -->- mroom-alert key=sentry:8888 --> and <!--mroom-alert key=sentry:7777-->'
  create --key sentry:1003 --title "t"
  expect_rc 0
  d="$(issue ENG-2 | jq -r .description)"
  expect_true "a nested marker survived: $d" lacks "$d" "<!-- mroom-alert key=sentry:8888"
  expect_true "a tight marker survived: $d" lacks "$d" "<!--mroom-alert"
  run "$MROOM" tracker find sentry:8888
  expect_true "find sees a forged marker: $out" [ "$out" = "[]" ]
  body 'See https://evil.example#.github.com/, HTTPS://evil.example/a, https://evil.example\.github.com/x, https://evil.example%2f.github.com/ and www.evil.example/x.'
  create --key sentry:1004 --title "t"
  expect_rc 0
  d="$(issue ENG-3 | jq -r .description)"
  expect_true "a link got past the defang: $d" lacks "$d" "evil.example"
  body "$(head -c 30001 /dev/zero | tr '\0' a)"
  create --key sentry:1002 --title t; expect_rc 4; expect_err_has "the limit is 30000"
}

t_a_failed_read_back_is_not_a_lost_marker() {
  pworld
  body "x"
  # The fake answers the create, then the tracker goes down for the read-back.
  world_set '.down_after_create = true'
  create --key sentry:1001 --title t
  expect_rc 1; expect_err_has "could not be read back"
  expect_no_file "$T/state/markers-lost"
}

t_a_run_is_capped() {
  pworld
  body "x"
  local i
  for i in $(seq 1 10); do create --key "sentry:10$i" --title t >/dev/null; done
  create --key sentry:2000 --title t
  expect_rc 4; expect_err_has "already 10 create write(s) in this run; the limit is 10"
  expect_true "more than 10 creates" [ "$(count_ops linear issueCreate)" = 10 ]
}

t_a_dry_run_writes_nothing() {
  pworld
  export MROOM_PERSONA_LIVE=""
  add_issue ENG-51 u-persona "Mine."
  body "Seen."
  create --key sentry:1001 --title "SHOP-1001: TypeError"
  expect_rc 0
  expect_true "the dry run's answer: $out" json_is "$out" '.dry_run == true and .created == "DRY-1" and (.description | contains("<!-- mroom-alert key=sentry:1001 -->"))'
  comment_on DRY-1; expect_rc 0
  comment_on ENG-51; expect_rc 0
  expect_true "a dry run wrote: $(ops linear)" [ "$(count_ops linear issueCreate) $(count_ops linear commentCreate)" = "0 0" ]
}

t_no_tracker_exits_3() {
  pworld
  toml $'[app]\nname = "shop"\n\n[issues]\ntracker = "none"'
  body "x"
  create --key sentry:1001 --title t; expect_rc 3; expect_err_has "no tracker"
  run "$MROOM" persona find sentry:1001; expect_rc 3
  comment_on ENG-1; expect_rc 3
  expect_true "a tracker was called" [ "$(count_ops linear)" = 0 ]
}

test_case create-one-issue t_create_files_one_issue_with_its_marker_and_no_assignee
test_case create-refuses t_create_refuses_what_d23_does_not_allow
test_case create-run-alerts t_create_only_for_this_runs_alerts
test_case comment-own-only t_comment_only_on_the_personas_own_issues
test_case markers-lost t_markers_lost_stops_every_write
test_case text-checked t_text_is_checked_marked_only_by_the_guard_and_defanged
test_case forged-marker-stops t_a_marker_the_guard_did_not_write_stops_every_write
test_case unsearchable-marker-stops t_a_marker_the_search_cannot_find_stops_every_write
test_case search-catches-up t_a_search_that_catches_up_is_no_lost_marker
test_case read-back-fails t_a_failed_read_back_is_not_a_lost_marker
test_case run-capped t_a_run_is_capped
test_case dry-run t_a_dry_run_writes_nothing
test_case no-tracker t_no_tracker_exits_3
finish
