#!/usr/bin/env bash
# reap.sh — starts a teardown for every QA environment older than qa.ttl_days (5), with or without the qa label
# (actions/qa-reap; design 8.2). Someone always forgets to close a pull request, and environments come up without
# the label too.
#
# An environment's age is its oldest site's, api or go, from Forge (lib/core/qa.sh); a list Forge cannot give fails
# the run instead of reaping nothing, and an environment whose created_at Forge does not give counts as past its
# time, with a warning. Each one past its time gets its own teardown: the app's qa-down workflow
# (MROOM_QA_DOWN_WORKFLOW, qa-down.yml), started on the default branch with the reason ttl, which takes the pull
# request's concurrency group, wakes a waiting pull request when it frees a slot, and can be re-run on its own when a
# step fails. An environment Forge is already removing is skipped; a site of it removing for half an hour gets the
# delete again, with a warning: the same environment warned about two nights running needs a person in Forge.
#
# Environment: MROOM_CONFIG, MROOM_FORGE_ORG, MROOM_FORGE_SERVER, MROOM_FORGE_TOKEN, GH_TOKEN, GITHUB_REPOSITORY and
# MROOM_QA_DEFAULT_BRANCH. With MROOM_FORGE_SERVER unset, the qa environment is not set up yet, and there is nothing
# to reap. Writes started=<n> to GITHUB_OUTPUT.
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
workflow="${MROOM_QA_DOWN_WORKFLOW:-qa-down.yml}"

if [ -z "${MROOM_FORGE_SERVER:-}" ]; then
  echo "the qa environment has no MROOM_FORGE_SERVER yet, so there is nothing to reap"
  exit 0
fi
[[ "$workflow" =~ ^[A-Za-z0-9._-]+\.ya?ml$ ]] || { qa_say "MROOM_QA_DOWN_WORKFLOW is not a workflow file name"; exit 2; }
need curl jq python3 gh
trap qa_cleanup EXIT

ttl="$(qa_config qa.ttl_days 5)" || exit 1
cutoff=$(($(mroom_now) - ttl * 86400))
envs="$(qa_envs)"
started=0 failed=()
while read -r n state created; do
  [ -n "$n" ] || continue
  qa_names "$n"
  if [ "$state" = removing ]; then
    echo "environment $n: Forge is already removing it; skipped"
    for domain in "$QA_API" "$QA_WEB"; do
      site="$(forge_site "$domain" </dev/null)"
      minutes="$(qa_redelete_stuck "${site:-null}" </dev/null)" || minutes=""
      if [ -n "$minutes" ]; then
        echo "::warning::environment $n: $domain had been removing for $minutes minutes, so the delete went again. If it is in this warning again tomorrow, the delete did not work: look at the site in Forge"
      fi
    done
    continue
  fi
  if ! age="$(date -u -d "${created/#-/none}" +%s 2>/dev/null)"; then
    echo "::warning::environment $n: Forge gives no readable created_at for its sites, so it counts as past its time"
    age=0
  fi
  ((age < cutoff)) || continue
  echo "environment $n: up since ${created/#-/an unknown time}, more than $ttl days; starting its teardown"
  if gh workflow run "$workflow" --repo "$GITHUB_REPOSITORY" ${MROOM_QA_DEFAULT_BRANCH:+--ref "$MROOM_QA_DEFAULT_BRANCH"} \
    -f pr_number="$n" -f reason=ttl </dev/null; then
    started=$((started + 1))
  else
    failed+=("$n")
  fi
done <<<"$envs"

if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "started=$started" >>"$GITHUB_OUTPUT"; fi
echo "started the teardown of $started environment(s)"
if [ "${#failed[@]}" -gt 0 ]; then
  qa_say "could not start the teardown of environment(s) ${failed[*]}; the next reap tries again"
  exit 1
fi
