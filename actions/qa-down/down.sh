#!/usr/bin/env bash
# down.sh <N> [--reason closed|label|hand|ttl] [--state present|removing|absent] — tears down QA environment N, the
# one of pull request N (actions/qa-down; design 8.2, 8.9).
#
# Every step runs, each skipping what is already gone, and none stops the teardown early because Forge has no site:
# so running it again, with GitHub's "Re-run failed jobs", finishes a teardown that stopped halfway. In order:
#   1. the pull request's comment says the environment is being removed, and why
#   2. its daemons, since supervisor starts again what is stopped; it waits until Forge has them gone
#   3. user-clean, through the gate: the site user's processes, and its files outside its home, since the next user
#      can be given the same UID. When it fails, nothing more is removed, so a run again cleans the user first
#   4. its sites, right after, so the PHP-FPM pool workers that start again end with them. A site Forge has been
#      removing for half an hour gets the delete again
#   5. its database and role, its Redis user and keys, its mail login and mail (qa.parity.mail is catcher) and its
#      buckets (qa.parity.files is same), through the gate; each is tried even when one before failed
# Then the comment says it was removed, or names the step that failed and says to re-run the failed job. --state is
# what qa-down's check job read; without it, Forge is read here. The comment's hidden line keeps the state the
# teardown started from (removing was=present, failed was=present), so a run again finds it when Forge has no site
# left: here, for a teardown started by hand or by the reaper, and in check.sh. Only an environment that was present
# held a slot: freed=true goes to GITHUB_OUTPUT once its sites are gone, before the box's side, which may fail without
# keeping the slot, and qa-down's wake job gives the slot to the pull request that has waited longest.
#
# Environment: MROOM_CONFIG (the app's mroom.toml, from its default branch), MROOM_FORGE_ORG, MROOM_FORGE_SERVER,
# MROOM_FORGE_TOKEN, MROOM_QA_SSH_HOST, MROOM_QA_SSH_USER (forge), MROOM_QA_SSH_KEY and MROOM_QA_SSH_KNOWN_HOSTS;
# for the comment, GH_TOKEN, GITHUB_REPOSITORY, RUN_URL and LABEL (qa). With MROOM_FORGE_SERVER unset, the qa
# environment is not set up yet, and there is nothing to tear down: it says so as a warning.
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

usage() { echo "usage: down.sh <N> [--reason closed|label|hand|ttl] [--state present|removing|absent]" >&2; exit 2; }
n="${1:-}"
[ "$#" = 0 ] || shift
reason=hand state=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --reason) [ "$#" -ge 2 ] || usage; reason="$2"; shift 2 ;;
    --state) [ "$#" -ge 2 ] || usage; state="$2"; shift 2 ;;
    *) usage ;;
  esac
done
qa_number "$n" || usage
case "$reason" in closed | label | hand | ttl) ;; *) usage ;; esac
case "$state" in "" | present | removing | absent) ;; *) usage ;; esac
if [ -z "${MROOM_FORGE_SERVER:-}" ]; then
  echo "::warning::the qa environment has no MROOM_FORGE_SERVER yet, so there is nothing to tear down"
  exit 0
fi
need curl jq python3 ssh

can_comment() { [ -n "${GH_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; }
# comment <state> <text> [<field>...]: the pull request's QA environment comment, best-effort.
comment() { if can_comment; then qa_comment "$n" "$@" </dev/null || echo "::warning::could not update the QA environment comment of pull request $n"; fi; }
STEP="the start" DONE="" was=""
on_exit() {
  if [ "$1" != 0 ] && [ -z "$DONE" ]; then
    comment failed "The teardown stopped at $STEP, so part of the environment is left. Re-run the failed job${RUN_URL:+ ([run]($RUN_URL))} to finish it: each step skips what is already gone." ${was:+"was=$was"}
  fi
  qa_cleanup
}
trap 'on_exit $?' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
qa_names "$n"
mail="$(qa_config qa.parity.mail catcher)" || exit 1
files="$(qa_config qa.parity.files same)" || exit 1
ttl="$(qa_config qa.ttl_days 5)" || exit 1
# A push brings an environment back only to a pull request that is still open.
open=""
if [ "$reason" = label ] || [ "$reason" = ttl ]; then
  if can_comment && [ "$(gh pr view "$n" --repo "$GITHUB_REPOSITORY" --json state --jq .state </dev/null 2>/dev/null)" = OPEN ]; then
    open="; the next push that needs one brings it back"
  fi
fi
case "$reason" in
  closed) why="the pull request closed" ;;
  label) why="its ${LABEL:-qa} label came off$open" ;;
  ttl) why="it was older than $ttl days$open" ;;
  *) why="torn down by hand" ;;
esac
qa_gate_init
if [ -z "$state" ]; then
  state="$(qa_env_state)"
  # Forge has no site left, but a teardown of it stopped partway: what that one started from counts, so a run again
  # frees the slot it held.
  if [ "$state" = absent ] && can_comment; then
    last="$(qa_comment_newest "$n" </dev/null)" || last=""
    case "$(jq -r '"\(.state // "") \(.was // "")"' <<<"${last:-null}")" in
      "removing present" | "failed present") state=present ;;
      "removing removing" | "failed removing") state=removing ;;
    esac
  fi
fi
was="$state"
echo "environment $n: $state when this teardown started; tearing down whatever of it is left"
comment removing "Being removed: $why." "was=$was"

# Daemons are the server's, not the site's: deleting the site would leave one running, and supervisor would
# start again what user-clean stops.
STEP="its daemons"
echo "==> Daemons"
waited=0 limit="${MROOM_QA_DAEMON_WAIT:-120}" pause="${MROOM_QA_POLL:-5}"
[[ "$limit" =~ ^[0-9]{1,4}$ ]] || limit=120
[[ "$pause" =~ ^[1-9][0-9]?$ ]] || pause=5
while :; do
  daemons="$(qa_processes)"
  [ -n "$daemons" ] || break
  while read -r id status _; do
    [ "$status" != removing ] || continue
    qa_delete "/background-processes/$id"
    echo "    deleted daemon $id"
  done <<<"$daemons"
  if ((waited >= limit)); then
    qa_say "Forge still lists daemons $(awk '{ printf "%s%s", sep, $1; sep = ", " }' <<<"$daemons") ${waited}s after deleting them, so the sites stay"
    exit 1
  fi
  sleep "$pause"
  waited=$((waited + pause))
done

STEP="user-clean"
echo "==> The site user's processes and files"
if ! out="$(qa_gate user-clean "$n")"; then
  qa_say "user-clean failed, so the sites stay"
  exit 1
fi
qa_show "$out"

STEP="its sites"
# By the names of now and of before mroom 0.5.0, so an environment brought up then goes too; an old name is said
# only when Forge has a site by it.
for domain in "$QA_API" "$QA_WEB" "$QA_OLD_API" "$QA_OLD_WEB"; do
  site="$(forge_site "$domain")"
  case "$domain" in "$QA_OLD_API" | "$QA_OLD_WEB") [ -n "$site" ] || continue ;; esac
  echo "==> Site $domain"
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
    qa_delete "/sites/$id"
    echo "    deleted site $id"
  fi
done
# With its sites gone the environment no longer counts against qa.max_envs, so its slot is free now, whatever the
# box's side comes to below: only an environment that was present held one, and qa-down's wake job gives it to the
# pull request that waited longest. A run again of a teardown that stopped on the box's side wakes another, which
# finds no slot and waits again.
freed=false
[ "$state" != present ] || freed=true
if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "freed=$freed" >>"$GITHUB_OUTPUT"; fi

# The box's side: each step is tried, and the run fails at the end if any did.
failed=()
step() {
  local what="$1" out
  shift
  echo "==> $what"
  if out="$(qa_gate "$@")"; then qa_show "$out"; else failed+=("$what"); fi
}
step "database and role" db-drop "$n"
step "Redis user" redis-user-remove "$n"
step "Redis keys" redis-clear "$n"
if [ "$mail" = catcher ]; then
  step "mail login" mail-user-remove "$n"
  step "mail" mail-clear "$n"
fi
if [ "$files" = same ]; then
  step "buckets" bucket-drop "$n"
fi
if [ "${#failed[@]}" -gt 0 ]; then
  STEP="$(printf '%s, ' "${failed[@]}")"
  STEP="the box's ${STEP%, }"
  qa_say "environment $n: its sites are gone, but not $STEP"
  exit 1
fi

DONE=1
comment removed "Removed: $why."
echo "environment $n: removed"
