#!/usr/bin/env bash
# check.sh <N> [--reason closed|label] — does pull request N have a QA environment to tear down? The check job of
# .github/workflows/qa-down.yml, which reads and never changes the environment, so that "Re-run failed jobs" on the
# teardown job reruns the teardown alone, with this answer.
#
# Prints state=present|removing|absent for GITHUB_OUTPUT. Forge decides (lib/core/qa.sh); a read that fails is
# retried and then fails the job, so it never reads as "absent". When the label came off a pull request that has no
# environment, a comment that said it waits for a slot says it no longer does: a push that needs an environment
# brings that back. Environment: as down.sh's, without the SSH key. With MROOM_FORGE_SERVER unset, the qa
# environment is not set up yet, and the answer is absent.
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

usage() { echo "usage: check.sh <N> [--reason closed|label]" >&2; exit 2; }
n="${1:-}" reason=closed
[ "$#" = 0 ] || shift
case "${1:-}" in
  "") ;;
  --reason) [ "$#" = 2 ] || usage; reason="$2" ;;
  *) usage ;;
esac
qa_number "$n" || usage
case "$reason" in closed | label) ;; *) usage ;; esac
if [ -z "${MROOM_FORGE_SERVER:-}" ]; then
  echo "the qa environment has no MROOM_FORGE_SERVER yet, so there is nothing to tear down" >&2
  echo "state=absent"
  exit 0
fi
need curl jq python3
trap qa_cleanup EXIT

qa_names "$n"
state="$(qa_env_state)"
if [ "$state" = absent ] && [ "$reason" = label ] && [ -n "${GH_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
  # Best-effort: a comment that cannot be read leaves the answer as it is.
  was="$(qa_comment_newest "$n" | jq -r '.state // ""')" || was=""
  if [ "$was" = waiting ] || [ "$was" = woken ]; then
    qa_comment "$n" idle "No longer waiting for a QA environment: its ${LABEL:-qa} label came off. A push that needs one brings it back." \
      || echo "::warning::could not update the QA environment comment of pull request $n" >&2
  fi
fi
echo "state=$state"
