#!/usr/bin/env bash
# shellcheck disable=SC2317  # the t_* functions run indirectly, through test_case
# Tests for the Forge client (lib/core/forge.sh) and bin/forge-api: pinned to one server, the token and
# the body kept off every command line, retries, 429s, pagination, and the guards before any call.
# Offline: curl is a fake that answers from $T/answers, and sleep only records how long it was asked for.
set -euo pipefail
SUITE=forge
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
skip_unless has_box_tools "this host lacks bash 5, flock or GNU date, which box commands need"
has_jq() { command -v jq >/dev/null 2>&1; }
skip_unless has_jq "this host has no jq"

FORGE_API="$ROOT/bin/forge-api"
BASE="https://forge.laravel.com/api/orgs/acme/servers/42"
export FAKE_TOKEN="fake-forge-token-0123456789"

# fake_tools: curl and sleep fakes first on PATH.
fake_tools() {
  mkdir -p "$T/bin"
  cat >"$T/bin/curl" <<'FAKE'
#!/usr/bin/env bash
# Answers from $T/answers, one "<code> <body file>" per line in order (the last one repeats). Logs every
# argument to $T/curl.argv, and "<method> <url> auth=<yes|no> [body=<request body>]" per call to
# $T/curl.log: auth=yes when a --header @file held exactly the expected Authorization line.
printf '%s\n' "$@" >>"$T/curl.argv"
out="" headers="" method=GET url="" auth=no request=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) out="$2"; shift 2 ;;
    --dump-header) headers="$2"; shift 2 ;;
    --request) method="$2"; shift 2 ;;
    --header)
      case "$2" in @*) if [ "$(cat "${2#@}")" = "Authorization: Bearer $FAKE_TOKEN" ]; then auth=yes; fi ;; esac
      shift 2 ;;
    --data-binary) request="$(cat "${2#@}")"; shift 2 ;;
    --write-out | --max-time) shift 2 ;;
    --*) shift ;;
    *) url="$1"; shift ;;
  esac
done
n=$(($(cat "$T/curl.n" 2>/dev/null || echo 0) + 1))
echo "$n" >"$T/curl.n"
line="$(sed -n "${n}p" "$T/answers")"
[ -n "$line" ] || line="$(tail -n 1 "$T/answers")"
code="${line%% *}" file="$T/${line#* }"
echo "$method $url auth=$auth${request:+ body=$request}" >>"$T/curl.log"
if [ "$code" = 000 ]; then echo "curl: (28) Operation timed out after 60000 milliseconds" >&2; exit 28; fi
{ printf 'HTTP/2 %s\r\n' "$code"; if [ -f "$file.headers" ]; then cat "$file.headers"; fi; } >"$headers"
cat "$file" >"$out"
printf '%s' "$code"
FAKE
  cat >"$T/bin/sleep" <<'FAKE'
#!/bin/sh
echo "$1" >>"$T/sleep.log"
FAKE
  chmod +x "$T/bin/curl" "$T/bin/sleep"
  export T PATH="$T/bin:$PATH"
}

# answer <code> <body> [<response header line>]: the next answer the fake curl gives.
answer() {
  local n=1 f
  if [ -f "$T/answers" ]; then n=$(($(wc -l <"$T/answers") + 1)); fi
  f="answer$n"
  printf '%s' "$2" >"$T/$f"
  [ -z "${3:-}" ] || printf '%s\r\n' "$3" >"$T/$f.headers"
  echo "$1 $f" >>"$T/answers"
}

# box: a box.env naming the server, and the token file, mode 600.
box() {
  mkdir -p "$HOME/.config/mroom/secrets"
  printf 'MROOM_FORGE_ORG=acme\nMROOM_FORGE_SERVER=42\n' >"$HOME/.config/mroom/box.env"
  printf '%s\n' "$FAKE_TOKEN" >"$HOME/.config/mroom/secrets/forge-token"
  chmod 600 "$HOME/.config/mroom/secrets/forge-token"
}

calls() { if [ -f "$T/curl.log" ]; then wc -l <"$T/curl.log" | tr -d ' '; else echo 0; fi; }
lacks() { case "$1" in *"$2"*) return 1 ;; esac; }
argv_lacks() { ! grep -qF -- "$1" "$T/curl.argv"; }

t_a_read_prints_the_body_and_keeps_the_token_off_every_command_line() {
  fake_tools; box; answer 200 '{"data":[{"id":"7"}]}'
  run "$FORGE_API" GET sites
  expect_rc 0; expect_out '{"data":[{"id":"7"}]}'
  expect_true "the token was printed" lacks "$out$err" "$FAKE_TOKEN"
  expect_true "the token was on curl's command line" argv_lacks "$FAKE_TOKEN"
  run cat "$T/curl.log"; expect_out "GET $BASE/sites auth=yes"
}

t_a_502_is_retried() {
  fake_tools; box; answer 502 'bad gateway'; answer 200 '{"ok":true}'
  run "$FORGE_API" GET sites
  expect_rc 0; expect_out '{"ok":true}'
  expect_true "expected 2 calls, got $(calls)" [ "$(calls)" = 2 ]
}

t_a_502_that_never_clears_fails_after_three_retries() {
  fake_tools; box; answer 502 'bad gateway'
  run "$FORGE_API" GET sites
  expect_rc 1; expect_err_has "forge-api: GET /sites -> HTTP 502: bad gateway"
  expect_true "expected 4 calls, got $(calls)" [ "$(calls)" = 4 ]
}

t_a_429_waits_as_long_as_forge_says() {
  fake_tools; box; answer 429 '{"message":"Too Many Attempts."}' 'Retry-After: 7'; answer 200 '{}'
  run "$FORGE_API" GET sites; expect_rc 0
  run cat "$T/sleep.log"; expect_out 7
}

t_a_429_without_retry_after_waits_the_default() {
  fake_tools; box; answer 429 '{}'; answer 200 '{}'
  export MROOM_FORGE_RATE_SLEEP=3
  run "$FORGE_API" GET sites; expect_rc 0
  run cat "$T/sleep.log"; expect_out 3
}

t_a_timed_out_read_is_retried_but_never_a_write() {
  fake_tools; box; answer 000 x; answer 200 '{}'
  run "$FORGE_API" GET sites
  expect_rc 0; expect_true "expected 2 calls, got $(calls)" [ "$(calls)" = 2 ]
  rm "$T/curl.log" "$T/curl.n"
  run "$FORGE_API" POST sites/1/deployments --write
  expect_rc 1; expect_err_has "forge-api: POST /sites/1/deployments -> HTTP 000: curl: (28) Operation timed out"
  expect_true "a write was retried ($(calls) calls)" [ "$(calls)" = 1 ]
}

t_an_http_error_fails_with_one_line() {
  fake_tools; box; answer 404 '{"message":"Not Found."}'
  run "$FORGE_API" GET sites/9
  expect_rc 1; expect_out ""; expect_err_has 'forge-api: GET /sites/9 -> HTTP 404: {"message":"Not Found."}'
}

t_a_write_needs_the_write_flag() {
  fake_tools; box; answer 200 '{}'
  run "$FORGE_API" DELETE sites/9
  expect_rc 2; expect_err_has "DELETE changes Forge and needs --write"
  expect_true "Forge was called" [ "$(calls)" = 0 ]
}

t_a_path_cannot_leave_the_server() {
  fake_tools; box; answer 200 '{}'
  local p
  for p in "../servers/1" "sites/../../x" "orgs/other" "servers/2/sites" "sites/%2e%2e/x" "sites/%2F" \
    "https://evil.example/x" "sites/1@evil.example" "sites/a b" 'sites/a\b' ""; do
    run "$FORGE_API" GET "$p"
    expect_rc 2
  done
  expect_true "Forge was called" [ "$(calls)" = 0 ]
}

t_a_query_with_brackets_is_a_plain_path() {
  fake_tools; box; answer 200 '{}'
  run "$FORGE_API" GET 'sites?filter[name]=api-1.qa.example.dev'
  expect_rc 0
  run cat "$T/curl.log"; expect_out "GET $BASE/sites?filter[name]=api-1.qa.example.dev auth=yes"
}

t_a_path_that_returns_secrets_needs_secret() {
  fake_tools; box; answer 200 '{"data":{"attributes":{"content":"APP_KEY=base64:x"}}}'
  run "$FORGE_API" GET sites/1/environment
  expect_rc 2; expect_err_has "returns secrets; run it as: forge-api --secret GET sites/1/environment"
  expect_true "Forge was called" [ "$(calls)" = 0 ]
  run "$FORGE_API" --secret GET sites/1/environment; expect_rc 0
}

t_a_body_reaches_curl_through_a_file() {
  fake_tools; box; answer 200 '{}'
  run "$FORGE_API" PUT sites/1/nginx --write --data '{"config":"server { listen 80; }"}'
  expect_rc 0
  expect_true "the body was on curl's command line" argv_lacks 'listen 80'
  run cat "$T/curl.log"; expect_out "PUT $BASE/sites/1/nginx auth=yes body={\"config\":\"server { listen 80; }\"}"
}

t_a_body_can_come_from_stdin() {
  fake_tools; box; answer 200 '{}'
  run bash -c "printf '%s' '{\"environment\":\"SECRET=1\"}' | '$FORGE_API' --secret PUT sites/1/environment --write --data -"
  expect_rc 0
  run cat "$T/curl.log"; expect_out_has 'body={"environment":"SECRET=1"}'
}

t_invalid_json_and_a_get_with_a_body_are_refused() {
  fake_tools; box; answer 200 '{}'
  run "$FORGE_API" POST sites --write --data '{bad'; expect_rc 2; expect_err_has "--data is not valid JSON"
  run "$FORGE_API" GET sites --data '{}'; expect_rc 2; expect_err_has "a GET takes no --data"
  run "$FORGE_API" GET sites --nonsense; expect_rc 2; expect_err_has "unknown argument: --nonsense"
  expect_true "Forge was called" [ "$(calls)" = 0 ]
}

t_the_token_file_must_be_private() {
  fake_tools; box; answer 200 '{}'
  chmod 644 "$HOME/.config/mroom/secrets/forge-token"
  run "$FORGE_API" GET sites
  expect_rc 1
  # shellcheck disable=SC2088  # the message shows the path with a literal ~
  expect_err_has "~/.config/mroom/secrets/forge-token must be yours and mode 600"
  rm "$HOME/.config/mroom/secrets/forge-token"
  run "$FORGE_API" GET sites
  expect_rc 1; expect_err_has "no Forge token: ~/.config/mroom/secrets/forge-token is missing (on a runner, set MROOM_FORGE_TOKEN)"
  expect_true "Forge was called" [ "$(calls)" = 0 ]
}

t_a_runner_passes_everything_in_the_environment() {
  fake_tools; answer 200 '{}'
  export MROOM_FORGE_ORG=acme MROOM_FORGE_SERVER=42 MROOM_FORGE_TOKEN="$FAKE_TOKEN"
  run "$FORGE_API" GET sites; expect_rc 0
  run cat "$T/curl.log"; expect_out "GET $BASE/sites auth=yes"
}

t_the_org_and_server_must_be_set_and_plain() {
  fake_tools; answer 200 '{}'
  export MROOM_FORGE_TOKEN="$FAKE_TOKEN"
  run "$FORGE_API" GET sites
  expect_rc 1; expect_err_has "MROOM_FORGE_ORG and MROOM_FORGE_SERVER must be set"
  export MROOM_FORGE_ORG=acme MROOM_FORGE_SERVER=42x
  run "$FORGE_API" GET sites
  expect_rc 1; expect_err_has "MROOM_FORGE_SERVER is not a server id: 42x"
  export MROOM_FORGE_ORG='acme/../other' MROOM_FORGE_SERVER=42
  run "$FORGE_API" GET sites
  expect_rc 1; expect_err_has "MROOM_FORGE_ORG is not an organisation slug"
  expect_true "Forge was called" [ "$(calls)" = 0 ]
}

# lib_run <shell code>: runs it with util.sh and forge.sh sourced, as an mroom command would.
lib_run() { run env MROOM_ROOT="$ROOT" bash -c ". '$ROOT/lib/core/util.sh'; . '$ROOT/lib/core/forge.sh'; $1"; }

t_a_list_follows_every_cursor() {
  fake_tools; box
  answer 200 '{"data":[{"id":"1"}],"meta":{"next_cursor":"c2=="}}'
  answer 200 '{"data":[{"id":"2"}],"meta":{"next_cursor":null}}'
  lib_run 'forge_list /sites'
  expect_rc 0; expect_out $'{"id":"1"}\n{"id":"2"}'
  run cat "$T/curl.log"
  expect_out $'GET '"$BASE"$'/sites?page[size]=100 auth=yes\nGET '"$BASE"$'/sites?page[size]=100&page[cursor]=c2%3D%3D auth=yes'
}

t_a_list_page_without_a_list_fails_instead_of_reading_empty() {
  fake_tools; box; answer 200 '{"message":"Server Error"}'
  lib_run 'forge_list /sites'
  expect_rc 1; expect_out ""; expect_err_has "mroom forge: GET /sites: the answer holds no list"
}

t_a_site_is_found_by_its_name() {
  fake_tools; box
  answer 200 '{"data":[{"id":"5","attributes":{"name":"api-1.qa.example.dev"}},{"id":"6","attributes":{"name":"api-12.qa.example.dev"}}],"meta":{}}'
  lib_run 'forge_site api-1.qa.example.dev'
  expect_rc 0; expect_out '{"id":"5","attributes":{"name":"api-1.qa.example.dev"}}'
  run cat "$T/curl.log"; expect_out "GET $BASE/sites?filter[name]=api-1.qa.example.dev&page[size]=100 auth=yes"
}

test_case read-prints-body-token-off-argv t_a_read_prints_the_body_and_keeps_the_token_off_every_command_line
test_case 502-retried t_a_502_is_retried
test_case 502-gives-up t_a_502_that_never_clears_fails_after_three_retries
test_case 429-retry-after t_a_429_waits_as_long_as_forge_says
test_case 429-default-wait t_a_429_without_retry_after_waits_the_default
test_case timeout-read-only t_a_timed_out_read_is_retried_but_never_a_write
test_case http-error-one-line t_an_http_error_fails_with_one_line
test_case write-needs-flag t_a_write_needs_the_write_flag
test_case path-stays-on-server t_a_path_cannot_leave_the_server
test_case query-with-brackets t_a_query_with_brackets_is_a_plain_path
test_case secret-path-needs-secret t_a_path_that_returns_secrets_needs_secret
test_case body-through-file t_a_body_reaches_curl_through_a_file
test_case body-from-stdin t_a_body_can_come_from_stdin
test_case bad-input-refused t_invalid_json_and_a_get_with_a_body_are_refused
test_case token-file-private t_the_token_file_must_be_private
test_case runner-environment t_a_runner_passes_everything_in_the_environment
test_case org-server-plain t_the_org_and_server_must_be_set_and_plain
test_case list-follows-cursors t_a_list_follows_every_cursor
test_case list-bad-page-fails t_a_list_page_without_a_list_fails_instead_of_reading_empty
test_case site-by-name t_a_site_is_found_by_its_name
finish
