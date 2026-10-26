#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2016  # t_* run through test_case; a $ in single quotes is for eval, later
# The gate's mail operations against the real Mailpit, run the way Forge runs it: what a fake cannot show.
# mroom baseline mailpit downloads the pinned build and checks its SHA-256, and a real supervisord, with the
# settings Forge gives a daemon, runs the two daemons it prints: mroom's mail relay and Mailpit. Each
# environment sends with its own login through the relay; mail with no login, a wrong one or a forged tag
# gets nowhere; mail-read returns only an environment's own mail and mail-clear deletes only it; a removed
# login stops working; a burst of new logins never makes the daemon give up; and while the gate restarts
# Mailpit, nothing else can take the SMTP port. CI only: it downloads Mailpit and needs supervisord, so
# tests/run.sh does not pick it up.
set -euo pipefail
SUITE=mail-real
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

cleanup() {
  local f
  for f in "$TOP"/*/supervisord.conf; do supervisorctl -c "$f" shutdown >/dev/null 2>&1 || true; done
  for f in "$TOP"/*/squatter.pid; do if [ -s "$f" ]; then kill "$(cat "$f")" 2>/dev/null || true; fi; done
  rm -rf "$TOP"
}
trap cleanup EXIT

gate() { run env SSH_ORIGINAL_COMMAND="$1" "$MROOM" gate provision; }
field() { sed -n "s/^$1=//p" <<<"$2"; }
ctl() { supervisorctl -c "$T/supervisord.conf" "$@" 2>&1 || true; }
is_running() { case "$(ctl status "$1")" in *RUNNING*) return 0 ;; esac; return 1; }
# running <program>: whether supervisord runs the program, once it has stayed up past Start Seconds; until
# then supervisord calls it STARTING.
running() { local _; for _ in $(seq 1 20); do if is_running "$1"; then return 0; fi; sleep 0.25; done; return 1; }
# quick_stops: how many times Mailpit stopped before Forge's daemon counted its start a success, each of which
# brings the daemon a step closer to giving up.
quick_stops() {
  local spawned succeeded
  spawned="$(grep -c "spawned: 'mailpit'" "$T/supervisord.log")" || true
  succeeded="$(grep -c 'success: mailpit entered RUNNING' "$T/supervisord.log")" || true
  echo $((spawned - succeeded))
}

# send <user|-> <password> <to> <subject> [<X-Tags>]: one mail through the relay; fails when it is refused.
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

# start_daemons <baseline output>: the two daemons mroom baseline printed, under a supervisord set up the
# way Forge sets up a daemon (autostart, autorestart, Start Seconds 1, SIGTERM, stopping the whole group).
start_daemons() {
  local commands=() dirs=() name i
  mapfile -t commands < <(sed -n 's/^  Command: *//p' <<<"$1")
  mapfile -t dirs < <(sed -n 's/^  Directory: *//p' <<<"$1")
  if [ "${#commands[@]}" != 2 ] || [ "${#dirs[@]}" != 2 ]; then echo "mroom baseline did not print two daemons" >&2; exit 1; fi
  cat >"$T/supervisord.conf" <<EOF
[unix_http_server]
file=$T/supervisor.sock
[supervisord]
logfile=$T/supervisord.log
pidfile=$T/supervisord.pid
childlogdir=$T
[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface
[supervisorctl]
serverurl=unix://$T/supervisor.sock
EOF
  for i in 0 1; do
    name=mail-relay
    [ "$i" = 0 ] || name=mailpit
    cat >>"$T/supervisord.conf" <<EOF
[program:$name]
command=${commands[$i]}
directory=${dirs[$i]}
autostart=true
autorestart=true
startsecs=1
stopwaitsecs=5
stopsignal=SIGTERM
stopasgroup=true
killasgroup=true
redirect_stderr=true
stdout_logfile=$T/$name.log
EOF
  done
  supervisord -c "$T/supervisord.conf"
  for _ in $(seq 1 60); do
    if is_running mail-relay && is_running mailpit \
      && curl -q --silent --fail --max-time 2 --output /dev/null \
        --unix-socket "$HOME/.local/share/mroom-services/mailpit/run/http.sock" http://localhost/livez; then
      return 0
    fi
    sleep 0.25
  done
  ctl status >&2; tail -n 20 "$T/mailpit.log" "$T/mail-relay.log" >&2 || true
  echo "the daemons did not start" >&2
  exit 1
}

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

t_the_mail_operations_against_the_real_mailpit() {
  if ! command -v supervisord >/dev/null || ! command -v supervisorctl >/dev/null; then
    echo "this test needs supervisord and supervisorctl (apt install supervisor)" >&2
    exit 1
  fi
  mkdir -p "$HOME/.config/mroom"
  printf 'MROOM_APP_NAME=shop\n' >"$HOME/.config/mroom/box.env"
  run "$MROOM" baseline mailpit
  expect_rc 0; expect_out_has "mailpit v1.32.0: installed, SHA-256"
  start_daemons "$out"
  local run_dir="$HOME/.local/share/mroom-services/mailpit/run" pw12 pw13 n pids=() relay_pid
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
  # Environment 12 sees only its own mail to ada.
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
  # Forge's daemon never gives up on Mailpit, the relay never restarts, and the port is never free.
  relay_pid="$(ctl pid mail-relay)"
  squat 25
  for n in 20 21 22 23 24; do
    (env SSH_ORIGINAL_COMMAND="mail-user-add $n" "$MROOM" gate provision >"$T/add-$n.out" 2>"$T/add-$n.err"
      echo $? >"$T/add-$n.rc") &
    pids+=($!)
  done
  wait "${pids[@]}"
  for n in 20 21 22 23 24; do
    run cat "$T/add-$n.rc"; expect_out 0
    expect_true "environment $n's new login does not work" \
      can_send "shop_qa_$n" "$(field MAIL_PASSWORD "$(cat "$T/add-$n.out")")" ada@example.test "burst$n"
  done
  expect_true "Forge's daemon gave up on Mailpit" running mailpit
  run grep -c 'gave up' "$T/supervisord.log"; expect_out 0
  run quick_stops; expect_out 0
  run ctl pid mail-relay; expect_out "$relay_pid"
  run squat_result; expect_out "taken 0"
  # The same squatter takes the port as soon as nothing holds it, which is what the relay prevents.
  ctl stop mail-relay >/dev/null
  squat 1
  run squat_result; expect_out_has "taken"
  expect_true "the squatter could not take a free port" eval '[ "$out" != "taken 0" ]'
  ctl start mail-relay >/dev/null

  # A removed login stops working once Mailpit has read its logins again; the other one goes on.
  gate "mail-user-remove 12"; expect_rc 0
  expect_true "a removed login could still send" eval '! can_send shop_qa_12 "$pw12" ada@example.test after'
  expect_true "the other login stopped working" can_send shop_qa_13 "$pw13" ada@example.test still13
  # A new password replaces the old one.
  gate "mail-user-add 13"; expect_rc 0
  expect_true "an old password still worked" eval '! can_send shop_qa_13 "$pw13" ada@example.test old13'
  expect_true "the new password does not work" can_send shop_qa_13 "$(field MAIL_PASSWORD "$out")" ada@example.test new13
  expect_true "Forge's daemon gave up on Mailpit" running mailpit
  run quick_stops; expect_out 0
}

test_case real-mailpit t_the_mail_operations_against_the_real_mailpit
finish
