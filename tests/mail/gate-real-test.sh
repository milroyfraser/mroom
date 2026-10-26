#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2016  # t_* run through test_case; a $ in single quotes is for eval, later
# The gate's mail operations against the real Mailpit: what a fake API cannot show. mroom baseline mailpit
# downloads the pinned build and checks its SHA-256; a loop that plays Forge's daemon runs the command it
# prints. Each environment sends with its own login, unauthenticated or forged mail gets nowhere, mail-read
# returns only an environment's own mail, mail-clear deletes only it, and a removed login stops working.
# CI only: it downloads Mailpit, so tests/run.sh does not pick it up.
set -euo pipefail
SUITE=mail-real
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

cleanup() {
  local f
  for f in "$TOP"/*/up; do rm -f "$f"; done
  for f in "$TOP"/*/pid; do if [ -s "$f" ]; then kill "$(cat "$f")" 2>/dev/null || true; fi; done
  rm -rf "$TOP"
}
trap cleanup EXIT

gate() { run env SSH_ORIGINAL_COMMAND="$1" "$MROOM" gate provision; }
field() { sed -n "s/^$1=//p" <<<"$2"; }

# send <user|-> <password> <to> <subject> [<X-Tags>]: one mail over SMTP; fails when Mailpit refuses it.
send() {
  python3 - "$@" <<'PY'
import smtplib, sys
user, password, to, subject = sys.argv[1:5]
xtags = sys.argv[5] if len(sys.argv) > 5 else ""
msg = (f"From: app@example.test\r\nTo: {to}\r\nSubject: {subject}\r\n"
       + (f"X-Tags: {xtags}\r\n" if xtags else "")
       + f"\r\nYour link: https://example.test/reset/{subject}\r\n")
with smtplib.SMTP("127.0.0.1", 1025, timeout=10) as smtp:
    if user != "-":
        smtp.login(user, password)
    smtp.sendmail("app@example.test", [to], msg)
PY
}
can_send() { send "$@" >/dev/null 2>&1; }

# start_mailpit: the command mroom baseline mailpit printed, kept running by a loop that plays Forge's
# daemon (wait fails when the gate stops Mailpit, which set -e would take for the loop's own failure).
start_mailpit() {
  local cmd argv
  cmd="$(sed -n 's/^  Command: *//p' <<<"$1")"
  [ -n "$cmd" ] || { echo "mroom baseline printed no command" >&2; exit 1; }
  read -r -a argv <<<"$cmd"
  : >"$T/up"
  (while [ -e "$T/up" ]; do "${argv[@]}" & echo $! >"$T/pid"; wait $! || true; done) >"$T/mailpit.log" 2>&1 &
  for _ in $(seq 1 40); do
    if curl -q --silent --fail --max-time 2 --output /dev/null http://127.0.0.1:8025/livez; then return 0; fi
    sleep 0.25
  done
  cat "$T/mailpit.log" >&2
  echo "Mailpit did not start" >&2
  exit 1
}

t_the_mail_operations_against_the_real_mailpit() {
  mkdir -p "$HOME/.config/mroom"
  printf 'MROOM_APP_NAME=shop\n' >"$HOME/.config/mroom/box.env"
  run "$MROOM" baseline mailpit
  expect_rc 0; expect_out_has "mailpit v1.32.0: installed, SHA-256"
  start_mailpit "$out"
  local pw12 pw13 mails
  expect_true "the API answered without the gate's login" \
    eval '[ "$(curl -q -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8025/api/v1/messages)" = 401 ]'

  gate "mail-user-add 12"; expect_rc 0
  pw12="$(field MAIL_PASSWORD "$out")"
  gate "mail-user-add 13"; expect_rc 0
  pw13="$(field MAIL_PASSWORD "$out")"

  expect_true "mail went without a login" eval '! can_send - - ada@example.test anonymous'
  expect_true "mail went with a wrong password" eval '! can_send shop_qa_12 "$pw13" ada@example.test wrong'
  expect_true "environment 12 could not send" can_send shop_qa_12 "$pw12" ada@example.test env12 shop_qa_13
  expect_true "environment 13 could not send" can_send shop_qa_13 "$pw13" ada@example.test env13
  expect_true "environment 12 could not send to another persona" can_send shop_qa_12 "$pw12" bob@example.test env12-bob

  # Environment 12 sees only its own mail to ada, the X-Tags header it forged notwithstanding.
  gate "mail-read 12 ada@example.test"; expect_rc 0
  mails="$out"
  run jq -r '[.[].subject] | join(" ")' <<<"$mails"; expect_out env12
  run jq -r '.[0].text' <<<"$mails"; expect_out_has "https://example.test/reset/env12"
  gate "mail-read 13 ada@example.test"; expect_rc 0
  run jq -r '[.[].subject] | join(" ")' <<<"$out"; expect_out env13

  gate "mail-clear 12"; expect_rc 0; expect_out "mail of shop_qa_12: 2 deleted"
  gate "mail-read 12 ada@example.test"; expect_out '[]'
  gate "mail-read 13 ada@example.test"
  run jq -r '[.[].subject] | join(" ")' <<<"$out"; expect_out env13

  # A removed login stops working once Mailpit has read its logins again; the other one goes on.
  gate "mail-user-remove 12"; expect_rc 0
  expect_true "a removed login could still send" eval '! can_send shop_qa_12 "$pw12" ada@example.test after'
  expect_true "the other login stopped working" can_send shop_qa_13 "$pw13" ada@example.test still13
  # A new password replaces the old one.
  gate "mail-user-add 13"; expect_rc 0
  expect_true "an old password still worked" eval '! can_send shop_qa_13 "$pw13" ada@example.test old13'
  expect_true "the new password does not work" can_send shop_qa_13 "$(field MAIL_PASSWORD "$out")" ada@example.test new13
}

test_case real-mailpit t_the_mail_operations_against_the_real_mailpit
finish
