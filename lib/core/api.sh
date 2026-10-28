# shellcheck shell=bash
# api.sh — the HTTP client the tracker and error-tracker adapters share (design section 7): one JSON call
# with retries, the token kept off every command line. Sourced by lib/core/tracker.sh and lib/core/errors.sh,
# never run on its own; needs bash 5, curl and jq.
#
# The caller makes a private folder with api_tmp (removed by api_cleanup, which the commands run from an
# EXIT trap) and puts the whole Authorization header value in a variable whose name it passes. The header
# reaches curl on stdin, so it is not on a command line or on disk, and xtrace is off while it is in hand.
# curl runs with -q, so a ~/.curlrc cannot change how it behaves.

API_TMP=""
API_MAX_CALLS=4

# api_tmp: makes the private folder for request and answer files, once.
api_tmp() {
  [ -n "$API_TMP" ] && return 0
  API_TMP="$(mktemp -d)" || { echo "mroom: could not make a temporary folder" >&2; return 1; }
}

# api_cleanup: removes the private folder. Safe to call from a trap at any time.
api_cleanup() {
  if [ -n "$API_TMP" ]; then
    rm -rf "$API_TMP"
    API_TMP=""
  fi
}

# api_token <env name> <what it is for>: the token in that environment variable, without whitespace, on
# stdout. Fails with one line that names the variable, never its value.
api_token() {
  local -
  set +x
  local name="$1" token
  [[ "$name" =~ ^[A-Z][A-Z0-9_]{0,63}$ ]] || { echo "mroom: $2: $name is not an environment variable's name" >&2; return 1; }
  token="${!name:-}"
  # A secret pasted with a trailing newline or space is the same token.
  token="${token//[$'\r\n\t ']/}"
  if [ -z "$token" ]; then
    echo "mroom: $2: the environment variable $name is not set or is empty" >&2
    return 1
  fi
  # Printable characters only, so the token can never add a header line of its own.
  [[ "$token" =~ ^[!-~]+$ ]] || { echo "mroom: $2: $name holds characters a token never has" >&2; return 1; }
  printf '%s' "$token"
}

# api_retry_after <headers file> <default>: seconds to wait before the next call: the answer's
# Retry-After when it is a number from 1 to 120, else the default.
api_retry_after() {
  local secs
  secs="$(tr -d '\r' <"$1" 2>/dev/null | awk -F': *' 'tolower($1) == "retry-after" { print $2; exit }')"
  if [[ "$secs" =~ ^[0-9]+$ ]] && ((secs >= 1 && secs <= 120)); then
    printf '%s\n' "$secs"
  else
    printf '%s\n' "$2"
  fi
}

# api_call <name> <safe|once> <METHOD> <url> <auth variable> [body]: one call. The answer's body lands in
# $API_TMP/body and its headers in $API_TMP/headers. Returns 0 on a 2xx; else 1, with one line on stderr
# naming the method, the URL without its query, the status and the start of the answer (the token, if the
# answer echoes it, is cut out).
#
# Retries, at most API_MAX_CALLS calls in all: a 429 (or a GraphQL answer whose error code is RATELIMITED)
# and a 503 always, since neither did the work; for a "safe" call (a read, or a write that does the same
# thing twice) any other 5xx and a call that got no answer too. A "once" call (one that adds something,
# such as a comment) is never repeated after an answer that may have come after the work was done. A 4xx
# other than 429 is never retried.
api_call() {
  local -
  set +x
  local name="$1" kind="$2" method="$3" url="$4" authvar="$5" body="${6-}"
  local code attempt=0 detail auth limited wait
  auth="${!authvar:-}"
  [ -n "$auth" ] || { echo "$name: no Authorization header to send" >&2; return 1; }
  api_tmp || return 1
  rm -f "$API_TMP/body" "$API_TMP/headers" "$API_TMP/request" "$API_TMP/stderr"
  local args=(-q --silent --show-error --globoff --max-time "${MROOM_API_TIMEOUT:-30}" --request "$method"
    --header "Accept: application/json" --header "Content-Type: application/json" --header @-
    --dump-header "$API_TMP/headers" --output "$API_TMP/body" --write-out '%{http_code}')
  if [ -n "$body" ]; then
    printf '%s' "$body" >"$API_TMP/request"
    args+=(--data-binary "@$API_TMP/request")
  fi
  while :; do
    code="$(printf 'Authorization: %s\n' "$auth" | curl "${args[@]}" "$url" 2>"$API_TMP/stderr")" || code=000
    [[ "$code" =~ ^[0-9]{3}$ ]] || code=000
    attempt=$((attempt + 1))
    limited=""
    if [ "$code" = 429 ] || { [ "${code:0:1}" != 5 ] && [ "$code" != 000 ] \
      && jq -e '(.errors? // []) | map(.extensions.code?) | index("RATELIMITED")' "$API_TMP/body" >/dev/null 2>&1; }; then
      limited=1
    fi
    if ((attempt < API_MAX_CALLS)); then
      wait=""
      if [ -n "$limited" ]; then
        wait="$(api_retry_after "$API_TMP/headers" "${MROOM_API_RATE_SLEEP:-20}")"
      elif [ "$code" = 503 ]; then
        wait=$((attempt * 2))
      elif [ "$kind" = safe ] && { [ "${code:0:1}" = 5 ] || [ "$code" = 000 ]; }; then
        wait=$((attempt * 2))
      fi
      if [ -n "$wait" ]; then
        sleep "$wait"
        continue
      fi
    fi
    break
  done
  if [ "${code:0:1}" = 2 ] && [ -z "$limited" ]; then
    return 0
  fi
  if [ "$code" = 000 ]; then
    detail="$(head -c 4000 "$API_TMP/stderr" 2>/dev/null | tr '\n' ' ')"
  else
    detail="$(head -c 4000 "$API_TMP/body" 2>/dev/null | tr '\n' ' ')"
  fi
  # The header value is "Bearer <token>" or the token alone: cut out whichever the answer echoes, before
  # the detail is shortened, so no part of it is left at the cut.
  local token="${auth#Bearer }"
  detail="${detail//"$token"/[token]}"
  detail="${detail:0:300}"
  echo "$name: $method ${url%%\?*} -> HTTP $code${limited:+ (rate limited)}${detail:+: $detail}" >&2
  return 1
}
