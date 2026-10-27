#!/usr/bin/env bash
# report.sh — writes pull request N's QA environment comment for a qa-up run, whatever happened in it: the last step
# of actions/qa-up, which runs always (design 8.2). What start.sh or up.sh left in MROOM_QA_STATUS says what to
# write. A step that failed or was cancelled before it could leave anything is said here: whether the environment
# was to come up could not be told, the plan's frontend build could not be had, or the deploy stopped partway. A run
# that had nothing to say, such as one for a change no user could notice, leaves the comment as it is.
#
# Environment: PR, SHA, START, DIST and UP (the outcomes of the action's steps: success, failure, cancelled or
# skipped), RUN_URL (this run), MROOM_QA_STATUS, GH_TOKEN and GITHUB_REPOSITORY. Never fails the job: a comment
# that cannot be written is a warning.
set -uo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
MROOM_ROOT="$(cd "$(dirname "$SELF")/../.." && pwd)"
export MROOM_ROOT
# shellcheck source=lib/core/util.sh
. "$MROOM_ROOT/lib/core/util.sh"
# shellcheck source=lib/core/forge.sh
. "$MROOM_ROOT/lib/core/forge.sh"
# shellcheck source=lib/core/qa.sh
. "$MROOM_ROOT/lib/core/qa.sh"
QA_NAME="mroom qa-up"

qa_number "${PR:-}" || exit 0
[[ "${SHA:-}" =~ ^[0-9a-f]{40}$ ]] || SHA="its head"
state="" text=""
if [ -n "${MROOM_QA_STATUS:-}" ] && [ -s "$MROOM_QA_STATUS" ]; then
  state="$(head -n1 "$MROOM_QA_STATUS")"
  text="$(tail -n +2 "$MROOM_QA_STATUS")"
fi
run="${RUN_URL:+ ([run]($RUN_URL))}"
commit="\`$SHA\`"
[ "$SHA" != "its head" ] || commit="its head"
if [ "${START:-}" = failure ] || [ "${START:-}" = cancelled ]; then
  state=failed text="Whether to bring the QA environment up for $commit could not be told: GitHub or Forge did not answer$run. The next push tries again."
elif [ "${DIST:-}" = failure ] || [ "${DIST:-}" = cancelled ]; then
  state=failed text="The QA plan's frontend build could not be had, so $commit was not deployed$run. The next push tries again."
elif [ "${UP:-}" = cancelled ]; then
  state=failed text="The deploy of $commit was cancelled, or ran out of time, partway$run. The next push finishes it; a half-built environment goes when the pull request closes."
elif [ "${UP:-}" = failure ] && [ "$state" != failed ]; then
  state=failed text="The deploy of $commit stopped before it could say why$run. The next push tries again."
fi
[ -n "$state" ] || exit 0
[[ "$state" =~ ^[a-z]+$ ]] || { echo "::warning::the QA environment comment's state is not a word"; exit 0; }
if [ -z "${GH_TOKEN:-}" ] || [ -z "${GITHUB_REPOSITORY:-}" ]; then exit 0; fi
qa_comment "$PR" "$state" "$text" </dev/null || echo "::warning::could not update the QA environment comment of pull request $PR"
exit 0
