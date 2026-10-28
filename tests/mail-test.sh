#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2016  # t_* run through test_case; a $ in single quotes is for eval, later
# Tests for the gate's mail operations (mail-user-add, mail-user-remove, mail-read, mail-clear): logins are
# SHA-512 crypt lines in Mailpit's SMTP login file, Mailpit is restarted to read them, a login goes out only
# while mroom's mail relay holds the SMTP port, and only mail whose Username is the environment's login is
# read or deleted. Offline: curl is a fake that plays Mailpit's API on its Unix socket, "mailpit" is a copy
# of perl at the installed path that listens on the SMTP socket, kept running by a loop that plays a daemon
# that starts it again (a copy of sleep may be a multi-call binary that goes by its name), and the relay is
# the real one, listening itself. systemd's root-held socket is tested in CI (tests/mail/gate-real-test.sh).
# tests/mail/gate-real-test.sh runs the real Mailpit in CI.
set -euo pipefail
SUITE=mail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
read -ra MAILPIT_TREE <<<"$(bash -c '. "$1"; echo "${MAILPIT_TREE[*]}"' _ "$ROOT/lib/root-setup")"
stop_all() {
  local f
  for f in "$TOP"/*/up; do rm -f "$f"; done
  for f in "$TOP"/*/pid "$TOP"/*/relay.pid "$TOP"/*/squatter.pid "$TOP"/*/v6.pid; do
    if [ -s "$f" ]; then kill "$(cat "$f")" 2>/dev/null || true; fi
  done
  rm -rf "$TOP"
}
trap stop_all EXIT
skip_unless has_box_tools "this host lacks bash 5, flock or GNU date, which box commands need"

API_PASSWORD=0123456789abcdef0123456789abcdef0123456789abcdef

world() {
  local secrets="$HOME/.config/mroom/secrets" services="$T/services"
  services_tree "${MAILPIT_TREE[@]}"
  mkdir -p "$secrets" "$services/mailpit/builds/v1.32.0" "$T/bin" "$T/api"
  SMTP_PORT=$((20000 + RANDOM % 30000))
  while (exec 3<>"/dev/tcp/127.0.0.1/$SMTP_PORT") 2>/dev/null; do SMTP_PORT=$((SMTP_PORT + 1)); done
  printf 'MROOM_APP_NAME=shop\nMROOM_QA_SMTP_PORT=%s\n' "$SMTP_PORT" >"$HOME/.config/mroom/box.env"
  printf 'MAILPIT_API_USER=mroom-gate\nMAILPIT_API_PASSWORD=%s\n' "$API_PASSWORD" >"$secrets/mailpit.env"
  printf 'mroom-none:$6$x$y\n' >"$services/mailpit/etc/mailpit-smtp.passwd"
  chmod 600 "$secrets/mailpit.env" "$services/mailpit/etc/mailpit-smtp.passwd"
  cp "$(command -v perl)" "$services/mailpit/builds/v1.32.0/mailpit"
  ln -sfn v1.32.0 "$services/mailpit/builds/current"
  install -m 700 "$ROOT/lib/mail-relay" "$services/mail-relay/bin/mail-relay"
  cat >"$T/bin/curl" <<'FAKE'
#!/usr/bin/env bash
# Plays Mailpit's API, which listens only on its Unix socket. Insists on the gate's login on stdin, never on
# the command line; logs every command line to $T/curl.argv. Answers searches from $T/api/search-<start>.json,
# messages from $T/api/message-<ID>.json, and records each DELETE's body in $T/deleted. /livez fails while
# $T/api/no-live exists.
printf '%s\n' "$*" >>"$T/curl.argv"
method=GET body="" write="" socket="" url="${!#}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --request) method="$2"; shift 2 ;;
    --data-binary) body="$2"; shift 2 ;;
    --write-out) write="$2"; shift 2 ;;
    --unix-socket) socket="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [ "$socket" != "$T/services/mailpit/run/http.sock" ]; then
  echo "curl: (7) Couldn't connect to server" >&2; exit 7
fi
path="${url#http://localhost}"
if [ "$path" = /livez ]; then
  if [ -e "$T/api/no-live" ]; then echo "curl: (7) Couldn't connect to server" >&2; exit 7; fi
  if [ -n "$write" ]; then printf 200; fi
  exit 0
fi
header="$(cat)"
want="Authorization: Basic $(printf 'mroom-gate:%s' "$API_PASSWORD" | base64 -w0)"
if [ "$header" != "$want" ] || [ -e "$T/api/refuse" ]; then
  echo "curl: (22) The requested URL returned error: 401" >&2; exit 22
fi
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
  export T PATH="$T/bin:$PATH" API_PASSWORD MROOM_GATE_RESTART_WAIT=10
}

# The stand-in Mailpit: listens on the SMTP socket unless $T/no-smtp exists, and sleeps. Like Mailpit, it
# removes a socket left from before.
STAND_IN='use IO::Socket::UNIX;
my $path = "$ENV{T}/services/mailpit/run/smtp.sock";
unless (-e "$ENV{T}/no-smtp") {
  unlink $path;
  $smtp = IO::Socket::UNIX->new(Local => $path, Listen => 5) or die "listen: $!";
}
sleep 600;'

# mailpit_up: a loop that plays Forge's daemon, starting "mailpit" again whenever it stops.
mailpit_up() {
  local bin="$T/services/mailpit/builds/current/mailpit"
  : >"$T/up"
  # wait fails when the gate stops "mailpit", which set -e would take for the loop's own failure.
  (while [ -e "$T/up" ]; do "$bin" -e "$STAND_IN" & echo $! >"$T/pid"; wait $! || true; sleep 0.05; done) >/dev/null 2>&1 &
  for _ in $(seq 1 40); do [ -s "$T/pid" ] && return 0; sleep 0.05; done
}
mailpit_down() { rm -f "$T/up"; [ -s "$T/pid" ] && kill "$(cat "$T/pid")" 2>/dev/null; sleep 0.2; }

listening() { (exec 3<>"/dev/tcp/${1:-127.0.0.1}/${2:-$SMTP_PORT}") 2>/dev/null; }
# wait_listening [<address> [<port>]]
wait_listening() {
  for _ in $(seq 1 50); do if listening "$@"; then return 0; fi; sleep 0.1; done
  echo "nothing came to listen on ${1:-127.0.0.1}:${2:-$SMTP_PORT}" >&2
  return 1
}
# relay_up [<port>]: mroom's mail relay, run as its systemd unit runs it, but listening itself.
relay_up() {
  local services="$T/services" port="${1:-$SMTP_PORT}"
  python3 -I "$services/mail-relay/bin/mail-relay" 127.0.0.1 "$port" "$services/mailpit/run/smtp.sock" >"$T/relay.log" 2>&1 &
  echo $! >"$T/relay.pid"
  wait_listening 127.0.0.1 "$port" || { cat "$T/relay.log" >&2; return 1; }
}
# squat [<address>]: a program that is not the relay, listening on the SMTP port at 127.0.0.1 or the address.
squat() {
  mkdir -p "$T/other"
  cp "$(command -v perl)" "$T/other/squatter"
  "$T/other/squatter" -MIO::Socket::INET -e 'my $port = IO::Socket::INET->new(LocalAddr => $ARGV[1],
    LocalPort => $ARGV[0], Listen => 5, ReuseAddr => 1) or die "listen: $!"; sleep 600' "$SMTP_PORT" "${1:-127.0.0.1}" >/dev/null 2>&1 &
  echo $! >"$T/squatter.pid"
  wait_listening "${1:-127.0.0.1}"
}
free_port() {
  local port=$((20000 + RANDOM % 30000))
  while (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null || [ "$port" = "$SMTP_PORT" ]; do port=$((port + 1)); done
  echo "$port"
}
stop_pid_file() { if [ -s "$1" ]; then kill "$(cat "$1")" 2>/dev/null || true; rm -f "$1"; fi; sleep 0.2; }

gate() { run env SSH_ORIGINAL_COMMAND="$1" "$MROOM" gate provision; }
logins() { cat "$T/services/mailpit/etc/mailpit-smtp.passwd"; }
gate_log_text() { cat "$HOME/.local/state/mroom/gate.log" 2>/dev/null || true; }
# hash_of <password> <hash>: whether the SHA-512 crypt hash is of the password.
hash_of() { [ "$(printf '%s' "$1" | openssl passwd -6 -salt "$(cut -d'$' -f3 <<<"$2")" -stdin)" = "$2" ]; }
hex48() { [[ "$1" =~ ^[0-9a-f]{48}$ ]]; }
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
lacks() { ! has "$@"; }
at_least() { [ "$1" -ge "$2" ]; }
now_ms() { date +%s%3N; }

# summary <ID> <Username> <To address> [<Cc address>] [<Bcc address>]: one search result.
summary() {
  jq -nc --arg id "$1" --arg u "$2" --arg to "$3" --arg cc "${4-}" --arg bcc "${5-}" \
    '{ID: $id, Username: $u, To: [{Address: $to}], Tags: [$u],
      Cc: (if $cc == "" then null else [{Address: $cc}] end), Bcc: (if $bcc == "" then null else [{Address: $bcc}] end)}'
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
  world; relay_up; mailpit_up
  local before after password hash started
  before="$(cat "$T/pid")"
  started=$(now_ms)
  gate "mail-user-add 12"
  expect_rc 0
  expect_out_has $'MAIL_MAILER=smtp\nMAIL_HOST=127.0.0.1\nMAIL_PORT='"$SMTP_PORT"$'\nMAIL_USERNAME=shop_qa_12\nMAIL_PASSWORD='
  # Forge's daemon counts a Mailpit stopped within a second of starting as a failed start.
  expect_true "the gate stopped a Mailpit that had just started" at_least $(($(now_ms) - started)) 2500
  password="$(sed -n 's/^MAIL_PASSWORD=//p' <<<"$out")"
  expect_true "the password is not 48 hex characters" hex48 "$password"
  hash="$(sed -n 's/^shop_qa_12://p' "$T/services/mailpit/etc/mailpit-smtp.passwd")"
  expect_true "the login's hash is not of the password" hash_of "$password" "$hash"
  expect_true "the placeholder login went" has "$(logins)" 'mroom-none:$6$x$y'
  after="$(cat "$T/pid")"
  expect_true "Mailpit was not restarted" [ "$before" != "$after" ]
  expect_true "the password reached a command line" lacks "$(cat "$T/curl.argv" 2>/dev/null)" "$password"
  expect_true "the API password reached a command line" lacks "$(cat "$T/curl.argv" 2>/dev/null)" "$API_PASSWORD"
  expect_true "the password reached the gate log" lacks "$(gate_log_text)" "$password"
  run stat -c %a "$T/services/mailpit/etc/mailpit-smtp.passwd"; expect_out 600
  # --rotate: a new password, and a restart, which waits for the Mailpit started a moment ago.
  started=$(now_ms)
  gate "mail-user-add 12 --rotate"; expect_rc 0
  expect_true "--rotate kept the password" lacks "$out" "$password"
  password="$(sed -n 's/^MAIL_PASSWORD=//p' <<<"$out")"
  expect_true "the second restart came within a second of the first" at_least $(($(now_ms) - started)) 2000
  expect_true "a new login did not restart Mailpit" [ "$(cat "$T/pid")" != "$after" ]
  after="$(cat "$T/pid")"
  hash="$(sed -n 's/^shop_qa_12://p' "$T/services/mailpit/etc/mailpit-smtp.passwd")"
  # The same login again, with the same password: the file is as it was, so Mailpit keeps running.
  gate "mail-user-add 12"; expect_rc 0
  expect_out_has "MAIL_PASSWORD=$password"
  expect_true "an unchanged login restarted Mailpit" [ "$(cat "$T/pid")" = "$after" ]
  run sed -n 's/^shop_qa_12://p' "$T/services/mailpit/etc/mailpit-smtp.passwd"; expect_out "$hash"
  run grep -c '^shop_qa_12:' "$T/services/mailpit/etc/mailpit-smtp.passwd"; expect_out 1
  run bash -c 'compgen -G "$1/.mailpit-smtp.*" || true' _ "$T/services/mailpit/etc"; expect_out ""
  mailpit_down
}

t_mail_user_remove_takes_the_login_away() {
  world; relay_up; mailpit_up
  gate "mail-user-add 12"; expect_rc 0
  gate "mail-user-add 13"; expect_rc 0
  local before
  gate "mail-user-remove 12"; expect_rc 0; expect_out "mail user shop_qa_12: removed"
  expect_true "the teardown kept the password" lacks "$(cat "$HOME/.local/state/mroom/qa/shop_qa_12.secrets" 2>/dev/null)" "MAIL_PASSWORD"
  expect_true "the login stayed" lacks "$(logins)" "shop_qa_12:"
  expect_true "another environment's login went" has "$(logins)" "shop_qa_13:"
  expect_true "the placeholder login went" has "$(logins)" "mroom-none:"
  # Nothing to remove: no restart.
  before="$(cat "$T/pid")"
  gate "mail-user-remove 12"; expect_rc 0
  expect_true "Mailpit was restarted for nothing" [ "$before" = "$(cat "$T/pid")" ]
  mailpit_down
}

t_a_login_goes_out_only_while_the_relay_holds_the_port() {
  world; mailpit_up
  local before
  before="$(cat "$T/pid")"
  gate "mail-user-add 12"
  expect_rc 1; expect_err_has "nothing listens on 127.0.0.1:$SMTP_PORT; check mroom-mail-relay.socket"
  # Something else on the port would be sent every app's login: no login goes out, and nothing changes,
  # also while a relay runs, on another port.
  relay_up "$(free_port)"
  squat
  gate "mail-user-add 12"
  expect_rc 1; expect_err_has "something other than mroom's mail relay listens on port $SMTP_PORT"
  expect_true "a password went out" lacks "$out" "MAIL_PASSWORD"
  expect_true "a refused request changed the logins" lacks "$(logins)" "shop_qa_12:"
  expect_true "a refused request restarted Mailpit" [ "$before" = "$(cat "$T/pid")" ]
  stop_pid_file "$T/squatter.pid"
  # One on every address would get apps' mail as well.
  squat 0.0.0.0
  gate "mail-user-add 12"
  expect_rc 1; expect_err_has "something listens on every address at port $SMTP_PORT"
  stop_pid_file "$T/squatter.pid"
  stop_pid_file "$T/relay.pid"
  # A listener at another address of the loopback, or a v6only one at ::, never sees what apps send to
  # 127.0.0.1, and blocks nothing.
  squat 127.0.0.2
  relay_up
  # (Where the box has no IPv6, the v6only listener cannot start, and the request passes all the same.)
  python3 -I -c 'import socket, sys, time
s = socket.socket(socket.AF_INET6); s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
s.bind(("::", int(sys.argv[1]))); s.listen(1); print("up", flush=True); time.sleep(600)' "$SMTP_PORT" >"$T/v6.out" 2>/dev/null &
  echo $! >"$T/v6.pid"
  sleep 0.5
  gate "mail-user-add 12"; expect_rc 0; expect_out_has "MAIL_USERNAME=shop_qa_12"
  stop_pid_file "$T/v6.pid"
  mailpit_down
}

t_a_mailpit_that_is_down_or_stays_down_fails_the_request() {
  world; relay_up
  # A program called mailpit that was not installed by mroom baseline is not Mailpit.
  mkdir -p "$T/other"
  cp "$(command -v perl)" "$T/other/mailpit"
  "$T/other/mailpit" -e 'sleep 600' &
  local impostor=$!
  gate "mail-user-add 12"; expect_rc 1; expect_err_has "Mailpit is not running; check mroom-mailpit.service"
  expect_true "a refused request changed the logins" lacks "$(logins)" "shop_qa_12:"
  expect_true "the gate stopped a program it did not install" kill -0 "$impostor"
  kill "$impostor" 2>/dev/null || true
  # Running once, but nothing starts it again.
  "$T/services/mailpit/builds/current/mailpit" -e "$STAND_IN" &
  local lone=$!
  MROOM_GATE_RESTART_WAIT=3 gate "mail-user-add 12"
  expect_rc 1; expect_err_has "Mailpit did not come back within 3 seconds of a restart"
  expect_true "the credentials were printed" lacks "$out" "MAIL_PASSWORD"
  kill "$lone" 2>/dev/null || true
  # Back, but not taking SMTP connections, or not answering on HTTP: not back.
  : >"$T/no-smtp"
  mailpit_up
  MROOM_GATE_RESTART_WAIT=3 gate "mail-user-add 12"
  expect_rc 1; expect_err_has "Mailpit did not come back within 3 seconds"
  rm "$T/no-smtp"
  : >"$T/api/no-live"
  MROOM_GATE_RESTART_WAIT=3 gate "mail-user-add 12"
  expect_rc 1; expect_err_has "Mailpit did not come back within 3 seconds"
  mailpit_down
}

t_a_restart_starts_the_current_build() {
  world; relay_up
  local services="$T/services/mailpit/builds"
  mailpit_up
  mkdir -p "$services/v1.33.0"
  cp "$(command -v perl)" "$services/v1.33.0/mailpit"
  ln -sfn v1.33.0 "$services/current"
  run readlink "/proc/$(cat "$T/pid")/exe"; expect_out "$(readlink -f "$services/v1.32.0/mailpit")"
  gate "mail-user-add 12"; expect_rc 0
  run readlink "/proc/$(cat "$T/pid")/exe"; expect_out "$(readlink -f "$services/v1.33.0/mailpit")"
  mailpit_down
}

t_a_login_file_that_cannot_be_written_is_left_as_it_was() {
  world; relay_up; mailpit_up
  local secrets="$T/services/mailpit/etc" before text
  before="$(cat "$T/pid")"
  text="$(logins)"
  chmod 500 "$secrets"
  gate "mail-user-add 12"
  chmod 700 "$secrets"
  expect_rc 1; expect_err_has "could not write $T/services/mailpit/etc/mailpit-smtp.passwd, which is unchanged"
  expect_true "a password went out" lacks "$out" "MAIL_PASSWORD"
  run logins; expect_out "$text"
  expect_true "Mailpit was restarted for a login it does not have" [ "$before" = "$(cat "$T/pid")" ]
  # Without the login no one knows, removing the last login would leave the file empty, which Mailpit takes
  # as "no login needed".
  printf 'shop_qa_7:$6$a$b\n' >"$secrets/mailpit-smtp.passwd"
  gate "mail-user-remove 7"
  expect_rc 1; expect_err_has "mailpit-smtp.passwd has lost its mroom-none line; run mroom baseline mailpit"
  run logins; expect_out 'shop_qa_7:$6$a$b'
  gate "mail-user-add 12"; expect_rc 1; expect_err_has "has lost its mroom-none line"
  mailpit_down
}

t_mail_read_returns_only_the_environments_mail_to_the_address() {
  world
  search 0 "$(summary a1 shop_qa_12 ada@example.test)" "$(summary a2 shop_qa_13 ada@example.test)" \
    "$(summary a3 shop_qa_12 bob@example.test)" "$(summary ../x shop_qa_12 ada@example.test)" \
    "$(summary a4 shop_qa_12 ADA@EXAMPLE.TEST)" "$(summary a5 shop_qa_12 carol@example.test ada@example.test)" \
    "$(summary a6 shop_qa_12 someone@customer.example ada@example.test)" \
    "$(summary a7 shop_qa_12 carol@example.test "" ada@example.test)"
  message a1 ada@example.test "Your link: https://example.test/reset/1"
  message a4 ada@example.test "$(head -c 40000 /dev/zero | tr '\0' x)"
  message a5 carol@example.test "Copied in"
  message a7 carol@example.test "Blind copy"
  gate "mail-read 12 ada@example.test"
  expect_rc 0
  # A mail that also went to someone who is not a persona is never shown.
  run jq -r '[.[].id] | join(" ")' <<<"$out"; expect_out "a1 a4 a5 a7"
  gate "mail-read 12 ada@example.test"
  run jq -r '.[0] | [.from, (.to | join(",")), .subject, .text] | join("|")' <<<"$out"
  expect_out "app@example.test|ada@example.test|Reset|Your link: https://example.test/reset/1"
  gate "mail-read 12 ada@example.test"
  run jq -r '.[1].text | length' <<<"$out"; expect_out 32768
  gate "mail-read 12 ada@example.test"
  expect_true "the HTML came along" eval '! jq -e ".[0].HTML or .[0].html" <<<"$out" >/dev/null'
  run grep -c 'message/' "$T/curl.argv"; expect_out 16
  gate "mail-read 12 nobody@example.test"; expect_rc 0; expect_out '[]'
  gate "mail-read 12 someone@customer.example"; expect_rc 1; expect_err_has "not a persona address ending in .test"
  expect_true "a refused address reached the log" lacks "$(gate_log_text)" "customer.example"
}

t_mail_read_shows_the_newest_five_and_stops_looking() {
  world
  local i page=()
  for i in $(seq 1 500); do page+=("$(summary "m$i" shop_qa_12 ada@example.test)"); done
  search 0 "${page[@]}"
  search 500 "$(summary n1 shop_qa_12 ada@example.test)"
  for i in 1 2 3 4 5; do message "m$i" ada@example.test "mail $i"; done
  gate "mail-read 12 ada@example.test"
  expect_rc 0
  run jq -r '[.[].id] | join(" ")' <<<"$out"; expect_out "m1 m2 m3 m4 m5"
  run grep -c 'start=500' "$T/curl.argv"; expect_out 0
  run grep -c 'message/' "$T/curl.argv"; expect_out 5
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

t_the_api_login_must_be_in_place() {
  world
  local secrets="$HOME/.config/mroom/secrets"
  : >"$T/api/refuse"
  gate "mail-read 12 ada@example.test"; expect_rc 1; expect_err_has "mail-read 12: curl: (22) The requested URL returned error: 401"
  rm "$T/api/refuse"
  printf 'MAILPIT_API_USER=mroom-gate\n' >"$secrets/mailpit.env"
  gate "mail-clear 12"; expect_rc 1; expect_err_has "must set MAILPIT_API_USER and MAILPIT_API_PASSWORD"
  chmod 644 "$secrets/mailpit.env"
  gate "mail-clear 12"; expect_rc 1; expect_err_has "mailpit.env must be yours and mode 600"
  rm "$secrets/mailpit.env"
  gate "mail-clear 12"; expect_rc 1; expect_err_has "mailpit.env is missing; run mroom baseline mailpit"
}

test_case mail-user-add t_mail_user_add_gives_the_environment_a_login_and_restarts_mailpit
test_case mail-user-remove t_mail_user_remove_takes_the_login_away
test_case relay t_a_login_goes_out_only_while_the_relay_holds_the_port
test_case mailpit-down t_a_mailpit_that_is_down_or_stays_down_fails_the_request
test_case current-build t_a_restart_starts_the_current_build
test_case unwritable t_a_login_file_that_cannot_be_written_is_left_as_it_was
test_case mail-read t_mail_read_returns_only_the_environments_mail_to_the_address
test_case newest-five t_mail_read_shows_the_newest_five_and_stops_looking
test_case mail-clear t_mail_clear_deletes_only_the_environments_mail
test_case api-login t_the_api_login_must_be_in_place
finish
