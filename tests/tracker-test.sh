#!/usr/bin/env bash
# shellcheck disable=SC2317  # the t_* functions run indirectly, through test_case
# shellcheck disable=SC2016  # GraphQL variables and the fake sleep's $1 are not this shell's
# Tests for the tracker adapter (lib/core/tracker.sh, lib/core/api.sh, `mroom tracker`): each operation's
# request and how it reads the answer, pagination, retries, the token kept off every command line and out
# of every message, create refusing without --allow-create, and the backend picked from mroom.toml.
# Offline: curl is tests/fakes/api-curl, sleep only records how long it was asked for, and every id, name and
# token is made up.
set -euo pipefail
SUITE=tracker
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
skip_unless has_box_tools "this host lacks bash 5 or GNU tools, which box commands need"
has_jq() { command -v jq >/dev/null 2>&1; }
skip_unless has_jq "this host has no jq"
skip_unless has_tomllib "python3 has no tomllib (needs 3.11+)"

URL="https://api.linear.app/graphql"
TOKEN="lin_api_fakeTOKEN0123456789abcdef"

# world [<issues table lines>]: the fake curl and sleep, a TMPDIR of the test's own, the token, and a
# mroom.toml with a Linear tracker (or the given [issues] lines).
world() {
  mkdir -p "$T/bin" "$T/tmp" "$T/api"
  cp "$ROOT/tests/fakes/api-curl" "$T/bin/curl"
  printf '#!/bin/sh\necho "$1" >>"%s/api/sleep.log"\n' "$T" >"$T/bin/sleep"
  chmod +x "$T/bin/curl" "$T/bin/sleep"
  export API_FAKE="$T/api" PATH="$T/bin:$PATH" TMPDIR="$T/tmp" LINEAR_API_KEY="$TOKEN" MROOM_API_RATE_SLEEP=5
  local table=$'tracker = "linear"\nid_pattern = "ENG-[0-9]+"\nteam = "ENG"'
  [ -z "${1:-}" ] || table="$1"
  printf '[app]\nname = "shop"\n\n[issues]\n%s\n' "$table" >"$T/mroom.toml"
  export MROOM_CONFIG="$T/mroom.toml"
}

# answer <code> <body> [<response header line>]: the next answer the fake curl gives.
answer() {
  local n=1 f
  if [ -f "$T/api/answers" ]; then n=$(($(wc -l <"$T/api/answers") + 1)); fi
  f="answer$n"
  printf '%s' "$2" >"$T/api/$f"
  [ -z "${3:-}" ] || printf '%s\r\n' "$3" >"$T/api/$f.headers"
  echo "$1 $f" >>"$T/api/answers"
}

calls() { find "$T/api" -name 'call.*' | wc -l | tr -d ' '; }
# call_line <n> <line>: line 1 (method), 2 (URL) or 3 (auth=...) of call n.
call_line() { sed -n "${2}p" "$T/api/call.$1"; }
# query <n> / vars <n>: the GraphQL query and variables call n sent.
query() { sed -n 's/^body=//p' "$T/api/call.$1" | jq -r .query; }
vars() { sed -n 's/^body=//p' "$T/api/call.$1" | jq -c .variables; }
lacks() { case "$1" in *"$2"*) return 1 ;; esac; }
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
tmp_empty() { [ -z "$(find "$T/tmp" -mindepth 1 -print -quit)" ]; }
json_is() { jq -e "$2" <<<"$1" >/dev/null 2>&1; }
token_nowhere() {
  lacks "$out$err" "$TOKEN" && lacks "$(cat "$T/api/argv" 2>/dev/null)" "$TOKEN"
}

ISSUE='{"data":{"issue":{"id":"uuid-issue-1","identifier":"ENG-12","title":"Checkout fails","description":"It breaks.","url":"https://tracker.example.dev/issue/ENG-12","priority":2,"priorityLabel":"High","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-02T00:00:00Z","state":{"id":"uuid-state-todo","name":"Todo","type":"unstarted"},"team":{"id":"uuid-team-1","key":"ENG"},"creator":{"name":"Sam Example"},"assignee":null,"labels":{"nodes":[{"name":"bug"}]}}}}'
STATES_1='{"data":{"team":{"states":{"nodes":[{"id":"uuid-state-todo","name":"Todo","type":"unstarted"},{"id":"uuid-state-prog","name":"In Progress","type":"started"}],"pageInfo":{"hasNextPage":true,"endCursor":"cursor-states-2"}}}}}'
STATES_2='{"data":{"team":{"states":{"nodes":[{"id":"uuid-state-review","name":"In Review","type":"started"}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}'

t_get_reads_the_issue_and_every_page_of_comments() {
  world
  answer 200 "$ISSUE"
  answer 200 '{"data":{"issue":{"comments":{"nodes":[{"body":"first","createdAt":"2026-01-01T01:00:00Z","user":{"name":"Sam Example"}}],"pageInfo":{"hasNextPage":true,"endCursor":"cursor-c-2"}}}}}'
  answer 200 '{"data":{"issue":{"comments":{"nodes":[{"body":"second","createdAt":"2026-01-01T02:00:00Z","user":null}],"pageInfo":{"hasNextPage":false,"endCursor":"cursor-c-3"}}}}}'
  run "$MROOM" tracker get ENG-12
  expect_rc 0; expect_err_empty
  expect_true "expected 3 calls, got $(calls)" [ "$(calls)" = 3 ]
  expect_true "call 1 is not a POST to Linear" [ "$(call_line 1 1) $(call_line 1 2)" = "POST $URL" ]
  expect_true "an API key is not sent as it is" [ "$(call_line 1 3)" = "auth=$TOKEN" ]
  expect_true "call 1 does not ask for the issue" has "$(query 1)" 'issue(id: $id)'
  expect_true "call 1 variables" [ "$(vars 1)" = '{"id":"ENG-12"}' ]
  expect_true "call 2 does not ask for comments" has "$(query 2)" 'comments(first: 50, after: $after)'
  expect_true "the first comments page sent a cursor" [ "$(vars 2)" = '{"id":"ENG-12"}' ]
  expect_true "the second comments page lost the cursor" [ "$(vars 3)" = '{"id":"ENG-12","after":"cursor-c-2"}' ]
  expect_true "the issue was not read right" json_is "$out" '.identifier == "ENG-12" and .title == "Checkout fails"
    and .state == "Todo" and .state_type == "unstarted" and .team == "ENG" and .priority == 2 and .labels == ["bug"]
    and .description == "It breaks." and .assignee == null and .creator == "Sam Example"'
  expect_true "the comments were not read right" json_is "$out" '.comments == [
    {by: "Sam Example", at: "2026-01-01T01:00:00Z", body: "first"},
    {by: "an integration", at: "2026-01-01T02:00:00Z", body: "second"}]'
  expect_true "the token leaked" token_nowhere
  expect_true "a file was left in TMPDIR" tmp_empty
}

t_an_oauth_token_goes_as_a_bearer_token() {
  world; export LINEAR_API_KEY="oauth-fake-token-42"
  answer 200 "$ISSUE"; answer 200 '{"data":{"issue":{"comments":{"nodes":[],"pageInfo":{"hasNextPage":false}}}}}'
  run "$MROOM" tracker get ENG-12
  expect_rc 0
  expect_true "an OAuth token was not sent as a Bearer token" [ "$(call_line 1 3)" = "auth=Bearer oauth-fake-token-42" ]
}

t_a_page_with_no_list_fails_rather_than_reading_short() {
  world
  answer 200 "$ISSUE"; answer 200 '{"data":{"issue":{"comments":null}}}'
  run "$MROOM" tracker get ENG-12
  expect_rc 1; expect_out ""; expect_err_has "the answer holds no list at .data.issue.comments"
  reset; world
  answer 200 "$ISSUE"; answer 200 '{"data":{"issue":{"comments":{"nodes":[],"pageInfo":{"hasNextPage":true,"endCursor":null}}}}}'
  run "$MROOM" tracker get ENG-12
  expect_rc 1; expect_err_has "a next page with no cursor"
}

t_comment_sends_the_body_from_stdin() {
  world
  answer 200 "$ISSUE"
  answer 200 '{"data":{"commentCreate":{"success":true,"comment":{"url":"https://tracker.example.dev/issue/ENG-12#c1"}}}}'
  printf 'Fixed in the PR.\nSecond "line".\n' >"$T/note.md"
  run bash -c '"$0" tracker comment ENG-12 <"$1"' "$MROOM" "$T/note.md"
  expect_rc 0; expect_err_empty
  expect_true "the comment was not a commentCreate" has "$(query 2)" 'commentCreate(input: {issueId: $i, body: $b})'
  expect_true "the comment's variables" [ "$(vars 2)" = '{"i":"uuid-issue-1","b":"Fixed in the PR.\nSecond \"line\"."}' ]
  expect_true "the answer" json_is "$out" '. == {commented: "ENG-12", url: "https://tracker.example.dev/issue/ENG-12#c1"}'
}

t_comment_refuses_an_empty_body_or_one_with_the_token() {
  world; answer 200 "$ISSUE"
  run bash -c '"$0" tracker comment ENG-12 </dev/null' "$MROOM"
  expect_rc 2; expect_err_has "the body on stdin is empty"
  run bash -c 'printf "key: %s\n" "$LINEAR_API_KEY" | "$0" tracker comment ENG-12' "$MROOM"
  expect_rc 1; expect_err_has "the body holds the tracker's token; not sent"
  expect_true "the token leaked" token_nowhere
  expect_true "Linear was called ($(calls) calls)" [ "$(calls)" = 0 ]
}

t_state_finds_the_state_across_pages_and_sets_it() {
  world
  answer 200 "$ISSUE"; answer 200 "$STATES_1"; answer 200 "$STATES_2"
  answer 200 '{"data":{"issueUpdate":{"success":true,"issue":{"identifier":"ENG-12","state":{"name":"In Review"}}}}}'
  run "$MROOM" tracker state ENG-12 "in review"
  expect_rc 0; expect_err_empty
  expect_true "the states query" has "$(query 2)" 'team(id: $t) { states(first: 100, after: $after)'
  expect_true "the states' first page" [ "$(vars 2)" = '{"t":"uuid-team-1"}' ]
  expect_true "the states' second page lost the cursor" [ "$(vars 3)" = '{"t":"uuid-team-1","after":"cursor-states-2"}' ]
  expect_true "the update" has "$(query 4)" 'issueUpdate(id: $i, input: {stateId: $s})'
  expect_true "the update's variables" [ "$(vars 4)" = '{"i":"uuid-issue-1","s":"uuid-state-review"}' ]
  expect_true "the answer" json_is "$out" '. == {identifier: "ENG-12", state: "In Review", changed: true}'
}

t_state_refuses_an_unknown_state_and_skips_the_same_one() {
  world
  answer 200 "$ISSUE"; answer 200 "$STATES_2"
  run "$MROOM" tracker state ENG-12 Shipped
  expect_rc 1; expect_err_has "the team has no state named 'Shipped' (it has: In Review)"
  expect_true "a mutation was sent" [ "$(calls)" = 2 ]
  reset; world
  answer 200 "$ISSUE"; answer 200 "$STATES_1"; answer 200 "$STATES_2"
  run "$MROOM" tracker state ENG-12 todo
  expect_rc 0; expect_true "the answer" json_is "$out" '.changed == false and .state == "Todo"'
  expect_true "a mutation was sent for the state it had" [ "$(calls)" = 3 ]
}

t_create_refuses_without_its_flag() {
  world; answer 200 '{}'
  run bash -c 'echo body | "$0" tracker create --title "A new bug"' "$MROOM"
  expect_rc 2; expect_err_has "create files a new issue, so it needs --allow-create; nothing was sent"
  expect_true "Linear was called" [ "$(calls)" = 0 ]
}

t_create_files_the_issue_in_the_configured_team() {
  world
  answer 200 '{"data":{"teams":{"nodes":[{"id":"uuid-team-1","key":"ENG"}]}}}'
  answer 200 "$STATES_1"; answer 200 "$STATES_2"
  answer 200 '{"data":{"issueLabels":{"nodes":[{"id":"uuid-label-bug","name":"bug","team":{"key":"ENG"}},{"id":"uuid-label-other","name":"bug","team":{"key":"OPS"}},{"id":"uuid-label-ws","name":"found-by-agent","team":null}]}}}'
  answer 200 '{"data":{"issueCreate":{"success":true,"issue":{"identifier":"ENG-99","url":"https://tracker.example.dev/issue/ENG-99"}}}}'
  run bash -c 'printf "What broke.\n" | "$0" tracker create --allow-create --title "A new bug" --state "In Review" --priority 3 --label bug --label found-by-agent' "$MROOM"
  expect_rc 0; expect_err_empty
  expect_true "the team lookup" [ "$(vars 1)" = '{"k":"ENG"}' ]
  expect_true "the label lookup" [ "$(vars 4)" = '{"n":["bug","found-by-agent"]}' ]
  expect_true "the create's input: $(vars 5)" json_is "$(vars 5)" '.i == {teamId: "uuid-team-1", title: "A new bug",
    description: "What broke.", stateId: "uuid-state-review", priority: 3, labelIds: ["uuid-label-bug", "uuid-label-ws"]}'
  expect_true "the create's mutation" has "$(query 5)" 'issueCreate(input: $i)'
  expect_true "the answer" json_is "$out" '. == {created: "ENG-99", url: "https://tracker.example.dev/issue/ENG-99"}'
}

t_create_refuses_a_missing_team_or_label_before_creating() {
  world $'tracker = "linear"'
  run bash -c 'echo body | "$0" tracker create --allow-create --title "A new bug"' "$MROOM"
  expect_rc 1; expect_err_has "issues.team is not set"
  expect_true "Linear was called" [ "$(calls)" = 0 ]
  reset; world
  answer 200 '{"data":{"teams":{"nodes":[{"id":"uuid-team-1","key":"ENG"}]}}}'
  answer 200 '{"data":{"issueLabels":{"nodes":[{"id":"uuid-label-other","name":"bug","team":{"key":"OPS"}}]}}}'
  run bash -c 'echo body | "$0" tracker create --allow-create --title "A new bug" --label bug' "$MROOM"
  expect_rc 1; expect_err_has "the team ENG has no label 'bug' (mroom never creates labels)"
  expect_true "an issue was created" [ "$(calls)" = 2 ]
  run bash -c 'echo body | "$0" tracker create --allow-create --title "x" --priority 7' "$MROOM"
  expect_rc 2; expect_err_has "--priority is 0 (none), 1 (urgent) to 4 (low)"
}

t_a_429_waits_as_long_as_it_is_told_and_a_5xx_read_is_retried() {
  world
  answer 429 '{"errors":[{"message":"slow down"}]}' 'Retry-After: 3'
  answer 502 'bad gateway'
  answer 200 "$ISSUE"; answer 200 '{"data":{"issue":{"comments":{"nodes":[],"pageInfo":{"hasNextPage":false}}}}}'
  run "$MROOM" tracker get ENG-12
  expect_rc 0
  expect_true "expected 4 calls, got $(calls)" [ "$(calls)" = 4 ]
  run cat "$T/api/sleep.log"; expect_out $'3\n4'
}

t_a_ratelimited_graphql_error_is_waited_out() {
  world
  answer 400 '{"errors":[{"message":"Rate limit exceeded","extensions":{"code":"RATELIMITED"}}]}'
  answer 200 "$ISSUE"; answer 200 '{"data":{"issue":{"comments":{"nodes":[],"pageInfo":{"hasNextPage":false}}}}}'
  run "$MROOM" tracker get ENG-12
  expect_rc 0; expect_true "expected 3 calls, got $(calls)" [ "$(calls)" = 3 ]
  run cat "$T/api/sleep.log"; expect_out 5
}

t_a_5xx_that_never_clears_fails_after_four_calls() {
  world; answer 500 'oops'
  run "$MROOM" tracker get ENG-12
  expect_rc 1; expect_err_has "mroom tracker: POST $URL -> HTTP 500: oops"
  expect_true "expected 4 calls, got $(calls)" [ "$(calls)" = 4 ]
  expect_true "a file was left in TMPDIR" tmp_empty
}

t_a_4xx_is_never_retried() {
  world; answer 400 '{"errors":[{"message":"Argument Validation Error"}]}'; answer 200 "$ISSUE"
  run "$MROOM" tracker get ENG-12
  expect_rc 1; expect_err_has "HTTP 400"
  expect_true "a 400 was retried ($(calls) calls)" [ "$(calls)" = 1 ]
  reset; world; answer 401 '{"errors":[{"message":"Authentication required"}]}'
  run "$MROOM" tracker get ENG-12
  expect_rc 1; expect_true "a 401 was retried ($(calls) calls)" [ "$(calls)" = 1 ]
}

t_a_comment_is_never_sent_twice_after_a_gateway_error() {
  world
  answer 200 "$ISSUE"; answer 502 'bad gateway'
  run bash -c 'echo hello | "$0" tracker comment ENG-12' "$MROOM"
  expect_rc 1; expect_err_has "HTTP 502"
  expect_true "the comment was sent again ($(calls) calls)" [ "$(calls)" = 2 ]
  reset; world
  answer 200 "$ISSUE"; answer 503 'unavailable'
  answer 200 '{"data":{"commentCreate":{"success":true,"comment":{"url":"u"}}}}'
  run bash -c 'echo hello | "$0" tracker comment ENG-12' "$MROOM"
  expect_rc 0; expect_true "a 503 (nothing done) was not retried ($(calls) calls)" [ "$(calls)" = 3 ]
}

t_a_graphql_error_fails_with_its_message() {
  world; answer 200 '{"data":null,"errors":[{"message":"Entity not found: Issue"}]}'
  run "$MROOM" tracker get ENG-404
  expect_rc 1; expect_out ""; expect_err_has "mroom tracker: Linear: Entity not found: Issue"
}

t_a_missing_or_empty_token_fails_clearly_and_calls_nothing() {
  world; unset LINEAR_API_KEY
  run "$MROOM" tracker get ENG-12
  expect_rc 1; expect_err_has "Linear: the environment variable LINEAR_API_KEY is not set or is empty"
  export LINEAR_API_KEY=$' \n\t'
  run "$MROOM" tracker get ENG-12
  expect_rc 1; expect_err_has "LINEAR_API_KEY is not set or is empty"
  export LINEAR_API_KEY=$'lin_api_bad\x01token'
  run "$MROOM" tracker get ENG-12
  expect_rc 1; expect_err_has "LINEAR_API_KEY holds characters a token never has"
  expect_err_lacks "lin_api_bad"
  expect_true "Linear was called" [ "$(calls)" = 0 ]
}

t_the_token_env_name_comes_from_config() {
  world $'tracker = "linear"\ntoken_env = "SHOP_LINEAR_TOKEN"'
  unset LINEAR_API_KEY
  run "$MROOM" tracker get ENG-12
  expect_rc 1; expect_err_has "the environment variable SHOP_LINEAR_TOKEN is not set"
  export SHOP_LINEAR_TOKEN="$TOKEN"
  answer 200 "$ISSUE"; answer 200 '{"data":{"issue":{"comments":{"nodes":[],"pageInfo":{"hasNextPage":false}}}}}'
  run "$MROOM" tracker get ENG-12
  expect_rc 0; expect_true "the configured token was not sent" [ "$(call_line 1 3)" = "auth=$TOKEN" ]
}

t_the_token_never_shows_even_when_echoed_or_traced() {
  world; answer 403 "{\"errors\":[{\"message\":\"key $TOKEN has no access\"}]}"
  run "$MROOM" tracker get ENG-12
  expect_rc 1; expect_err_has "key [token] has no access"
  expect_true "the token leaked" token_nowhere
  reset; world
  answer 200 "$ISSUE"; answer 200 '{"data":{"issue":{"comments":{"nodes":[],"pageInfo":{"hasNextPage":false}}}}}'
  run bash -x "$ROOT/lib/tracker" get ENG-12
  expect_rc 0; expect_true "bash -x printed the token" token_nowhere
  reset; world
  answer 200 "$ISSUE"; answer 200 '{"data":{"issue":{"comments":{"nodes":[],"pageInfo":{"hasNextPage":false}}}}}'
  run env SHELLOPTS=xtrace "$ROOT/lib/tracker" get ENG-12
  expect_rc 0; expect_true "SHELLOPTS=xtrace printed the token" token_nowhere
}

t_an_id_must_match_the_pattern() {
  world; answer 200 "$ISSUE"
  run "$MROOM" tracker get OPS-1
  expect_rc 2; expect_err_has "OPS-1 does not match issues.id_pattern (ENG-[0-9]+)"
  run "$MROOM" tracker get 'ENG-1/../x'
  expect_rc 2; expect_err_has "not an issue id"
  expect_true "Linear was called" [ "$(calls)" = 0 ]
}

t_the_backend_comes_from_config_and_none_calls_nothing() {
  world; answer 200 "$ISSUE"
  run "$MROOM" tracker backend; expect_rc 0; expect_out linear
  world $'tracker = "none"'
  run "$MROOM" tracker backend; expect_out none
  run "$MROOM" tracker get ENG-12
  expect_rc 3; expect_err_has "issues.tracker is none, so there is no tracker to read an issue"
  run bash -c 'echo hi | "$0" tracker comment ENG-12' "$MROOM"; expect_rc 3
  run "$MROOM" tracker state ENG-12 Done; expect_rc 3
  run bash -c 'echo hi | "$0" tracker create --allow-create --title t' "$MROOM"; expect_rc 3
  printf '[app]\nname = "shop"\n' >"$T/mroom.toml"
  run "$MROOM" tracker backend; expect_out none
  run "$MROOM" tracker get ENG-12; expect_rc 3
  printf '[app]\nname = "shop"\n[issues]\ntracker = "jira"\n' >"$T/mroom.toml"
  run "$MROOM" tracker get ENG-12; expect_rc 1; expect_err_has "issues.tracker must be one of linear, none"
  expect_true "a tracker was called" [ "$(calls)" = 0 ]
}

t_usage_errors() {
  world
  run "$MROOM" tracker; expect_rc 0; expect_out_has "mroom tracker get <id>"
  run "$MROOM" tracker frob; expect_rc 2; expect_err_has "unknown command 'frob'"
  run "$MROOM" tracker get; expect_rc 2; expect_err_has "usage: get <id>"
  run "$MROOM" tracker state ENG-1; expect_rc 2
  run bash -c 'echo x | "$0" tracker create --allow-create --bogus' "$MROOM"; expect_rc 2; expect_err_has "unknown option '--bogus'"
  expect_true "Linear was called" [ "$(calls)" = 0 ]
}

# reset: forget the last world's answers and calls, for a second round in the same test.
reset() { rm -rf "$T/api"; }

test_case get-reads-the-issue-and-every-page-of-comments t_get_reads_the_issue_and_every_page_of_comments
test_case an-oauth-token-goes-as-a-bearer-token t_an_oauth_token_goes_as_a_bearer_token
test_case a-page-with-no-list-fails t_a_page_with_no_list_fails_rather_than_reading_short
test_case comment-sends-the-body-from-stdin t_comment_sends_the_body_from_stdin
test_case comment-refuses-empty-or-token t_comment_refuses_an_empty_body_or_one_with_the_token
test_case state-across-pages t_state_finds_the_state_across_pages_and_sets_it
test_case state-unknown-or-same t_state_refuses_an_unknown_state_and_skips_the_same_one
test_case create-refuses-without-its-flag t_create_refuses_without_its_flag
test_case create-files-the-issue t_create_files_the_issue_in_the_configured_team
test_case create-refuses-missing-team-or-label t_create_refuses_a_missing_team_or_label_before_creating
test_case 429-and-5xx-read-retried t_a_429_waits_as_long_as_it_is_told_and_a_5xx_read_is_retried
test_case ratelimited-graphql-error t_a_ratelimited_graphql_error_is_waited_out
test_case 5xx-fails-after-four t_a_5xx_that_never_clears_fails_after_four_calls
test_case 4xx-never-retried t_a_4xx_is_never_retried
test_case comment-never-sent-twice t_a_comment_is_never_sent_twice_after_a_gateway_error
test_case graphql-error t_a_graphql_error_fails_with_its_message
test_case missing-or-empty-token t_a_missing_or_empty_token_fails_clearly_and_calls_nothing
test_case token-env-from-config t_the_token_env_name_comes_from_config
test_case token-never-shows t_the_token_never_shows_even_when_echoed_or_traced
test_case id-must-match t_an_id_must_match_the_pattern
test_case backend-from-config t_the_backend_comes_from_config_and_none_calls_nothing
test_case usage-errors t_usage_errors
finish
