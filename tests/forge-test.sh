#!/usr/bin/env bash
# shellcheck disable=SC2317  # the t_* functions run indirectly, through test_case
# Tests for the Forge client (lib/core/forge.sh) and bin/forge-api: pinned to one server, the token kept
# off every command line and the disk, retries, 429s, pagination, the guards before any call, and no file
# left behind. Offline: curl is a fake that answers from $T/answers, sleep only records how long it was
# asked for, and TMPDIR is $T/tmp, which every test checks is empty afterwards.
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

# fake_tools: curl and sleep fakes first on PATH, and a TMPDIR of the test's own.
fake_tools() {
  mkdir -p "$T/bin" "$T/tmp"
  cat >"$T/bin/curl" <<'FAKE'
#!/usr/bin/env bash
# Answers from $T/answers, one "<code> <body file>" per line in order (the last one repeats). Logs a
# "--call--" line, then every argument, to $T/curl.argv; and "<method> <url> auth=<yes|no> [body=<request
# body>]" per call to $T/curl.log. auth=yes when --header @- brought exactly one line on stdin, the
# expected Authorization one. With $T/kill-me, it sends forge-api SIGTERM and takes a second to answer.
{ echo --call--; printf '%s\n' "$@"; } >>"$T/curl.argv"
out="" headers="" method=GET url="" auth=no request=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) out="$2"; shift 2 ;;
    --dump-header) headers="$2"; shift 2 ;;
    --request) method="$2"; shift 2 ;;
    --header)
      if [ "$2" = @- ]; then
        given="$(cat)"
        if [ "$given" = "Authorization: Bearer $FAKE_TOKEN" ]; then auth=yes; fi
      fi
      shift 2 ;;
    --data-binary) request="$(cat "${2#@}")"; shift 2 ;;
    --write-out | --max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
n=$(($(cat "$T/curl.n" 2>/dev/null || echo 0) + 1))
echo "$n" >"$T/curl.n"
line="$(sed -n "${n}p" "$T/answers")"
[ -n "$line" ] || line="$(tail -n 1 "$T/answers")"
code="${line%% *}" file="$T/${line#* }"
echo "$method $url auth=$auth${request:+ body=$request}" >>"$T/curl.log"
if [ -f "$T/kill-me" ]; then kill -TERM "$FORGE_API_PID"; /bin/sleep 1; fi
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
  export T PATH="$T/bin:$PATH" TMPDIR="$T/tmp"
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
# reset_answers: forget every answer and call, to script a second round in the same test.
reset_answers() { rm -f "$T"/answer* "$T/curl.log" "$T/curl.n" "$T/sleep.log"; }
lacks() { case "$1" in *"$2"*) return 1 ;; esac; }
tmp_empty() { [ -z "$(find "$T/tmp" -mindepth 1 -print -quit)" ]; }
# every_call_starts_with_q: curl's first argument is always -q, so no ~/.curlrc is read.
every_call_starts_with_q() { ! grep -A1 -x -- --call-- "$T/curl.argv" | grep -v -x -e --call-- -e -q -e -- | grep -q .; }

t_a_read_prints_the_body_and_keeps_the_token_off_every_command_line() {
  fake_tools; box; answer 200 '{"data":[{"id":"7"}]}'
  run "$FORGE_API" GET sites
  expect_rc 0; expect_out '{"data":[{"id":"7"}]}'
  expect_true "the token was printed" lacks "$out$err" "$FAKE_TOKEN"
  expect_true "the token was on curl's command line" lacks "$(cat "$T/curl.argv")" "$FAKE_TOKEN"
  expect_true "a file was left in TMPDIR" tmp_empty
  run cat "$T/curl.log"; expect_out "GET $BASE/sites auth=yes"
}

t_curl_ignores_curlrc_and_keeps_its_safety_options() {
  fake_tools; box; answer 200 '{}'
  run "$FORGE_API" GET 'sites?filter[name]=api.1.qa.example.dev'; expect_rc 0
  expect_true "curl's first argument is not -q" every_call_starts_with_q
  run grep -c -x -e --globoff -e --max-time "$T/curl.argv"; expect_out 2
}

t_202_and_204_answers_succeed() {
  fake_tools; box; answer 202 '{"data":{"id":"5"}}'; answer 204 ''
  run "$FORGE_API" POST sites/1/deployments --write; expect_rc 0; expect_out '{"data":{"id":"5"}}'
  run "$FORGE_API" DELETE sites/1 --write; expect_rc 0; expect_out ""
  expect_true "a file was left in TMPDIR" tmp_empty
}

t_a_503_is_retried_for_any_method_and_a_502_only_for_safe_ones() {
  fake_tools; box; answer 503 'unavailable'; answer 202 '{}'
  run "$FORGE_API" POST sites/1/deployments --write
  expect_rc 0; expect_true "expected 2 calls, got $(calls)" [ "$(calls)" = 2 ]
  reset_answers
  answer 502 'bad gateway'; answer 202 '{}'
  run "$FORGE_API" POST sites/1/deployments --write
  expect_rc 1; expect_err_has "POST /sites/1/deployments -> HTTP 502"
  expect_true "a POST was retried after a 502 ($(calls) calls)" [ "$(calls)" = 1 ]
  reset_answers
  answer 502 'bad gateway'; answer 200 '{"ok":true}'
  run "$FORGE_API" GET sites
  expect_rc 0; expect_out '{"ok":true}'; expect_true "expected 2 calls, got $(calls)" [ "$(calls)" = 2 ]
}

t_a_502_that_never_clears_fails_after_three_retries() {
  fake_tools; box; answer 502 'bad gateway'
  run "$FORGE_API" GET sites
  expect_rc 1; expect_err_has "forge-api: GET /sites -> HTTP 502: bad gateway"
  expect_true "expected 4 calls, got $(calls)" [ "$(calls)" = 4 ]
  expect_true "a file was left in TMPDIR" tmp_empty
}

t_a_429_waits_as_long_as_forge_says_and_gives_up_after_three() {
  fake_tools; box; answer 429 '{"message":"Too Many Attempts."}' 'Retry-After: 7'; answer 200 '{}'
  run "$FORGE_API" GET sites; expect_rc 0
  run cat "$T/sleep.log"; expect_out 7
  reset_answers
  answer 429 '{}'
  export MROOM_FORGE_RATE_SLEEP=3
  run "$FORGE_API" GET sites
  expect_rc 1; expect_true "expected 4 calls, got $(calls)" [ "$(calls)" = 4 ]
  run cat "$T/sleep.log"; expect_out $'3\n3\n3'
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

t_an_http_error_fails_with_one_line_and_leaves_nothing() {
  fake_tools; box; answer 404 '{"message":"Not Found."}'
  run "$FORGE_API" GET sites/9
  expect_rc 1; expect_out ""; expect_err_has 'forge-api: GET /sites/9 -> HTTP 404: {"message":"Not Found."}'
  expect_true "a file was left in TMPDIR" tmp_empty
}

t_an_interrupted_call_leaves_nothing_behind() {
  fake_tools; box; answer 200 '{}'; : >"$T/kill-me"
  run bash -c 'export FORGE_API_PID=$$; exec "$0" PUT sites/1/nginx --write --data "{\"config\":\"secret\"}"' "$FORGE_API"
  expect_rc 143
  expect_true "the interrupted call left files in TMPDIR" tmp_empty
}

t_xtrace_never_shows_the_token() {
  fake_tools; box; answer 200 '{}'
  run bash -x "$FORGE_API" GET sites
  expect_rc 0; expect_true "bash -x printed the token" lacks "$out$err" "$FAKE_TOKEN"
  run env SHELLOPTS=xtrace "$FORGE_API" GET sites
  expect_rc 0; expect_true "SHELLOPTS=xtrace printed the token" lacks "$out$err" "$FAKE_TOKEN"
}

t_a_write_needs_the_write_flag() {
  fake_tools; box; answer 200 '{}'
  run "$FORGE_API" DELETE sites/9
  expect_rc 2; expect_err_has "DELETE changes Forge and needs --write"
  expect_true "Forge was called" [ "$(calls)" = 0 ]
}

t_a_path_cannot_leave_the_server_or_reach_it() {
  fake_tools; box; answer 200 '{}'
  local p
  for p in "../servers/1" "sites/../../x" "orgs/other" "servers/2/sites" "sites/%2e%2e/x" "sites/%2F" \
    "https://evil.example/x" "sites/1@evil.example" "sites/a b" 'sites/a\b' "" "." "./" "//sites" "?x=1" \
    "sites//1" "sites/./1" "sites/1/" "Sites" "1/sites" 'sites/1#frag' "sites?a=b c"; do
    run "$FORGE_API" DELETE "$p" --write
    expect_rc 2
  done
  expect_true "Forge was called" [ "$(calls)" = 0 ]
  expect_true "a file was left in TMPDIR" tmp_empty
}

t_a_query_with_brackets_is_a_plain_path() {
  fake_tools; box; answer 200 '{}'
  run "$FORGE_API" GET 'sites?filter[name]=api.1.qa.example.dev'
  expect_rc 0
  run cat "$T/curl.log"; expect_out "GET $BASE/sites?filter[name]=api.1.qa.example.dev auth=yes"
}

t_paths_that_return_secrets_need_secret_however_they_are_spelled() {
  fake_tools; box; answer 200 '{"data":{}}'
  local p
  for p in sites/1/environment sites/1/env sites/1/%65nvironment sites/1/envi%72onment sites/1/ENVIRONMENT \
    sites/1/composer/credentials sites/1/npm/credentials sites/1/deployments/deploy-hook sites/1/webhooks \
    sites/1/heartbeats sites/1/commands/9/output; do
    run "$FORGE_API" GET "$p"
    expect_rc 2
  done
  expect_true "Forge was called" [ "$(calls)" = 0 ]
  run "$FORGE_API" --secret GET sites/1/environment; expect_rc 0
  run "$FORGE_API" --secret GET sites/1/composer/credentials; expect_rc 0
}

t_a_body_reaches_curl_through_a_file() {
  fake_tools; box; answer 200 '{}'
  run "$FORGE_API" PUT sites/1/nginx --write --data '{"config":"server { listen 80; }"}'
  expect_rc 0
  expect_true "the body was on curl's command line" lacks "$(cat "$T/curl.argv")" 'listen 80'
  expect_true "a file was left in TMPDIR" tmp_empty
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

t_a_runner_token_cannot_add_a_header() {
  fake_tools; answer 200 '{}'
  export MROOM_FORGE_ORG=acme MROOM_FORGE_SERVER=42 MROOM_FORGE_TOKEN=$'fake-forge-token-\n0123456789 '
  run "$FORGE_API" GET sites; expect_rc 0
  run cat "$T/curl.log"; expect_out "GET $BASE/sites auth=yes"
  export MROOM_FORGE_TOKEN=$'tok\x01en'
  run "$FORGE_API" GET sites; expect_rc 1; expect_err_has "the Forge token holds characters a token never has"
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

t_a_list_page_without_a_list_or_a_readable_cursor_fails() {
  fake_tools; box; answer 200 '{"message":"Server Error"}'
  lib_run 'forge_list /sites'
  expect_rc 1; expect_out ""; expect_err_has "mroom forge: GET /sites: the answer holds no list"
  reset_answers
  answer 200 '{"data":[],"meta":{"next_cursor":{"not":"a string"}}}'
  lib_run 'forge_list /sites'
  expect_rc 1; expect_err_has "the answer's next page cannot be read"
}

t_a_list_stops_after_too_many_pages() {
  fake_tools; box; answer 200 '{"data":[],"meta":{"next_cursor":"again"}}'
  lib_run 'FORGE_MAX_PAGES=3; forge_list /sites'
  expect_rc 1; expect_err_has "GET /sites: more than 3 pages"
  expect_true "expected 3 calls, got $(calls)" [ "$(calls)" = 3 ]
}

t_a_site_is_found_by_a_plain_name() {
  fake_tools; box
  answer 200 '{"data":[{"id":"5","attributes":{"name":"api.1.qa.example.dev"}},{"id":"6","attributes":{"name":"api.12.qa.example.dev"}}],"meta":{}}'
  lib_run 'forge_site api.1.qa.example.dev'
  expect_rc 0; expect_out '{"id":"5","attributes":{"name":"api.1.qa.example.dev"}}'
  run cat "$T/curl.log"; expect_out "GET $BASE/sites?filter[name]=api.1.qa.example.dev&page[size]=100 auth=yes"
  lib_run "forge_site 'api-#1'"; expect_rc 1; expect_err_has "not a domain"
}

t_the_library_wants_a_path_from_the_root() {
  fake_tools; box; answer 200 '{}'
  lib_run 'forge GET 0/sites'
  expect_rc 1; expect_err_has "a path must start with /"
  expect_true "Forge was called" [ "$(calls)" = 0 ]
}

test_case read-prints-body-token-off-argv t_a_read_prints_the_body_and_keeps_the_token_off_every_command_line
test_case curl-ignores-curlrc t_curl_ignores_curlrc_and_keeps_its_safety_options
test_case 202-and-204 t_202_and_204_answers_succeed
test_case 503-and-502-retries t_a_503_is_retried_for_any_method_and_a_502_only_for_safe_ones
test_case 502-gives-up t_a_502_that_never_clears_fails_after_three_retries
test_case 429-retry-after-and-cap t_a_429_waits_as_long_as_forge_says_and_gives_up_after_three
test_case timeout-read-only t_a_timed_out_read_is_retried_but_never_a_write
test_case http-error-one-line t_an_http_error_fails_with_one_line_and_leaves_nothing
test_case interrupted-call-leaves-nothing t_an_interrupted_call_leaves_nothing_behind
test_case xtrace-never-shows-token t_xtrace_never_shows_the_token
test_case write-needs-flag t_a_write_needs_the_write_flag
test_case path-stays-on-server t_a_path_cannot_leave_the_server_or_reach_it
test_case query-with-brackets t_a_query_with_brackets_is_a_plain_path
test_case secret-paths-need-secret t_paths_that_return_secrets_need_secret_however_they_are_spelled
test_case body-through-file t_a_body_reaches_curl_through_a_file
test_case body-from-stdin t_a_body_can_come_from_stdin
test_case bad-input-refused t_invalid_json_and_a_get_with_a_body_are_refused
test_case token-file-private t_the_token_file_must_be_private
test_case runner-environment t_a_runner_passes_everything_in_the_environment
test_case runner-token-no-header t_a_runner_token_cannot_add_a_header
test_case org-server-plain t_the_org_and_server_must_be_set_and_plain
test_case list-follows-cursors t_a_list_follows_every_cursor
test_case list-bad-page-fails t_a_list_page_without_a_list_or_a_readable_cursor_fails
test_case list-page-cap t_a_list_stops_after_too_many_pages
test_case site-by-name t_a_site_is_found_by_a_plain_name
test_case library-path-from-root t_the_library_wants_a_path_from_the_root
finish
