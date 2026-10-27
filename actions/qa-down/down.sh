#!/usr/bin/env bash
# down.sh <N> [--why <text>] [--always] [--wake] — tears down QA environment N, the one of pull request N
# (actions/qa-down; design 8.2, 8.9).
#
# Forge says whether there is anything to tear down (lib/core/qa.sh). With no site of the environment, nothing is
# done or said, unless --always (a teardown asked for by hand), which clears the box's side anyway. In order:
#   1. its daemons, since supervisor starts again what is stopped; it waits until Forge has them gone
#   2. user-clean, through the gate: the site user's processes, and its files outside its home, since the next
#      user can be given the same UID. When it fails, nothing more is removed, so the next teardown tries again
#   3. its sites, right after, so the PHP-FPM pool workers that start again end with them. A site Forge has
#      been removing for half an hour gets the delete again
#   4. its database and role, its Redis user and keys, its mail login and mail (qa.parity.mail is catcher) and
#      its buckets (qa.parity.files is same), through the gate; each is tried even when one before failed
# Each step skips what is already gone, so a teardown of a half-built or half-removed environment finishes it.
# Then, given GH_TOKEN, the pull request's QA environment comment says it was removed and why, and with --wake the
# slot it freed goes to the pull request that has waited longest.
#
# Environment: MROOM_CONFIG (the app's mroom.toml, from its default branch), MROOM_FORGE_ORG, MROOM_FORGE_SERVER,
# MROOM_FORGE_TOKEN, MROOM_QA_SSH_HOST, MROOM_QA_SSH_USER (forge), MROOM_QA_SSH_KEY and MROOM_QA_SSH_KNOWN_HOSTS;
# for the comment and the wake, GH_TOKEN, GITHUB_REPOSITORY, MROOM_QA_PLAN_WORKFLOW and MROOM_QA_DEFAULT_BRANCH.
# Writes freed=true|false to GITHUB_OUTPUT: true when the environment held a slot.
#
# Exit codes: 0 done, 1 a step failed, 2 a usage error.
set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
MROOM_ROOT="$(cd "$(dirname "$SELF")/../.." && pwd)"
export MROOM_ROOT
# shellcheck source=lib/core/util.sh
. "$MROOM_ROOT/lib/core/util.sh"
# shellcheck source=lib/core/forge.sh
. "$MROOM_ROOT/lib/core/forge.sh"
# shellcheck source=lib/core/qa.sh
. "$MROOM_ROOT/lib/core/qa.sh"
FORGE_NAME="mroom qa-down" QA_NAME="mroom qa-down"

usage() { echo "usage: down.sh <N> [--why <text>] [--always] [--wake]" >&2; exit 2; }
n="${1:-}"
[ "$#" = 0 ] || shift
why="" always=0 wake=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --why) [ "$#" -ge 2 ] || usage; why="$2"; shift 2 ;;
    --always) always=1; shift ;;
    --wake) wake=1; shift ;;
    *) usage ;;
  esac
done
qa_number "$n" || usage
need curl jq python3 ssh

output() { if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "$1" >>"$GITHUB_OUTPUT"; fi; }

trap qa_cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
qa_names "$n"
qa_gate_init

state="$(qa_env_state)"
case "$state" in
  present) output freed=true; echo "environment $n: Forge has its sites, so it comes down" ;;
  removing) output freed=false; echo "environment $n: Forge is removing its sites; finishing the rest" ;;
  *)
    output freed=false
    if [ "$always" = 0 ]; then echo "environment $n: Forge has no site of it, so there is nothing to tear down"; exit 0; fi
    echo "environment $n: Forge has no site of it; clearing the box's side anyway, as asked"
    ;;
esac

# Daemons are the server's, not the site's: deleting the site would leave one running, and supervisor would
# start again what user-clean stops.
echo "==> Daemons"
waited=0 limit="${MROOM_QA_DAEMON_WAIT:-120}" pause="${MROOM_QA_POLL:-5}"
[[ "$limit" =~ ^[0-9]{1,4}$ ]] || limit=120
[[ "$pause" =~ ^[1-9][0-9]?$ ]] || pause=5
while :; do
  daemons="$(qa_processes)"
  [ -n "$daemons" ] || break
  while read -r id status _; do
    [ "$status" != removing ] || continue
    forge DELETE "/background-processes/$id" >/dev/null
    echo "    deleted daemon $id"
  done <<<"$daemons"
  if ((waited >= limit)); then
    qa_say "Forge still lists daemons $(awk '{ printf "%s%s", sep, $1; sep = ", " }' <<<"$daemons") ${waited}s after deleting them; the sites stay until the next teardown"
    exit 1
  fi
  sleep "$pause"
  waited=$((waited + pause))
done

echo "==> The site user's processes and files"
if ! out="$(qa_gate user-clean "$n")"; then
  qa_say "user-clean failed, so the sites stay until the next teardown tries again"
  exit 1
fi
qa_show "$out"

for domain in "$QA_API" "$QA_WEB"; do
  echo "==> Site $domain"
  site="$(forge_site "$domain")"
  status="$(jq -r '.attributes.status // ""' <<<"${site:-null}")"
  id="$(jq -r '.id // ""' <<<"${site:-null}")"
  if [ -z "$site" ]; then
    echo "    not there"
  elif [ "$status" = removing ]; then
    minutes="$(qa_redelete_stuck "$site")"
    if [ -n "$minutes" ]; then echo "    had been removing for $minutes minutes; sent the delete again"
    else echo "    Forge is removing it"; fi
  else
    [[ "$id" =~ ^[0-9]+$ ]] || { qa_say "Forge gave $domain no id"; exit 1; }
    forge DELETE "/sites/$id" >/dev/null
    echo "    deleted site $id"
  fi
done

# The box's side: each step is tried, and the run fails at the end if any did.
failed=()
step() {
  local what="$1" out
  shift
  echo "==> $what"
  if out="$(qa_gate "$@")"; then qa_show "$out"; else failed+=("$what"); fi
}
step "Database and role" db-drop "$n"
step "Redis user" redis-user-remove "$n"
step "Redis keys" redis-clear "$n"
if [ "$(qa_config qa.parity.mail catcher)" = catcher ]; then
  step "Mail login" mail-user-remove "$n"
  step "Mail" mail-clear "$n"
fi
if [ "$(qa_config qa.parity.files same)" = same ]; then
  step "Buckets" bucket-drop "$n"
fi
if [ "${#failed[@]}" -gt 0 ]; then
  qa_say "environment $n is down, but these are left: ${failed[*]}; a teardown run again finishes them"
  exit 1
fi

if [ -n "${GH_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
  qa_comment "$n" removed "Removed${why:+: $why}." || echo "::warning::could not update the QA environment comment of pull request $n"
  if [ "$wake" = 1 ] && [ "$state" = present ]; then qa_wake 1; fi
fi
echo "environment $n: removed"
