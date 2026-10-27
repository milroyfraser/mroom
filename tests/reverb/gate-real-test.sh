#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2016  # t_* run through test_case; a $ in single quotes is for eval, later
# The gate's Reverb operations against mroom's real Reverb host, run the way a box runs it: what a fake cannot
# show. mroom baseline reverb installs this release's reverb-host with the packages its composer.lock pins, its
# unit is installed by this release's lib/root-setup, run as root, from a home under /home as on a box, and
# systemd runs it confined. The test then checks:
# - an app reverb-app-add gives connects from its environment's two sites and from no other, and an app no one
#   added does not exist;
# - an event its backend sends through Reverb's HTTP API, signed with its secret, reaches its sockets, and one
#   signed with another environment's secret is refused;
# - a new secret replaces the old one at once, and the host never restarts for any of it;
# - through an nginx made from the config baseline prints, with Forge's own blocks left in place, sockets open
#   and events arrive;
# - a removed app opens no socket, and the other environment's app keeps working;
# - the host comes back with its apps when systemd starts it again.
# CI only: it installs a systemd unit as root, replacing a box's own, so it refuses to run anywhere but GitHub
# Actions, and tests/run.sh does not pick it up.
set -euo pipefail
if [ "${GITHUB_ACTIONS:-}" != true ]; then
  echo "tests/reverb/gate-real-test.sh: CI only; it would replace this machine's mroom systemd units" >&2
  exit 2
fi
SUITE=reverb-real
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

CI_HOME=""
LISTEN_PID=""
cleanup() {
  local f
  if [ -n "$LISTEN_PID" ]; then kill "$LISTEN_PID" 2>/dev/null || true; fi
  for f in "$TOP"/*/nginx/nginx.pid; do if [ -s "$f" ]; then kill "$(cat "$f")" 2>/dev/null || true; fi; done
  sudo systemctl disable --now mroom-reverb.service >/dev/null 2>&1 || true
  sudo rm -f /etc/systemd/system/mroom-reverb.service
  sudo systemctl daemon-reload || true
  [ -z "$CI_HOME" ] || rm -rf "$CI_HOME"
  rm -rf "$TOP"
}
trap cleanup EXIT

gate() { run env SSH_ORIGINAL_COMMAND="$1" "$MROOM" gate provision; }
field() { sed -n "s/^$1=//p" <<<"$2"; }
reverb_dir() { echo "$HOME/.local/share/mroom-services/reverb"; }
sock() { echo "unix:$(reverb_dir)/run/reverb.sock"; }
client() { python3 -I "$ROOT/tests/reverb/client.py" "$@"; }
main_pid() { systemctl show -p MainPID --value mroom-reverb.service; }

wait_ready() {
  for _ in $(seq 1 120); do
    if [ "$(systemctl is-active mroom-reverb.service 2>/dev/null)" = active ] \
      && [ "$(curl -q -s --max-time 2 --unix-socket "$(reverb_dir)/run/reverb.sock" -o /dev/null -w '%{http_code}' \
        http://localhost/up 2>/dev/null)" = 200 ]; then
      return 0
    fi
    sleep 0.25
  done
  systemctl status --no-pager mroom-reverb.service >&2 || true
  sudo journalctl -u mroom-reverb.service -n 40 --no-pager >&2 || true
  echo "the Reverb host did not start" >&2
  exit 1
}

# listen_for <where> <key> <origin> <channel>: a socket in the background, subscribed to the channel once this
# returns; heard waits for the first event it gets.
listen_for() {
  local name="listen.$1.$4"
  # Only the file's own name loses its : and /, never the folder's path.
  LISTEN_OUT="$T/${name//[:\/]/-}"
  client listen "$@" 15 >"$LISTEN_OUT" 2>&1 &
  LISTEN_PID=$!
  for _ in $(seq 1 100); do
    if grep -qx ready "$LISTEN_OUT"; then return 0; fi
    kill -0 "$LISTEN_PID" 2>/dev/null || break
    sleep 0.1
  done
  cat "$LISTEN_OUT" >&2
  echo "the socket did not subscribe" >&2
  exit 1
}
heard() { wait "$LISTEN_PID" || true; LISTEN_PID=""; cat "$LISTEN_OUT"; }

t_the_reverb_operations_against_the_real_host() {
  CI_HOME="$(mktemp -d "/home/$(id -un)/mroom-ci.XXXXXX")"
  export HOME="$CI_HOME"
  mkdir -p "$HOME/.config/mroom"
  printf 'MROOM_APP_NAME=shop\nMROOM_QA_ZONE=qa.example.test\n' >"$HOME/.config/mroom/box.env"
  run "$MROOM" baseline reverb
  expect_rc 0; expect_out_has "installed (Reverb v1.12.0)"
  expect_out_has "To be installed or updated: mroom-reverb.service."
  expect_out_has "Reverb host does not answer yet"
  # Install the unit as the root recipe does: this release's lib/root-setup, run as root.
  run sudo bash "$ROOT/lib/root-setup" --user "$(id -un)" --home "$HOME" reverb
  expect_rc 0; expect_out_has "systemd units written: mroom-reverb.service"
  wait_ready
  run "$MROOM" baseline reverb
  expect_rc 0; expect_out_has "matches this mroom"; expect_out_has "Reverb host answers, with 0 apps."
  expect_out_has "systemd units: installed as this mroom writes them (mroom-reverb.service active)."
  local baseline_out="$out" app12 app13 key12 key13 secret12 secret13 old12 pid
  run stat -c %a "$(reverb_dir)/run"; expect_out 700
  run stat -c %a "$(reverb_dir)/run/reverb.sock"
  expect_true "the socket is open to others: $out" eval '[[ "$out" =~ ^[67]00$ ]]'
  pid="$(main_pid)"

  # An app for each environment, added while the host runs.
  gate "reverb-app-add 12"; expect_rc 0; app12="$out"
  gate "reverb-app-add 13"; expect_rc 0; app13="$out"
  key12="$(field REVERB_APP_KEY "$app12")" secret12="$(field REVERB_APP_SECRET "$app12")"
  key13="$(field REVERB_APP_KEY "$app13")" secret13="$(field REVERB_APP_SECRET "$app13")"
  expect_true "the key is not the PR's: $key12" [ "$key12" = shop-qa-12 ]

  # From its two sites only; an app no one added does not exist.
  run client open "$(sock)" "$key12" https://go-12.qa.example.test; expect_out_has '"event":"pusher:connection_established"'
  run client open "$(sock)" "$key12" https://api-12.qa.example.test; expect_out_has '"event":"pusher:connection_established"'
  run client open "$(sock)" "$key12" https://go-13.qa.example.test; expect_out_has 'Origin not allowed'
  run client open "$(sock)" shop-qa-14 https://go-14.qa.example.test; expect_out_has 'Application does not exist'

  # An event its backend sends, signed with its secret, reaches its sockets; another's secret is refused.
  listen_for "$(sock)" "$key12" https://go-12.qa.example.test orders
  run client send "$(sock)" shop-qa-12 "$key12" "$secret12" orders shipped '{"id":7}'; expect_out 200
  run heard; expect_out_has 'event shipped {"id":7}'
  run client send "$(sock)" shop-qa-12 "$key12" "$secret13" orders shipped '{}'; expect_out 401

  # A new secret replaces the old one at once, with no restart.
  old12="$secret12"
  gate "reverb-app-add 12"; expect_rc 0; secret12="$(field REVERB_APP_SECRET "$out")"
  run client send "$(sock)" shop-qa-12 "$key12" "$old12" orders shipped '{}'; expect_out 401
  run client send "$(sock)" shop-qa-12 "$key12" "$secret12" orders shipped '{}'; expect_out 200
  expect_true "the host restarted" [ "$(main_pid)" = "$pid" ]

  # Through an nginx made from the config baseline printed.
  mkdir -p "$T/nginx"
  {
    echo "worker_processes 1; pid $T/nginx/nginx.pid; error_log $T/nginx/error.log warn; events {}"
    echo "http { access_log $T/nginx/access.log; client_body_temp_path $T/nginx/body; proxy_temp_path $T/nginx/proxy;"
    echo "fastcgi_temp_path $T/nginx/fcgi; uwsgi_temp_path $T/nginx/uwsgi; scgi_temp_path $T/nginx/scgi;"
    # Forge's own blocks of a PHP site, left in place: the printed one must still take every path.
    echo 'server { listen 127.0.0.1:8082; server_name ws.qa.example.test;'
    echo 'location ~ \.php$ { return 418; } location ~ /\.(?!well-known).* { deny all; }'
    # The printed config lines alone, which are indented; the text around them is not.
    sed -n '/^ws.qa.example.test, WebSockets/,$p' <<<"$baseline_out" | grep '^    '
    echo "} }"
  } >"$T/nginx/nginx.conf"
  nginx -p "$T/nginx" -c "$T/nginx/nginx.conf" 2>"$T/nginx/start.err" || { cat "$T/nginx/nginx.conf" "$T/nginx/start.err" >&2; exit 1; }
  sleep 0.5
  run client open 127.0.0.1:8082 "$key12" https://go-12.qa.example.test; expect_out_has '"event":"pusher:connection_established"'
  listen_for 127.0.0.1:8082 "$key12" https://go-12.qa.example.test orders
  run client send 127.0.0.1:8082 shop-qa-12 "$key12" "$secret12" orders packed '"box 3"'; expect_out 200
  run heard; expect_out_has 'event packed "box 3"'

  # A removed app opens no socket; the other environment's keeps working, and nothing restarted.
  gate "reverb-app-remove 12"; expect_rc 0
  run client open "$(sock)" "$key12" https://go-12.qa.example.test; expect_out_has 'Application does not exist'
  run client open "$(sock)" "$key13" https://go-13.qa.example.test; expect_out_has '"event":"pusher:connection_established"'
  expect_true "the host restarted" [ "$(main_pid)" = "$pid" ]

  # systemd starts it again, with its apps.
  sudo systemctl kill --signal=SIGKILL mroom-reverb.service
  sleep 1.5
  wait_ready
  expect_true "systemd did not start it again" [ "$(main_pid)" != "$pid" ]
  run client open "$(sock)" "$key13" https://go-13.qa.example.test; expect_out_has '"event":"pusher:connection_established"'
  listen_for "$(sock)" "$key13" https://go-13.qa.example.test orders
  run client send "$(sock)" shop-qa-13 "$key13" "$secret13" orders shipped '{"id":8}'; expect_out 200
  run heard; expect_out_has 'event shipped {"id":8}'
  run sudo journalctl -u mroom-reverb.service --no-pager
  expect_true "the host logged an error: $out" eval '! grep -q -i -E "exception|PHP (Warning|Fatal)" <<<"$out"'
}

test_case real-reverb t_the_reverb_operations_against_the_real_host
finish
