# shellcheck shell=bash
# forge.sh — the Laravel Forge v2 client every mroom command uses: bin/forge-api on the box, and the QA
# environment actions on a runner. Sourced after util.sh, never run on its own; needs curl and jq.
#
# Every call is pinned to one server, https://forge.laravel.com/api/orgs/<org>/servers/<server>, from
# MROOM_FORGE_ORG and MROOM_FORGE_SERVER (box.env, or the environment, which wins). The token comes from
# MROOM_FORGE_TOKEN when it is set (a runner), else from ~/.config/mroom/secrets/forge-token (mode 600).
# The token and any request body reach curl through private files, never its command line (design 8.4),
# and neither is printed. The caller may set FORGE_NAME to the name its messages start with.

FORGE_BASE=""
FORGE_UA="Mozilla/5.0 (X11; Linux x86_64) mroom-forge/1.0"

# forge_say <message>: one line on stderr, named after the command that uses the client.
forge_say() { echo "${FORGE_NAME:-mroom forge}: $*" >&2; }

# forge_token_file: where the box keeps the token.
forge_token_file() { printf '%s\n' "$HOME/.config/mroom/secrets/forge-token"; }

# forge_init: sets FORGE_BASE from MROOM_FORGE_ORG and MROOM_FORGE_SERVER. Fails when either is missing,
# or is not an organisation slug and a numeric server id, so a stray value can't move the call elsewhere.
forge_init() {
  [ -n "$FORGE_BASE" ] && return 0
  load_box || return 1
  local org="${BOX[MROOM_FORGE_ORG]:-}" server="${BOX[MROOM_FORGE_SERVER]:-}"
  if [ -z "$org" ] || [ -z "$server" ]; then
    forge_say "MROOM_FORGE_ORG and MROOM_FORGE_SERVER must be set (in box.env, or in the environment on a runner)"
    return 1
  fi
  [[ "$org" =~ ^[A-Za-z0-9_-]+$ ]] || { forge_say "MROOM_FORGE_ORG is not an organisation slug: $org"; return 1; }
  [[ "$server" =~ ^[0-9]+$ ]] || { forge_say "MROOM_FORGE_SERVER is not a server id: $server"; return 1; }
  FORGE_BASE="https://forge.laravel.com/api/orgs/$org/servers/$server"
}

# forge_write_auth <file>: writes the Authorization header into <file>. printf is a builtin, so the token
# never appears in a process's arguments.
forge_write_auth() {
  local file="$1" token tf
  if [ -n "${MROOM_FORGE_TOKEN:-}" ]; then
    token="$MROOM_FORGE_TOKEN"
  else
    tf="$(forge_token_file)"
    if [ ! -r "$tf" ]; then
      forge_say "no Forge token: $(home_short "$tf") is missing (on a runner, set MROOM_FORGE_TOKEN)"
      return 1
    fi
    secret_file_ok "$tf" || { forge_say "$(home_short "$tf") must be yours and mode 600"; return 1; }
    token="$(<"$tf")"
    token="${token//[$'\r\n\t ']/}"
  fi
  [ -n "$token" ] || { forge_say "the Forge token is empty"; return 1; }
  printf 'Authorization: Bearer %s\n' "$token" >"$file"
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
# Retries what never ran (502, 503), waits out a 429, and retries a timeout only for a GET, since a write
# may have run. The path is relative to the server, for example /sites or /sites/123/nginx.
forge() {
  local method="$1" path="$2" body="${3-}" dir code attempt=0 detail
  forge_init || return 1
  dir="$(umask 077 && mktemp -d)" || return 1
  if ! forge_write_auth "$dir/auth"; then
    rm -rf "$dir"
    return 1
  fi
  local args=(--silent --show-error --globoff --max-time "${MROOM_FORGE_TIMEOUT:-60}" --request "$method"
    --header "User-Agent: $FORGE_UA" --header "Accept: application/json"
    --header "Content-Type: application/json" --header "@$dir/auth"
    --dump-header "$dir/headers" --output "$dir/body" --write-out '%{http_code}')
  if [ -n "$body" ]; then
    printf '%s' "$body" >"$dir/request"
    args+=(--data-binary "@$dir/request")
  fi
  while :; do
    code="$(curl "${args[@]}" "$FORGE_BASE$path" 2>"$dir/stderr")" || code=000
    attempt=$((attempt + 1))
    if ((attempt <= 3)); then
      case "$code" in
        502 | 503) sleep $((attempt * 2)); continue ;;
        429) sleep "$(forge_retry_after "$dir/headers")"; continue ;;
        000) if [ "$method" = GET ]; then sleep $((attempt * 2)); continue; fi ;;
      esac
    fi
    break
  done
  if [ "${code:0:1}" = 2 ]; then
    cat "$dir/body"
    rm -rf "$dir"
    return 0
  fi
  if [ "$code" = 000 ]; then
    detail="$(head -c 200 "$dir/stderr" | tr '\n' ' ')"
  else
    detail="$(head -c 300 "$dir/body" 2>/dev/null | tr '\n' ' ')"
  fi
  forge_say "$method $path -> HTTP $code${detail:+: $detail}"
  rm -rf "$dir"
  return 1
}

# forge_list <path>: every item of a paginated list, one JSON object per line. Fails when a page can't be
# read or holds no list: an API blip must never read as an empty list, which would say "no environment"
# for one that exists.
forge_list() {
  local path="$1" cursor="" page sep='?'
  case "$path" in *\?*) sep='&' ;; esac
  while :; do
    page="$(forge GET "${path}${sep}page[size]=100${cursor:+&page[cursor]=$cursor}")" || return 1
    if ! jq -e '.data | type == "array"' <<<"$page" >/dev/null 2>&1; then
      forge_say "GET $path: the answer holds no list"
      return 1
    fi
    jq -c '.data[]' <<<"$page"
    cursor="$(jq -r '.meta.next_cursor // empty | @uri' <<<"$page")"
    [ -n "$cursor" ] || return 0
  done
}

# forge_site <domain>: the site's JSON (its id and attributes), or nothing when there is no such site.
# Forge v2 has no GET for one site, so this filters the list.
forge_site() {
  local items
  items="$(forge_list "/sites?filter[name]=$1")" || return 1
  jq -c --arg domain "$1" 'select(.attributes.name == $domain)' <<<"$items" | head -n1
}
