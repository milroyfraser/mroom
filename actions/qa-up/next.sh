#!/usr/bin/env bash
# next.sh <PR> "<workflow file> ..." — starts the app's workflows that follow qa-up (.github/workflows/qa-up.yml,
# next job; design 8.2), for a qa-up run the job token started: such a run ends with no workflow_run, so a workflow
# of the app's that waits for one would never start. Each is dispatched on the default branch with the inputs pr and
# up_run_id (this run), once the deploy ran, whatever it came to: the follower reads how it went from GitHub's record
# of that run, as qa-up reads its plan's.
#
# The names come as one argument, next-workflows as it is, split on blanks here and never globbed. A name that is
# not a workflow file's, such as one that starts with -, which gh would read as an option, is refused.
# Environment: GH_TOKEN (actions: write), GITHUB_REPOSITORY, GITHUB_RUN_ID and MROOM_QA_DEFAULT_BRANCH. Exits 1 when
# any could not be started, after trying each.
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
QA_NAME="mroom qa-up"

if [ "$#" -ne 2 ] || ! qa_number "$1"; then
  qa_say "usage: next.sh <PR> \"<workflow file> ...\""
  exit 2
fi
pr="$1"
read -r -a workflows <<<"$2"
[[ "${GITHUB_RUN_ID:-}" =~ ^[1-9][0-9]{0,19}$ ]] || { qa_say "GITHUB_RUN_ID is not a run's id"; exit 2; }
[ -n "${GITHUB_REPOSITORY:-}" ] || { qa_say "GITHUB_REPOSITORY is not set"; exit 2; }
failed=0
for workflow in "${workflows[@]}"; do
  if ! [[ "$workflow" =~ $QA_WORKFLOW_RE ]]; then
    echo "::error::next-workflows holds a name that is not a workflow file's"
    failed=1
    continue
  fi
  if gh workflow run "$workflow" --repo "$GITHUB_REPOSITORY" ${MROOM_QA_DEFAULT_BRANCH:+--ref "$MROOM_QA_DEFAULT_BRANCH"} \
    -f pr="$pr" -f up_run_id="$GITHUB_RUN_ID" </dev/null; then
    echo "started $workflow for pull request $pr"
  else
    echo "::error::could not start $workflow for pull request $pr"
    failed=1
  fi
done
exit "$failed"
