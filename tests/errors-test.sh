#!/usr/bin/env bash
# shellcheck disable=SC2317  # the t_* functions run indirectly, through test_case
# shellcheck disable=SC2016  # GraphQL variables and the fake sleep's $1 are not this shell's
# Tests for the error-tracker adapter (lib/core/errors.sh, `mroom errors`): each operation's request and how
# it reads the answer, the search's pages, retries, the token kept off every command line and out of every
# message, the host fixed by region, and the backend picked from mroom.toml. Offline: curl is
# tests/fakes/api-curl, sleep only records how long it was asked for, and every id, name and token is made up.
set -euo pipefail
SUITE=errors
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
skip_unless has_box_tools "this host lacks bash 5 or GNU tools, which box commands need"
has_jq() { command -v jq >/dev/null 2>&1; }
skip_unless has_jq "this host has no jq"
skip_unless has_tomllib "python3 has no tomllib (needs 3.11+)"

BASE="https://us.sentry.io/api/0/organizations/example-org"
TOKEN="sntrys_fakeTOKEN0123456789abcdef"

# world [<errors table lines>]: the fake curl and sleep, a TMPDIR of the test's own, the token, and a
# mroom.toml with a Sentry error tracker (or the given [errors] lines; "-" for no table).
world() {
  mkdir -p "$T/bin" "$T/tmp" "$T/api"
  cp "$ROOT/tests/fakes/api-curl" "$T/bin/curl"
  printf '#!/bin/sh\necho "$1" >>"%s/api/sleep.log"\n' "$T" >"$T/bin/sleep"
  chmod +x "$T/bin/curl" "$T/bin/sleep"
  export API_FAKE="$T/api" PATH="$T/bin:$PATH" TMPDIR="$T/tmp" SENTRY_AUTH_TOKEN="$TOKEN" MROOM_API_RATE_SLEEP=5
  local table=$'provider = "sentry"\norg = "example-org"\nid_pattern = "SHOP-[A-Z0-9]+"'
  [ -z "${1:-}" ] || table="$1"
  if [ "$table" = - ]; then
    printf '[app]\nname = "shop"\n' >"$T/mroom.toml"
  else
    printf '[app]\nname = "shop"\n\n[errors]\n%s\n' "$table" >"$T/mroom.toml"
  fi
  export MROOM_CONFIG="$T/mroom.toml"
}

answer() {
  local n=1 f
  if [ -f "$T/api/answers" ]; then n=$(($(wc -l <"$T/api/answers") + 1)); fi
  f="answer$n"
  printf '%s' "$2" >"$T/api/$f"
  [ -z "${3:-}" ] || printf '%s\r\n' "$3" >"$T/api/$f.headers"
  echo "$1 $f" >>"$T/api/answers"
}

reset() { rm -rf "$T/api"; }
calls() { find "$T/api" -name 'call.*' | wc -l | tr -d ' '; }
call_line() { sed -n "${2}p" "$T/api/call.$1"; }
call_body() { sed -n 's/^body=//p' "$T/api/call.$1"; }
lacks() { case "$1" in *"$2"*) return 1 ;; esac; }
tmp_empty() { [ -z "$(find "$T/tmp" -mindepth 1 -print -quit)" ]; }
json_is() { jq -e "$2" <<<"$1" >/dev/null 2>&1; }
token_nowhere() { lacks "$out$err" "$TOKEN" && lacks "$(cat "$T/api/argv" 2>/dev/null)" "$TOKEN"; }

ISSUE='{"id":"1001","shortId":"SHOP-1A2","title":"TypeError: x is undefined","culprit":"app/checkout","permalink":"https://example-org.sentry.example/issues/1001/","level":"error","status":"unresolved","substatus":"ongoing","count":"42","userCount":7,"firstSeen":"2026-01-01T00:00:00Z","lastSeen":"2026-01-02T00:00:00Z","firstRelease":{"version":"v1.2.0"},"lastRelease":{"version":"v1.3.0"},"project":{"slug":"web"},"tags":[{"key":"browser","topValues":[{"value":"Firefox","count":5},{"value":"Chrome","count":2}]}]}'
EVENT='{"eventID":"ev-abc","dateCreated":"2026-01-02T00:00:00Z","message":"","title":"TypeError: x is undefined","release":{"version":"v1.3.0"},"tags":[{"key":"environment","value":"production"},{"key":"user.email","value":"someone@example.com"},{"key":"url","value":"https://shop.example.dev/cart"}],"entries":[{"type":"exception","data":{"values":[{"type":"TypeError","value":"x is undefined","stacktrace":{"frames":[{"filename":"vendor/lib.js","function":"run","lineNo":1,"inApp":false},{"filename":"src/cart.ts","function":"total","lineNo":12,"inApp":true}]}}]}}]}'
PROJECTS='[{"slug":"web"}]'

t_get_reads_the_issue_and_its_latest_event() {
  world; answer 200 "$ISSUE"; answer 200 "$EVENT"
  run "$MROOM" errors get SHOP-1A2
  expect_rc 0; expect_err_empty
  expect_true "expected 2 calls, got $(calls)" [ "$(calls)" = 2 ]
  expect_true "call 1: $(call_line 1 1) $(call_line 1 2)" [ "$(call_line 1 1) $(call_line 1 2)" = "GET $BASE/issues/SHOP-1A2/" ]
  expect_true "call 2: $(call_line 2 2)" [ "$(call_line 2 2)" = "$BASE/issues/SHOP-1A2/events/latest/" ]
  expect_true "not a Bearer token" [ "$(call_line 1 3)" = "auth=Bearer $TOKEN" ]
  expect_true "the issue was not read right" json_is "$out" '.id == "1001" and .short_id == "SHOP-1A2" and .count == "42"
    and .user_count == 7 and .first_release == "v1.2.0" and .last_release == "v1.3.0" and .project == "web"
    and .tags == [{key: "browser", top: [{value: "Firefox", count: 5}, {value: "Chrome", count: 2}]}]'
  expect_true "the event was not read right" json_is "$out" '.latest_event == {id: "ev-abc", at: "2026-01-02T00:00:00Z",
    message: "", release: "v1.3.0", environment: "production",
    tags: [{key: "environment", value: "production"}, {key: "url", value: "https://shop.example.dev/cart"}],
    exception: [{type: "TypeError", value: "x is undefined", frames: [{filename: "src/cart.ts", function: "total", line: 12}]}]}'
  expect_true "the token leaked" token_nowhere
  expect_true "a file was left in TMPDIR" tmp_empty
}

t_the_region_picks_the_host() {
  world $'provider = "sentry"\norg = "example-org"\nregion = "de"'
  answer 200 "$ISSUE"; answer 200 "$EVENT"
  run "$MROOM" errors get 1001
  expect_rc 0
  expect_true "call 1: $(call_line 1 2)" [ "$(call_line 1 2)" = "https://de.sentry.io/api/0/organizations/example-org/issues/1001/" ]
}

t_search_follows_the_cursor_until_no_more_results() {
  world
  answer 200 "$PROJECTS"
  answer 200 "[$ISSUE]" 'Link: <https://us.sentry.io/x>; rel="previous"; results="false"; cursor="0:0:1", <https://us.sentry.io/x>; rel="next"; results="true"; cursor="0:100:0"'
  answer 200 "[$ISSUE]" 'Link: <https://us.sentry.io/x>; rel="previous"; results="true"; cursor="0:0:1", <https://us.sentry.io/x>; rel="next"; results="false"; cursor="0:200:0"'
  run "$MROOM" errors search 'is:unresolved release:"v1.3.0"' --environment production --period 24h --limit 300
  expect_rc 0; expect_err_empty
  expect_true "expected 3 calls, got $(calls)" [ "$(calls)" = 3 ]
  expect_true "the scope check: $(call_line 1 2)" [ "$(call_line 1 2)" = "$BASE/projects/?per_page=1" ]
  expect_true "page 1: $(call_line 2 2)" [ "$(call_line 2 2)" = "$BASE/issues/?project=-1&query=is%3Aunresolved%20release%3A%22v1.3.0%22&statsPeriod=24h&limit=100&sort=date&environment=production" ]
  expect_true "page 2 lost the cursor: $(call_line 3 2)" [ "$(call_line 3 2)" = "$BASE/issues/?project=-1&query=is%3Aunresolved%20release%3A%22v1.3.0%22&statsPeriod=24h&limit=100&sort=date&environment=production&cursor=0%3A100%3A0" ]
  expect_true "the answer: $out" json_is "$out" 'length == 2 and .[0].short_id == "SHOP-1A2" and (.[0] | has("tags") | not)'
}

t_search_stops_at_its_limit() {
  world
  answer 200 "$PROJECTS"
  answer 200 "[$ISSUE,$ISSUE,$ISSUE]" 'Link: <https://us.sentry.io/x>; rel="next"; results="true"; cursor="0:3:0"'
  run "$MROOM" errors search is:unresolved --limit 2
  expect_rc 0
  expect_true "expected 2 calls, got $(calls)" [ "$(calls)" = 2 ]
  expect_true "the limit: $(call_line 2 2)" lacks "$(call_line 2 2)" "environment="
  expect_true "more than the limit" json_is "$out" 'length == 2'
}

t_search_refuses_when_the_token_sees_no_project() {
  world; answer 200 '[]'; answer 200 '[]'
  run "$MROOM" errors search is:unresolved
  expect_rc 1; expect_out ""; expect_err_has "the token sees no project"
  expect_true "a search ran anyway" [ "$(calls)" = 1 ]
}

t_resolve_puts_the_status() {
  world; answer 200 '{"status":"resolved","statusDetails":{}}'
  run "$MROOM" errors resolve SHOP-1A2
  expect_rc 0
  expect_true "the call: $(call_line 1 1) $(call_line 1 2)" [ "$(call_line 1 1) $(call_line 1 2)" = "PUT $BASE/issues/SHOP-1A2/" ]
  expect_true "the body: $(call_body 1)" [ "$(call_body 1)" = '{"status":"resolved"}' ]
  expect_true "the answer" json_is "$out" '. == {resolved: "SHOP-1A2", status: "resolved"}'
}

t_a_429_or_5xx_is_retried_and_a_4xx_is_not() {
  world; answer 429 '{"detail":"slow"}' 'Retry-After: 2'; answer 503 'down'; answer 200 "$ISSUE"; answer 200 "$EVENT"
  run "$MROOM" errors get 1001
  expect_rc 0; expect_true "expected 4 calls, got $(calls)" [ "$(calls)" = 4 ]
  run cat "$T/api/sleep.log"; expect_out $'2\n4'
  reset; world; answer 404 '{"detail":"The requested resource does not exist"}'; answer 200 "$ISSUE"
  run "$MROOM" errors get 1001
  expect_rc 1; expect_err_has "mroom errors: GET $BASE/issues/1001/ -> HTTP 404"
  expect_true "a 404 was retried ($(calls) calls)" [ "$(calls)" = 1 ]
  reset; world; answer 403 '{"detail":"You do not have permission"}'
  run "$MROOM" errors resolve 1001
  expect_rc 1; expect_err_has "HTTP 403"; expect_true "a 403 was retried" [ "$(calls)" = 1 ]
  reset; world; answer 000 x
  run "$MROOM" errors get 1001
  expect_rc 1; expect_err_has "HTTP 000: curl: (28)"
  expect_true "expected 4 calls, got $(calls)" [ "$(calls)" = 4 ]
  expect_true "a file was left in TMPDIR" tmp_empty
}

t_a_missing_token_fails_clearly_and_an_echoed_one_is_cut() {
  world; unset SENTRY_AUTH_TOKEN
  run "$MROOM" errors get 1001
  expect_rc 1; expect_err_has "Sentry: the environment variable SENTRY_AUTH_TOKEN is not set or is empty"
  export SENTRY_AUTH_TOKEN=""
  run "$MROOM" errors search x; expect_rc 1; expect_err_has "SENTRY_AUTH_TOKEN is not set or is empty"
  expect_true "Sentry was called" [ "$(calls)" = 0 ]
  world $'provider = "sentry"\norg = "example-org"\ntoken_env = "SHOP_SENTRY_READ"'
  run "$MROOM" errors get 1001; expect_rc 1; expect_err_has "SHOP_SENTRY_READ is not set"
  export SHOP_SENTRY_READ="$TOKEN"
  answer 401 "{\"detail\":\"Invalid token $TOKEN\"}"
  run "$MROOM" errors get 1001
  expect_rc 1; expect_err_has "Invalid token [token]"
  expect_true "the token leaked" token_nowhere
}

t_an_id_must_be_numeric_or_match_the_pattern() {
  world; answer 200 "$ISSUE"
  run "$MROOM" errors get OTHER-1; expect_rc 2; expect_err_has "neither a numeric id nor matches errors.id_pattern"
  run "$MROOM" errors get '1001/../../x'; expect_rc 2; expect_err_has "not an error issue id"
  run "$MROOM" errors resolve '1001?status=x'; expect_rc 2
  expect_true "Sentry was called" [ "$(calls)" = 0 ]
}

t_the_backend_comes_from_config() {
  world; answer 200 '[]'
  run "$MROOM" errors backend; expect_rc 0; expect_out sentry
  world -
  run "$MROOM" errors backend; expect_out none
  run "$MROOM" errors get 1001; expect_rc 3; expect_err_has "mroom.toml has no [errors] table"
  run "$MROOM" errors search x; expect_rc 3
  run "$MROOM" errors resolve 1001; expect_rc 3
  world $'provider = "sentry"'
  run "$MROOM" errors get 1001; expect_rc 1; expect_err_has "errors.org is not set"
  world $'provider = "rollbar"\norg = "example-org"'
  run "$MROOM" errors get 1001; expect_rc 1; expect_err_has "errors.provider must be one of sentry"
  expect_true "an error tracker was called" [ "$(calls)" = 0 ]
}

t_usage_errors() {
  world
  run "$MROOM" errors; expect_rc 0; expect_out_has "mroom errors get <id>"
  run "$MROOM" errors search; expect_rc 2
  run "$MROOM" errors search a b; expect_rc 2; expect_err_has "one query"
  run "$MROOM" errors search x --limit 0; expect_rc 2
  run "$MROOM" errors search x --limit 1001; expect_rc 2
  run "$MROOM" errors search x --period forever; expect_rc 2
  run "$MROOM" errors search x --environment 'a&b'; expect_rc 2
  run "$MROOM" errors frob; expect_rc 2
  expect_true "Sentry was called" [ "$(calls)" = 0 ]
}

test_case get-reads-issue-and-latest-event t_get_reads_the_issue_and_its_latest_event
test_case region-picks-the-host t_the_region_picks_the_host
test_case search-follows-the-cursor t_search_follows_the_cursor_until_no_more_results
test_case search-stops-at-its-limit t_search_stops_at_its_limit
test_case search-needs-a-project t_search_refuses_when_the_token_sees_no_project
test_case resolve-puts-the-status t_resolve_puts_the_status
test_case retries t_a_429_or_5xx_is_retried_and_a_4xx_is_not
test_case token t_a_missing_token_fails_clearly_and_an_echoed_one_is_cut
test_case id-checked t_an_id_must_be_numeric_or_match_the_pattern
test_case backend-from-config t_the_backend_comes_from_config
test_case usage-errors t_usage_errors
finish
