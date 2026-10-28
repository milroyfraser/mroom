# shellcheck shell=bash
# qa.sh — what the QA environment actions share on a runner (design 8.2): the names of environment N, Forge's
# record of it, the box's gate over SSH, and the pull request's QA environment comment. Sourced after util.sh
# and forge.sh, never run on its own; needs bash 5, GNU date, curl, jq, python3 3.11, and ssh or gh for the
# parts that use them. The caller sets MROOM_ROOT, and MROOM_CONFIG to the app's mroom.toml.
#
# Environment N is pull request N. Its names are built here from mroom.toml (app.name, qa.zone, and the app's
# folders), and must match what a person set in the box's box.env (MROOM_APP_NAME, MROOM_QA_ZONE,
# MROOM_QA_BACKEND_DIR), where the gate builds the same ones: the Laravel app's site api.<N>.<zone> and a frontend of
# its own's <N>.<zone>, both in the home of the Forge isolated user <app>_qa_<N> (D17). Before mroom 0.5.0 they were
# api-<N>.<zone> and go-<N>.<zone>: an environment brought up then is still found, counted and torn down by them.
#
# Forge is the one source of truth for whether an environment exists: its api or frontend site, whichever is left.
# A read that fails is retried and then fails the caller, so an API blip never reads as "no environment". The pull
# request's comment is for people, and for qa_wake.

QA_APP="" QA_ZONE="" QA_BACKEND="" QA_FRONTEND="" QA_N="" QA_USER="" QA_API="" QA_WEB="" QA_KEYS=""
QA_OLD_API="" QA_OLD_WEB=""
QA_HEADING='### QA environment'

# qa_say <message>: one line on stderr.
qa_say() { echo "${QA_NAME:-mroom qa}: $*" >&2; }

# qa_show <text>: the gate's answer, each of its lines indented.
qa_show() { printf '    %s\n' "${1//$'\n'/$'\n'    }"; }

# qa_config <key> [<default>]: one value from the app's mroom.toml, through the one reader.
qa_config() {
  if [ "$#" -ge 2 ]; then
    python3 "$MROOM_ROOT/lib/core/config.py" get "$1" --default "$2"
  else
    python3 "$MROOM_ROOT/lib/core/config.py" get "$1"
  fi
}

# qa_number <word>: whether the word is an environment number, as the gate takes one.
qa_number() { [[ "$1" =~ ^[1-9][0-9]{0,8}$ ]]; }

# qa_now: the time now (MROOM_NOW in tests), as GitHub and Forge write times.
qa_now() { date -u -d "@$(mroom_now)" +%Y-%m-%dT%H:%M:%SZ; }

# qa_temp: a private folder for scratch files: under RUNNER_TEMP on a runner, which GitHub empties after the job.
qa_temp() { mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/mroom-qa.XXXXXX"; }

# qa_init: the app's name, the QA zone and the app's folders, from mroom.toml. app.frontend_dir is a folder for a
# separate frontend (it gets the site <N>.<zone>), . for Vite inside the Laravel app, and empty for no frontend.
qa_init() {
  [ -z "$QA_APP" ] || return 0
  QA_APP="$(qa_config app.name)" || return 1
  QA_ZONE="$(qa_config qa.zone)" || return 1
  QA_BACKEND="$(qa_config app.backend_dir .)" || return 1
  QA_FRONTEND="$(qa_config app.frontend_dir .)" || return 1
}

# qa_separate_frontend: whether the app has a frontend of its own, served from the site <N>.<zone>.
qa_separate_frontend() { [ -n "$QA_FRONTEND" ] && [ "$QA_FRONTEND" != . ]; }

# qa_names <N>: environment N's names: QA_N, QA_USER (its sites' Unix user, which is also its database, role,
# Redis user and mail login on the box), QA_API and QA_WEB (its sites' domains: the Laravel app's, and a frontend of
# its own's), and QA_OLD_API and QA_OLD_WEB, the names mroom gave them before 0.5.0, by which an environment
# brought up then is still found and torn down.
qa_names() {
  qa_number "$1" || { qa_say "an environment number is 1 to 999999999"; return 1; }
  qa_init || return 1
  QA_N="$1" QA_USER="${QA_APP}_qa_$1" QA_API="api.$1.$QA_ZONE" QA_WEB="$1.$QA_ZONE"
  QA_OLD_API="api-$1.$QA_ZONE" QA_OLD_WEB="go-$1.$QA_ZONE"
  # The box's limit for a user name (README, QA gate): an app name of 19 characters or fewer always fits.
  ((${#QA_USER} <= 32)) || { qa_say "$QA_USER is longer than a user name may be (32); shorten app.name"; return 1; }
}

# QA_WORKFLOW_RE: a workflow file's name, as a dispatch takes it: never one that starts with -, which gh would read as
# an option.
QA_WORKFLOW_RE='^[A-Za-z0-9_][A-Za-z0-9._-]*\.ya?ml$'

# QA_SITE_RE: qa_names read backwards, for jq: a site name's environment number and zone, as its two captures, for
# the names of now (api.<N>.<zone>, <N>.<zone>) and of before 0.5.0 (api-<N>.<zone>, go-<N>.<zone>). Every name of an
# environment's sites is built in qa_names and read back with this, and nowhere else.
QA_SITE_RE='\A(?:api\.|api-|go-)?([1-9][0-9]{0,8})\.(.+)\z'

# qa_public_env: environment N's settings that are not secret, as KEY=value lines: what qa-plan builds the
# frontend with, and part of what qa-up writes into the environment's .env. A separate frontend, at <N>.<zone>, reads
# the session and XSRF cookies the Laravel app at api.<N>.<zone> sets, so they are set for .<N>.<zone>: no other
# environment's host is under it, and neither are the zone's shared hosts, Garage's and the Reverb host's (design
# 8.7). An app with no frontend of its own keeps them on its one host. Their names are the environment's own too,
# and not the ones of before mroom 0.5.0 (<user>_session, <user>_xsrf): a browser keeps a cookie of those, set for the
# whole zone, until it expires, and sends it ahead of the environment's own of the same name, of which PHP reads
# only the first.
qa_public_env() {
  printf 'APP_URL=https://%s\n' "$QA_API"
  printf 'SESSION_COOKIE=%s_sid\nXSRF_COOKIE_NAME=%s_csrf\n' "$QA_USER" "$QA_USER"
  if qa_separate_frontend; then
    printf 'CLIENT_URL=https://%s\nSESSION_DOMAIN=.%s\n' "$QA_WEB" "$QA_WEB"
    printf 'CORS_ALLOWED_ORIGINS=https://%s\nSANCTUM_STATEFUL_DOMAINS=%s,%s\n' "$QA_WEB" "$QA_WEB" "$QA_API"
  else
    printf 'CLIENT_URL=https://%s\nSESSION_DOMAIN=null\n' "$QA_API"
  fi
}

# qa_all_sites: every site of the server, one JSON object per line, read up to 3 times, MROOM_QA_RETRY_SLEEP
# (10) seconds apart. Fails after that: a list Forge could not give must never read as an empty one.
qa_all_sites() {
  local attempt out
  for attempt in 1 2 3; do
    if out="$(forge_list /sites)"; then
      printf '%s\n' "$out"
      return 0
    fi
    qa_say "could not read Forge's sites (attempt $attempt of 3)"
    [ "$attempt" = 3 ] || sleep "${MROOM_QA_RETRY_SLEEP:-10}"
  done
  qa_say "Forge's sites could not be read 3 times, so whether an environment exists cannot be told"
  return 1
}

# qa_env_state: present when one of environment N's sites, by its names of now or of before 0.5.0, exists and is not
# being removed, removing when all that is left of them is being removed, absent otherwise.
qa_env_state() {
  local sites
  sites="$(qa_all_sites)" || return 1
  jq -rs --arg api "$QA_API" --arg web "$QA_WEB" --arg old_api "$QA_OLD_API" --arg old_web "$QA_OLD_WEB" '[.[]
    | .attributes | select(.name == $api or .name == $web or .name == $old_api or .name == $old_web) | .status]
    | if any(. != "removing") then "present" elif length > 0 then "removing" else "absent" end' <<<"$sites"
}

# qa_envs: "<N> <present|removing> <created_at>" for every environment, from its api or frontend site, whichever is
# left, by the names of now or of before 0.5.0: a teardown that deleted one of them and stopped still leaves an
# environment. created_at is its oldest site's, or - when Forge gives none.
qa_envs() {
  local sites
  qa_init || return 1
  sites="$(qa_all_sites)" || return 1
  jq -rs --arg zone "$QA_ZONE" --arg re "$QA_SITE_RE" '[.[] | .attributes | ((.name // "") | [match($re).captures[].string]) as $m
      | select(($m | length) == 2 and $m[1] == $zone) | {n: ($m[0] | tonumber), status: (.status // "unknown"), created: (.created_at // "")}]
    | group_by(.n)[] | "\(.[0].n) \(if any(.[]; .status != "removing") then "present" else "removing" end) \(
      [.[].created | select(. != "")] | min // "-")"' <<<"$sites"
}

# qa_env_rank <N>: environment N's place, from 1, among the environments with a site Forge is not removing, by the
# id of each one's first such site: the order Forge made them in. 0 when N has no such site.
qa_env_rank() {
  local sites
  qa_init || return 1
  sites="$(qa_all_sites)" || return 1
  jq -rs --arg zone "$QA_ZONE" --arg re "$QA_SITE_RE" --argjson n "$1" '[.[] | . as $site
      | select(($site.id | tostring) | test("\\A[0-9]{1,15}\\z")) | .attributes
      | select((.status // "") != "removing") | ((.name // "") | [match($re).captures[].string]) as $m
      | select(($m | length) == 2 and $m[1] == $zone) | {n: ($m[0] | tonumber), id: ($site.id | tostring | tonumber)}]
    | group_by(.n) | map({n: .[0].n, first: (map(.id) | min)}) | sort_by(.first) | map(.n) | index($n)
    | if . == null then 0 else . + 1 end' <<<"$sites"
}

# qa_delete <path>: deletes a Forge resource; one that is already gone (404) counts as deleted, since a teardown run
# again, or one beside it, may have deleted it first.
qa_delete() {
  local err
  if err="$(forge DELETE "$1" 2>&1 >/dev/null)"; then return 0; fi
  [[ "$err" == *"-> HTTP 404"* ]] && return 0
  printf '%s\n' "$err" >&2
  return 1
}

# qa_redelete_stuck <site JSON>: sends the delete again for a site Forge accepted for removal but has not removed
# after MROOM_QA_STUCK_MINUTES (30). Forge can accept a delete and never run it: after a burst of deployments,
# sites have stayed removing for days, their folders still on the box, until the delete was sent again. A normal
# removal takes under a minute, and updated_at is when the site turned removing. Prints how many minutes it had
# been removing when it sent the delete again, and nothing when it did not.
qa_redelete_stuck() {
  local minutes="${MROOM_QA_STUCK_MINUTES:-30}" id since flipped age
  # A mistyped limit must never turn into "delete every removing site again".
  [[ "$minutes" =~ ^[1-9][0-9]{0,4}$ ]] || minutes=30
  [ "$(jq -r '.attributes.status // ""' <<<"$1")" = removing ] || return 0
  id="$(jq -r '.id // ""' <<<"$1")"
  since="$(jq -r '.attributes.updated_at // ""' <<<"$1")"
  if ! [[ "$id" =~ ^[0-9]+$ ]] || [ -z "$since" ]; then return 0; fi
  flipped="$(date -u -d "$since" +%s 2>/dev/null)" || return 0
  age=$((($(mroom_now) - flipped) / 60))
  ((age >= minutes)) || return 0
  qa_delete "/sites/$id" || return 1
  # A list of stuck sites is a burst of deletes, which Forge answers with 429s: pace them.
  sleep "${MROOM_QA_DELETE_PACE:-2}"
  echo "$age"
}

# qa_jobs <path> [all]: environment N's Forge daemons (/background-processes) or scheduled jobs (/scheduled-jobs),
# one JSON object a line, {id, user, status, command}: those run as its site user, and those that run from one of its
# folders or whose command names one by its path, wherever they run from and as whomever, such as a daemon of
# forge's that runs the site's artisan. One of its folders is its home or anything in it, or a path with one of its
# sites' domains as a whole part; a URL is no path, so a job that only asks a site for a page is not the
# environment's. With all, every one in the list, which is then one of the environment's own sites'
# (/sites/<id>/scheduled-jobs).
qa_jobs() {
  local items
  items="$(forge_list "$1")" || return 1
  jq -c --arg user "$QA_USER" --arg home "/home/$QA_USER" --arg all "${2:-}" \
    --argjson sites "$(jq -nc --args '$ARGS.positional' "$QA_API" "$QA_WEB" "$QA_OLD_API" "$QA_OLD_WEB")" '
    def ours: . == $home or startswith($home + "/") or (split("/") | any(.[]; IN($sites[])));
    def names_ours: [scan("[^\\s\"\u0027`;|&()<>=]+") | select(startswith("/"))] | any(.[]; ours);
    select($all == "all" or .attributes.user == $user or ((.attributes.directory // "") | startswith("/") and ours)
      or ((.attributes.command // "") | names_ours))
    | (.id | tostring) as $id | select($id | test("\\A[0-9]+\\z"))
    | {id: $id, user: (.attributes.user // "unknown"), status: (.attributes.status // "unknown"),
       command: (.attributes.command // "")}' <<<"$items"
}

# qa_processes: "<id> <status> <user>" for each of environment N's Forge daemons (qa_jobs).
qa_processes() {
  local jobs
  jobs="$(qa_jobs /background-processes)" || return 1
  jq -r '"\(.id) \(.status) \(.user)"' <<<"$jobs"
}

# qa_gate_init: the runner's way to the box's gate. MROOM_QA_SSH_KEY is a private key whose line in the box user's
# authorized_keys forces `mroom gate provision` (README, QA gate), and MROOM_QA_SSH_KNOWN_HOSTS the box's host
# key line, so the runner never trusts whatever answers first. Both go into a private folder that qa_cleanup
# removes; the key never reaches a command line.
qa_gate_init() {
  local name
  for name in MROOM_QA_SSH_HOST MROOM_QA_SSH_KEY MROOM_QA_SSH_KNOWN_HOSTS; do
    [ -n "${!name:-}" ] || { qa_say "$name is not set (README, QA environments)"; return 1; }
  done
  [[ "$MROOM_QA_SSH_HOST" =~ ^[A-Za-z0-9.-]+$ ]] || { qa_say "MROOM_QA_SSH_HOST is not a plain host name"; return 1; }
  [[ "${MROOM_QA_SSH_USER:-forge}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { qa_say "MROOM_QA_SSH_USER is not a user name"; return 1; }
  [ -n "$QA_KEYS" ] || QA_KEYS="$(qa_temp)" || return 1
  (
    umask 077
    printf '%s\n' "$MROOM_QA_SSH_KEY" >"$QA_KEYS/key"
    printf '%s\n' "$MROOM_QA_SSH_KNOWN_HOSTS" >"$QA_KEYS/known_hosts"
  )
}

# qa_gate <operation> <argument...>: one request to the box's gate, whose forced command reads it from
# SSH_ORIGINAL_COMMAND and runs nothing else; stdout is the gate's answer. Only a put (code-put, dist-put, env-put)
# gets stdin: without -n, ssh reads the caller's stdin and sends it on whatever the command, which in a loop that
# reads its own input would swallow the rest of the list. No ssh config file of the runner's applies (-F).
qa_gate() {
  local stdin=(-n)
  case "$1" in code-put | dist-put | env-put) stdin=() ;; esac
  ssh -T "${stdin[@]}" -F /dev/null -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -i "$QA_KEYS/key" \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$QA_KEYS/known_hosts" -o GlobalKnownHostsFile=/dev/null \
    -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 \
    "${MROOM_QA_SSH_USER:-forge}@$MROOM_QA_SSH_HOST" "$*"
}

# qa_cleanup: removes the key folder and the Forge client's scratch folder. Safe to call from a trap at any time.
qa_cleanup() {
  if [ -n "$QA_KEYS" ]; then rm -rf "$QA_KEYS"; QA_KEYS=""; fi
  forge_cleanup
}

# qa_up_code <url>: <url>/up's HTTP code, asked up to MROOM_QA_UP_TRIES (6) times, MROOM_QA_UP_PAUSE (5) seconds
# apart, until it answers 200. A site Forge has just made answers 502 for a few seconds, and so does any site on the
# box while PHP-FPM or nginx reloads for another, so one answer never says an environment is down. Each try waits
# 20 seconds at most; 000 means nothing answered.
qa_up_code() {
  local code=000 tries="${MROOM_QA_UP_TRIES:-6}" pause="${MROOM_QA_UP_PAUSE:-5}" i
  [[ "$tries" =~ ^[1-9][0-9]?$ ]] || tries=6
  [[ "$pause" =~ ^[0-9]{1,2}$ ]] || pause=5
  for ((i = 1; i <= tries; i++)); do
    code="$(curl -q -s -o /dev/null -m 20 -w '%{http_code}' "$1/up")" || code=000
    [ "$code" != 200 ] || break
    if ((i < tries)); then sleep "$pause"; fi
  done
  echo "$code"
}

# qa_mask <value>: on a runner, tells GitHub to hide the value wherever a later line of the log would show it.
qa_mask() { if [ "${GITHUB_ACTIONS:-}" = true ] && [ -n "$1" ]; then echo "::add-mask::$1"; fi; }

# qa_comment_newest <PR>: the newest of github-actions[bot]'s QA environment comments on the pull request, as
# {"id", "state", "since", "woken", "was", "updated_at"} on one line, or nothing. Found by its heading, never as the
# bot's last comment, which may be another of its comments. The state and its fields come from the comment's hidden
# line. 100 comments a page, the most GitHub gives.
qa_comment_newest() {
  local found
  found="$(gh api --paginate "repos/$GITHUB_REPOSITORY/issues/$1/comments?per_page=100" --jq '.[]
    | select(.user.login == "github-actions[bot]" and ((.body // "") | startswith("### QA environment\n")))
    | ([.body | match("\n<!-- mroom-qa: ([a-z]+)((?: [a-z]+=[0-9A-Za-z:-]+)*) -->\n").captures[].string]) as $m
    | def field($k): [($m[1] // "") | match(" " + $k + "=([0-9A-Za-z:-]+)").captures[].string][0] // "";
      {id, updated_at, state: ($m[0] // ""), since: field("since"), woken: field("woken"), was: field("was")}
    | @json')" || return 1
  tail -n1 <<<"$found"
}

# qa_comment <PR> <state> <text> [<field>=<value>...]: writes the pull request's one QA environment comment: the
# heading, a hidden line with the state (ready, waiting, woken, idle, failed, removing, removed or skipped), its times
# and the fields given (a teardown's was=<the state it started from>), then the text, which is mroom's own words,
# never text from the pull request. A pull request that keeps waiting keeps the time it started
# waiting (since), whatever rewrites the comment meanwhile; woken is when a freed slot last started its plan. Edits
# the newest one, or makes one.
qa_comment() {
  local body id now newest previous since="" marker field
  [[ "$2" =~ ^[a-z]+$ ]] || { qa_say "a comment state is a lowercase word"; return 1; }
  for field in "${@:4}"; do
    [[ "$field" =~ ^[a-z]+=[0-9A-Za-z:-]+$ ]] || { qa_say "a comment field is <word>=<plain value>"; return 1; }
  done
  newest="$(qa_comment_newest "$1")" || return 1
  id="$(jq -r '.id // empty' <<<"${newest:-null}")"
  previous="$(jq -r '.state // ""' <<<"${newest:-null}")"
  now="$(qa_now)"
  marker="$2"
  if [ "$2" = waiting ] || [ "$2" = woken ]; then
    case "$previous" in waiting | woken) since="$(jq -r '.since // ""' <<<"$newest")" ;; esac
    [[ "$since" =~ ^[0-9TZ:-]+$ ]] || since="$now"
    marker+=" since=$since"
  fi
  if [ "$2" = woken ]; then marker+=" woken=$now"; fi
  for field in "${@:4}"; do marker+=" $field"; done
  body="$(jq -n --arg b "$(printf '%s\n<!-- mroom-qa: %s -->\n\n%s\n' "$QA_HEADING" "$marker" "$3")" '{body: $b}')"
  if [ -n "$id" ]; then
    [[ "$id" =~ ^[0-9]+$ ]] || { qa_say "the comment's id is not a number"; return 1; }
    gh api -X PATCH "repos/$GITHUB_REPOSITORY/issues/comments/$id" --input - <<<"$body" >/dev/null
  else
    gh api -X POST "repos/$GITHUB_REPOSITORY/issues/$1/comments" --input - <<<"$body" >/dev/null
  fi
}

# qa_status <state> <text>: what pull request QA_N's QA environment comment is to say. In actions/qa-up, the comment
# is written by the step after the others, which runs whatever happened before it (report.sh): this leaves it the
# state and the text, in MROOM_QA_STATUS, its first line the state. Without MROOM_QA_STATUS, as when a script runs
# on its own, it writes the comment itself.
qa_status() {
  if [ -n "${MROOM_QA_STATUS:-}" ]; then
    printf '%s\n%s\n' "$1" "$2" >"$MROOM_QA_STATUS"
  elif [ -n "${GH_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
    qa_comment "$QA_N" "$1" "$2" </dev/null || echo "::warning::could not update the QA environment comment of pull request $QA_N"
  fi
}

# qa_wake <slots>: after a teardown frees slots, starts the app's QA plan workflow (MROOM_QA_PLAN_WORKFLOW,
# qa-plan.yml) on the default branch for the open pull requests that wait for a slot, the longest waiting first, at
# most <slots>. It runs in qa-down's wake job, one wake at a time for the whole repository (its concurrency group):
# two at once would each read the comments before the other marked one, and wake the same pull request. Each one's
# comment is marked woken first, so the next wake picks another; a woken one counts as waiting again after
# MROOM_QA_WAKE_AGAIN (1800) seconds, in case its plan never ran, and one whose plan could not be started waits again
# at once.
# The job token's dispatch does start the plan, but nothing after it starts by itself: a run the job token started
# starts no workflow_run when it ends, and neither does a run that one starts in turn. So each link starts the next
# itself: the plan dispatches qa-up (.github/workflows/qa-plan.yml, hand-over), and qa-up, started that way,
# dispatches the app's workflows that follow it in turn (.github/workflows/qa-up.yml, next-workflows), whose
# workflow_run would never come either.
# The cost is bounded: one listing of the 100 newest open pull requests, and one of each one's comments, 100 a page;
# one older than those is not seen. It lists every open pull request, not the waiting ones alone, since only their
# comment's hidden line tells those apart, and GitHub's search does not promise to see it. Best-effort: a failure
# only warns.
qa_wake() {
  local slots="$1" workflow="${MROOM_QA_PLAN_WORKFLOW:-qa-plan.yml}" again="${MROOM_QA_WAKE_AGAIN:-1800}"
  local prs pr found state since woken cutoff waiting="" picked=0
  [[ "$slots" =~ ^[0-9]+$ ]] || { qa_say "the number of slots to wake for is not a number"; return 1; }
  ((slots > 0)) || return 0
  [[ "$workflow" =~ $QA_WORKFLOW_RE ]] || { qa_say "MROOM_QA_PLAN_WORKFLOW is not a workflow file name"; return 1; }
  [[ "$again" =~ ^[0-9]{1,6}$ ]] || again=1800
  cutoff="$(date -u -d "@$(($(mroom_now) - again))" +%Y-%m-%dT%H:%M:%SZ)"
  prs="$(gh pr list --repo "$GITHUB_REPOSITORY" --state open --limit 100 --json number,isDraft \
    --jq '.[] | select(.isDraft | not) | .number' </dev/null)" \
    || { echo "::warning::could not list the open pull requests to wake one"; return 0; }
  for pr in $prs; do
    [[ "$pr" =~ ^[0-9]+$ ]] || continue
    found="$(qa_comment_newest "$pr" </dev/null)" || continue
    [ -n "$found" ] || continue
    state="$(jq -r '.state' <<<"$found")" since="$(jq -r '.since' <<<"$found")" woken="$(jq -r '.woken' <<<"$found")"
    [[ "$since" =~ ^[0-9TZ:-]+$ ]] || since="$(jq -r '.updated_at // ""' <<<"$found")"
    if [ "$state" = waiting ] || { [ "$state" = woken ] && [[ "$woken" < "$cutoff" ]]; }; then
      waiting+="$since $pr"$'\n'
    fi
  done
  if [ -z "$waiting" ]; then echo "no pull request waits for a QA environment slot"; return 0; fi
  for pr in $(sort <<<"$waiting" | awk 'NF == 2 { print $2 }'); do
    ((picked < slots)) || break
    # Marked first, so the next wake does not pick it as well.
    if ! qa_comment "$pr" woken "A QA environment slot freed up at $(qa_now); its QA plan is being started again, and deploys if it still needs an environment." </dev/null; then
      echo "::warning::could not mark pull request $pr as woken, so it is left for the next wake"
      continue
    fi
    picked=$((picked + 1))
    echo "starting the QA plan for pull request $pr, which waited for a slot"
    if ! gh workflow run "$workflow" --repo "$GITHUB_REPOSITORY" ${MROOM_QA_DEFAULT_BRANCH:+--ref "$MROOM_QA_DEFAULT_BRANCH"} \
      -f pr_number="$pr" </dev/null; then
      echo "::warning::could not start the QA plan for pull request $pr, so it waits again"
      qa_comment "$pr" waiting "Waits for a QA environment slot: one freed up at $(qa_now), but its QA plan could not be started, so the next one tries again." </dev/null \
        || echo "::warning::could not say so in the QA environment comment of pull request $pr"
    fi
  done
}
