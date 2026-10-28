# shellcheck shell=bash
# errors.sh — the error-tracker adapter (design section 7): read an error issue with its latest event,
# search issues, and resolve one, on the error tracker mroom.toml names (errors.provider). Sourced after
# api.sh by lib/errors, never run on its own; needs bash 5, curl, jq and python3 3.11. The caller sets
# MROOM_ROOT.
#
# v1 backend: sentry. Without an [errors] table there is no error tracker, and every operation returns 3.
# Each function takes the command line's words and prints JSON on stdout.
#
# Exit codes: 0 done; 1 the error tracker or the config failed; 2 a usage error; 3 there is no error tracker.
#
# Every call goes to https://<errors.region>.sentry.io/api/0/organizations/<errors.org>/, never a URL from
# config, so a changed mroom.toml cannot send the token to another host. The token is the environment
# variable errors.token_env names (SENTRY_AUTH_TOKEN by default); the adapter reads no file for it. Reading
# needs Issue & Event: read and Project: read; resolving needs Issue & Event: write too.

ERRORS_NAME="mroom errors"
ERRORS_BASE=""
SENTRY_AUTH=""
ERRORS_MAX_PAGES=50

errors_say() { echo "$ERRORS_NAME: $*" >&2; }

# errors_config <key> [<default> | --optional]: one value from the app's mroom.toml, through the one reader;
# with --optional, nothing when the key is not set.
errors_config() {
  if [ "${2-}" = --optional ]; then
    python3 "$MROOM_ROOT/lib/core/config.py" get "$1" --optional
  elif [ "$#" -ge 2 ]; then
    python3 "$MROOM_ROOT/lib/core/config.py" get "$1" --default "$2"
  else
    python3 "$MROOM_ROOT/lib/core/config.py" get "$1"
  fi
}

# errors_backend: sentry, or none when mroom.toml has no errors.provider.
errors_backend() {
  local provider
  provider="$(errors_config errors.provider --optional)" || return 1
  printf '%s\n' "${provider:-none}"
}

errors_none() {
  errors_say "mroom.toml has no [errors] table (errors.provider), so there is no error tracker to $1"
  return 3
}

# errors_id_ok <id>: a numeric issue id, or a short id that matches errors.id_pattern when that is set.
errors_id_ok() {
  local id="$1" pattern
  [[ "$id" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || { errors_say "not an error issue id: ${id:0:80}"; return 2; }
  [[ "$id" =~ ^[0-9]+$ ]] && return 0
  pattern="$(errors_config errors.id_pattern --optional)" || return 1
  if [ -n "$pattern" ] && ! [[ "$id" =~ ^($pattern)$ ]]; then
    errors_say "$id is neither a numeric id nor matches errors.id_pattern ($pattern)"
    return 2
  fi
}

# ---- Sentry -------------------------------------------------------------------------------------

# sentry_init: sets ERRORS_BASE and SENTRY_AUTH from errors.org, errors.region and errors.token_env.
sentry_init() {
  local -
  set +x
  local org region env token
  [ -n "$ERRORS_BASE" ] && return 0
  org="$(errors_config errors.org --optional)" || return 1
  [ -n "$org" ] || { errors_say "errors.org is not set (the Sentry organisation's slug)"; return 1; }
  [[ "$org" =~ ^[a-z0-9][a-z0-9_-]{0,49}$ ]] || { errors_say "errors.org is not an organisation slug: ${org:0:60}"; return 1; }
  region="$(errors_config errors.region us)" || return 1
  [[ "$region" =~ ^(us|de)$ ]] || { errors_say "errors.region is us or de"; return 1; }
  env="$(errors_config errors.token_env SENTRY_AUTH_TOKEN)" || return 1
  token="$(api_token "$env" "Sentry")" || return 1
  # shellcheck disable=SC2034  # read by api_call, through its name
  SENTRY_AUTH="Bearer $token"
  ERRORS_BASE="https://$region.sentry.io/api/0/organizations/$org"
}

# sentry_call <safe|once> <METHOD> <path> [body]: one call under the organisation; the answer is in
# $API_TMP/body and $API_TMP/headers. The path starts with / and holds its query, already encoded.
sentry_call() {
  api_call "$ERRORS_NAME" "$1" "$2" "$ERRORS_BASE$3" SENTRY_AUTH "${4-}" || return 1
  jq -e 'type == "array" or type == "object"' "$API_TMP/body" >/dev/null 2>&1 \
    || { errors_say "Sentry: $2 ${3%%\?*} answered with something that is not JSON"; return 1; }
}

# sentry_next_cursor: the cursor of the next page from the last answer's Link header, or nothing when
# Sentry says there are no more results.
sentry_next_cursor() {
  tr -d '\r' <"$API_TMP/headers" | awk 'tolower($0) ~ /^link:/' | sed 's/, </\n</g' \
    | awk '/rel="next"/ && /results="true"/' | sed -n 's/.*cursor="\([^"]*\)".*/\1/p' | head -n1
}

# sentry_uri <text>: the text, URL-encoded.
sentry_uri() { jq -rn --arg v "$1" '$v | @uri'; }

SENTRY_ISSUE_JQ='{id, short_id: .shortId, title, culprit, permalink, level, status, substatus, count, user_count: .userCount,
  first_seen: .firstSeen, last_seen: .lastSeen, first_release: .firstRelease.version?, last_release: .lastRelease.version?,
  project: .project.slug?, tags: [.tags[]? | {key, top: [.topValues[]? | {value, count}][0:3]}]}'

SENTRY_EVENT_JQ='{id: .eventID, at: .dateCreated, message: (.message // .title), release: (.release.version? // .release),
  environment: ([.tags[]? | select(.key == "environment") | .value][0]),
  tags: [.tags[]? | select(.key | IN("environment", "release", "url", "transaction", "server_name", "level")) | {key, value}],
  exception: [.entries[]? | select(.type == "exception") | .data.values[]? | {type, value,
    frames: [.stacktrace.frames[]? | select(.inApp) | {filename, function, line: .lineNo}] | .[-8:]}]}'

sentry_issue_get() {
  local issue
  sentry_init || return 1
  sentry_call safe GET "/issues/$1/" || return 1
  issue="$(jq -c "$SENTRY_ISSUE_JQ" "$API_TMP/body")" || { errors_say "Sentry: the issue could not be read"; return 1; }
  sentry_call safe GET "/issues/$1/events/latest/" || return 1
  jq -c --argjson i "$issue" "\$i + {latest_event: $SENTRY_EVENT_JQ}" "$API_TMP/body" \
    || { errors_say "Sentry: the latest event could not be read"; return 1; }
}

# sentry_scope_ok: the token sees at least one project. Without that, a search across the organisation
# (project=-1) answers [] whatever happened, so an empty answer would read as "no issues" when nothing
# was searched.
sentry_scope_ok() {
  sentry_call safe GET "/projects/?per_page=1" || return 1
  jq -e 'type == "array" and length > 0' "$API_TMP/body" >/dev/null 2>&1 && return 0
  errors_say "Sentry: the token sees no project (it needs Project: read), so a search would prove nothing"
  return 1
}

# sentry_search <query> <environment> <period> <limit>: issues across every project, newest first, up to
# <limit>, following the Link header's cursor page by page.
sentry_search() {
  local query="$1" environment="$2" period="$3" limit="$4" cursor="" pages=0 got=0 per path items=()
  sentry_init || return 1
  sentry_scope_ok || return 1
  while :; do
    pages=$((pages + 1))
    ((pages <= ERRORS_MAX_PAGES)) || { errors_say "Sentry: more than $ERRORS_MAX_PAGES pages"; return 1; }
    per=$((limit - got))
    ((per <= 100)) || per=100
    path="/issues/?project=-1&query=$(sentry_uri "$query")&statsPeriod=$period&limit=$per&sort=date"
    [ -z "$environment" ] || path+="&environment=$(sentry_uri "$environment")"
    [ -z "$cursor" ] || path+="&cursor=$(sentry_uri "$cursor")"
    sentry_call safe GET "$path" || return 1
    jq -e 'type == "array"' "$API_TMP/body" >/dev/null 2>&1 || { errors_say "Sentry: the search answer is not a list"; return 1; }
    items+=("$(jq -c "[.[] | $SENTRY_ISSUE_JQ | del(.tags)]" "$API_TMP/body")")
    got=$((got + $(jq 'length' "$API_TMP/body")))
    ((got < limit)) || break
    cursor="$(sentry_next_cursor)"
    [ -n "$cursor" ] || break
  done
  printf '%s\n' "${items[@]}" | jq -sc --argjson n "$limit" 'add | .[0:$n]'
}

sentry_issue_resolve() {
  sentry_init || return 1
  sentry_call safe PUT "/issues/$1/" '{"status":"resolved"}' || return 1
  jq -c --arg id "$1" '{resolved: $id, status: (.status // "resolved")}' "$API_TMP/body"
}

# ---- The adapter's functions --------------------------------------------------------------------

# errors_issue_get <id>: the error issue (counts, first and last seen and release, top tags) and its
# latest event (message, release, environment, the exception's in-app frames).
errors_issue_get() {
  [ "$#" = 1 ] || { errors_say "usage: get <id>"; return 2; }
  local backend
  backend="$(errors_backend)" || return 1
  case "$backend" in
    none) errors_none "read an issue from" ;;
    sentry) errors_id_ok "$1" || return; sentry_issue_get "$1" ;;
  esac
}

# errors_search <query> [--environment <name>] [--period 24h|14d|...] [--limit 1-1000]: issues for a search,
# in the error tracker's own search syntax (default: the last 14 days, 25 issues).
errors_search() {
  local query="" environment="" period=14d limit=25 backend
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --environment) environment="${2-}"; shift 2 || { errors_say "--environment takes a value"; return 2; } ;;
      --period) period="${2-}"; shift 2 || { errors_say "--period takes a value"; return 2; } ;;
      --limit) limit="${2-}"; shift 2 || { errors_say "--limit takes a value"; return 2; } ;;
      --*) errors_say "search: unknown option '$1'"; return 2 ;;
      *) [ -z "$query" ] || { errors_say "search takes one query (quote it)"; return 2; }; query="$1"; shift ;;
    esac
  done
  [ -n "$query" ] || { errors_say "usage: search <query> [--environment <name>] [--period 14d] [--limit 25]"; return 2; }
  if [ "${#query}" -gt 500 ] || [[ "$query" == *[$'\r\n']* ]]; then
    errors_say "the query is one line of at most 500 characters"; return 2
  fi
  [[ "$period" =~ ^[1-9][0-9]{0,2}[mhdw]$ ]] || { errors_say "--period is a number and m, h, d or w, such as 14d"; return 2; }
  if ! [[ "$limit" =~ ^[1-9][0-9]{0,3}$ ]] || ((limit > 1000)); then errors_say "--limit is 1 to 1000"; return 2; fi
  [[ "$environment" =~ ^[A-Za-z0-9._-]{0,64}$ ]] || { errors_say "--environment is a plain name"; return 2; }
  backend="$(errors_backend)" || return 1
  case "$backend" in
    none) errors_none "search" ;;
    sentry) sentry_search "$query" "$environment" "$period" "$limit" ;;
  esac
}

# errors_issue_resolve <id>: marks the error issue resolved. Needs a token with Issue & Event: write.
errors_issue_resolve() {
  [ "$#" = 1 ] || { errors_say "usage: resolve <id>"; return 2; }
  local backend
  backend="$(errors_backend)" || return 1
  case "$backend" in
    none) errors_none "resolve an issue in" ;;
    sentry) errors_id_ok "$1" || return; sentry_issue_resolve "$1" ;;
  esac
}
