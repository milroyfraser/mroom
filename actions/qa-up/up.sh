#!/usr/bin/env bash
# up.sh <N> <commit> — creates or refreshes QA environment N for pull request N at <commit> (actions/qa-up; design
# 8.2, D17). It runs where no pull request code runs: in the qa environment, with the default branch's mroom.toml
# and mroom at the workflow's commit. The pull request's code reaches the box only as data, GitHub's tarball of the
# commit and the frontend qa-plan built, which the gate unpacks as the environment's own site user. Each step checks
# its own resource, so a run that stopped halfway is repaired by the next. In order:
#   1. refuses what it cannot do yet, and a build that holds anything but files and folders, before anything is made
#   2. waits for a site of the environment that Forge is still removing, sending the delete again when it is stuck;
#      then, for a new environment, counts the others: from qa.max_envs (5) on, it waits for a slot
#   3. the api site, and the go site for a frontend of its own: Forge isolated sites in the home of the user
#      <app>_qa_<N>, each with a certificate and nginx's disable_symlinks if_not_owner, which is checked on every
#      run before any code goes in; the go site also serves index.html for a path it does not have
#   4. the code: GitHub's tarball of the commit through the gate's code-put, with Vite's build inside the Laravel
#      app put into it; a frontend of its own goes to the go site through dist-put
#   5. the environment's services through the gate: its database and role, Redis user, mail login and a bucket for
#      each file disk, as [qa.parity] says. qa.parity.broadcast = "same" waits for mroom's Reverb host
#   6. its .env: MROOM_QA_ENV_TEMPLATE, then mroom's own values, through env-put, as the site user
#   7. Forge's deploy, whose script pulls nothing and runs the app's qa-deploy and qa-fixtures hooks or their
#      defaults; then one queue worker, which must run as the site user
#   8. https://api-<N>.<zone>/up, asked until it answers 200
# Then the pull request's QA environment comment says it is ready, or waits for a slot, or failed.
#
# Environment: as down.sh's, and MROOM_QA_ENV_TEMPLATE (the shared .env: third-party test-mode keys, no app key and
# no credentials for the box), MROOM_QA_DIST (the folder of qa-plan's build), MROOM_QA_CERTIFICATE (a wildcard
# certificate to clone; without it, each site gets its own from Let's Encrypt), MROOM_QA_NGINX_TEMPLATE (an nginx
# template for new sites) and RUN_URL (this run, for the comment). Writes app_url, api_url and refused to
# GITHUB_OUTPUT. Exit codes: 0 up, or waiting for a slot; 1 failed; 2 a usage error.
set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
HERE="$(dirname "$SELF")"
MROOM_ROOT="$(cd "$HERE/../.." && pwd)"
export MROOM_ROOT
# shellcheck source=lib/core/util.sh
. "$MROOM_ROOT/lib/core/util.sh"
# shellcheck source=lib/core/forge.sh
. "$MROOM_ROOT/lib/core/forge.sh"
# shellcheck source=lib/core/qa.sh
. "$MROOM_ROOT/lib/core/qa.sh"
FORGE_NAME="mroom qa-up" QA_NAME="mroom qa-up"

n="${1:-}" sha="${2:-}"
if ! qa_number "$n" || ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || [ "$#" != 2 ]; then
  echo "usage: up.sh <N> <full commit SHA>" >&2
  exit 2
fi
need curl jq python3 ssh gh tar sha256sum
# The scratch folder holds the environment's settings and the gate's answers.
umask 077

WORK="" DONE=""
output() { if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "$1" >>"$GITHUB_OUTPUT"; fi; }
can_comment() { [ -n "${GH_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; }
# die <why>: stops the run, and leaves the why for the comment, also from a subshell.
die() { if [ -n "$WORK" ]; then printf '%s' "$1" >"$WORK/failed"; fi; qa_say "$1"; exit 1; }
on_exit() {
  local why=""
  if [ -n "$WORK" ] && [ -f "$WORK/failed" ]; then why="$(cat "$WORK/failed")"; fi
  if [ "$1" != 0 ] && [ -z "$DONE" ] && can_comment; then
    qa_comment "$n" failed "The deploy of \`$sha\` failed${why:+: $why}${RUN_URL:+ ([run]($RUN_URL))}. The next push tries again; a half-built environment goes when the pull request closes." \
      || echo "::warning::could not update the QA environment comment of pull request $n"
  fi
  qa_cleanup
  if [ -n "$WORK" ]; then rm -rf "$WORK"; fi
}
trap 'on_exit $?' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
WORK="$(mktemp -d)"
pause="${MROOM_QA_POLL:-5}"
[[ "$pause" =~ ^[1-9][0-9]?$ ]] || pause=5

qa_names "$n"
qa_gate_init

# 1. What the app asks for, from the default branch's mroom.toml, all checked before anything is made. A key that
# cannot be read stops the run.
# setting <key> <default>: one value of the app's mroom.toml.
setting() { qa_config "$1" "$2" || die "mroom.toml's $1 could not be read"; }
broadcast="$(setting qa.parity.broadcast same)"
if [ "$broadcast" = same ]; then
  die "not yet: qa.parity.broadcast = \"same\" needs mroom's Reverb host, which is wired in later (design D16); set it to \"log\" in mroom.toml until then"
fi
mail="$(setting qa.parity.mail catcher)"
files="$(setting qa.parity.files same)"
max="$(setting qa.max_envs 5)"
ttl="$(setting qa.ttl_days 5)"
php="$(setting app.php 8.4)"
[[ "$php" =~ ^([5-9])\.([0-9])$ ]] || die "app.php must be a version such as 8.4"
forge_php="php${BASH_REMATCH[1]}${BASH_REMATCH[2]}" php_bin="php$php"
queues="$(setting app.build.queues '["default"]')"
queues="$(paste -sd, - <<<"$queues")"
[[ "$queues" =~ ^[A-Za-z0-9_.:-]+(,[A-Za-z0-9_.:-]+)*$ ]] || die "app.build.queues must be plain queue names"
after_deploy=()
text="$(setting app.build.after_deploy '[]')"
while IFS= read -r command; do
  [ -n "$command" ] || continue
  [[ "$command" =~ ^[a-z][a-z0-9:_-]*(\ --?[a-z][a-z0-9-]*(=[A-Za-z0-9_.:/-]+)?)*$ ]] \
    || die "app.build.after_deploy holds a command that is not a plain artisan command: ${command:0:60}"
  after_deploy+=("$command")
done <<<"$text"
declare -A disks=() public=()
if [ "$files" = same ]; then
  text="$(setting qa.disks '{}')"
  while IFS='=' read -r disk prefix; do [ -z "$disk" ] || disks["$disk"]="$prefix"; done <<<"$text"
  text="$(setting qa.public_disks '[]')"
  while IFS= read -r disk; do
    [ -n "$disk" ] || continue
    [ -n "${disks[$disk]+set}" ] || die "qa.public_disks names $disk, which qa.disks does not have"
    public["$disk"]=1
  done <<<"$text"
fi
backend_path="/home/$QA_USER/$QA_API" tree_dist=""
[ "$QA_BACKEND" = . ] || backend_path+="/$QA_BACKEND"
dist="" build=""
build="$(setting app.build.frontend "")"
if [ -n "$build" ] && [ -n "$QA_FRONTEND" ]; then
  dist="${MROOM_QA_DIST:-}"
  if [ -z "$dist" ] || [ ! -d "$dist" ]; then die "there is no frontend build from the QA plan (MROOM_QA_DIST)"; fi
  # The build comes from a job that ran the pull request's code. nginx runs as the box user and follows links, so
  # only files and folders go on; a name is never printed, since one can hold a newline and a workflow command.
  [ -z "$(find "$dist" ! -type f ! -type d -print -quit)" ] || die "the frontend build holds something other than files and folders, such as a link"
  if qa_separate_frontend; then
    [ -f "$dist/index.html" ] || die "the frontend build has no index.html"
  else
    tree_dist="$(setting app.build.frontend_dist public/build)"
    [ "$QA_BACKEND" = . ] || tree_dist="$QA_BACKEND/$tree_dist"
  fi
fi

# site_id <domain>: the site's id, or nothing when there is none or Forge is removing it.
site_id() {
  local site
  site="$(forge_site "$1")" || return 1
  jq -r 'select(.attributes.status != "removing") | .id // empty' <<<"${site:-null}"
}

# 2. A site of this environment that Forge is still removing (a teardown just before this push) is waited for, so
# the environment is made fresh; a removing site is never refreshed or counted.
for domain in "$QA_API" "$QA_WEB"; do
  site="$(forge_site "$domain")"
  [ "$(jq -r '.attributes.status // ""' <<<"${site:-null}")" = removing ] || continue
  minutes="$(qa_redelete_stuck "$site")"
  [ -z "$minutes" ] || echo "==> $domain had been removing for $minutes minutes; sent the delete again"
  echo "==> $domain is still being removed; waiting for it to go"
  waited=0
  while :; do
    site="$(forge_site "$domain")" || die "Forge's site $domain could not be read"
    [ -n "$site" ] || break
    ((waited < ${MROOM_QA_REMOVE_WAIT:-600})) || die "$domain was still being removed after ${waited}s"
    sleep "$pause"
    waited=$((waited + pause))
  done
done

api_id="$(site_id "$QA_API")" || die "Forge's site $QA_API could not be read"
if [ -z "$api_id" ]; then
  # An existing environment is always refreshed; only a new one waits.
  envs="$(qa_envs)"
  running="$(awk '$2 != "removing"' <<<"$envs" | grep -c . || true)"
  if ((running >= max)); then
    refused="All $max QA environments are in use, so this pull request waits for a slot. It deploys when one frees up, or on a later push once one is free."
    echo "::warning::$refused"
    output "refused=$refused"
    DONE=1
    if can_comment; then qa_comment "$n" waiting "$refused" || echo "::warning::could not update the QA environment comment"; fi
    exit 0
  fi
fi

# 3. The sites.
# site_ready <domain>: waits until Forge has made the site, and refuses one that is not isolated in the
# environment's own user's home (D17), such as a site someone made by hand.
site_ready() {
  local site status waited=0
  while :; do
    site="$(forge_site "$1")"
    status="$(jq -r '.attributes.status // "missing"' <<<"${site:-null}")"
    case "$status" in
      installed | deployed | never-deployed) break ;;
      failed) die "Forge could not make the site $1" ;;
    esac
    ((waited < ${MROOM_QA_SITE_WAIT:-300})) || die "the site $1 was still $status after ${waited}s"
    sleep "$pause"
    waited=$((waited + pause))
  done
  jq -e --arg user "$QA_USER" '.attributes.isolated == true and .attributes.user == $user' <<<"$site" >/dev/null \
    || die "$1 is not a Forge isolated site of the user $QA_USER; delete it in Forge and run again"
}

# make_site <domain> <type> <web directory>: sets SITE_ID to the site's, made when there is none.
make_site() {
  local id body
  id="$(site_id "$1")" || die "Forge's site $1 could not be read"
  if [ -z "$id" ]; then
    body="$(jq -nc --arg name "$1" --arg type "$2" --arg web "$3" --arg user "$QA_USER" --arg php "$forge_php" \
      --arg template "${MROOM_QA_NGINX_TEMPLATE:-}" '{type: $type, name: $name, domain_mode: "custom",
        www_redirect_type: "none", allow_wildcard_subdomains: false, web_directory: $web, is_isolated: true,
        isolated_user: $user, push_to_deploy: false}
      + (if $type == "php" then {php_version: $php, install_composer_dependencies: false,
          zero_downtime_deployments: false} else {} end)
      + (if $template | test("^[0-9]+$") then {nginx_template_id: ($template | tonumber)} else {} end)')"
    id="$(forge POST /sites "$body" | jq -r '.data.id // empty')"
    [[ "$id" =~ ^[0-9]+$ ]] || die "Forge made no site $1"
    echo "    created site $id"
  fi
  SITE_ID="$id"
}

# certificate <site id>: an active certificate, cloned from MROOM_QA_CERTIFICATE or from Let's Encrypt, waited for:
# the site's health is asked over https.
certificate() {
  local domain body waited=0
  if [ "$(forge GET "/sites/$1/certificates" | jq '[.data[]?.attributes
      | select(.active == true or ((.request_status // "") | IN("verifying", "creating")))] | length')" = 0 ]; then
    domain="$(forge GET "/sites/$1/domains" | jq -r '[.data[]? | select(.attributes.type == "primary")][0].id // empty')"
    [[ "$domain" =~ ^[0-9]+$ ]] || die "Forge gave site $1 no primary domain"
    if [[ "${MROOM_QA_CERTIFICATE:-}" =~ ^[0-9]+$ ]]; then
      body="$(jq -nc --argjson id "$MROOM_QA_CERTIFICATE" '{type: "clone", clone: {certificate_id: $id}}')"
    else
      body='{"type":"letsencrypt","letsencrypt":{"verification_method":"http-01","key_type":"ecdsa"}}'
    fi
    forge POST "/sites/$1/domains/$domain/certificates" "$body" >/dev/null
    echo "    asked for a certificate"
  fi
  until forge GET "/sites/$1/certificates" | jq -e 'any(.data[]?; .attributes.active == true)' >/dev/null; do
    ((waited < ${MROOM_QA_CERT_WAIT:-300})) || die "site $1 had no active certificate after ${waited}s"
    sleep "$pause"
    waited=$((waited + pause))
  done
}

# guard_nginx <site id> [spa]: nginx runs as the box user and follows links, so it must follow one only when the
# link and its target have one owner (disable_symlinks if_not_owner), or code put into the site could link to a box
# user's file and serve it (D17). With spa, a path the site does not have serves index.html, so a single-page
# app's routes survive a reload. Checked on every run, after the certificate, and before any code goes in.
guard_nginx() {
  local config want
  config="$(forge GET "/sites/$1/nginx" | jq -r '.data.attributes.content // empty')"
  [ -n "$config" ] || die "Forge gave site $1 no nginx config"
  want="$config"
  if ! grep -q 'disable_symlinks if_not_owner;' <<<"$want"; then
    want="$(awk '{ print } /^[[:space:]]*root[[:space:]]+[^;]+;[[:space:]]*$/ {
      match($0, /^[[:space:]]*/); printf "%sdisable_symlinks if_not_owner;\n", substr($0, 1, RLENGTH) }' <<<"$want")"
  fi
  # shellcheck disable=SC2016  # nginx's own $uri
  if [ "${2:-}" = spa ]; then want="${want//'try_files $uri $uri/ =404;'/'try_files $uri $uri/ /index.html;'}"; fi
  if [ "$want" != "$config" ]; then
    forge PUT "/sites/$1/nginx" "$(jq -nc --arg c "$want" '{config: $c}')" >/dev/null
    config="$(forge GET "/sites/$1/nginx" | jq -r '.data.attributes.content // empty')"
    echo "    nginx config: links followed only to their owner's files${2:+, and the single-page fallback}"
  fi
  grep -q 'disable_symlinks if_not_owner;' <<<"$config" || die "site $1's nginx config has no root line for disable_symlinks, so no code goes in"
  # shellcheck disable=SC2016
  if [ "${2:-}" = spa ] && ! grep -qF 'try_files $uri $uri/ /index.html;' <<<"$config"; then
    die "site $1's nginx config has no try_files line to send unknown paths to index.html"
  fi
}

echo "==> Site $QA_API"
web_root=/public
[ "$QA_BACKEND" = . ] || web_root="/$QA_BACKEND/public"
make_site "$QA_API" php "$web_root"
api_id="$SITE_ID"
site_ready "$QA_API"
certificate "$api_id"
guard_nginx "$api_id"
web_id=""
if qa_separate_frontend; then
  echo "==> Site $QA_WEB"
  make_site "$QA_WEB" static-html /
  web_id="$SITE_ID"
  site_ready "$QA_WEB"
  certificate "$web_id"
  guard_nginx "$web_id" spa
fi

# 4. The code, as data.
echo "==> Code: $sha"
gh api "repos/$GITHUB_REPOSITORY/tarball/$sha" >"$WORK/code.tgz" || die "GitHub gave no tarball of $sha"
if [ -n "$tree_dist" ]; then
  python3 -I "$HERE/merge-build" "$WORK/code.tgz" "$dist" "$tree_dist" >"$WORK/code-build.tgz" \
    || die "the frontend build could not go into the code"
  mv "$WORK/code-build.tgz" "$WORK/code.tgz"
  echo "    with the frontend build in $tree_dist"
fi
out="$(qa_gate code-put "$n" "$sha" <"$WORK/code.tgz")" || die "the gate refused the code (code-put)"
qa_show "$out"
if [ -n "$web_id" ]; then
  echo "==> Frontend"
  tar -czf "$WORK/dist.tgz" -C "$dist" .
  out="$(qa_gate dist-put "$n" <"$WORK/dist.tgz")" || die "the gate refused the frontend build (dist-put)"
  qa_show "$out"
fi

# 5. The services, through the gate. What it gives is kept for the .env, masked in the log, never printed.
: >"$WORK/values"
set_env() { printf '%s=%s\n' "$1" "$2" >>"$WORK/values"; }
# service <what> <operation> <argument...>: the gate's KEY=value lines, kept in $WORK/gate for keep and gate_value,
# its passwords and secret keys masked, and its other lines shown.
service() {
  local what="$1" out line
  shift
  echo "==> $what"
  out="$(qa_gate "$@")" || die "the gate could not give the environment its $what ($1)"
  : >"$WORK/gate"
  while IFS= read -r line; do
    if [[ "$line" =~ ^([A-Z][A-Z_]*)=([!-~]*)$ ]]; then
      case "${BASH_REMATCH[1]}" in *PASSWORD | *SECRET*) qa_mask "${BASH_REMATCH[2]}" ;; esac
      printf '%s=%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" >>"$WORK/gate"
    elif [ -n "$line" ]; then
      qa_show "$line"
    fi
  done <<<"$out"
}
gate_value() { sed -n "s/^$1=//p" "$WORK/gate" | head -n1; }
# keep <KEY...>: the gate's values of these keys, into the .env under the same names.
keep() {
  local key value
  for key in "$@"; do
    value="$(gate_value "$key")"
    [ -n "$value" ] || die "the gate gave no $key"
    set_env "$key" "$value"
  done
}
service "database and role" db-create "$n"
set_env DB_CONNECTION pgsql
# The box's pg_hba.conf lets an environment's role in over TCP alone (README, QA gate).
set_env DB_HOST 127.0.0.1
keep DB_DATABASE DB_USERNAME DB_PASSWORD
service "Redis user" redis-user-add "$n"
keep REDIS_USERNAME REDIS_PASSWORD REDIS_PREFIX HORIZON_PREFIX
if [ "$mail" = catcher ]; then
  service "mail login" mail-user-add "$n"
  keep MAIL_MAILER MAIL_HOST MAIL_PORT MAIL_USERNAME MAIL_PASSWORD
else
  set_env MAIL_MAILER log
fi
if [ "$files" = same ]; then
  # A bucket and a key of its own for each disk, under the env names the disk reads: Laravel's own for s3, with
  # the disk's prefix in place of AWS_ (AWS_BUCKET, AWS_ACCESS_KEY_ID, ...).
  for disk in $(printf '%s\n' "${!disks[@]}" | sort); do
    prefix="${disks[$disk]}"
    service "bucket for the disk $disk" bucket-create "$n" "$disk" ${public[$disk]:+public}
    for pair in BUCKET:BUCKET ACCESS_KEY_ID:ACCESS_KEY_ID SECRET_ACCESS_KEY:SECRET_ACCESS_KEY REGION:DEFAULT_REGION \
      ENDPOINT:ENDPOINT PATH_STYLE:USE_PATH_STYLE_ENDPOINT URL:URL; do
      value="$(gate_value "${pair%%:*}")"
      [ -n "$value" ] || [ "${pair%%:*}" = URL ] || die "the gate gave the disk $disk no ${pair%%:*}"
      [ -z "$value" ] || set_env "$prefix${pair#*:}" "$value"
    done
  done
else
  set_env FILESYSTEM_DISK local
fi
set_env BROADCAST_CONNECTION log
set_env BROADCAST_DRIVER log

# 6. The .env: the template, without any key mroom sets, then mroom's values. A new app key each deploy, since the
# template holds none and the environment's own .env cannot be read back.
app_key="base64:$(head -c 32 /dev/urandom | base64 | tr -d '\n')"
qa_mask "$app_key"
set_env APP_KEY "$app_key"
# Off: the hosts are public, and a debug page shows the environment's settings.
set_env APP_DEBUG false
while IFS= read -r line; do set_env "${line%%=*}" "${line#*=}"; done < <(qa_public_env)
set_env CACHE_PREFIX "${QA_USER}_cache_"
printf '%s\n' "${MROOM_QA_ENV_TEMPLATE:-}" >"$WORK/template"
awk -F '=' 'NR == FNR { set[$1] = 1; next }
  { key = $1; sub(/^export[[:space:]]+/, "", key); if (!(key in set)) print }' "$WORK/values" "$WORK/template" >"$WORK/env"
cat "$WORK/values" >>"$WORK/env"
echo "==> .env"
out="$(qa_gate env-put "$n" <"$WORK/env")" || die "the gate could not write the .env (env-put)"
want="$(printf '%s' "$(cat "$WORK/env")" | sha256sum | cut -d' ' -f1)"
[ "$out" = "env=$want" ] || die "the .env the gate wrote is not the one sent"
echo "    written, $(wc -l <"$WORK/env" | tr -d ' ') lines"

# 7. Forge's deploy: a script that pulls nothing, then the queue worker.
deploy_script() {
  local root="/home/$QA_USER/$QA_API" command
  printf '%s\n' "# Written by mroom's qa-up for QA environment $n (design 6, D17). The gate put the tree in place, so this" \
    "# pulls nothing and builds no frontend; Forge runs it as the site's own user." \
    "set -eo pipefail" "php=\"\${FORGE_PHP:-$php_bin}\"" "composer=\"\${FORGE_COMPOSER:-composer}\"" \
    "export MROOM_QA_ENV=$n" "cd $backend_path" \
    "if [ -x $root/.mroom/hooks/qa-deploy ]; then" "  $root/.mroom/hooks/qa-deploy" "else" \
    "  \$composer install --no-interaction --prefer-dist --optimize-autoloader" "  \"\$php\" artisan migrate --force"
  # shellcheck disable=SC2016  # the script's own $php
  for command in "${after_deploy[@]}"; do printf '  "$php" artisan %s\n' "$command"; done
  printf '%s\n' "fi" "if [ -x $root/.mroom/hooks/qa-fixtures ]; then" "  $root/.mroom/hooks/qa-fixtures" \
    "elif \"\$php\" artisan list --raw 2>/dev/null | grep -q '^mroom:qa-fixtures '; then" "  \"\$php\" artisan mroom:qa-fixtures" \
    "fi" "\"\$php\" artisan queue:restart"
}
newest_deployment() { forge GET "/sites/$api_id/deployments?sort=-created_at&page[size]=1" | jq -r '.data[0].id // empty'; }
echo "==> Deploy"
forge PUT "/sites/$api_id/deployments/script" "$(jq -nc --arg c "$(deploy_script)" '{content: $c, auto_source: false}')" >/dev/null
before="$(newest_deployment)"
forge POST "/sites/$api_id/deployments" >/dev/null
# The answer may name no deployment: the one newer than the newest before is this run's.
waited=0
until deployment="$(newest_deployment)" && [ -n "$deployment" ] && [ "$deployment" != "$before" ]; do
  ((waited < 120)) || die "no new deployment of $QA_API appeared"
  sleep "$pause"
  waited=$((waited + pause))
done
[[ "$deployment" =~ ^[0-9]+$ ]] || die "Forge gave the deployment no id"
waited=0
while :; do
  status="$(forge GET "/sites/$api_id/deployments/$deployment" | jq -r '.data.attributes.status // "unknown"')"
  case "$status" in
    finished) break ;;
    failed | failed-build | cancelled)
      # The output is the pull request's code's, so no line of it may be read as a workflow command.
      token="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
      echo "The end of the deploy's output:"
      echo "::stop-commands::$token"
      forge GET "/sites/$api_id/deployments/$deployment/log" | jq -r '.data.attributes.output // empty' | tail -n 60 || true
      echo "::$token::"
      die "Forge's deploy $deployment of $QA_API ended $status"
      ;;
  esac
  ((waited < ${MROOM_QA_DEPLOY_WAIT:-900})) || die "Forge's deploy $deployment of $QA_API was still $status after ${waited}s"
  sleep "$pause"
  waited=$((waited + pause))
done
echo "    deploy $deployment finished"

echo "==> Queue worker"
daemons="$(qa_processes)" || die "Forge's daemons could not be read"
mine=""
while read -r id status user; do
  [ -n "$id" ] || continue
  if [ "$user" = "$QA_USER" ]; then mine="$id"; continue; fi
  # A daemon as another user would run the pull request's code as that user, forge or root (D20).
  forge DELETE "/background-processes/$id" >/dev/null
  echo "    deleted daemon $id, which ran as $user"
done <<<"$daemons"
if [ -z "$mine" ]; then
  body="$(jq -nc --arg name "${QA_USER}-queue" --argjson site "$api_id" --arg user "$QA_USER" --arg dir "$backend_path" \
    --arg command "$php_bin artisan queue:work --queue=$queues --tries=3 --max-time=3600" \
    '{name: $name, site_id: $site, command: $command, user: $user, directory: $dir, processes: 1}')"
  made="$(forge POST /background-processes "$body")" || die "Forge refused the queue worker, run as $QA_USER (design D17)"
  mine="$(jq -r '.data.id // empty' <<<"$made")"
  [[ "$mine" =~ ^[0-9]+$ ]] || die "Forge made no queue worker"
  # Forge's API names only root and forge as a daemon's user: the new one is read back, and kept only when it runs
  # as the site user (D17).
  user="$(forge GET "/background-processes/$mine" | jq -r '.data.attributes.user // ""')"
  if [ "$user" != "$QA_USER" ]; then
    forge DELETE "/background-processes/$mine" >/dev/null || true
    die "Forge started the queue worker as ${user:-an unknown user}, not $QA_USER, so it was deleted again"
  fi
  echo "    created worker $mine, run as $QA_USER"
else
  echo "    worker $mine runs as $QA_USER"
fi

# 8. Health.
echo "==> https://$QA_API/up"
code="$(qa_up_code "https://$QA_API")"
[ "$code" = 200 ] || die "https://$QA_API/up answered $code, still, after ${MROOM_QA_UP_TRIES:-6} tries"
echo "    200"

app_url="https://$QA_API"
if qa_separate_frontend; then app_url="https://$QA_WEB"; fi
output "app_url=$app_url"
output "api_url=https://$QA_API"
DONE=1
if can_comment; then
  table="| | |"$'\n'"|---|---|"$'\n'
  if qa_separate_frontend; then table+="| App | $app_url |"$'\n'; fi
  table+="| API | https://$QA_API |"
  qa_comment "$n" ready "$table"$'\n\n'"Updated for \`$sha\`. Every push that needs it refreshes it. It goes when the pull request closes, its ${LABEL:-qa} label comes off, or after $ttl days." \
    || echo "::warning::could not update the QA environment comment of pull request $n"
fi
echo "environment $n: up at $app_url"
