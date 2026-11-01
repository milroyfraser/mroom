#!/usr/bin/env bash
# verify.sh — waits until production runs the release just deployed (design 10, pattern 9), for the deploy-verify
# action. It asks the app's app.version_path (lib/core/version.sh), and a separate SPA's /version.json, with a query
# no cache has seen, until each reports the tag's commit three times in a row with the app's health path answering
# 200, and fails after the time limit. A fixed sleep and a health ping pass when the host's deploy failed, since the
# old release answers too; the commit cannot.
#
# Environment (the action sets it from its inputs):
#   DEPLOY_ORIGIN            the app's origin, https://<host>[:port] (http:// only for tests)
#   DEPLOY_FRONTEND_ORIGIN   a separate SPA's origin, or empty
#   DEPLOY_COMMIT            the full commit the release tag points at
#   DEPLOY_TAG               the tag, for the warning when the app names another release; may be empty
#   DEPLOY_HEALTH_PATH       a path that must answer 200 for a poll of the app to count (/up); empty for none
#   DEPLOY_TIMEOUT           how long to wait (10m)
#   DEPLOY_INTERVAL          the pause between polls (10s)
#   MROOM_CONFIG             the app's mroom.toml
# Prints seconds=<how long it took> for GITHUB_OUTPUT; everything else goes to stderr. Exits 1 when the time ran out,
# 2 for a bad input. It sends no credential and prints only commits, release names and HTTP codes.
set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
MROOM_ROOT="$(cd "$(dirname "$SELF")/../.." && pwd)"
export MROOM_ROOT
# shellcheck source=lib/core/util.sh
. "$MROOM_ROOT/lib/core/util.sh"
# shellcheck source=lib/core/version.sh
. "$MROOM_ROOT/lib/core/version.sh"

# In a row, by design: one answer from the new release can come from a server that is still switching over.
TIMES=3

bad() { echo "::error::deploy-verify: $*" >&2; exit 2; }

origin="${DEPLOY_ORIGIN:-}" frontend="${DEPLOY_FRONTEND_ORIGIN:-}" want="${DEPLOY_COMMIT:-}" tag="${DEPLOY_TAG:-}"
health="${DEPLOY_HEALTH_PATH-/up}"
[[ "$want" =~ ^[0-9a-f]{40}$ ]] || bad "commit must be a full commit SHA, not '${want:0:60}'"
[ -z "$tag" ] || [[ "$tag" =~ ^[A-Za-z0-9._+-]{1,100}$ ]] || bad "tag '${tag:0:60}' is not a plain tag name"
[ -z "$health" ] || [[ "$health" =~ ^(/[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}){1,8}$ ]] \
  || bad "health-path '${health:0:60}' is not a path such as /up"
timeout="$(dur_secs "${DEPLOY_TIMEOUT:-10m}")" || bad "timeout '${DEPLOY_TIMEOUT:0:20}' is not a duration such as 10m"
interval="$(dur_secs "${DEPLOY_INTERVAL:-10s}")" || bad "interval '${DEPLOY_INTERVAL:0:20}' is not a duration such as 10s"
((interval >= 1)) || bad "interval must be at least 1s"
need curl jq python3
# Both addresses checked before the first poll, so a typo fails at once rather than after the time limit.
version_url "$origin" >/dev/null || exit 2
[ -z "$frontend" ] || version_url "$frontend" /version.json >/dev/null || exit 2

targets=(app)
[ -z "$frontend" ] || targets+=(frontend)
declare -A streak=() state=() warned=()
body="$(mktemp)"
trap 'rm -f "$body"' EXIT

# fetch <url>: the HTTP code (000 when nothing answered), with the body in $body. No redirect is followed: a version
# path that redirects is not the app's answer.
fetch() {
  local code
  : >"$body"
  code="$(curl -sS --max-time 10 --max-filesize 65536 --proto '=https,http' -H 'Cache-Control: no-cache' \
    -o "$body" -w '%{http_code}' "$1" 2>/dev/null)" || true
  [[ "$code" =~ ^[0-9]{3}$ ]] || code=000
  printf '%s\n' "$code"
}

# poll <target>: one ask; a match adds one to the target's streak, anything else sets it back to 0. state holds what
# it saw, printed when it changes.
poll() {
  local target="$1" url code answer release="" commit="" seen
  if [ "$target" = app ]; then url="$(version_url "$origin")"; else url="$(version_url "$frontend" /version.json)"; fi
  code="$(fetch "$url")"
  if [ "$code" != 200 ]; then
    seen="HTTP $code"
  elif ! answer="$(version_parse <"$body")"; then
    seen="an answer that is not {\"release\", \"commit\"}"
  else
    release="$(sed -n 's/^release=//p' <<<"$answer")" commit="$(sed -n 's/^commit=//p' <<<"$answer")"
    seen="commit $commit ($release)"
    if [ "$commit" = "$want" ] && [ "$target" = app ] && [ -n "$health" ]; then
      code="$(fetch "$origin$health")"
      [ "$code" = 200 ] || seen="the release, but $health answered HTTP $code"
    fi
  fi
  if [ "$seen" != "${state[$target]:-}" ]; then
    echo "$target: $seen" >&2
    state[$target]="$seen"
  fi
  if [ "$seen" != "commit $want ($release)" ]; then
    streak[$target]=0
    return 0
  fi
  streak[$target]=$((${streak[$target]:-0} + 1))
  if [ -n "$tag" ] && [ "$release" != "$tag" ] && [ -z "${warned[$target]:-}" ]; then
    warned[$target]=1
    if [ "$release" = none ]; then
      echo "::warning::$target runs $tag's commit but names no release: its version file was not written from a tag (git describe --tags --exact-match)" >&2
    else
      echo "::warning::$target runs $tag's commit but names it $release: two tags point at it, or its version file is stale" >&2
    fi
  fi
}

echo "Waiting up to $(dur_text "$timeout") for ${tag:-the release}'s commit $want, $TIMES times in a row" >&2
start="$(mroom_now)" slept=0
while :; do
  done=1
  for target in "${targets[@]}"; do
    poll "$target"
    ((streak[$target] >= TIMES)) || done=0
  done
  elapsed=$(($(mroom_now) - start))
  ((elapsed >= slept)) || elapsed=$slept
  [ "$done" = 0 ] || break
  if ((elapsed + interval > timeout)); then
    echo "::error::production did not report ${tag:-the release}'s commit $want $TIMES times in a row within $(dur_text "$timeout")" >&2
    for target in "${targets[@]}"; do echo "  $target last answered: ${state[$target]}" >&2; done
    echo "The host's deploy may have failed or not started: check its deploy log. A rollback deploys the previous tag through the same workflow." >&2
    exit 1
  fi
  sleep "$interval"
  slept=$((slept + interval))
done

echo "Live: ${tag:-the release} ($want), confirmed $TIMES times in a row after $(dur_text "$elapsed")" >&2
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  # shellcheck disable=SC2016  # the backticks are Markdown
  printf '### Deploy verified\n\n%s (`%s`) is live on %s, confirmed %s times in a row after %s.\n' \
    "${tag:-The release}" "$want" "${targets[*]}" "$TIMES" "$(dur_text "$elapsed")" >>"$GITHUB_STEP_SUMMARY"
fi
echo "seconds=$elapsed"
