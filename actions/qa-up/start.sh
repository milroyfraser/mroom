#!/usr/bin/env bash
# start.sh — whether this push brings pull request N's QA environment up (actions/qa-up; design 8.2). It runs in
# the deploy job, after every older deploy of the pull request has ended (the job's concurrency group), so Forge's
# answer is current.
#
# The environment comes up, or is refreshed, when the path rules say a user could notice the change (scope maybe),
# when it already exists, so that it never serves an older commit than the head, when the label forces it on, or
# for a plan started by hand or by a wake. A draft comes up only when it already has an environment, when it is
# started by hand, or when the label forces it; its next plan, once it is ready for review, decides again. A pull
# request that is no longer open gets nothing, since this deploy may have waited behind its teardown. When the QA
# build failed, nothing can be deployed, and the comment says so.
#
# Environment: PR, SHA, SCOPE, REASON, FORCED, DRAFT, DISPATCHED and BUILT (true or false), and as down.sh's for
# Forge and the comment. Prints, for GITHUB_OUTPUT: start=true|false, exists=true|false, dist=true|false (whether
# the plan built a frontend to put) and why=<the reason>.
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
FORGE_NAME="mroom qa-up" QA_NAME="mroom qa-up"

qa_number "${PR:-}" || { qa_say "PR is not a pull request number"; exit 2; }
[[ "${SHA:-}" =~ ^[0-9a-f]{40}$ ]] || { qa_say "SHA is not a full commit"; exit 2; }
need curl jq python3
trap qa_cleanup EXIT
qa_names "$PR"

state="$(qa_env_state)"
exists=false
[ "$state" != present ] || exists=true
is_true() { [ "${!1:-}" = true ]; }

start=false
if is_true FORCED; then
  start=true why="the ${LABEL:-qa} label forces it on"
elif is_true DRAFT; then
  why="a draft, which gets an environment once it is ready for review"
  if [ "$exists" = true ]; then start=true why="a draft whose environment is refreshed, so it serves the head"
  elif is_true DISPATCHED; then start=true why="a draft started by hand"; fi
elif [ "$exists" = true ]; then
  start=true why="its environment is refreshed, so it serves the head"
elif is_true DISPATCHED; then
  start=true why="started by hand, or by a freed slot"
elif [ "${SCOPE:-maybe}" != none ]; then
  start=true why="a user could notice it: ${REASON:-the paths could not be sorted}"
else
  why="no user could notice it: ${REASON:-}"
fi

# A deploy that waited behind a teardown must not bring a closed pull request's environment back.
if [ "$start" = true ] && [ -n "${GH_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
  open="$(gh pr view "$PR" --repo "$GITHUB_REPOSITORY" --json state --jq '.state == "OPEN"')" \
    || { qa_say "could not read pull request $PR from GitHub"; exit 1; }
  if [ "$open" != true ]; then start=false why="the pull request is no longer open"; fi
fi
if [ "$start" = true ] && ! is_true BUILT; then
  start=false why="the QA build failed, so there is nothing to deploy"
  if [ -n "${GH_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
    qa_comment "$PR" failed "The QA build of \`$SHA\` failed, so nothing was deployed${RUN_URL:+ ([run]($RUN_URL))}. The next push tries again." \
      || echo "::warning::could not update the QA environment comment of pull request $PR"
  fi
fi

# What the plan built: a frontend of its own goes to the go site, and Vite's build inside the Laravel app goes into
# the code put.
dist=false
if [ -n "$(qa_config app.build.frontend "")" ] && [ -n "$QA_FRONTEND" ]; then dist=true; fi

printf 'start=%s\nexists=%s\ndist=%s\nwhy=%s\n' "$start" "$exists" "$dist" "$why"
