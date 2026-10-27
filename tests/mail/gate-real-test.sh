#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2016  # t_* run through test_case; a $ in single quotes is for eval, later
# The gate's mail operations against the real Mailpit, run the way a box runs it: what a fake cannot show.
# mroom baseline mailpit downloads the pinned build and checks its SHA-256, and the three systemd units are
# installed by running, as root, the very script it prints, from a home under /home as on a box (the units
# hide /home and /tmp from Mailpit, but for its own files). The test then checks:
# - systemd holds the SMTP port as root and hands it to mroom's mail relay;
# - each environment sends with its own login through it, and mail with no login, a wrong one or a forged
#   tag gets nowhere;
# - mail-read returns only an environment's own mail, and mail-clear deletes only it;
# - the same login again keeps its password and Mailpit running, and --rotate gives a new one;
# - a burst of new logins restarts Mailpit as often as it needs;
# - while the relay restarts, or is stopped, nothing else can take the port;
# - a removed login stops working.
# CI only: it downloads Mailpit and installs systemd units as root, replacing a box's own, so it refuses to
# run anywhere but GitHub Actions, and tests/run.sh does not pick it up.
set -euo pipefail
if [ "${GITHUB_ACTIONS:-}" != true ]; then
  echo "tests/mail/gate-real-test.sh: CI only; it would replace this machine's mroom systemd units" >&2
  exit 2
fi
SUITE=mail-real
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

UNITS=(mroom-mail-relay.socket mroom-mail-relay.service mroom-mailpit.service)
CI_HOME=""
cleanup() {
  local f
  for f in "$TOP"/*/squatter.pid "$TOP"/*/v6.pid; do if [ -s "$f" ]; then kill "$(cat "$f")" 2>/dev/null || true; fi; done
  sudo pkill -f mroom-ci-root-listener 2>/dev/null || true
  sudo systemctl disable --now "${UNITS[@]}" >/dev/null 2>&1 || true
  for f in "${UNITS[@]}"; do sudo rm -f "/etc/systemd/system/$f"; done
  sudo systemctl daemon-reload || true
  [ -z "$CI_HOME" ] || rm -rf "$CI_HOME"
  rm -rf "$TOP"
}
trap cleanup EXIT

gate() { run env SSH_ORIGINAL_COMMAND="$1" "$MROOM" gate provision; }
field() { sed -n "s/^$1=//p" <<<"$2"; }
active() { [ "$(systemctl is-active "$1" 2>/dev/null)" = active ]; }
main_pid() { systemctl show --property=MainPID --value "$1"; }
now_ms() { date +%s%3N; }
under() { [ "$1" -lt "$2" ]; }

# send <user|-> <password> <to> <subject> [<X-Tags>]: one mail to 127.0.0.1:1025; fails when it is refused.
send() {
  python3 -I - "$@" <<'PY'
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

# api <path>: Mailpit's API on its Unix socket, as the gate's login.
api() {
  local user pass
  user="$(sed -n 's/^MAILPIT_API_USER=//p' "$HOME/.config/mroom/secrets/mailpit.env")"
  pass="$(sed -n 's/^MAILPIT_API_PASSWORD=//p' "$HOME/.config/mroom/secrets/mailpit.env")"
  printf 'Authorization: Basic %s\n' "$(printf '%s:%s' "$user" "$pass" | base64 -w0)" \
    | curl -q --silent --fail --header @- --unix-socket "$HOME/.local/share/mroom-services/mailpit/run/http.sock" \
      "http://localhost$1"
}

# port_owner: the owner (uid) of what listens on 127.0.0.1:1025.
port_owner() { awk '$4 == "0A" && $2 == "0100007F:0401" { print $8; exit }' /proc/net/tcp; }

# squat <seconds>: tries to take the SMTP port the way anyone on the box could, every 2 ms, and logs each
# time it did.
squat() {
  python3 -I - "$1" >"$T/squatter.log" 2>&1 <<'PY' &
import socket, sys, time
deadline = time.monotonic() + float(sys.argv[1])
taken = 0
while time.monotonic() < deadline:
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("127.0.0.1", 1025))
        s.listen(1)
        taken += 1
        time.sleep(0.2)
    except OSError:
        pass
    finally:
        s.close()
    time.sleep(0.002)
print(f"taken {taken}", flush=True)
PY
  echo $! >"$T/squatter.pid"
}
squat_result() { wait "$(cat "$T/squatter.pid")" || true; rm -f "$T/squatter.pid"; cat "$T/squatter.log"; }

wait_ready() {
  for _ in $(seq 1 80); do
    if active mroom-mailpit.service && [ "$(port_owner)" = 0 ] \
      && curl -q --silent --fail --max-time 2 --output /dev/null \
        --unix-socket "$HOME/.local/share/mroom-services/mailpit/run/http.sock" http://localhost/livez; then
      return 0
    fi
    sleep 0.25
  done
  systemctl status --no-pager "${UNITS[@]}" >&2 || true
  echo "the units did not start" >&2
  exit 1
}

t_the_mail_operations_against_the_real_mailpit() {
  CI_HOME="$(mktemp -d "/home/$(id -un)/mroom-ci.XXXXXX")"
  export HOME="$CI_HOME"
  mkdir -p "$HOME/.config/mroom"
  printf 'MROOM_APP_NAME=shop\n' >"$HOME/.config/mroom/box.env"
  run "$MROOM" baseline mailpit
  expect_rc 0; expect_out_has "mailpit v1.32.0: installed, SHA-256"
  expect_out_has "To be installed or updated: mroom-mail-relay.socket mroom-mail-relay.service mroom-mailpit.service."
  # Install the units as the root recipe does: this release's lib/root-setup, run as root.
  run sudo bash "$ROOT/lib/root-setup" --user "$(id -un)" --home "$HOME" mailpit
  expect_rc 0; expect_out_has "systemd units written: mroom-mail-relay.socket mroom-mail-relay.service mroom-mailpit.service"
  wait_ready
  local run_dir="$HOME/.local/share/mroom-services/mailpit/run" pw12 pw13 pw25 n pids=() relay_pid started
  run port_owner; expect_out 0
  run "$MROOM" baseline mailpit
  expect_out_has "systemd units: installed as this mroom writes them (mroom-mail-relay.socket active, mroom-mail-relay.service active, mroom-mailpit.service active)."
  expect_out_has "systemd holds 127.0.0.1:1025 (mroom-mail-relay.socket)."
  # The API is on a Unix socket only, in a folder only the box user can open, and needs the gate's login.
  run stat -c %a "$run_dir"; expect_out 700
  run stat -c %a "$run_dir/http.sock"; expect_out 600
  run stat -c %a "$run_dir/smtp.sock"; expect_out 600
  run curl -q --silent --max-time 2 --output /dev/null http://127.0.0.1:8025/livez; expect_rc 7
  run curl -q --silent --output /dev/null --write-out '%{http_code}' --unix-socket "$run_dir/http.sock" http://localhost/api/v1/messages
  expect_out 401

  gate "mail-user-add 12"; expect_rc 0
  pw12="$(field MAIL_PASSWORD "$out")"
  gate "mail-user-add 13"; expect_rc 0
  pw13="$(field MAIL_PASSWORD "$out")"
  # The same login again keeps its password, and Mailpit, which every environment's mail goes through, keeps
  # running; --rotate gives a new password, which takes a restart.
  local mailpit_pid old12
  mailpit_pid="$(main_pid mroom-mailpit.service)"
  gate "mail-user-add 12"; expect_rc 0
  expect_true "a second mail-user-add changed the password" [ "$(field MAIL_PASSWORD "$out")" = "$pw12" ]
  expect_true "an unchanged login restarted Mailpit" [ "$(main_pid mroom-mailpit.service)" = "$mailpit_pid" ]
  old12="$pw12"
  gate "mail-user-add 12 --rotate"; expect_rc 0
  pw12="$(field MAIL_PASSWORD "$out")"
  expect_true "--rotate kept the password" [ "$pw12" != "$old12" ]
  expect_true "a new login did not restart Mailpit" [ "$(main_pid mroom-mailpit.service)" != "$mailpit_pid" ]
  expect_true "the rotated password still sends" eval '! can_send shop_qa_12 "$old12" ada@example.test rotated'

  expect_true "mail went without a login" eval '! can_send - - ada@example.test anonymous'
  expect_true "mail went with a wrong password" eval '! can_send shop_qa_12 "$pw13" ada@example.test wrong'
  expect_true "environment 12 could not send" can_send shop_qa_12 "$pw12" ada@example.test env12 shop_qa_13
  expect_true "environment 12 could not send to a plus address" can_send shop_qa_12 "$pw12" ada+shop_qa_13@example.test env12-plus
  expect_true "environment 13 could not send" can_send shop_qa_13 "$pw13" ada@example.test env13
  expect_true "environment 12 could not send to another persona" can_send shop_qa_12 "$pw12" bob@example.test env12-bob

  # Neither the X-Tags header nor the plus address gave environment 12's mail environment 13's tag.
  run api "/api/v1/search?query=$(jq -rn '"tag:\"shop_qa_13\"" | @uri')"
  expect_rc 0
  run jq -r '[.messages[].Subject] | sort | join(" ")' <<<"$out"; expect_out env13
  gate "mail-read 12 ada@example.test"; expect_rc 0
  run jq -r '[.[].subject] | join(" ")' <<<"$out"; expect_out env12
  gate "mail-read 12 ada@example.test"
  run jq -r '.[0].text' <<<"$out"; expect_out_has "https://example.test/reset/env12"
  gate "mail-read 13 ada@example.test"; expect_rc 0
  run jq -r '[.[].subject] | join(" ")' <<<"$out"; expect_out env13

  gate "mail-clear 12"; expect_rc 0; expect_out "mail of shop_qa_12: 3 deleted"
  gate "mail-read 12 ada@example.test"; expect_out '[]'
  gate "mail-read 13 ada@example.test"
  run jq -r '[.[].subject] | join(" ")' <<<"$out"; expect_out env13

  # A burst of new logins, all at once, while someone tries to take the SMTP port: every login goes out,
  # without waiting between restarts (systemd starts Mailpit again however often it stops), and the port
  # is never free.
  squat 30
  started=$(now_ms)
  for n in 20 21 22 23 24; do
    (env SSH_ORIGINAL_COMMAND="mail-user-add $n" "$MROOM" gate provision >"$T/add-$n.out" 2>"$T/add-$n.err"
      echo $? >"$T/add-$n.rc") &
    pids+=($!)
  done
  wait "${pids[@]}"
  expect_true "the burst waited between restarts, as for a supervisor" under $(($(now_ms) - started)) 10000
  for n in 20 21 22 23 24; do
    run cat "$T/add-$n.rc"; expect_out 0
    expect_true "environment $n's new login does not work" \
      can_send "shop_qa_$n" "$(field MAIL_PASSWORD "$(cat "$T/add-$n.out")")" ada@example.test "burst$n"
  done
  expect_true "systemd stopped running Mailpit" active mroom-mailpit.service
  # The relay restarts, and is stopped: systemd holds the port throughout, and the next connection starts
  # the relay again.
  relay_pid="$(main_pid mroom-mail-relay.service)"
  for n in 1 2 3; do sudo systemctl restart mroom-mail-relay.service; sleep 0.5; done
  expect_true "the relay did not restart" [ "$(main_pid mroom-mail-relay.service)" != "$relay_pid" ]
  sudo systemctl stop mroom-mail-relay.service
  run port_owner; expect_out 0
  gate "mail-user-add 25"; expect_rc 0
  pw25="$(field MAIL_PASSWORD "$out")"
  expect_true "mail did not start the stopped relay again" can_send shop_qa_25 "$pw25" ada@example.test woken
  expect_true "the relay is not running again" active mroom-mail-relay.service
  run squat_result; expect_out "taken 0"

  # A relay that changed: baseline restarts it, and systemd holds the port meanwhile, squatter or not.
  relay_pid="$(main_pid mroom-mail-relay.service)"
  printf '# changed\n' >>"$HOME/.local/share/mroom-services/mail-relay/mail-relay"
  squat 6
  run "$MROOM" baseline mailpit
  expect_out_has "mail relay: restarted to run this one; systemd held the port meanwhile"
  sleep 2
  expect_true "baseline did not restart the relay" [ "$(main_pid mroom-mail-relay.service)" != "$relay_pid" ]
  run squat_result; expect_out "taken 0"
  run port_owner; expect_out 0
  expect_true "the restarted relay does not pass mail" can_send shop_qa_25 "$pw25" ada@example.test after-update
  # Mailpit's copy of the API login gone: baseline writes it again from the same password and restarts
  # Mailpit to read it; the gate reads mail as before.
  local mailpit_pid
  mailpit_pid="$(main_pid mroom-mailpit.service)"
  rm "$HOME/.config/mroom/secrets/mailpit-ui.passwd"
  run "$MROOM" baseline mailpit
  expect_out_has "Mailpit: restarted to run its build and read its API login"
  expect_out_has "Mailpit answers."
  wait_ready
  expect_true "baseline did not restart Mailpit" [ "$(main_pid mroom-mailpit.service)" != "$mailpit_pid" ]
  gate "mail-read 25 ada@example.test"; expect_rc 0
  # A v6only listener at :: beside systemd's socket never sees apps' mail, and blocks nothing.
  python3 -I -c 'import socket, sys, time
s = socket.socket(socket.AF_INET6); s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
s.bind(("::", 1025)); s.listen(1); time.sleep(60)' >/dev/null 2>&1 &
  echo $! >"$T/v6.pid"
  sleep 0.5
  gate "mail-user-add 26"; expect_rc 0
  kill "$(cat "$T/v6.pid")" 2>/dev/null || true
  # A root process on the port that is not systemd's socket for the relay: no login goes out.
  sudo systemctl stop mroom-mail-relay.socket mroom-mail-relay.service
  sudo python3 -I -c 'import socket, sys, time
s = socket.create_server(("127.0.0.1", 1025)); time.sleep(60)' mroom-ci-root-listener >/dev/null 2>&1 &
  for n in $(seq 1 50); do [ "$(port_owner)" = 0 ] && break; sleep 0.1; done
  gate "mail-user-add 27"
  expect_rc 1; expect_err_has "a root process other than mroom-mail-relay.socket listens on port 1025"
  expect_true "a password went out" eval '! grep -q MAIL_PASSWORD <<<"$out"'
  run "$MROOM" baseline mailpit
  expect_out_has "Something else listens on 127.0.0.1:1025 (user 0)"
  sudo pkill -f mroom-ci-root-listener || true
  sleep 0.5
  sudo systemctl start mroom-mail-relay.socket mroom-mail-relay.service
  wait_ready

  # The same squatter takes the port as soon as nothing holds it, which is what systemd prevents.
  sudo systemctl stop mroom-mail-relay.socket mroom-mail-relay.service
  squat 1
  run squat_result; expect_out_has "taken"
  expect_true "the squatter could not take a free port" eval '[ "$out" != "taken 0" ]'
  sudo systemctl start mroom-mail-relay.socket mroom-mail-relay.service
  wait_ready

  # A removed login stops working once Mailpit has read its logins again; the other one goes on.
  gate "mail-user-remove 12"; expect_rc 0
  expect_true "a removed login could still send" eval '! can_send shop_qa_12 "$pw12" ada@example.test after'
  expect_true "the other login stopped working" can_send shop_qa_13 "$pw13" ada@example.test still13
  # A new password replaces the old one.
  gate "mail-user-add 13"; expect_rc 0
  expect_true "an old password still worked" eval '! can_send shop_qa_13 "$pw13" ada@example.test old13'
  expect_true "the new password does not work" can_send shop_qa_13 "$(field MAIL_PASSWORD "$out")" ada@example.test new13
  expect_true "systemd stopped running Mailpit" active mroom-mailpit.service
}

test_case real-mailpit t_the_mail_operations_against_the_real_mailpit
finish
