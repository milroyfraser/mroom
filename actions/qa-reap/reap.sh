#!/usr/bin/env bash
# reap.sh — tears down every QA environment older than qa.ttl_days (5), with or without the qa label
# (actions/qa-reap; design 8.2). Someone always forgets to close a pull request, and environments come up
# without the label too.
#
# An environment's age is its api site's, from Forge (lib/core/qa.sh); a list Forge cannot give fails the run
# instead of reaping nothing. A site Forge is already removing is skipped and never counted as a freed slot, so
# no waiting pull request is woken for it; but once it has been removing for half an hour it gets the delete
# again, with a warning: the same environment warned about two nights running needs a person in Forge. Each
# environment past its time comes down (actions/qa-down/down.sh), its pull request's comment says so, and each
# slot freed goes to a pull request that waits for one. One teardown that fails does not stop the others, but
# fails the run.
#
# Environment: as down.sh's. With MROOM_FORGE_SERVER unset, the qa environment is not set up yet, and there is
# nothing to reap. MROOM_QA_DOWN replaces down.sh in tests. Writes reaped=<n> to GITHUB_OUTPUT.
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
FORGE_NAME="mroom qa-reap" QA_NAME="mroom qa-reap"
DOWN="${MROOM_QA_DOWN:-$MROOM_ROOT/actions/qa-down/down.sh}"

if [ -z "${MROOM_FORGE_SERVER:-}" ]; then
  echo "the qa environment has no MROOM_FORGE_SERVER yet, so there is nothing to reap"
  exit 0
fi
need curl jq python3
trap qa_cleanup EXIT

ttl="$(qa_config qa.ttl_days 5)"
cutoff=$(($(mroom_now) - ttl * 86400))
envs="$(qa_envs)"
reaped=0 failed=()
while read -r n status created; do
  [ -n "$n" ] || continue
  qa_names "$n"
  if [ "$status" = removing ]; then
    echo "environment $n: Forge is already removing it; skipped"
    minutes="$(qa_redelete_stuck "$(forge_site "$QA_API")")" || minutes=""
    if [ -n "$minutes" ]; then
      echo "::warning::environment $n: $QA_API had been removing for $minutes minutes, so the delete went again. If it is in this warning again tomorrow, the delete did not work: look at the site in Forge"
    fi
    continue
  fi
  # One record that cannot be read must not stop the rest of the reaping.
  if ! age="$(date -u -d "$created" +%s 2>/dev/null)"; then
    echo "::warning::environment $n: Forge gave its api site no readable created_at"
    continue
  fi
  ((age < cutoff)) || continue
  echo "environment $n: up since $created, more than $ttl days; reaping it"
  # The teardown's own outputs are not this step's.
  if GITHUB_OUTPUT="" "$DOWN" "$n" --why "it was older than $ttl days. The next push that needs one brings it back"; then
    reaped=$((reaped + 1))
  else
    failed+=("$n")
  fi
done <<<"$envs"

if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "reaped=$reaped" >>"$GITHUB_OUTPUT"; fi
echo "reaped $reaped environment(s)"
if [ -n "${GH_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then qa_wake "$reaped"; fi
if [ "${#failed[@]}" -gt 0 ]; then
  qa_say "the teardown of environment(s) ${failed[*]} failed; the next reap tries again"
  exit 1
fi
