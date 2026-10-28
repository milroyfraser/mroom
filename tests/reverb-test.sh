#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2016  # t_* run through test_case; a $ in single quotes is for eval, later
# Tests for the gate's Reverb operations (design D16): reverb-app-add gives an environment an app of its own on
# mroom's Reverb host, with an id and key built from box.env and the PR alone, a new secret each time, and
# origins of its own two sites; reverb-app-remove takes it away; both replace the apps file whole, keep every
# other environment's app, never log a secret, and refuse what is not theirs to do; and what qa-plan derives
# for the frontend is what the gate gives. Offline: a small Python server on the host's socket answers its
# health check. tests/reverb/gate-real-test.sh runs the same gate against the real Reverb host in CI, with
# sockets that connect and events that arrive.
set -euo pipefail
SUITE=reverb
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
skip_unless has_box_tools "this host lacks bash 5, flock or GNU date, which box commands need"
skip_unless has_tomllib "python3 has no tomllib (needs 3.11+), which reading mroom.toml needs"

HOSTS=()
cleanup() {
  local pid
  for pid in "${HOSTS[@]}"; do kill "$pid" 2>/dev/null || true; done
  rm -rf "$TOP"
}
trap cleanup EXIT

gate() { run env SSH_ORIGINAL_COMMAND="$1" "$MROOM" gate provision; }
field() { sed -n "s/^$1=//p" <<<"$2"; }
reverb_dir() { echo "$HOME/.local/share/mroom-services/reverb"; }
apps_file() { echo "$(reverb_dir)/apps/apps.json"; }

# world: box.env, and the folders and empty apps file mroom baseline reverb makes.
world() {
  mkdir -p "$HOME/.config/mroom" "$(reverb_dir)/apps" "$(reverb_dir)/run"
  chmod 700 "$(reverb_dir)" "$(reverb_dir)/apps" "$(reverb_dir)/run"
  printf 'MROOM_APP_NAME=shop\nMROOM_QA_ZONE=qa.example.test\n' >"$HOME/.config/mroom/box.env"
  printf '{"apps": []}\n' >"$(apps_file)"
  chmod 600 "$(apps_file)"
}

# host_up: a stand-in for the Reverb host, answering GET /up on its socket, as the real one does.
host_up() {
  local sock
  sock="$(reverb_dir)/run/reverb.sock"
  python3 -I - "$sock" <<'PY' &
import http.server, os, socketserver, sys
path = sys.argv[1]


class Health(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200 if self.path == "/up" else 404)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"{}")

    def address_string(self):
        return "local"

    def log_message(self, *args):
        pass


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


if os.path.exists(path):
    os.unlink(path)
Server(path, Health).serve_forever()
PY
  HOSTS+=("$!")
  for _ in $(seq 1 40); do
    if [ -S "$sock" ]; then return 0; fi
    sleep 0.1
  done
  echo "the stand-in Reverb host did not start" >&2
  exit 1
}

apps() { jq -c "${1:-.}" "$(apps_file)"; }

t_add_gives_an_environment_an_app_of_its_own() {
  world; host_up
  local secret
  gate "reverb-app-add 12"
  expect_rc 0
  secret="$(field REVERB_APP_SECRET "$out")"
  expect_true "the secret is not 48 hex characters: $secret" eval '[[ "$secret" =~ ^[0-9a-f]{48}$ ]]'
  expect_out "REVERB_APP_ID=shop-qa-12
REVERB_APP_KEY=shop-qa-12
REVERB_APP_SECRET=$secret
REVERB_HOST=ws.qa.example.test
REVERB_PORT=443
REVERB_SCHEME=https"
  run apps '.apps | length'; expect_out 1
  run jq -c --arg s "$secret" '.apps[0] | [.app_id, .key, (.secret == $s), .allowed_origins, .max_connections, .accept_client_events_from]' "$(apps_file)"
  expect_out '["shop-qa-12","shop-qa-12",true,["api.12.qa.example.test","12.qa.example.test"],100,"members"]'
  run stat -c %a "$(apps_file)"; expect_out 600
  run cat "$HOME/.local/state/mroom/gate.log"
  expect_out_has "reverb-app-add 12: shop-qa-12 ready"
  expect_true "the gate log holds the secret" eval '[[ "$out" != *"$secret"* ]]'
}

t_add_again_keeps_the_secret_and_replaces_the_file_whole() {
  world; host_up
  local first second inode
  gate "reverb-app-add 12"; first="$(field REVERB_APP_SECRET "$out")"
  inode="$(stat -c %i "$(apps_file)")"
  # Reverb keeps the app each socket opened with: a new secret would fail the open sockets' private channels.
  gate "reverb-app-add 12"; expect_rc 0; second="$(field REVERB_APP_SECRET "$out")"
  expect_true "the secret changed while the app stayed" [ "$first" = "$second" ]
  run jq -c '[.apps[] | .app_id]' "$(apps_file)"; expect_out '["shop-qa-12"]'
  run jq -r '.apps[0].secret' "$(apps_file)"; expect_out "$first"
  expect_true "the apps file was written in place, not replaced" [ "$(stat -c %i "$(apps_file)")" != "$inode" ]
  run ls -A "$(reverb_dir)/apps"; expect_out apps.json
}

t_remove_then_add_gives_a_new_secret() {
  world; host_up
  local first
  gate "reverb-app-add 12"; first="$(field REVERB_APP_SECRET "$out")"
  gate "reverb-app-remove 12"; expect_rc 0
  gate "reverb-app-add 12"; expect_rc 0
  expect_true "the secret stayed the same" [ "$(field REVERB_APP_SECRET "$out")" != "$first" ]
  # An entry the gate did not write, with a secret that is not one of its own, gets a new one.
  jq '.apps[0].secret = "short"' "$(apps_file)" >"$T/apps" && cat "$T/apps" >"$(apps_file)"
  gate "reverb-app-add 12"; expect_rc 0
  expect_true "a strange secret was kept: $out" eval '[[ "$(field REVERB_APP_SECRET "$out")" =~ ^[0-9a-f]{48}$ ]]'
}

t_remove_takes_only_its_own_app() {
  world; host_up
  gate "reverb-app-add 12"; gate "reverb-app-add 13"
  # An app the gate did not write, another box's own, stays too.
  jq '.apps += [{"app_id": "other", "key": "other", "secret": "s"}]' "$(apps_file)" >"$T/apps" && cat "$T/apps" >"$(apps_file)"
  gate "reverb-app-remove 12"
  expect_rc 0; expect_out "Reverb app shop-qa-12: removed; its sockets already open stay until they close"
  run jq -c '[.apps[] | .app_id]' "$(apps_file)"; expect_out '["shop-qa-13","other"]'
  run stat -c %a "$(apps_file)"; expect_out 600
  gate "reverb-app-remove 12"
  expect_rc 0; expect_out "environment 12 has no Reverb app, so nothing to remove"
}

t_remove_works_while_the_host_is_down() {
  world; host_up
  gate "reverb-app-add 12"
  kill "${HOSTS[@]}"; wait "${HOSTS[@]}" 2>/dev/null || true; HOSTS=()
  gate "reverb-app-remove 12"; expect_rc 0
  run jq '.apps | length' "$(apps_file)"; expect_out 0
}

t_adds_at_once_keep_every_app() {
  world; host_up
  local n pids=()
  for n in 21 22 23 24 25; do
    env SSH_ORIGINAL_COMMAND="reverb-app-add $n" "$MROOM" gate provision >"$T/add-$n.out" 2>&1 &
    pids+=("$!")
  done
  for n in "${pids[@]}"; do wait "$n" || true; done
  run jq -c '[.apps[] | .app_id] | sort' "$(apps_file)"
  expect_out '["shop-qa-21","shop-qa-22","shop-qa-23","shop-qa-24","shop-qa-25"]'
}

t_qa_plan_derives_what_the_gate_gives() {
  # qa-plan builds the frontend with the app's settings that are not secret, without asking the gate
  # (lib/core/qa.sh, qa_public_env): the two must build them alike, for an app name with an _ too, which a
  # bucket's name turns into a -.
  world; host_up
  printf 'MROOM_APP_NAME=my_shop\nMROOM_QA_ZONE=qa.example.test\n' >"$HOME/.config/mroom/box.env"
  printf '[app]\nname = "my_shop"\n\n[qa]\nzone = "qa.example.test"\n' >"$T/mroom.toml"
  gate "reverb-app-add 12"; expect_rc 0
  local given derived
  given="$(grep -v '^REVERB_APP_SECRET=' <<<"$out")"
  derived="$(MROOM_ROOT="$ROOT" MROOM_CONFIG="$T/mroom.toml" bash -c '. "$MROOM_ROOT/lib/core/util.sh"
    . "$MROOM_ROOT/lib/core/forge.sh"; . "$MROOM_ROOT/lib/core/qa.sh"; qa_names 12 && qa_public_env' | grep '^REVERB_')"
  expect_true "qa-plan derives other Reverb settings than the gate gives: $derived" [ "$derived" = "$given" ]
  run jq -r '.apps[0].app_id' "$(apps_file)"; expect_out my_shop-qa-12
}

t_add_refuses_while_the_host_does_not_answer() {
  world
  gate "reverb-app-add 12"
  expect_rc 1; expect_err_has "the Reverb host does not answer; check mroom-reverb.service"
  run apps; expect_out '{"apps":[]}'
}

t_what_the_reverb_operations_refuse() {
  world; host_up
  local cmd message
  while IFS='|' read -r cmd message; do
    gate "$cmd"
    expect_rc 1; expect_err_has "$message"
  done <<'EOF'
reverb-app-add 0|its first argument is not an environment number
reverb-app-add 012|its first argument is not an environment number
reverb-app-add shop|its first argument is not an environment number
reverb-app-add 12 13|reverb-app-add takes 1 argument(s), got 2
reverb-app-remove|reverb-app-remove takes 1 argument(s), got 0
EOF
  run apps; expect_out '{"apps":[]}'

  chmod 644 "$(apps_file)"
  gate "reverb-app-add 12"; expect_rc 1; expect_err_has "apps.json must be yours and mode 600"
  chmod 600 "$(apps_file)"

  printf 'not json\n' >"$(apps_file)"
  gate "reverb-app-add 12"; expect_rc 1; expect_err_has 'apps.json is not {"apps": [...]} in JSON'
  run cat "$(apps_file)"; expect_out "not json"
  gate "reverb-app-remove 12"; expect_rc 1; expect_err_has 'apps.json is not {"apps": [...]} in JSON'
  run ls -A "$(reverb_dir)/apps"; expect_out apps.json

  rm "$(apps_file)"
  gate "reverb-app-add 12"; expect_rc 1; expect_err_has "apps.json is missing; run mroom baseline reverb"

  world
  printf 'MROOM_APP_NAME=shop\n' >"$HOME/.config/mroom/box.env"
  gate "reverb-app-add 12"; expect_rc 1; expect_err_has "MROOM_QA_ZONE is not set in box.env"
}

test_case add t_add_gives_an_environment_an_app_of_its_own
test_case add-again t_add_again_keeps_the_secret_and_replaces_the_file_whole
test_case remove-add t_remove_then_add_gives_a_new_secret
test_case remove t_remove_takes_only_its_own_app
test_case remove-host-down t_remove_works_while_the_host_is_down
test_case adds-at-once t_adds_at_once_keep_every_app
test_case derived-alike t_qa_plan_derives_what_the_gate_gives
test_case host-down t_add_refuses_while_the_host_does_not_answer
test_case refusals t_what_the_reverb_operations_refuse
finish
