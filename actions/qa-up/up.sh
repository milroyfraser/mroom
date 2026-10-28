#!/usr/bin/env bash
# up.sh <N> <commit> — creates or refreshes QA environment N for pull request N at <commit> (actions/qa-up; design
# 8.2, D17). It runs where no pull request code runs: in the qa environment, with the default branch's mroom.toml
# and mroom at the workflow's commit. The pull request's code reaches the box only as data, GitHub's tarball of the
# commit and the frontend qa-plan built, which the gate unpacks as the environment's own site user. Each step checks
# its own resource, so a run that stopped halfway is repaired by the next. In order:
#   1. refuses settings it cannot use, and a build that holds anything but files and folders, before anything is made
#   2. refuses an environment brought up under the names of before mroom 0.5.0, which its teardown removes; waits
#      for a site of the environment that Forge is still removing, sending the delete again when it is stuck; then,
#      for a new environment (one whose code never went in, by the gate's record), counts the others: from
#      qa.max_envs (5) on, it waits for a slot, and it counts again once its site is made, giving way to one that
#      made its first site before it: its sites deleted, and waited for until Forge has them gone
#   3. the api site, api.<N>.<zone>, and for a frontend of its own the site <N>.<zone>: Forge isolated sites in the
#      home of the user <app>_qa_<N>, each with a certificate (one that failed is deleted and asked for again,
#      once; one installed but not active is enabled), and nginx's disable_symlinks if_not_owner at the top of its
#      config, which each of its domains includes in its server block: checked on every run, after Forge has
#      applied it, before any code goes in. The frontend's site also serves index.html for a path it does not have.
#      A site's PHP version is set when it is made: a site that runs another than app.php is refused, since it
#      needs making again
#   4. any daemon or scheduled job of the environment that does not run as its site user is deleted, and nothing goes
#      on while one is left: it would run the pull request's code as that user, forge or root (D20). Then the proof
#      that nginx refuses a link to another owner's file: the gate links the box's root-owned site-op into each web
#      root, and what the link answers must not be that file
#   5. the code: GitHub's tarball of the commit through the gate's code-put, with Vite's build inside the Laravel
#      app put into it; a frontend of its own goes to its own site through dist-put
#   6. the environment's services through the gate: its database and role, Redis user, mail login, a bucket for
#      each file disk and an app on the box's Reverb host, as [qa.parity] says, and its app key. The gate keeps their
#      passwords, the Reverb app's secret and the key, so each deploy gets the same ones: its users stay signed in,
#      and its open sockets keep their private channels
#   7. its .env file: MROOM_QA_ENV_TEMPLATE less the entries whose keys mroom sets, then mroom's own values,
#      through env-put, as the site user, and never through Forge's API for a site's environment
#   8. Forge's deploy, whose script refuses to run as any user but the site user, pulls nothing, and runs the app's
#      qa-deploy and qa-fixtures hooks or their defaults; then one queue worker, which also refuses any other user,
#      kept only when Forge's record names the site user, and made again when its command changed
#   9. https://api.<N>.<zone>/up, asked until it answers 200; only then is the commit said to be deployed (sha)
# What the pull request's QA environment comment is to say goes to qa_status: ready, waiting for a slot, or failed,
# and why.
#
# Environment: as down.sh's, and MROOM_QA_ENV_TEMPLATE (the shared .env: third-party test-mode keys, no app key and
# no credentials for the box), MROOM_QA_DIST (the folder of qa-plan's build), MROOM_QA_CERTIFICATE (a certificate to
# clone onto a frontend's site, such as one for *.<zone>; the API's site, which no certificate for *.<zone> names,
# and every site without it, gets its own from Let's Encrypt), MROOM_QA_NGINX_TEMPLATE (an nginx template for new
# sites), MROOM_QA_STATUS (lib/core/qa.sh, qa_status) and RUN_URL (this run, for the comment). Writes sha, app_url,
# api_url and refused to GITHUB_OUTPUT. Exit codes: 0 up, or waiting for a slot; 1 failed; 2 a usage error.
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
# die <why>: stops the run, and leaves the why for the comment, also from a subshell. die_teardown <why>: the same,
# for an environment only its teardown can fix, so the comment does not say that the next push tries again.
die() { if [ -n "$WORK" ]; then printf '%s' "$1" >"$WORK/failed"; fi; qa_say "$1"; exit 1; }
die_teardown() { if [ -n "$WORK" ]; then : >"$WORK/teardown"; fi; die "$1"; }
on_exit() {
  local why="" next="The next push tries again; a half-built environment goes when the pull request closes."
  if [ -n "$WORK" ] && [ -f "$WORK/failed" ]; then why="$(cat "$WORK/failed")"; fi
  if [ -n "$WORK" ] && [ -f "$WORK/teardown" ]; then next=""; fi
  if [ "$1" != 0 ] && [ -z "$DONE" ]; then
    qa_status failed "The deploy of \`$sha\` failed${why:+: $why}${RUN_URL:+ ([run]($RUN_URL))}.${next:+ $next}"
  fi
  qa_cleanup
  if [ -n "$WORK" ]; then rm -rf "$WORK"; fi
}
trap 'on_exit $?' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
qa_names "$n"
WORK="$(qa_temp)"
pause="${MROOM_QA_POLL:-5}"
[[ "$pause" =~ ^[1-9][0-9]?$ ]] || pause=5
qa_gate_init

# 1. What the app asks for, from the default branch's mroom.toml, all checked before anything is made. A key that
# cannot be read stops the run.
# setting <key> <default>: one value of the app's mroom.toml.
setting() { qa_config "$1" "$2" || die "mroom.toml's $1 could not be read"; }
broadcast="$(setting qa.parity.broadcast same)"
# The environment's values that are not secret, which qa-plan built the frontend with (lib/core/qa.sh).
public_env="$(qa_public_env)" || die "mroom.toml's qa.parity.broadcast could not be read"
public_value() { sed -n "s/^$1=//p" <<<"$public_env" | head -n1; }
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
# The worker refuses to run as any user but the site user, as the deploy script does: exit 78, a setup error, which
# supervisor stops retrying after a few tries.
worker_command="bash -c 'test \"\$(id -un)\" = $QA_USER || exit 78; exec $php_bin artisan queue:work --queue=$queues --tries=3 --max-time=3600'"

# site_id <domain>: the site's id, or nothing when there is none or Forge is removing it.
site_id() {
  local site
  site="$(forge_site "$1")" || return 1
  jq -r 'select(.attributes.status != "removing") | .id // empty' <<<"${site:-null}"
}

# 2. A site of this environment that Forge is still removing (a teardown just before this push) is waited for, so
# the environment is made fresh; a removing site is never refreshed or counted. An environment brought up before
# mroom 0.5.0 has its sites at api-<N>.<zone> and go-<N>.<zone>: one of them that Forge is not removing is refused
# first, before anything is sent or waited for, and is not refreshed under the names of now beside it. Its teardown
# removes it, by hand or when the pull request closes, its label comes off or its time is up, and the next deploy
# brings it up as new. One of them being removed is waited for too.
declare -A found=()
for domain in "$QA_API" "$QA_WEB" "$QA_OLD_API" "$QA_OLD_WEB"; do
  found[$domain]="$(forge_site "$domain")" || die "Forge's site $domain could not be read"
done
new_names="$QA_API"
if qa_separate_frontend; then new_names="$QA_WEB and $QA_API"; fi
for domain in "$QA_OLD_API" "$QA_OLD_WEB"; do
  site="${found[$domain]}"
  [ -z "$site" ] || [ "$(jq -r '.attributes.status // ""' <<<"$site")" = removing ] \
    || die_teardown "environment $n was brought up as $domain, a name mroom gave QA sites before 0.5.0. Tear it down (gh workflow run qa-down.yml -f pr_number=$n), and the next deploy brings it up as $new_names"
done
for domain in "$QA_API" "$QA_WEB" "$QA_OLD_API" "$QA_OLD_WEB"; do
  site="${found[$domain]}"
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

# wait_for_a_slot: says this pull request waits for a slot, and ends the run, as a success.
wait_for_a_slot() {
  refused="All $max QA environments are in use, so this pull request waits for a slot. It deploys when one frees up, or on a later push once one is free."
  echo "::warning::$refused"
  output "refused=$refused"
  DONE=1
  qa_status waiting "$refused"
  exit 0
}
# site_gone <domain> <id>: whether Forge no longer lists that site.
site_gone() {
  local site
  site="$(forge_site "$1")" || die "Forge's site $1 could not be read"
  [ "$(jq -r '.id // ""' <<<"${site:-null}")" != "$2" ]
}
# give_way: deletes the sites of this environment, a new one past qa.max_envs, waits until Forge has them gone, and
# then waits for a slot. Forge can refuse a site's delete, or accept one and never run it (as it does a delete queued
# right behind the delete of the site's daemon, which a later delete always gets past). So each site is first waited
# for until Forge has made it, then deleted and waited for until its id is gone, and one still there gets the delete
# once more. One that still does not go fails the run; the environment's code never went in, so the next run gives
# way again.
give_way() {
  local domain site id try waited limit="${MROOM_QA_SITE_WAIT:-300}" gone_wait="${MROOM_QA_GIVE_WAY_WAIT:-120}"
  for domain in "$QA_API" "$QA_WEB"; do
    site="$(forge_site "$domain")" || die "Forge's site $domain could not be read"
    id="$(jq -r '.id // ""' <<<"${site:-null}")"
    [ -n "$id" ] || continue
    [[ "$id" =~ ^[0-9]+$ ]] || die "Forge gave $domain no id"
    # A delete sent while Forge is still making the site may never run.
    waited=0
    while [ "$(jq -r '.attributes.status // ""' <<<"${site:-null}")" = installing ]; do
      ((waited < limit)) || die "site $id was still installing after ${waited}s, so it could not give way"
      sleep "$pause"
      waited=$((waited + pause))
      site="$(forge_site "$domain")" || die "Forge's site $domain could not be read"
    done
    for try in 1 2; do
      if qa_delete "/sites/$id"; then
        waited=0
        until site_gone "$domain" "$id" || ((waited >= gone_wait)); do
          sleep "$pause"
          waited=$((waited + pause))
        done
        if site_gone "$domain" "$id"; then
          echo "    site $id gave way, past qa.max_envs"
          continue 2
        fi
      fi
      if ((try == 1)); then
        echo "    site $id is still there; its delete goes again"
        sleep "$pause"
      fi
    done
    die "Forge did not remove site $id, made past qa.max_envs, though its delete went twice; the next run gives way again"
  done
  wait_for_a_slot
}
api_site="$(forge_site "$QA_API")" || die "Forge's site $QA_API could not be read"
api_id="$(jq -r 'select(.attributes.status != "removing") | .id // empty' <<<"${api_site:-null}")"
# An environment is new until its code has gone in: one with no api site, and one whose api site a first deploy left
# before the code went in, as a run that stopped early leaves one, or a site that gave way past qa.max_envs and whose
# delete Forge never ran. The gate's record of the commit code-put put in says which (env-sha), but a site Forge is
# still making has had no code yet. An environment whose code went in is always refreshed; a new one counts the
# others now, and again once its site is made (step 3).
new_env=""
if [ -z "$api_id" ] || [ "$(jq -r '.attributes.status // ""' <<<"$api_site")" = installing ]; then
  new_env=1
else
  jq -e --arg user "$QA_USER" '.attributes.isolated == true and .attributes.user == $user' <<<"$api_site" >/dev/null \
    || die "$QA_API is not a Forge isolated site of the user $QA_USER; delete it in Forge and run again"
  out="$(qa_gate env-sha "$n")" || die "the gate could not say whether environment $n's code ever went in (env-sha)"
  [[ "$(sed -n 's/^commit=//p' <<<"$out")" =~ ^[0-9a-f]{40}$ ]] || new_env=1
fi
if [ -n "$new_env" ]; then
  envs="$(qa_envs)"
  running="$(awk -v n="$n" '$1 != n && $2 != "removing"' <<<"$envs" | grep -c . || true)"
  ((running < max)) || give_way
fi

# 3. The sites.
# site_ready <domain> <web root>: waits until Forge has made the site, and refuses one that is not isolated in the
# environment's own user's home (D17), such as a site someone made by hand, one whose web root is elsewhere, and a
# PHP site that runs another PHP version than app.php.
site_ready() {
  local site status waited=0 web want
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
  # Forge gives the web root as an absolute path.
  web="$(jq -r '.attributes.web_directory // ""' <<<"$site")" want="/home/$QA_USER/$1$2"
  if [ -n "$web" ] && [ "${web%/}" != "${want%/}" ]; then
    die "$1's web root is ${web:0:120}, not $want; delete the site in Forge and run again"
  fi
  if [ "$2" != / ] && [ "$(jq -r '.attributes.php_version // ""' <<<"$site")" != "PHP $php" ]; then
    die_teardown "$1 runs $(jq -r '.attributes.php_version // "an unknown PHP"' <<<"$site" | cut -c1-20), and app.php is $php. A site's PHP version is set when it is made: tear the environment down (gh workflow run qa-down.yml -f pr_number=$n), and the next deploy makes it with PHP $php"
  fi
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

# primary_domain <site id>: the id of the site's primary domain, whose certificates and server block these are.
primary_domain() {
  local domain
  domain="$(forge GET "/sites/$1/domains" | jq -r '[.data[]? | select(.attributes.type == "primary")][0].id // empty')" \
    || die "Forge's domains of site $1 could not be read"
  [[ "$domain" =~ ^[0-9]+$ ]] || die "Forge gave site $1 no primary domain"
  echo "$domain"
}

# certificate <site id> <domain id> [clone]: an active certificate on the domain, from Let's Encrypt, or with clone
# cloned from MROOM_QA_CERTIFICATE (and enabled) when that is set: for the frontend's site, <N>.<zone>, which a
# certificate for *.<zone> names, while api.<N>.<zone> is a level below it. Waited for, since the site's health is
# asked over https. One that failed (its
# status failed, or failed-<why>, as one from Let's Encrypt can when the domain does not answer yet) is deleted,
# waited for until Forge has it gone, and asked for again, once; failing again, it needs a person. One installed but
# not active, such as a clone Forge did not enable, is enabled through its actions, once. Another is asked for only
# when the domain has none at all: one Forge is still working on, whatever it calls that, is waited for.
certificate() {
  local site="$1" base="/sites/$1/domains/$2/certificates" body certs failed inactive asked=0 waited=0 enabled=" "
  local limit="${MROOM_QA_CERT_WAIT:-300}"
  if [ "${3:-}" = clone ] && [[ "${MROOM_QA_CERTIFICATE:-}" =~ ^[0-9]+$ ]]; then
    body="$(jq -nc --argjson id "$MROOM_QA_CERTIFICATE" '{type: "clone", enable: true, clone: {certificate_id: $id}}')"
  else
    body='{"type":"letsencrypt","letsencrypt":{"verification_method":"http-01","key_type":"ecdsa"}}'
  fi
  # pause_for <what the site still has>: one pause of the wait, or its end.
  pause_for() {
    ((waited < limit)) || die "site $site $1 after ${waited}s"
    sleep "$pause"
    waited=$((waited + pause))
  }
  # cert_where <jq condition>: the id of the first certificate that meets it.
  cert_where() { jq -r "[.data[]? | select($1) | .id | tostring | select(test(\"\\\\A[0-9]+\\\\z\"))] | first // empty" <<<"$certs"; }
  while :; do
    certs="$(forge GET "$base")" || die "Forge's certificates of site $site could not be read"
    if jq -e 'any(.data[]?; .attributes.active == true)' <<<"$certs" >/dev/null; then return 0; fi
    failed="$(cert_where '(.attributes.status // "") | startswith("failed")')"
    if [ -n "$failed" ]; then
      ((asked < 2)) || die "the certificate of site $site failed again; look at it in Forge, then run the deploy again"
      qa_delete "$base/$failed" || die "Forge would not delete the failed certificate $failed of site $site"
      echo "    deleted certificate $failed, which failed"
      # Forge deletes it later: until it is gone, it would read as failed again.
      while forge GET "$base" | jq -e --arg id "$failed" 'any(.data[]?; (.id | tostring) == $id)' >/dev/null; do
        pause_for "still had the failed certificate $failed it was asked to delete"
      done
      continue
    fi
    inactive="$(cert_where '.attributes.active != true and ((.attributes.status // "") | IN("installed", "disabled"))')"
    if [ -n "$inactive" ] && [[ "$enabled" != *" $inactive "* ]]; then
      forge POST "$base/$inactive/actions" '{"action":"enable"}' >/dev/null \
        || die "Forge would not enable the certificate $inactive of site $site"
      enabled+="$inactive "
      echo "    enabled certificate $inactive"
    elif ! jq -e '.data[]?' <<<"$certs" >/dev/null; then
      ((asked < 2)) || die "site $site has no certificate, though one was asked for twice"
      forge POST "$base" "$body" >/dev/null || die "Forge refused a certificate for site $site"
      asked=$((asked + 1))
      echo "    asked for a certificate"
    fi
    pause_for "had no active certificate"
  done
}

# nginx_conf <guard|check|includes> [--spa]: lib's nginx parser, on stdin (actions/qa-up/nginx-conf).
nginx_conf() { python3 -I "$HERE/nginx-conf" "$@"; }

# guard_nginx <site id> <domain id> [--spa]: nginx runs as the box user and follows links, so it must follow one only
# when the link and its target have one owner (disable_symlinks if_not_owner), or code put into the site could link
# to a box user's file and serve it (D17). The site's config is the fragment each of its domains includes in its
# server block: the guard goes at its top level, and the domain's server block must include it and set nothing of
# its own. Forge applies a new config later, so it is read back until it has it. With --spa, a path the site does
# not have serves index.html, so a single-page app's routes survive a reload. Checked on every run, after the
# certificate, and before any code goes in.
guard_nginx() {
  local config want why waited=0
  forge GET "/sites/$1/domains/$2/nginx" | jq -r '.data.attributes.content // ""' | nginx_conf includes \
    || die "site $1's nginx server block does not take its site config as it is, so no code goes in"
  config="$(forge GET "/sites/$1/nginx" | jq -r '.data.attributes.content // empty')" \
    || die "Forge's nginx config of site $1 could not be read"
  [ -n "$config" ] || die "Forge gave site $1 no nginx config"
  if nginx_conf check ${3:+"$3"} <<<"$config" 2>/dev/null; then return 0; fi
  want="$(nginx_conf guard ${3:+"$3"} <<<"$config")" || die "site $1's nginx config does not parse, so no code goes in"
  # A disable_symlinks inside a block, or a try_files mroom does not know, would stay as it is: a person fixes it.
  why="$(nginx_conf check ${3:+"$3"} <<<"$want" 2>&1)" \
    || die "site $1's nginx config cannot be guarded as it is ($why), so no code goes in; fix it in Forge"
  forge PUT "/sites/$1/nginx" "$(jq -nc --arg c "$want" '{config: $c}')" >/dev/null || die "Forge refused site $1's nginx config"
  echo "    nginx config: links followed only to their owner's files${3:+, and the single-page fallback}"
  until config="$(forge GET "/sites/$1/nginx" | jq -r '.data.attributes.content // empty')" \
    && nginx_conf check ${3:+"$3"} <<<"$config" 2>/dev/null; do
    ((waited < ${MROOM_QA_NGINX_WAIT:-120})) || die "site $1's nginx config still lacked the guard ${waited}s after it was sent, so no code goes in"
    sleep "$pause"
    waited=$((waited + pause))
  done
}

echo "==> Site $QA_API"
web_root=/public
[ "$QA_BACKEND" = . ] || web_root="/$QA_BACKEND/public"
make_site "$QA_API" php "$web_root"
api_id="$SITE_ID"
# Two first deploys at once each count under qa.max_envs before either has made its site, since each counts inside
# its own pull request's group. So a new environment, once its site is made, counts again: by the order Forge made
# the environments' first sites in, which its ids give, the ones past qa.max_envs give way.
if [ -n "$new_env" ]; then
  rank="$(qa_env_rank "$n")" || die "Forge's sites could not be read to count the environments again"
  if [[ "$rank" =~ ^[0-9]+$ ]] && ((rank > max)); then give_way; fi
fi
site_ready "$QA_API" "$web_root"
api_domain="$(primary_domain "$api_id")"
certificate "$api_id" "$api_domain"
guard_nginx "$api_id" "$api_domain"
web_id=""
if qa_separate_frontend; then
  echo "==> Site $QA_WEB"
  make_site "$QA_WEB" static-html /
  web_id="$SITE_ID"
  site_ready "$QA_WEB" /
  web_domain="$(primary_domain "$web_id")"
  certificate "$web_id" "$web_domain" clone
  guard_nginx "$web_id" "$web_domain" --spa
fi

# 4. Daemons and scheduled jobs that run as anyone but the site user go before any code does, and are waited for
# until Forge has them gone: they would run the pull request's code as that user, forge or root (D20). Forge lists
# the server's daemons and scheduled jobs, and each site's own scheduled jobs (lib/core/qa.sh, qa_jobs).
env_daemons() { qa_jobs /background-processes; }
# away <path> <what> [all] [<ids to leave>]: deletes those of the environment's daemons or scheduled jobs in the list
# that run as another user, and waits until Forge lists none; a delete Forge refuses, or one that never ends, keeps
# the code out. The ids to leave are the sites' own jobs, which the server's list may hold too: a delete through the
# server's path would miss them, and they go through their site's.
away() {
  local others job id user waited=0
  while :; do
    others="$(qa_jobs "$1" "${3:-}" | jq -c --arg user "$QA_USER" --arg leave " ${4:-} " \
      '.id as $id | select(.user != $user and ($leave | contains(" \($id) ") | not))')" || die "Forge's ${2}s could not be read"
    [ -n "$others" ] || return 0
    while IFS= read -r job; do
      id="$(jq -r .id <<<"$job")" user="$(jq -r .user <<<"$job" | cut -c1-32)"
      # One Forge is deleting already is waited for, not deleted again.
      case "$(jq -r .status <<<"$job")" in removing | deleting) continue ;; esac
      qa_delete "$1/$id" || die "Forge would not delete $2 $id, which runs as $user, so no code goes in"
      echo "    deleted $2 $id, which ran as $user"
    done <<<"$others"
    ((waited < ${MROOM_QA_DAEMON_WAIT:-120})) || die "${2}s of the environment still run as another user ${waited}s after they were deleted, so no code goes in"
    sleep "$pause"
    waited=$((waited + pause))
  done
}
echo "==> Daemons and scheduled jobs"
away /background-processes daemon
own=""
for id in "$api_id" "$web_id"; do
  [ -n "$id" ] || continue
  jobs="$(forge_list "/sites/$id/scheduled-jobs")" || die "Forge's scheduled jobs of site $id could not be read"
  own+=" $(jq -r '.id | tostring' <<<"$jobs" | tr '\n' ' ')"
done
away /scheduled-jobs "scheduled job" "" "$own"
away "/sites/$api_id/scheduled-jobs" "scheduled job" all
if [ -n "$web_id" ]; then away "/sites/$web_id/scheduled-jobs" "scheduled job" all; fi

# 4b. The proof that nginx refuses a link to another owner's file, the last step before any of the pull request's
# code is in the site: the gate links the box's site-op, root's, into each web root, and what the link answers must
# not be that file, by the SHA-256 the gate gives for it, whichever release the box runs. The body is compared, not
# the status: with the guard, try_files hands the path on to the app or the single-page fallback, which may answer 200.
# Asked as /up is (MROOM_QA_UP_TRIES, MROOM_QA_UP_PAUSE), since nginx reloads a config Forge has just written a moment
# later, and a new site may not answer yet; still served, or still unanswered, at the last try, it stops the run.
# probe <domain> <api|web>
probe() {
  local code want got i tries="${MROOM_QA_UP_TRIES:-6}" wait="${MROOM_QA_UP_PAUSE:-5}"
  [[ "$tries" =~ ^[1-9][0-9]?$ ]] || tries=6
  [[ "$wait" =~ ^[0-9]{1,2}$ ]] || wait=5
  out="$(qa_gate probe-link "$n" "$2")" || die "the gate could not put the link that proves nginx's guard in $1"
  want="$(sed -n 's/^sha256=\([0-9a-f]\{64\}\)$/\1/p' <<<"$out")"
  [ -n "$want" ] || die "the gate named no SHA-256 of the file it linked in $1, so the proof cannot be judged"
  for ((i = 1; i <= tries; i++)); do
    rm -f "$WORK/probe"
    code="$(curl -q -s -o "$WORK/probe" -m 20 -w '%{http_code}' "https://$1/mroom-symlink-probe")" || code=000
    got="$(sha256sum "$WORK/probe" 2>/dev/null | cut -d' ' -f1)" || got=""
    if [ "$code" != 000 ] && [ "$got" != "$want" ]; then
      echo "    $1: a link to a root-owned file is not served (it answered $code with another body)"
      return 0
    fi
    if ((i < tries)); then sleep "$wait"; fi
  done
  [ "$code" != 000 ] || die "https://$1/mroom-symlink-probe did not answer, so whether nginx follows links cannot be told"
  die "https://$1 served a link to a root-owned file, so nginx follows links it must not (D17), and no code goes in"
}
echo "==> Links"
probe "$QA_API" api
if [ -n "$web_id" ]; then probe "$QA_WEB" web; fi

# 5. The code, as data.
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

# 6. The services, through the gate. What it gives is kept for the .env, masked in the log, never printed.
: >"$WORK/values"
set_env() { printf '%s=%s\n' "$1" "$2" >>"$WORK/values"; }
# service <what> <operation> <argument...>: the gate's KEY=value lines, kept in $WORK/gate for keep and gate_value,
# its passwords, secret keys and app key masked. Any other line is shown only when it is a plain message: one that
# could hold a value, or a workflow command, is not shown at all.
PLAIN='^[A-Za-z0-9 ._:,/()-]{1,200}$'
service() {
  local what="$1" out line hidden=0
  shift
  echo "==> $what"
  out="$(qa_gate "$@")" || die "the gate could not give the environment its $what ($1)"
  : >"$WORK/gate"
  while IFS= read -r line; do
    if [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=([!-~]*)$ ]]; then
      case "${BASH_REMATCH[1]}" in *PASSWORD | *SECRET* | APP_KEY) qa_mask "${BASH_REMATCH[2]}" ;; esac
      printf '%s=%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" >>"$WORK/gate"
    elif [[ "$line" =~ $PLAIN && "$line" != *::* ]]; then
      qa_show "$line"
    elif [ -n "$line" ]; then
      hidden=$((hidden + 1))
    fi
  done <<<"$out"
  if ((hidden > 0)); then echo "    ($hidden line(s) of the gate's answer not shown, since they may hold a value)"; fi
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
keep REDIS_USERNAME REDIS_PASSWORD REDIS_PREFIX HORIZON_PREFIX REDIS_HOST REDIS_PORT
if [ "$mail" = catcher ]; then
  service "mail login" mail-user-add "$n"
  keep MAIL_MAILER MAIL_HOST MAIL_PORT MAIL_USERNAME MAIL_PASSWORD
  # Plain SMTP to the relay on the box, whatever the template says about TLS.
  set_env MAIL_SCHEME smtp
  set_env MAIL_ENCRYPTION null
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
if [ "$broadcast" = same ]; then
  # An app of its own on the box's Reverb host, which takes sockets from the environment's own hosts alone. Its id,
  # key, host, port and scheme are public, and qa-plan builds the frontend with them, from mroom.toml and the pull
  # request's number (lib/core/qa.sh, qa_public_env): the gate's must be the ones derived here, or the frontend would
  # open its sockets for another app or on another host.
  # Each deploy asks for the app again, and never removes it first: the gate keeps its secret while it exists, since
  # each open socket holds the app it opened with, and a new secret would fail their private channels.
  service "Reverb app" reverb-app-add "$n"
  for key in REVERB_APP_ID REVERB_APP_KEY REVERB_HOST REVERB_PORT REVERB_SCHEME; do
    [ "$(gate_value "$key")" = "$(public_value "$key")" ] \
      || die "the gate's Reverb app has another $key than $(public_value "$key"), which qa-plan builds the frontend with: box.env's MROOM_APP_NAME and MROOM_QA_ZONE must be mroom.toml's app.name and qa.zone, and the box must run the mroom release the workflows pin"
  done
  keep REVERB_APP_SECRET
  set_env BROADCAST_CONNECTION reverb
  set_env BROADCAST_DRIVER reverb
else
  set_env BROADCAST_CONNECTION log
  set_env BROADCAST_DRIVER log
fi
service "app key" app-key "$n"
keep APP_KEY

# 7. The .env: the template, without any key mroom sets, then mroom's values.
set_env APP_ENV qa
# Off: the hosts are public, and a debug page shows the environment's settings.
set_env APP_DEBUG false
# The hosts answer over https alone, so the cookies never go over http, not even to Forge's redirect on port 80.
set_env SESSION_SECURE_COOKIE true
while IFS= read -r line; do set_env "${line%%=*}" "${line#*=}"; done <<<"$public_env"
# For an app with a frontend, the build values Reverb's installer puts in a Laravel app's .env, as the frontend was
# built with them. A template's own would stay otherwise, and one such as VITE_REVERB_HOST="${REVERB_HOST}" reads a
# key that comes later in this file, which makes it empty.
if [ "$broadcast" = same ] && [ -n "$QA_FRONTEND" ]; then
  for key in APP_KEY HOST PORT SCHEME; do set_env "VITE_REVERB_$key" "$(public_value "REVERB_$key")"; done
fi
set_env CACHE_PREFIX "${QA_USER}_cache_"
# Entry by entry, so a quoted value of several lines stays whole (actions/qa-up/env-merge).
printf '%s\n' "${MROOM_QA_ENV_TEMPLATE:-}" | python3 -I "$HERE/env-merge" "$WORK/values" >"$WORK/env" \
  || die "the template could not be read"
echo "==> .env"
out="$(qa_gate env-put "$n" <"$WORK/env")" || die "the gate could not write the .env (env-put)"
want="$(printf '%s' "$(cat "$WORK/env")" | sha256sum | cut -d' ' -f1)"
[ "$out" = "env=$want" ] || die "the .env the gate wrote is not the one sent"
echo "    written, $(wc -l <"$WORK/env" | tr -d ' ') lines"

# 8. Forge's deploy: a script that runs as the site user alone and pulls nothing, then the queue worker.
deploy_script() {
  local root="/home/$QA_USER/$QA_API" command
  printf '%s\n' "# Written by mroom's qa-up for QA environment $n (design 6, D17). The gate put the tree in place, so this" \
    "# pulls nothing and builds no frontend; Forge runs it as the site's own user, and as no other." \
    "set -eo pipefail" "test \"\$(id -un)\" = $QA_USER || exit 78" \
    "php=\"\${FORGE_PHP:-$php_bin}\"" "composer=\"\${FORGE_COMPOSER:-composer}\"" \
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
daemons="$(env_daemons)" || die "Forge's daemons could not be read"
mine="" stale=""
while IFS= read -r daemon; do
  [ -n "$daemon" ] || continue
  [ "$(jq -r .user <<<"$daemon")" = "$QA_USER" ] || die "a daemon of the environment runs as another user again, so the worker waits"
  [ "$(jq -r .status <<<"$daemon")" != removing ] || continue
  if [ "$(jq -r .command <<<"$daemon")" = "$worker_command" ] && [ -z "$mine" ]; then
    mine="$(jq -r .id <<<"$daemon")"
  else
    stale+="$(jq -r .id <<<"$daemon") "
  fi
done <<<"$daemons"
# A worker whose command is not the one wanted now (other queues or another PHP) goes, and a new one comes.
for id in $stale; do
  qa_delete "/background-processes/$id" || die "Forge would not delete the old worker $id"
  echo "    deleted worker $id, whose command is not the one wanted now"
done
if [ -z "$mine" ]; then
  body="$(jq -nc --arg name "${QA_USER}-queue" --argjson site "$api_id" --arg user "$QA_USER" --arg dir "$backend_path" \
    --arg command "$worker_command" '{name: $name, site_id: $site, command: $command, user: $user, directory: $dir, processes: 1}')"
  made="$(forge POST /background-processes "$body")" || die "Forge refused the queue worker, run as $QA_USER (design D17)"
  mine="$(jq -r '.data.id // empty' <<<"$made")"
  [[ "$mine" =~ ^[0-9]+$ ]] || die "Forge made no queue worker"
  # Forge's API names only root and forge as a daemon's user: the new one is read back, and kept only when Forge's
  # record of it names the site user (D17).
  user="$(forge GET "/background-processes/$mine" | jq -r '.data.attributes.user // ""')"
  if [ "$user" != "$QA_USER" ]; then
    if qa_delete "/background-processes/$mine"; then
      die "Forge started the queue worker as ${user:-an unknown user}, not $QA_USER, so it was deleted again"
    fi
    die "Forge started the queue worker as ${user:-an unknown user}, not $QA_USER, and would not delete it: delete daemon $mine in Forge"
  fi
  echo "    created worker $mine, run as $QA_USER"
else
  echo "    worker $mine runs as $QA_USER"
fi

# 9. Health.
echo "==> https://$QA_API/up"
code="$(qa_up_code "https://$QA_API")"
[ "$code" = 200 ] || die "https://$QA_API/up answered $code, still, after ${MROOM_QA_UP_TRIES:-6} tries"
echo "    200"

app_url="https://$QA_API"
if qa_separate_frontend; then app_url="https://$QA_WEB"; fi
output "sha=$sha"
output "app_url=$app_url"
output "api_url=https://$QA_API"
DONE=1
table="| | |"$'\n'"|---|---|"$'\n'
if qa_separate_frontend; then table+="| App | $app_url |"$'\n'; fi
table+="| API | https://$QA_API |"
qa_status ready "$table"$'\n\n'"Updated for \`$sha\`. Every push that needs it refreshes it. It goes when the pull request closes, its ${LABEL:-qa} label comes off, or after $ttl days."
echo "environment $n: up at $app_url"
