#!/usr/bin/env bash
# check.sh <N> [--reason closed|label] — does pull request N have a QA environment to tear down? The check job of
# .github/workflows/qa-down.yml, which reads and never changes the environment, so that "Re-run failed jobs" on the
# teardown job reruns the teardown alone, with this answer.
#
# Prints state=present|removing|absent for GITHUB_OUTPUT. Forge decides (lib/core/qa.sh); a read that fails is
# retried and then fails the job, so it never reads as "absent". When Forge has no site left but the pull request's
# comment says a teardown stopped partway (removing or failed, with the state it started from), that state is the
# answer, so "Re-run all jobs" finishes the teardown's box side, and frees its slot. When the label came off a pull
# request that has no environment, a comment that said it waits for a slot says it no longer does: a push that needs
# an environment brings that back. Environment: as down.sh's, without the SSH key. With MROOM_FORGE_SERVER unset,
# the qa environment is not set up yet: the answer is absent, with a warning.
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
  echo "::warning::the qa environment has no MROOM_FORGE_SERVER yet, so there is nothing to tear down" >&2
  echo "state=absent"
  exit 0
fi
need curl jq python3
trap qa_cleanup EXIT

qa_names "$n"
state="$(qa_env_state)"
if [ "$state" = absent ] && [ -n "${GH_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
  # Best-effort: a comment that cannot be read leaves the answer as it is.
  last="$(qa_comment_newest "$n" </dev/null)" || last=""
  case "$(jq -r '"\(.state // "") \(.was // "")"' <<<"${last:-null}")" in
    "removing present" | "failed present" | "removing removing" | "failed removing")
      state="$(jq -r .was <<<"$last")"
      echo "::notice::Forge has no site of environment $n, but its last teardown stopped partway, from $state: it runs again" >&2 ;;
    "waiting "* | "woken "*)
      if [ "$reason" = label ]; then
        qa_comment "$n" idle "No longer waiting for a QA environment: its ${LABEL:-qa} label came off. A push that needs one brings it back." </dev/null \
          || echo "::warning::could not update the QA environment comment of pull request $n" >&2
      fi ;;
  esac
fi
echo "state=$state"
