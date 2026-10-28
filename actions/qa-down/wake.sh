#!/usr/bin/env bash
# wake.sh — gives the slot a teardown freed to the pull request that has waited longest (lib/core/qa.sh, qa_wake):
# the wake job of .github/workflows/qa-down.yml, which runs after a teardown that freed one, and one at a time for the
# whole repository (its concurrency group), so two wakes never read the comments at once and wake the same pull
# request. Needs no secret: only GitHub.
#
# Environment: GH_TOKEN (pull-requests: write, actions: write), GITHUB_REPOSITORY, MROOM_QA_PLAN_WORKFLOW
# (qa-plan.yml) and MROOM_QA_DEFAULT_BRANCH. Best-effort: a wake that fails only warns, and the next one tries again.
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
QA_NAME="mroom qa-down"

if [ -z "${GH_TOKEN:-}" ] || [ -z "${GITHUB_REPOSITORY:-}" ]; then
  qa_say "GH_TOKEN and GITHUB_REPOSITORY are needed to wake a pull request"
  exit 2
fi
need jq gh
qa_wake 1
