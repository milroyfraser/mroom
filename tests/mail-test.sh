#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2016  # t_* run through test_case; a $ in single quotes is for eval, later
# Tests for the gate's mail operations (mail-user-add, mail-user-remove, mail-read, mail-clear): logins are
# SHA-512 crypt lines in Mailpit's SMTP login file, Mailpit is restarted to read them, and only mail whose
# Username is the environment's login is read or deleted. Offline: curl is a fake that plays Mailpit's API,
# and "mailpit" is a copy of perl at the installed path that listens on a free port for SMTP, kept running by
# a loop that plays Forge's daemon (a copy of sleep may be a multi-call binary that goes by its name).
# tests/mail/gate-real-test.sh runs the real Mailpit in CI.
set -euo pipefail
SUITE=mail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
stop_all() {
  local f
  for f in "$TOP"/*/up; do rm -f "$f"; done
  for f in "$TOP"/*/pid; do if [ -s "$f" ]; then kill "$(cat "$f")" 2>/dev/null || true; fi; done
  rm -rf "$TOP"
}
trap stop_all EXIT
skip_unless has_box_tools "this host lacks bash 5, flock or GNU date, which box commands need"

API_PASSWORD=0123456789abcdef0123456789abcdef0123456789abcdef

world() {
  local secrets="$HOME/.config/mroom/secrets" bin="$HOME/.local/share/mroom-services/mailpit/v1.32.0"
  mkdir -p "$secrets" "$bin" "$T/bin" "$T/api"
  printf 'MROOM_APP_NAME=shop\n' >"$HOME/.config/mroom/box.env"
  SMTP_PORT=$((20000 + RANDOM % 30000))
  while (exec 3<>"/dev/tcp/127.0.0.1/$SMTP_PORT") 2>/dev/null; do SMTP_PORT=$((SMTP_PORT + 1)); done
  printf 'MAILPIT_API_USER=mroom-gate\nMAILPIT_API_PASSWORD=%s\nMAILPIT_SMTP_PORT=%s\n' "$API_PASSWORD" "$SMTP_PORT" >"$secrets/mailpit.env"
  printf 'mroom-none:$6$x$y\n' >"$secrets/mailpit-smtp.passwd"
  chmod 600 "$secrets/mailpit.env" "$secrets/mailpit-smtp.passwd"
  cp "$(command -v perl)" "$bin/mailpit"
  ln -sfn v1.32.0 "$HOME/.local/share/mroom-services/mailpit/current"
  cat >"$T/bin/curl" <<'FAKE'
#!/usr/bin/env bash
# Plays Mailpit's API. Insists on the gate's login on stdin, never on the command line; logs every command
# line to $T/curl.argv. Answers searches from $T/api/search-<start>.json, messages from
# $T/api/message-<ID>.json, and records each DELETE's body in $T/deleted.
printf '%s\n' "$*" >>"$T/curl.argv"
method=GET body="" write="" url="${!#}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --request) method="$2"; shift 2 ;;
    --data-binary) body="$2"; shift 2 ;;
    --write-out) write="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [[ "$url" == */livez ]]; then [ -n "$write" ] && printf 200; exit 0; fi
header="$(cat)"
want="Authorization: Basic $(printf 'mroom-gate:%s' "$API_PASSWORD" | base64 -w0)"
if [ "$header" != "$want" ] || [ -e "$T/api/refuse" ]; then
  echo "curl: (22) The requested URL returned error: 401" >&2; exit 22
fi
path="${url#http://127.0.0.1:8025}"
case "$method $path" in
  "GET /api/v1/search?"*)
    start="$(sed -n 's/.*[?&]start=\([0-9]*\).*/\1/p' <<<"$path")"
    cat "$T/api/search-$start.json" 2>/dev/null || echo '{"messages": []}' ;;
  "GET /api/v1/message/"*)
    cat "$T/api/message-${path##*/}.json" 2>/dev/null || { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; } ;;
  "DELETE /api/v1/messages") printf '%s\n' "$body" >>"$T/deleted"; echo ok ;;
  *) echo "curl: (22) The requested URL returned error: 404" >&2; exit 22 ;;
esac
FAKE
  printf '#!/bin/sh\necho "$*" >>"$T/syslog"\n' >"$T/bin/logger"
  chmod +x "$T/bin/curl" "$T/bin/logger"
  export T PATH="$T/bin:$PATH" API_PASSWORD SMTP_PORT MROOM_GATE_RESTART_WAIT=40
}

# The stand-in Mailpit: listens for SMTP on $SMTP_PORT unless $T/no-smtp exists, and sleeps.
STAND_IN='unless (-e "$ENV{T}/no-smtp") {
  $smtp = IO::Socket::INET->new(LocalAddr => "127.0.0.1", LocalPort => $ENV{SMTP_PORT}, Listen => 5, ReuseAddr => 1)
    or die "listen: $!";
}
sleep 600;'

# mailpit_up: a loop that plays Forge's daemon, starting "mailpit" again whenever it stops.
mailpit_up() {
  local bin="$HOME/.local/share/mroom-services/mailpit/current/mailpit"
  : >"$T/up"
  # wait fails when the gate stops "mailpit", which set -e would take for the loop's own failure.
  (while [ -e "$T/up" ]; do "$bin" -MIO::Socket::INET -e "$STAND_IN" & echo $! >"$T/pid"; wait $! || true; sleep 0.05; done) >/dev/null 2>&1 &
  for _ in $(seq 1 40); do [ -s "$T/pid" ] && return 0; sleep 0.05; done
}
mailpit_down() { rm -f "$T/up"; [ -s "$T/pid" ] && kill "$(cat "$T/pid")" 2>/dev/null; sleep 0.2; }

gate() { run env SSH_ORIGINAL_COMMAND="$1" "$MROOM" gate provision; }
logins() { cat "$HOME/.config/mroom/secrets/mailpit-smtp.passwd"; }
gate_log_text() { cat "$HOME/.local/state/mroom/gate.log" 2>/dev/null || true; }
# hash_of <password> <hash>: whether the SHA-512 crypt hash is of the password.
hash_of() { [ "$(printf '%s' "$1" | openssl passwd -6 -salt "$(cut -d'$' -f3 <<<"$2")" -stdin)" = "$2" ]; }
hex48() { [[ "$1" =~ ^[0-9a-f]{48}$ ]]; }
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
lacks() { ! has "$@"; }

# summary <ID> <Username> <To address> [<Cc address>]: one search result.
summary() {
  jq -nc --arg id "$1" --arg u "$2" --arg to "$3" --arg cc "${4-}" \
    '{ID: $id, Username: $u, To: [{Address: $to}], Cc: (if $cc == "" then null else [{Address: $cc}] end), Tags: [$u]}'
}
# search <start> <summary>...: a search page.
search() { local start="$1"; shift; printf '%s\n' "$@" | jq -s '{messages: .}' >"$T/api/search-$start.json"; }
# message <ID> <to> <text>: a whole mail.
message() {
  jq -n --arg id "$1" --arg to "$2" --arg text "$3" \
    '{ID: $id, Date: "2026-10-26T12:00:00Z", From: {Address: "app@example.test"}, To: [{Address: $to}], Subject: "Reset", Text: $text, HTML: "<p>x</p>", Username: "shop_qa_12"}' \
    >"$T/api/message-$1.json"
}

t_mail_user_add_gives_the_environment_a_login_and_restarts_mailpit() {
  world; mailpit_up
  local before after password hash
  before="$(cat "$T/pid")"
  gate "mail-user-add 12"
  expect_rc 0
  expect_out_has $'MAIL_MAILER=smtp\nMAIL_HOST=127.0.0.1\nMAIL_PORT='"$SMTP_PORT"$'\nMAIL_USERNAME=shop_qa_12\nMAIL_PASSWORD='
  password="$(sed -n 's/^MAIL_PASSWORD=//p' <<<"$out")"
  expect_true "the password is not 48 hex characters" hex48 "$password"
  hash="$(sed -n 's/^shop_qa_12://p' "$HOME/.config/mroom/secrets/mailpit-smtp.passwd")"
  expect_true "the login's hash is not of the password" hash_of "$password" "$hash"
  expect_true "the placeholder login went" has "$(logins)" 'mroom-none:$6$x$y'
  after="$(cat "$T/pid")"
  expect_true "Mailpit was not restarted" [ "$before" != "$after" ]
  expect_true "the password reached a command line" lacks "$(cat "$T/curl.argv" 2>/dev/null)" "$password"
  expect_true "the API password reached a command line" lacks "$(cat "$T/curl.argv" 2>/dev/null)" "$API_PASSWORD"
  expect_true "the password reached the gate log" lacks "$(gate_log_text)" "$password"
  run stat -c %a "$HOME/.config/mroom/secrets/mailpit-smtp.passwd"; expect_out 600
  gate "mail-user-add 12"; expect_rc 0
  run grep -c '^shop_qa_12:' "$HOME/.config/mroom/secrets/mailpit-smtp.passwd"; expect_out 1
  mailpit_down
}

t_mail_user_remove_takes_the_login_away() {
  world; mailpit_up
  gate "mail-user-add 12"; expect_rc 0
  gate "mail-user-add 13"; expect_rc 0
  local before
  gate "mail-user-remove 12"; expect_rc 0; expect_out "mail user shop_qa_12: removed"
  expect_true "the login stayed" lacks "$(logins)" "shop_qa_12:"
  expect_true "another environment's login went" has "$(logins)" "shop_qa_13:"
  expect_true "the placeholder login went" has "$(logins)" "mroom-none:"
  # Nothing to remove: no restart.
  before="$(cat "$T/pid")"
  gate "mail-user-remove 12"; expect_rc 0
  expect_true "Mailpit was restarted for nothing" [ "$before" = "$(cat "$T/pid")" ]
  mailpit_down
}

t_a_mailpit_that_is_down_or_stays_down_fails_the_request() {
  world
  # A program called mailpit that was not installed by mroom baseline is not Mailpit.
  mkdir -p "$T/other"
  cp "$(command -v perl)" "$T/other/mailpit"
  "$T/other/mailpit" -e 'sleep 600' &
  local impostor=$!
  gate "mail-user-add 12"; expect_rc 1; expect_err_has "Mailpit is not running; create its daemon"
  expect_true "a refused request changed the logins" lacks "$(logins)" "shop_qa_12:"
  expect_true "the gate stopped a program it did not install" kill -0 "$impostor"
  kill "$impostor" 2>/dev/null || true
  # Running once, but nothing starts it again.
  "$HOME/.local/share/mroom-services/mailpit/current/mailpit" -e 'sleep 600' &
  local lone=$!
  MROOM_GATE_RESTART_WAIT=4 gate "mail-user-add 12"
  expect_rc 1; expect_err_has "Mailpit did not come back within 30 seconds"
  expect_true "the credentials were printed" lacks "$out" "MAIL_PASSWORD"
  kill "$lone" 2>/dev/null || true
  # Back on HTTP, but not taking SMTP connections: not back.
  : >"$T/no-smtp"
  mailpit_up
  MROOM_GATE_RESTART_WAIT=4 gate "mail-user-add 12"
  expect_rc 1; expect_err_has "Mailpit did not come back within 30 seconds"
  mailpit_down
}

t_a_restart_starts_the_current_build() {
  world
  local services="$HOME/.local/share/mroom-services/mailpit"
  mailpit_up
  mkdir -p "$services/v1.33.0"
  cp "$(command -v perl)" "$services/v1.33.0/mailpit"
  ln -sfn v1.33.0 "$services/current"
  run readlink "/proc/$(cat "$T/pid")/exe"; expect_out "$(readlink -f "$services/v1.32.0/mailpit")"
  gate "mail-user-add 12"; expect_rc 0
  run readlink "/proc/$(cat "$T/pid")/exe"; expect_out "$(readlink -f "$services/v1.33.0/mailpit")"
  mailpit_down
}

t_mail_read_returns_only_the_environments_mail_to_the_address() {
  world
  search 0 "$(summary a1 shop_qa_12 ada@example.test)" "$(summary a2 shop_qa_13 ada@example.test)" \
    "$(summary a3 shop_qa_12 bob@example.test)" "$(summary ../x shop_qa_12 ada@example.test)" \
    "$(summary a4 shop_qa_12 ADA@EXAMPLE.TEST)" "$(summary a5 shop_qa_12 carol@example.test ada@example.test)"
  message a1 ada@example.test "Your link: https://example.test/reset/1"
  message a5 carol@example.test "Copied in"
  message a4 ada@example.test "$(head -c 40000 /dev/zero | tr '\0' x)"
  gate "mail-read 12 ada@example.test"
  expect_rc 0
  run jq -r '[.[].id] | join(" ")' <<<"$out"; expect_out "a1 a4 a5"
  gate "mail-read 12 ada@example.test"
  run jq -r '.[0] | [.from, (.to | join(",")), .subject, .text] | join("|")' <<<"$out"
  expect_out "app@example.test|ada@example.test|Reset|Your link: https://example.test/reset/1"
  gate "mail-read 12 ada@example.test"
  run jq -r '.[1].text | length' <<<"$out"; expect_out 32768
  gate "mail-read 12 ada@example.test"
  expect_true "the HTML came along" eval '! jq -e ".[0].HTML or .[0].html" <<<"$out" >/dev/null'
  run grep -c 'message/' "$T/curl.argv"; expect_out 12
  gate "mail-read 12 nobody@example.test"; expect_rc 0; expect_out '[]'
  gate "mail-read 12 someone@customer.example"; expect_rc 1; expect_err_has "not a persona address ending in .test"
  expect_true "a refused address reached the log" lacks "$(gate_log_text)" "customer.example"
}

t_mail_clear_deletes_only_the_environments_mail() {
  world
  local i page=()
  for i in $(seq 1 500); do page+=("$(summary "m$i" shop_qa_12 ada@example.test)"); done
  search 0 "${page[@]}"
  search 500 "$(summary n1 shop_qa_12 bob@example.test)" "$(summary n2 shop_qa_13 ada@example.test)" "$(summary n3 shop_qa_12 x@example.test)"
  gate "mail-clear 12"
  expect_rc 0; expect_out "mail of shop_qa_12: 502 deleted"
  run wc -l <"$T/deleted"; expect_out 2
  run jq -s '.[0].IDs | length' "$T/deleted"; expect_out 500
  run jq -sc '.[1].IDs' "$T/deleted"; expect_out '["n1","n3"]'
  expect_true "another environment's mail was deleted" eval '! jq -e "[.IDs[]] | index(\"n2\")" "$T/deleted" >/dev/null'
  rm -f "$T"/api/search-*.json "$T/deleted"
  gate "mail-clear 12"; expect_rc 0; expect_out "mail of shop_qa_12: 0 deleted"
  expect_no_file "$T/deleted"
}

t_the_api_login_and_settings_must_be_in_place() {
  world
  local secrets="$HOME/.config/mroom/secrets"
  : >"$T/api/refuse"
  gate "mail-read 12 ada@example.test"; expect_rc 1; expect_err_has "mail-read 12: curl: (22) The requested URL returned error: 401"
  rm "$T/api/refuse"
  printf 'MAILPIT_API_USER=mroom-gate\nMAILPIT_API_PASSWORD=x\nMAILPIT_API_URL=http://mail.example.dev\n' >"$secrets/mailpit.env"
  gate "mail-clear 12"; expect_rc 1; expect_err_has "MAILPIT_API_URL must be http://127.0.0.1:<port>"
  printf 'MAILPIT_API_USER=mroom-gate\n' >"$secrets/mailpit.env"
  gate "mail-clear 12"; expect_rc 1; expect_err_has "must set MAILPIT_API_USER and MAILPIT_API_PASSWORD"
  chmod 644 "$secrets/mailpit.env"
  gate "mail-clear 12"; expect_rc 1; expect_err_has "mailpit.env must be yours and mode 600"
  rm "$secrets/mailpit.env"
  gate "mail-clear 12"; expect_rc 1; expect_err_has "mailpit.env is missing; run mroom baseline mailpit"
}

test_case mail-user-add t_mail_user_add_gives_the_environment_a_login_and_restarts_mailpit
test_case mail-user-remove t_mail_user_remove_takes_the_login_away
test_case mailpit-down t_a_mailpit_that_is_down_or_stays_down_fails_the_request
test_case current-build t_a_restart_starts_the_current_build
test_case mail-read t_mail_read_returns_only_the_environments_mail_to_the_address
test_case mail-clear t_mail_clear_deletes_only_the_environments_mail
test_case api-login t_the_api_login_and_settings_must_be_in_place
finish
