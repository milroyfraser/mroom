#!/usr/bin/env bash
# shellcheck disable=SC2317  # the t_* functions run indirectly, through test_case
# shellcheck disable=SC2119  # pworld's argument is optional
# shellcheck disable=SC2016  # jq programs and Markdown backticks, not the shell's
# Tests for alert triage (actions/triage): one issue per alert key; a second run files nothing new; no write to
# an issue the persona did not file; no assignee; event data redacted before it reaches an issue; the stop when
# the tracker drops the markers, and the switch-off that turns the workflow off; the alarm, once a UTC day; the
# fallback without a tracker; and a dry run. Also `mroom errors new`, which triage reads its window from.
# Offline: the tracker, the error tracker and chat are tests/fakes/persona.py, GitHub tests/fakes/gh, and every
# id, name and token is made up.
set -euo pipefail
SUITE=triage
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
skip_unless has_box_tools "this host lacks bash 5 or GNU tools, which box commands need"
has_jq() { command -v jq >/dev/null 2>&1; }
skip_unless has_jq "this host has no jq"
skip_unless has_tomllib "python3 has no tomllib (needs 3.11+)"
# shellcheck source=tests/persona-world.sh
source "$ROOT/tests/persona-world.sh"

TRIAGE="$ROOT/actions/triage/triage.sh"
ALARM="$ROOT/actions/triage/alarm.sh"
SWITCH_OFF="$ROOT/actions/triage/switch-off.sh"

# triage: one triage run, its tokens handed over as the action hands them.
triage() {
  : >"$T/output"
  rm -f "$T/state/count-"* "$T/state/actions.jsonl"
  run env -u LINEAR_API_KEY -u SENTRY_AUTH_TOKEN \
    MROOM_TRIAGE_TRACKER_TOKEN="$LINEAR_TOKEN" MROOM_TRIAGE_ERRORS_TOKEN="$SENTRY_TOKEN" "$TRIAGE"
}

# a_window: a new error, a regression of an error the persona filed, and one of an error a person filed.
a_window() {
  add_alert new 1001 2026-10-28T11:50:00Z "TypeError: x is undefined"
  add_alert regressed 1002 2026-10-28T11:45:00Z "ValueError: bad total"
  add_alert regressed 1003 2026-10-28T11:40:00Z "KeyError: cart"
  add_event 1001 "x is undefined for pat@example.com, key ghp_abcdefghijklmnopqrstuvwxyz0123, call +1 555 0100 2345"
  add_issue ENG-90 u-persona "Filed by the persona.
<!-- mroom-alert key=sentry:1002 -->"
  add_issue ENG-91 u-person "Filed by a person, who copied the marker.
<!-- mroom-alert key=sentry:1003 -->"
  world_set '.next = 1'
}

t_errors_new_reads_the_three_searches_in_the_window() {
  pworld
  add_alert new 1001 2026-10-28T11:50:00Z
  add_alert new 1009 2026-10-28T10:00:00Z
  add_alert regressed 1002 2026-10-28T11:45:00Z
  add_alert escalating 1004 2026-10-28T11:30:00Z
  run "$MROOM" errors new 40 --environment production
  expect_rc 0
  expect_true "the alerts: $out" json_is "$out" '[.[] | "\(.kind) \(.id) \(.at)"] == ["escalating 1004 2026-10-28T11:30:00Z",
    "regressed 1002 2026-10-28T11:45:00Z", "new 1001 2026-10-28T11:50:00Z"]'
  local paths
  paths="$(ops sentry | jq -r .path)"
  expect_true "the searches: $paths" has "$paths" "query=firstSeen%3A-40m&statsPeriod=24h&limit=25&sort=date&environment=production"
  expect_true "no regressed search" has "$paths" "query=is%3Aregressed%20lastSeen%3A-40m"
  expect_true "no escalating search" has "$paths" "query=is%3Aescalating%20lastSeen%3A-40m"
  run "$MROOM" errors new 0; expect_rc 2
  run "$MROOM" errors new 1441; expect_rc 2
  run "$MROOM" errors new 40 --limit 101; expect_rc 2
  run "$MROOM" errors new 40 --environment 'a b'; expect_rc 2
  toml $'[app]\nname = "shop"'
  run "$MROOM" errors new 40; expect_rc 3
}

t_one_issue_per_alert_key() {
  pworld
  a_window
  triage
  expect_rc 0
  expect_true "expected 3 creates, got $(count_ops linear issueCreate)" [ "$(count_ops linear issueCreate)" = 3 ]
  local all
  all="$(issues)"
  expect_true "not one issue a key: $all" json_is "$all" '
    [.[] | select(.creator == "u-persona" and .identifier != "ENG-90") | [.description | scan("<!-- mroom-alert key=([^ ]+) -->") | .[0]]]
    | sort == [["sentry:1001"], ["sentry:1002:regressed:2026-10-28"], ["sentry:1003:regressed:2026-10-28"]]'
  expect_true "the outputs: $(cat "$T/output")" [ "$(output_of new) $(output_of filed)" = "3 3" ]
  expect_true "the regression does not link the earlier issue" json_is "$all" \
    '[.[] | select(.description | contains("key=sentry:1002:regressed"))][0].description | contains("Earlier alerts of this error: [ENG-90](https://tracker.example.dev/issue/ENG-90)")'
  expect_true "the persona's earlier issue got no comment" json_is "$(issue ENG-90)" '.comments | length == 1 and (.[0].body | startswith("This error is regressed again (2026-10-28): ENG-"))'
  expect_true "the summary lacks the count" grep -q "3 alert(s) in the window: 0 already filed, 3 filed now, 1 comment(s) on earlier issues." "$T/summary.md"
}

t_a_second_run_files_nothing_new() {
  pworld
  a_window
  triage; expect_rc 0
  local before
  before="$(count_ops linear issueCreate) $(count_ops linear commentCreate)"
  triage; expect_rc 0
  expect_true "the second run wrote ($before, then $(count_ops linear issueCreate) $(count_ops linear commentCreate))" \
    [ "$(count_ops linear issueCreate) $(count_ops linear commentCreate)" = "$before" ]
  expect_true "the summary does not say they are filed" grep -q "3 already filed, 0 filed now" "$T/summary.md"
  # A new regression of an error already filed, another day, is a new alert.
  world_set '.sentry.regressed[0].lastSeen = "2026-10-29T11:45:00Z"'
  export MROOM_NOW=$((NOW_EPOCH + 86400))
  triage; expect_rc 0
  expect_true "the next day's regression was not filed" [ "$(count_ops linear issueCreate)" = 4 ]
}

t_no_write_to_an_issue_the_persona_did_not_file() {
  pworld
  a_window
  triage
  expect_rc 0
  expect_true "a person's issue was written to: $(issue ENG-91)" json_is "$(issue ENG-91)" \
    '.comments == [] and .description == "Filed by a person, who copied the marker.\n<!-- mroom-alert key=sentry:1003 -->"'
  expect_true "a comment went to ENG-91" [ "$(ops linear commentCreate | jq -r .vars.i | grep -c uuid-ENG-91 || true)" = 0 ]
  expect_true "no write but create and comment" [ "$(ops linear | jq -r .op | grep -cEv '^(viewer|issue|issues|teams|team|issueLabels|issueCreate|commentCreate)$' || true)" = 0 ]
}

t_no_assignee() {
  pworld
  a_window
  triage
  expect_rc 0
  expect_true "an issue has an assignee" json_is "$(issues)" 'all(.[]; .assignee == null)'
  expect_true "a create sent an assignee" [ "$(ops linear issueCreate | jq -c '.vars.i | keys | map(select(test("assignee|delegate")))' | sort -u)" = "[]" ]
}

t_event_data_is_redacted_before_it_reaches_an_issue() {
  pworld
  a_window
  triage
  expect_rc 0
  local d
  d="$(jq -r '.issues[] | select(.description | contains("key=sentry:1001 -->")) | .description' "$T/world.json")"
  expect_true "the event is not in the issue: $d" has "$d" "TypeError: x is undefined for [redacted], key [redacted token], call [redacted]"
  expect_true "an address reached the issue" lacks "$d" "pat@example.com"
  expect_true "a token reached the issue" lacks "$d" "ghp_abcdefghijklmnopqrstuvwxyz0123"
  expect_true "a phone number reached the issue" lacks "$d" "0100 2345"
  expect_true "the frames are missing" has "$d" "src/cart.ts in total, line 12"
  expect_true "the link is missing" has "$d" "[SHOP-1001](https://example-org.sentry.io/issues/1001/)"
  expect_true "the summary was not redacted" lacks "$(cat "$T/summary.md")" "pat@example.com"
}

t_the_stop_when_markers_are_lost_and_the_switch_off() {
  pworld
  a_window
  world_set '.strip_markers = true'
  triage
  expect_rc 0
  expect_true "triage went on after the markers were lost" [ "$(count_ops linear issueCreate)" = 1 ]
  expect_true "markers_lost: $(cat "$T/output")" [ "$(output_of markers_lost)" = ENG-1 ]
  expect_true "the summary does not say why" grep -q "the tracker did not keep the hidden marker on ENG-1" "$T/summary.md"
  # The workflow's switch-off job.
  export SLACK_BOT_TOKEN="$CHAT_TOKEN"
  run "$SWITCH_OFF" ENG-1
  expect_rc 1
  expect_true "the workflow was not turned off: $(cat "$T/gh/gh.log" 2>/dev/null)" grep -qx "disable alerts.yml --repo example/shop" "$T/gh/gh.log"
  expect_true "no ping" [ "$(count_ops slack)" = 1 ]
  expect_true "the ping: $(ops slack)" json_is "$(ops slack)" '.body.channel == "C0123456789"
    and (.body.text | startswith("Bot One: alert triage switched itself off: the tracker did not keep the hidden markers on ENG-1"))
    and (.body.text | contains("<https://github.com/example/shop/actions/runs/777|Run>"))'
  touch "$T/gh/disable-fails"
  run "$SWITCH_OFF" ENG-1
  expect_rc 1
  expect_true "the second ping does not ask for a hand" json_is "$(ops slack | tail -n1)" '.body.text | contains("could NOT switch itself off")'
  run "$SWITCH_OFF" 'ENG-1; rm'; expect_rc 2
}

# alarm: one alarm run, its token handed over as the action hands it.
alarm() { run env -u LINEAR_API_KEY MROOM_TRIAGE_TRACKER_TOKEN="$LINEAR_TOKEN" "$ALARM"; }

jobs_with_a_failed_step() {
  jq -n '{jobs: [{name: "alerts / Alert triage", steps: [{name: "Check out mroom", conclusion: "success"},
    {name: "Run ./mroom/actions/triage", conclusion: "failure"}]}]}' >"$T/gh/jobs-777.json"
}

t_the_alarm_pings_once_a_utc_day() {
  pworld
  jobs_with_a_failed_step
  export SLACK_BOT_TOKEN="$CHAT_TOKEN"
  alarm
  expect_rc 0
  expect_true "expected one ping, got $(count_ops slack)" [ "$(count_ops slack)" = 1 ]
  expect_true "the ping: $(ops slack)" json_is "$(ops slack)" '.body.text | startswith("Bot One: alert triage could not run: the triage job failed at \"Run ./mroom/actions/triage\".")'
  expect_true "the ping does not link the day's issue" json_is "$(ops slack)" '.body.text | contains("<https://tracker.example.dev/issue/ENG-1|ENG-1>") and endswith("Who can look before the next run?")'
  expect_true "the day's issue lacks its key" json_is "$(issue ENG-1)" '.description | contains("<!-- mroom-alert key=triage:20261028 -->")'
  expect_true "the chat token was not the bot's" json_is "$(ops slack)" ".auth == \"Bearer $CHAT_TOKEN\""
  alarm
  expect_rc 0; expect_out_has "already pinged today (ENG-1)"
  expect_true "a second ping the same day" [ "$(count_ops slack) $(count_ops linear issueCreate)" = "1 1" ]
  export MROOM_NOW=$((NOW_EPOCH + 86400))
  alarm
  expect_rc 0
  expect_true "no ping the next day" [ "$(count_ops slack) $(count_ops linear issueCreate)" = "2 2" ]
}

t_the_alarm_sends_nothing_it_cannot_record() {
  pworld
  jobs_with_a_failed_step
  export SLACK_BOT_TOKEN="$CHAT_TOKEN"
  world_set '.down = ["linear"]'
  alarm
  expect_rc 1; expect_err_has "does not ping"
  expect_true "a ping with no record" [ "$(count_ops slack)" = 0 ]
  world_set '.down = [] | .slack_error = "channel_not_found"'
  alarm
  expect_rc 1; expect_err_has "Slack refused the message: channel_not_found"
  world_set 'del(.slack_error)'
  alarm
  expect_rc 0; expect_out_has "already pinged today"
  expect_true "a refused ping was sent again" [ "$(count_ops slack)" = 1 ]
}

t_without_a_tracker_nothing_is_filed() {
  pworld
  add_alert new 1001 2026-10-28T11:50:00Z "TypeError: for pat@example.com"
  toml $'[app]\nname = "shop"\n\n[issues]\ntracker = "none"\n\n[errors]\nprovider = "sentry"\norg = "example-org"\n\n[persona]\nchannel = "C0123456789"'
  triage
  expect_rc 0
  expect_true "the tracker was called" [ "$(count_ops linear)" = 0 ]
  expect_true "the summary does not list the alert: $(cat "$T/summary.md")" grep -q '^- `sentry:1001`: SHOP-1001 (new) TypeError: for \[redacted\]' "$T/summary.md"
  expect_true "the summary does not say why" grep -q 'issues.tracker = "none", so nothing was filed' "$T/summary.md"
  jobs_with_a_failed_step
  export SLACK_BOT_TOKEN="$CHAT_TOKEN"
  run "$ALARM"
  expect_rc 0; expect_err_has "cannot record that it pinged today, and does not ping"
  expect_true "the alarm pinged with nowhere to record it" [ "$(count_ops slack)" = 0 ]
  toml $'[app]\nname = "shop"\n\n[issues]\ntracker = "none"'
  : >"$T/calls.jsonl"
  triage
  expect_rc 0
  expect_true "no error tracker, but it searched" [ "$(count_ops sentry)" = 0 ]
  expect_true "the summary does not say there is nothing to triage" grep -q "no error tracker" "$T/summary.md"
}

t_a_dry_run_files_nothing() {
  pworld
  a_window
  export MROOM_PERSONA_LIVE=""
  triage
  expect_rc 0
  expect_true "a dry run wrote" [ "$(count_ops linear issueCreate) $(count_ops linear commentCreate)" = "0 0" ]
  expect_true "the summary lacks the dry runs" grep -q "dry-run (dry run): create DRY-1 for sentry:" "$T/summary.md"
  expect_true "a dry run says it is live" grep -q "Live: no." "$T/summary.md"
}

t_a_tracker_that_cannot_be_read_fails_the_run() {
  pworld
  a_window
  world_set '.down = ["linear"]'
  triage
  expect_rc 1
  expect_true "the summary does not say why" grep -q "the tracker could not be searched for sentry:1002, so triage stopped" "$T/summary.md"
  world_set '.down = ["sentry"]'
  triage
  expect_rc 1
  expect_true "the summary does not say the error tracker failed" grep -q "the error tracker could not be read" "$T/summary.md"
}

test_case errors-new t_errors_new_reads_the_three_searches_in_the_window
test_case one-issue-per-key t_one_issue_per_alert_key
test_case second-run t_a_second_run_files_nothing_new
test_case not-the-personas t_no_write_to_an_issue_the_persona_did_not_file
test_case no-assignee t_no_assignee
test_case redacted t_event_data_is_redacted_before_it_reaches_an_issue
test_case markers-lost t_the_stop_when_markers_are_lost_and_the_switch_off
test_case alarm-once-a-day t_the_alarm_pings_once_a_utc_day
test_case alarm-records-first t_the_alarm_sends_nothing_it_cannot_record
test_case no-tracker t_without_a_tracker_nothing_is_filed
test_case dry-run t_a_dry_run_files_nothing
test_case tracker-down t_a_tracker_that_cannot_be_read_fails_the_run
finish
