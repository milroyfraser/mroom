#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2016  # t_* run through test_case; a $ in single quotes is nginx's or the script's own
# Tests for bringing a QA environment up (actions/qa-up/up.sh and start.sh): isolated sites with nginx guarded
# before any code goes in, the code and the frontend as data through the gate, the environment's own services and
# .env, a deploy script that pulls nothing, a queue worker kept only when it runs as the site user, /up asked again
# after a 502, slots, and secrets never in the log. Offline: Forge, GitHub and the gate are fakes.
set -euo pipefail
SUITE=qa-up
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/qa-world.sh
source "$(dirname "${BASH_SOURCE[0]}")/qa-world.sh"
skip_unless has_box_tools "this host lacks bash 5, flock or GNU date, which the QA actions need"
skip_unless has_tomllib "python3 has no tomllib (needs 3.11+)"

UP="$ROOT/actions/qa-up/up.sh"
START="$ROOT/actions/qa-up/start.sh"
SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
SECRETS=(db-pw-7 redis-pw-7 mail-pw-7 bucket-pw-files bucket-pw-media)
TWO='[app]
name = "shop"
backend_dir = "api"
frontend_dir = "web"
php = "8.4"

[app.build]
frontend = "npm run build"
after_deploy = ["config:cache", "route:cache"]
queues = ["default", "mail"]

[qa]
zone = "qa.example.dev"
max_envs = 3
disks = { files = "AWS_", media = "MEDIA_" }
public_disks = ["media"]

[qa.parity]
broadcast = "log"'

# app <toml> [<path=content>...]: the app's mroom.toml, GitHub's tarball of $SHA with those files, a frontend
# build in $T/dist, the shared .env template and /up answering 200.
app() {
  qa_world
  printf '%s\n' "$1" >"$MROOM_CONFIG"
  shift
  local top="$T/src/example-shop-${SHA:0:7}" file
  mkdir -p "$top" "$T/dist/assets"
  for file in "$@"; do mkdir -p "$(dirname "$top/${file%%=*}")"; printf '%s\n' "${file#*=}" >"$top/${file%%=*}"; done
  tar -czf "$GH_FAKE/tarball.tgz" -C "$T/src" "example-shop-${SHA:0:7}"
  echo '<html>app</html>' >"$T/dist/index.html"
  echo 'console.log(1)' >"$T/dist/assets/app.js"
  export MROOM_QA_DIST="$T/dist" FORGE_UP="$T/up-codes" LABEL=qa
  # A runner sets GITHUB_ACTIONS, with which up.sh masks its secrets; the test that wants that sets it itself.
  unset GITHUB_ACTIONS
  export MROOM_QA_ENV_TEMPLATE=$'APP_NAME=Shop\nAPP_KEY=base64:from-the-template\nDB_PASSWORD=from-the-template\nMAPS_KEY=test-maps-key'
  echo 200 >"$FORGE_UP"
}
up() { run "$UP" 7 "$SHA"; }
state() { jq -r "$1" "$FORGE_STATE"; }
env_sent() { cat "$GATE/env-put.in"; }
has_line() { grep -qxF -- "$2" <<<"$1"; }
members() { tar -tzf "$1" | sort; }

t_a_new_environment_comes_up() {
  app "$TWO" api/artisan=php api/public/index.php=php
  up
  expect_rc 0; expect_out_has "environment 7: up at https://go-7.qa.example.dev"
  # Both sites isolated in the user's own home, with nginx guarded before the code went in.
  run state '[.sites[] | "\(.name) \(.type) \(.user) \(.isolated) \(.web_directory) \(.php_version)"] | join("\n")'
  expect_out $'api-7.qa.example.dev php shop_qa_7 true /api/public php84\ngo-7.qa.example.dev static-html shop_qa_7 true / null'
  run state '.sites[0].nginx'
  expect_out_has $'    root /home/shop_qa_7/api-7.qa.example.dev/api/public;\n    disable_symlinks if_not_owner;'
  run state '.sites[1].nginx'
  expect_out_has $'    root /home/shop_qa_7/go-7.qa.example.dev;\n    disable_symlinks if_not_owner;'
  expect_out_has 'try_files $uri $uri/ /index.html;'
  run order
  expect_out $'forge POST /sites\nforge POST /sites/101/domains/1010/certificates\nforge PUT /sites/101/nginx
forge POST /sites\nforge POST /sites/103/domains/1030/certificates\nforge PUT /sites/103/nginx
gate code-put 7 '"$SHA"$'\ngate dist-put 7\ngate db-create 7\ngate redis-user-add 7\ngate mail-user-add 7
gate bucket-create 7 files\ngate bucket-create 7 media public\ngate env-put 7
forge PUT /sites/101/deployments/script\nforge POST /sites/101/deployments\nforge POST /background-processes'
  # The code is GitHub's tarball, as it came; the frontend, the build's files.
  expect_true "the code put is not GitHub's tarball" cmp -s "$GATE/code-put.in" "$GH_FAKE/tarball.tgz"
  run members "$GATE/dist-put.in"; expect_out $'./\n./assets/\n./assets/app.js\n./index.html'
  run cat "$GITHUB_OUTPUT"; expect_out $'app_url=https://go-7.qa.example.dev\napi_url=https://api-7.qa.example.dev'
  run cat "$FORGE_UP.log"; expect_out 200
}

t_the_env_holds_the_environments_own_values() {
  app "$TWO" api/artisan=php
  up
  expect_rc 0
  local sent
  sent="$(env_sent)"
  local line
  for line in APP_NAME=Shop MAPS_KEY=test-maps-key DB_CONNECTION=pgsql DB_HOST=127.0.0.1 DB_DATABASE=shop_qa_7 \
    DB_USERNAME=shop_qa_7 DB_PASSWORD=db-pw-7 REDIS_USERNAME=shop_qa_7 REDIS_PASSWORD=redis-pw-7 \
    REDIS_PREFIX=shop:qa7: HORIZON_PREFIX=shop:qa7:horizon: MAIL_MAILER=smtp MAIL_HOST=127.0.0.1 MAIL_PORT=1025 \
    MAIL_USERNAME=shop_qa_7 MAIL_PASSWORD=mail-pw-7 AWS_BUCKET=shop-qa-7-files AWS_ACCESS_KEY_ID=GKfiles \
    AWS_SECRET_ACCESS_KEY=bucket-pw-files AWS_DEFAULT_REGION=garage AWS_ENDPOINT=https://s3.qa.example.dev \
    AWS_USE_PATH_STYLE_ENDPOINT=true MEDIA_BUCKET=shop-qa-7-media MEDIA_URL=https://files.qa.example.dev/shop-qa-7-media \
    BROADCAST_CONNECTION=log APP_DEBUG=false APP_URL=https://api-7.qa.example.dev CLIENT_URL=https://go-7.qa.example.dev \
    SESSION_DOMAIN=.qa.example.dev SESSION_COOKIE=shop_qa_7_session XSRF_COOKIE_NAME=shop_qa_7_xsrf \
    CORS_ALLOWED_ORIGINS=https://go-7.qa.example.dev SANCTUM_STATEFUL_DOMAINS=go-7.qa.example.dev,api-7.qa.example.dev \
    CACHE_PREFIX=shop_qa_7_cache_; do
    expect_true ".env lacks $line" has_line "$sent" "$line"
  done
  # The template's own key and password are replaced, never kept beside mroom's; a private disk has no URL.
  run grep -c -e '^APP_KEY=' -e '^DB_PASSWORD=' <<<"$sent"; expect_out 2
  expect_true "the template's app key was kept" lacks "$sent" "from-the-template"
  run grep -c '^APP_KEY=base64:' <<<"$sent"; expect_out 1
  expect_true "a private disk got a URL" lacks "$sent" "AWS_URL="
}

t_secrets_never_reach_the_log() {
  app "$TWO" api/artisan=php
  up
  expect_rc 0
  local secret key
  key="$(sed -n 's/^APP_KEY=//p' "$GATE/env-put.in")"
  for secret in "${SECRETS[@]}" "$key" not-a-real-key fake-forge-token; do
    expect_true "the log shows $secret" lacks "$out$err" "$secret"
  done
  # On a runner, each is masked first, which is the one line that may name it.
  export GITHUB_ACTIONS=true
  rm -f "$GATE/gate.log"
  up
  expect_rc 0
  for secret in "${SECRETS[@]}"; do
    run_out="$out"
    expect_true "$secret is not masked" has_line "$run_out" "::add-mask::$secret"
    expect_true "$secret shows outside its mask" [ "$(grep -c -- "$secret" <<<"$run_out")" = 1 ]
  done
  expect_true "the app key is not masked" grep -q '^::add-mask::base64:' <<<"$out"
  expect_true "the key folder or the .env was left in TMPDIR" tmp_empty
}

t_the_deploy_script_pulls_nothing() {
  app "$TWO" api/artisan=php
  up
  expect_rc 0
  run state '.sites[0].script'
  expect_out_has 'set -eo pipefail'
  expect_out_has 'cd /home/shop_qa_7/api-7.qa.example.dev/api'
  expect_out_has $'if [ -x /home/shop_qa_7/api-7.qa.example.dev/.mroom/hooks/qa-deploy ]; then\n  /home/shop_qa_7/api-7.qa.example.dev/.mroom/hooks/qa-deploy\nelse'
  expect_out_has $'  "$php" artisan migrate --force\n  "$php" artisan config:cache\n  "$php" artisan route:cache\nfi'
  expect_out_has '"$php" artisan mroom:qa-fixtures'
  expect_out_has '"$php" artisan queue:restart'
  expect_out_has 'php="${FORGE_PHP:-php8.4}"'
  expect_true "the deploy script pulls" lacks "$out" "git "
  expect_true "the deploy script builds a frontend" lacks "$out" "npm"
  run state '[.processes[] | "\(.user) \(.directory) \(.command) \(.processes)"] | join("\n")'
  expect_out "shop_qa_7 /home/shop_qa_7/api-7.qa.example.dev/api php8.4 artisan queue:work --queue=default,mail --tries=3 --max-time=3600 1"
}

t_a_single_app_gets_its_build_in_the_code() {
  app $'[app]\nname = "shop"\n\n[app.build]\nfrontend = "npm run build"\n\n[qa]\nzone = "qa.example.dev"\n\n[qa.parity]\nbroadcast = "log"\nmail = "log"\nfiles = "local"' \
    artisan=php public/index.php=php public/build/old.js=old
  # GitHub's tarball starts with a global header that names the commit.
  python3 -I - "$T/src" "$GH_FAKE/tarball.tgz" "$SHA" <<'PY'
import os, sys, tarfile
src, dst, sha = sys.argv[1:]
with tarfile.open(dst, "w:gz", format=tarfile.PAX_FORMAT, pax_headers={"comment": sha}) as tf:
    tf.add(os.path.join(src, f"example-shop-{sha[:7]}"), arcname=f"example-shop-{sha[:7]}")
PY
  up
  expect_rc 0; expect_out_has "with the frontend build in public/build"
  run python3 -I -c 'import sys, tarfile; print(tarfile.open(sys.argv[1]).pax_headers.get("comment"))' "$GATE/code-put.in"
  expect_out "$SHA"
  run state '[.sites[] | "\(.name) \(.web_directory)"] | join("\n")'; expect_out "api-7.qa.example.dev /public"
  run members "$GATE/code-put.in"
  expect_out "example-shop-aaaaaaa/
example-shop-aaaaaaa/artisan
example-shop-aaaaaaa/public/
example-shop-aaaaaaa/public/build/
example-shop-aaaaaaa/public/build/assets/
example-shop-aaaaaaa/public/build/assets/app.js
example-shop-aaaaaaa/public/build/index.html
example-shop-aaaaaaa/public/index.php"
  expect_no_file "$GATE/dist-put.in"
  run gate_log; expect_out $'code-put 7 '"$SHA"$'\ndb-create 7\nredis-user-add 7\nenv-put 7'
  local sent
  sent="$(env_sent)"
  expect_true ".env lacks MAIL_MAILER=log" has_line "$sent" MAIL_MAILER=log
  expect_true ".env lacks FILESYSTEM_DISK=local" has_line "$sent" FILESYSTEM_DISK=local
  expect_true ".env lacks CLIENT_URL" has_line "$sent" CLIENT_URL=https://api-7.qa.example.dev
  expect_true ".env lacks SESSION_DOMAIN=null" has_line "$sent" SESSION_DOMAIN=null
  run cat "$GITHUB_OUTPUT"; expect_out $'app_url=https://api-7.qa.example.dev\napi_url=https://api-7.qa.example.dev'
}

t_an_existing_environment_is_refreshed() {
  app "$TWO" api/artisan=php
  up
  expect_rc 0
  : >"$ORDER_LOG"
  up
  expect_rc 0
  # No second site, certificate, nginx edit or worker: only the code, the services, the .env and a deploy.
  run order
  expect_out $'gate code-put 7 '"$SHA"$'\ngate dist-put 7\ngate db-create 7\ngate redis-user-add 7\ngate mail-user-add 7
gate bucket-create 7 files\ngate bucket-create 7 media public\ngate env-put 7
forge PUT /sites/101/deployments/script\nforge POST /sites/101/deployments'
  run state '.sites | length'; expect_out 2
  run state '.processes | length'; expect_out 1
  run gh_log
  expect_out_has $'### QA environment\\n<!-- mroom-qa: ready -->\\n\\n| | |\\n|---|---|\\n| App | https://go-7.qa.example.dev |\\n| API | https://api-7.qa.example.dev |\\n\\nUpdated for `'"$SHA"'`.'
  run grep -c '^POST 7 ' "$GH_FAKE/gh.log"; expect_out 1
  run grep -c '^PATCH ' "$GH_FAKE/gh.log"; expect_out 1
}

t_a_new_environment_waits_for_a_slot() {
  app "$TWO" api/artisan=php
  site 1 api-1.qa.example.dev installed
  site 2 api-2.qa.example.dev installed
  site 3 api-3.qa.example.dev installed
  site 4 api-4.qa.example.dev removing
  up
  expect_rc 0; expect_out_has "::warning::All 3 QA environments are in use, so this pull request waits for a slot."
  run forge_writes; expect_out ""
  run gate_log; expect_out ""
  run sed -n 's/^refused=//p' "$GITHUB_OUTPUT"; expect_out_has "All 3 QA environments are in use"
  run gh_log; expect_out_has 'POST 7 ### QA environment\n<!-- mroom-qa: waiting -->'
  # An environment that exists is refreshed, however many there are.
  site 5 api-7.qa.example.dev installed
  forge_set '.sites[-1] += {user: "shop_qa_7", nginx: "server {\n    root /home/shop_qa_7/api-7.qa.example.dev/api/public;\n}\n"}'
  up
  expect_rc 0
  run gate_log; expect_out_has "code-put 7 $SHA"
}

t_a_site_that_is_not_isolated_is_refused() {
  app "$TWO" api/artisan=php
  site 5 api-7.qa.example.dev installed
  forge_set '.sites[-1] += {user: "forge", isolated: false}'
  up
  expect_rc 1; expect_err_has "api-7.qa.example.dev is not a Forge isolated site of the user shop_qa_7; delete it in Forge and run again"
  run gate_log; expect_out ""
  run gh_log; expect_out_has 'mroom-qa: failed'
}

t_broadcast_same_is_not_yet() {
  app "${TWO/broadcast = \"log\"/broadcast = \"same\"}" api/artisan=php
  up
  expect_rc 1; expect_err_has "not yet: qa.parity.broadcast = \"same\" needs mroom's Reverb host"
  run forge_writes; expect_out ""
  run gate_log; expect_out ""
  run gh_log; expect_out_has "The deploy of \`$SHA\` failed: not yet: qa.parity.broadcast"
}

t_a_build_with_a_link_is_refused_before_anything_is_made() {
  app "$TWO" api/artisan=php
  ln -s /etc/hostname "$T/dist/assets/leak.txt"
  up
  expect_rc 1; expect_err_has "the frontend build holds something other than files and folders"
  run forge_writes; expect_out ""
  rm "$T/dist/assets/leak.txt" "$T/dist/index.html"
  up
  expect_rc 1; expect_err_has "the frontend build has no index.html"
  run forge_writes; expect_out ""
}

t_a_worker_forge_runs_as_another_user_is_deleted() {
  app "$TWO" api/artisan=php
  forge_set '.process_user = "forge"'
  up
  expect_rc 1; expect_err_has "Forge started the queue worker as forge, not shop_qa_7, so it was deleted again"
  run state '.processes | length'; expect_out 0
  # An old daemon of the environment as another user goes before a new one is made.
  forge_set 'del(.process_user)'
  process 50 forge /home/shop_qa_7/api-7.qa.example.dev/api
  up
  expect_rc 0; expect_out_has "deleted daemon 50, which ran as forge"
  run state '[.processes[].user] | join(",")'; expect_out "shop_qa_7"
}

t_a_failed_deploy_shows_its_output_but_runs_no_command() {
  app "$TWO" api/artisan=php
  forge_set '.deploy_result = "failed" | .deploy_log = "composer: done\n::set-output name=app_url::https://evil.example\nPHP Fatal error"'
  up
  expect_rc 1; expect_err_has "Forge's deploy 105 of api-7.qa.example.dev ended failed"
  local token
  token="$(sed -n 's/^::stop-commands:://p' <<<"$out")"
  expect_true "no stop-commands token" [ -n "$token" ]
  expect_out_has $'::stop-commands::'"$token"$'\ncomposer: done\n::set-output name=app_url::https://evil.example\nPHP Fatal error\n::'"$token"'::'
  run state '.processes | length'; expect_out 0
  run gh_log; expect_out_has "The deploy of \`$SHA\` failed: Forge's deploy 105 of api-7.qa.example.dev ended failed"
}

t_up_is_asked_again_after_a_502_and_fails_when_it_stays_down() {
  app "$TWO" api/artisan=php
  printf '502\n000\n200\n' >"$FORGE_UP"
  up
  expect_rc 0
  run cat "$FORGE_UP.log"; expect_out $'502\n000\n200'
  printf '502\n' >"$FORGE_UP"
  : >"$FORGE_UP.log"
  : >"$T/sleep.log"
  up
  expect_rc 1; expect_err_has "https://api-7.qa.example.dev/up answered 502, still, after 6 tries"
  run grep -c . "$FORGE_UP.log"; expect_out 6
  # One pause while the deploy runs, then five between the six tries, none after the last.
  run grep -c -x 5 "$T/sleep.log"; expect_out 6
}

t_a_site_forge_is_removing_is_waited_for() {
  app "$TWO" api/artisan=php
  site 9 api-7.qa.example.dev removing "$(ago 86400)" "$(ago 7200)"
  forge_set '.sites[-1].remove_reads = 2'
  up
  expect_rc 0
  expect_out_has "api-7.qa.example.dev had been removing for 120 minutes; sent the delete again"
  expect_out_has "api-7.qa.example.dev is still being removed; waiting for it to go"
  run state '[.sites[] | "\(.id) \(.name) \(.status)"] | join("\n")'
  expect_out $'101 api-7.qa.example.dev installed\n103 go-7.qa.example.dev installed'
}

t_an_env_the_gate_did_not_write_as_sent_fails() {
  app "$TWO" api/artisan=php
  echo "env=0000000000000000000000000000000000000000000000000000000000000000" >"$GATE/env-put.out"
  up
  expect_rc 1; expect_err_has "the .env the gate wrote is not the one sent"
  run forge_writes; expect_true "a deploy ran" lacks "$out" "/deployments"
}

t_what_decides_whether_it_comes_up() {
  app "$TWO" api/artisan=php
  echo '{"state": "OPEN"}' >"$GH_FAKE/pr-7.json"
  export PR=7 SHA REASON="1 of 1 paths could reach the app: 1 frontend"
  start() { run env "$@" "$START"; out="$(sed -n 's/^\(start\|why\)=//p' <<<"$out" | paste -sd'|' -)"; }
  start SCOPE=maybe BUILT=true; expect_out "true|a user could notice it: 1 of 1 paths could reach the app: 1 frontend"
  start SCOPE=none BUILT=true REASON="only paths no user can see changed: 2 docs"
  expect_out "false|no user could notice it: only paths no user can see changed: 2 docs"
  start SCOPE=none BUILT=true DISPATCHED=true; expect_out "true|started by hand, or by a freed slot"
  start SCOPE=maybe BUILT=true DRAFT=true; expect_out "false|a draft, which gets an environment once it is ready for review"
  start SCOPE=none BUILT=true DRAFT=true FORCED=true; expect_out "true|the qa label forces it on"
  start SCOPE=none BUILT=true DRAFT=true DISPATCHED=true; expect_out "true|a draft started by hand"
  site 1 api-7.qa.example.dev installed
  start SCOPE=none BUILT=true; expect_out "true|its environment is refreshed, so it serves the head"
  start SCOPE=none BUILT=true DRAFT=true; expect_out "true|a draft whose environment is refreshed, so it serves the head"
  run gh_log; expect_out ""
  # A build that failed deploys nothing, and the comment says so.
  start SCOPE=maybe BUILT=false RUN_URL=https://github.example/runs/1
  expect_out "false|the QA build failed, so there is nothing to deploy"
  run gh_log; expect_out_has "The QA build of \`$SHA\` failed, so nothing was deployed ([run](https://github.example/runs/1))."
  run env SCOPE=maybe BUILT=true "$START"; expect_out_has $'exists=true\ndist=true'
  # A deploy that waited behind a teardown brings no closed pull request's environment back.
  echo '{"state": "CLOSED"}' >"$GH_FAKE/pr-7.json"
  start SCOPE=maybe BUILT=true; expect_out "false|the pull request is no longer open"
}

t_usage() {
  app "$TWO"
  run "$UP" 7; expect_rc 2
  run "$UP" 07 "$SHA"; expect_rc 2
  run "$UP" 7 "${SHA:0:12}"; expect_rc 2
  run forge_writes; expect_out ""
}

test_case comes-up t_a_new_environment_comes_up
test_case env-values t_the_env_holds_the_environments_own_values
test_case secrets-off-the-log t_secrets_never_reach_the_log
test_case deploy-script t_the_deploy_script_pulls_nothing
test_case single-app t_a_single_app_gets_its_build_in_the_code
test_case refreshed t_an_existing_environment_is_refreshed
test_case waits-for-a-slot t_a_new_environment_waits_for_a_slot
test_case not-isolated t_a_site_that_is_not_isolated_is_refused
test_case broadcast-not-yet t_broadcast_same_is_not_yet
test_case build-with-a-link t_a_build_with_a_link_is_refused_before_anything_is_made
test_case worker-as-another-user t_a_worker_forge_runs_as_another_user_is_deleted
test_case failed-deploy-output t_a_failed_deploy_shows_its_output_but_runs_no_command
test_case up-asked-again t_up_is_asked_again_after_a_502_and_fails_when_it_stays_down
test_case removing-waited-for t_a_site_forge_is_removing_is_waited_for
test_case env-hash t_an_env_the_gate_did_not_write_as_sent_fails
test_case start-decisions t_what_decides_whether_it_comes_up
test_case usage t_usage
finish
