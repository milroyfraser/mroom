# shellcheck shell=bash
# forge.sh — the Laravel Forge v2 client every mroom command uses: bin/forge-api on the box, and the QA
# environment actions on a runner. Sourced after util.sh, never run on its own; needs bash 5, curl and jq.
#
# Every call is pinned to one server, https://forge.laravel.com/api/orgs/<org>/servers/<server>, from
# MROOM_FORGE_ORG and MROOM_FORGE_SERVER (box.env, or the environment, which wins). The token comes from
# MROOM_FORGE_TOKEN when it is set (a runner), else from ~/.config/mroom/secrets/forge-token (mode 600).
# It reaches curl on stdin, so it is never on a command line or on disk, and it is not printed even under
# `bash -x`. A request body and the answer pass through a private folder, FORGE_TMP, which the client
# removes; a caller that can be interrupted removes it in its own trap too (bin/forge-api does). curl is
# run with -q, so a ~/.curlrc cannot change how it behaves. The caller may set FORGE_NAME to the name its
# messages start with.

_FORGE_BASE=""
FORGE_TMP=""
# Cloudflare in front of Forge refuses some default user agents (python's, for one): name a browser.
FORGE_UA="Mozilla/5.0 (X11; Linux x86_64) mroom-forge/1.0"
FORGE_MAX_PAGES=1000

# forge_say <message>: one line on stderr, named after the command that uses the client.
forge_say() { echo "${FORGE_NAME:-mroom forge}: $*" >&2; }

# forge_token_file: where the box keeps the token.
forge_token_file() { printf '%s\n' "$HOME/.config/mroom/secrets/forge-token"; }

# forge_cleanup: removes the call's private folder. Safe to call from a trap at any time.
forge_cleanup() {
  if [ -n "$FORGE_TMP" ]; then
    rm -rf "$FORGE_TMP"
    FORGE_TMP=""
  fi
}

# forge_init: sets the base URL from MROOM_FORGE_ORG and MROOM_FORGE_SERVER. Fails when either is missing,
# or is not an organisation slug and a numeric server id, so a stray value can't move the call elsewhere.
forge_init() {
  [ -n "$_FORGE_BASE" ] && return 0
  load_box || return 1
  local org="${BOX[MROOM_FORGE_ORG]:-}" server="${BOX[MROOM_FORGE_SERVER]:-}"
  if [ -z "$org" ] || [ -z "$server" ]; then
    forge_say "MROOM_FORGE_ORG and MROOM_FORGE_SERVER must be set (in box.env, or in the environment on a runner)"
    return 1
  fi
  [[ "$org" =~ ^[A-Za-z0-9_-]+$ ]] || { forge_say "MROOM_FORGE_ORG is not an organisation slug: $org"; return 1; }
  [[ "$server" =~ ^[0-9]+$ ]] || { forge_say "MROOM_FORGE_SERVER is not a server id: $server"; return 1; }
  _FORGE_BASE="https://forge.laravel.com/api/orgs/$org/servers/$server"
}

# forge_token: the token on stdout, without whitespace. Called only from forge, with xtrace off.
forge_token() {
  local token tf
  if [ -n "${MROOM_FORGE_TOKEN:-}" ]; then
    token="$MROOM_FORGE_TOKEN"
  else
    tf="$(forge_token_file)"
    if [ ! -e "$tf" ]; then
      forge_say "no Forge token: $(home_short "$tf") is missing (on a runner, set MROOM_FORGE_TOKEN)"
      return 1
    fi
    [ -r "$tf" ] || { forge_say "$(home_short "$tf") cannot be read"; return 1; }
    secret_file_ok "$tf" || { forge_say "$(home_short "$tf") must be yours and mode 600"; return 1; }
    token="$(<"$tf")"
  fi
  token="${token//[$'\r\n\t ']/}"
  [ -n "$token" ] || { forge_say "the Forge token is empty"; return 1; }
  # Printable characters only, so the token can never add a header line of its own.
  [[ "$token" =~ ^[!-~]+$ ]] || { forge_say "the Forge token holds characters a token never has"; return 1; }
  printf '%s' "$token"
}

# forge_retry_after <headers file>: seconds to wait after a 429: the answer's Retry-After when it is a
# number from 1 to 120, else MROOM_FORGE_RATE_SLEEP (20).
forge_retry_after() {
  local secs
  secs="$(tr -d '\r' <"$1" 2>/dev/null | awk -F': *' 'tolower($1) == "retry-after" { print $2; exit }')"
  if [[ "$secs" =~ ^[0-9]+$ ]] && ((secs >= 1 && secs <= 120)); then
    printf '%s\n' "$secs"
  else
    printf '%s\n' "${MROOM_FORGE_RATE_SLEEP:-20}"
  fi
}

# forge <METHOD> <path> [body]: one call; prints the response body on success. Fails with one line on
# stderr on any HTTP error (curl alone exits 0 on a 4xx, which would turn a failed provision green).
# Waits out a 429 and retries a 503 for every method, since neither ran; retries a 502 only for GET, PUT
# and DELETE, since a gateway error can come after the work was done; retries a timeout only for a GET.
# At most 4 calls. The path is relative to the server and starts with /, for example /sites/123/nginx.
forge() {
  # Shell options are local here, so xtrace stays off while the token is in hand and comes back on return.
  local -
  set +x
  local method="$1" path="${2:-}" body="${3-}" token code attempt=0 detail answer
  case "$path" in
    /*) ;;
    *) forge_say "a path must start with /: ${path:0:40}"; return 1 ;;
  esac
  forge_init || return 1
  token="$(forge_token)" || return 1
  forge_cleanup
  FORGE_TMP="$(mktemp -d)" || return 1
  local args=(-q --silent --show-error --globoff --max-time "${MROOM_FORGE_TIMEOUT:-60}" --request "$method"
    --header "User-Agent: $FORGE_UA" --header "Accept: application/json"
    --header "Content-Type: application/json" --header @-
    --dump-header "$FORGE_TMP/headers" --output "$FORGE_TMP/body" --write-out '%{http_code}')
  if [ -n "$body" ]; then
    printf '%s' "$body" >"$FORGE_TMP/request"
    args+=(--data-binary "@$FORGE_TMP/request")
  fi
  while :; do
    code="$(printf 'Authorization: Bearer %s\n' "$token" | curl "${args[@]}" "$_FORGE_BASE$path" 2>"$FORGE_TMP/stderr")" || code=000
    attempt=$((attempt + 1))
    if ((attempt <= 3)); then
      case "$code" in
        503) sleep $((attempt * 2)); continue ;;
        429) sleep "$(forge_retry_after "$FORGE_TMP/headers")"; continue ;;
        502) case "$method" in GET | PUT | DELETE) sleep $((attempt * 2)); continue ;; esac ;;
        000) if [ "$method" = GET ]; then sleep $((attempt * 2)); continue; fi ;;
      esac
    fi
    break
  done
  if [ "${code:0:1}" = 2 ]; then
    # Read the answer before printing it, so a reader that stops early cannot leave the folder behind.
    answer="$(cat "$FORGE_TMP/body" 2>/dev/null)"
    forge_cleanup
    printf '%s' "$answer"
    return 0
  fi
  if [ "$code" = 000 ]; then
    detail="$(head -c 200 "$FORGE_TMP/stderr" 2>/dev/null | tr '\n' ' ')"
  else
    detail="$(head -c 300 "$FORGE_TMP/body" 2>/dev/null | tr '\n' ' ')"
  fi
  forge_cleanup
  forge_say "$method $path -> HTTP $code${detail:+: $detail}"
  return 1
}

# forge_list <path>: every item of a paginated list, one JSON object per line. Fails when a page can't be
# read or holds no list, and after FORGE_MAX_PAGES pages: an API blip must never read as an empty or a
# shorter list, which would say "no environment" for one that exists.
forge_list() {
  local path="$1" cursor="" page sep='?' pages=0
  case "$path" in *\?*) sep='&' ;; esac
  while :; do
    pages=$((pages + 1))
    ((pages <= FORGE_MAX_PAGES)) || { forge_say "GET $path: more than $FORGE_MAX_PAGES pages"; return 1; }
    page="$(forge GET "${path}${sep}page[size]=100${cursor:+&page[cursor]=$cursor}")" || return 1
    if ! jq -e '.data | type == "array"' <<<"$page" >/dev/null 2>&1; then
      forge_say "GET $path: the answer holds no list"
      return 1
    fi
    jq -c '.data[]' <<<"$page"
    cursor="$(jq -r '.meta.next_cursor as $c
      | if $c == null then empty elif ($c | type) == "string" then ($c | @uri) else error("not a cursor") end' \
      <<<"$page" 2>/dev/null)" || { forge_say "GET $path: the answer's next page cannot be read"; return 1; }
    [ -n "$cursor" ] || return 0
  done
}

# forge_site <domain>: the site's JSON (its id and attributes), or nothing when there is no such site.
# There is no GET for one site under a server, so this filters the server's list.
forge_site() {
  [[ "$1" =~ ^[A-Za-z0-9.-]+$ ]] || { forge_say "not a domain: ${1:0:60}"; return 1; }
  local items
  items="$(forge_list "/sites?filter[name]=$1")" || return 1
  jq -c --arg domain "$1" 'select(.attributes.name == $domain)' <<<"$items" | head -n1
}
