#!/usr/bin/env bash
# start.sh — whether this run brings pull request N's QA environment up (actions/qa-up; design 8.2). It runs in the
# deploy job, after every older deploy and teardown of the pull request has ended (the job's concurrency group), so
# what it reads is current: GitHub first, then Forge.
#
# Nothing comes up for a pull request that is no longer open, since this deploy may have waited behind its teardown,
# or whose head is no longer SHA: the newer push's own run deploys that, and an older one must never replace it.
# Otherwise the environment comes up, or is refreshed, when the label forces it on, when it already exists, so that
# it never serves an older commit than the head, when a person started the plan by hand, or when the path rules say
# a user could notice the change (scope maybe). A plan a freed slot started (woken) decides as a push does, so a
# pull request whose label came off, or whose change no longer reaches users, gets no environment. A draft comes up
# only when it already has one, when it is started by hand, or when the label forces it; its next plan, once it is
# ready for review, decides again. And it does not come up, with a comment that says why, when the QA build failed,
# when mroom.toml asks for what qa-up cannot do yet (qa.parity.broadcast = "same"), or when the pull request's
# mroom.toml puts the frontend elsewhere than the default branch's, which qa-up deploys by. A comment that said the
# pull request waits for a slot says it no longer does, when the environment is not coming up for want of a change
# users could notice.
#
# Environment: PR, SHA, SCOPE, REASON, DISPATCHED, WOKEN and BUILT (true or false), PLAN_RUN_URL, LABEL (qa),
# MROOM_QA_STATUS (where the comment's state and text go, for report.sh), and as down.sh's for Forge and GitHub.
# Prints, for GITHUB_OUTPUT: start=true|false, exists=true|false, dist=true|false (whether the plan built a
# frontend to put) and why=<the reason>. Exits 1 when GitHub or Forge cannot be read.
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
[ -n "${GITHUB_REPOSITORY:-}" ] || { qa_say "GITHUB_REPOSITORY is not set"; exit 2; }
need curl jq python3 gh
if [ -n "${MROOM_QA_STATUS:-}" ]; then : >"$MROOM_QA_STATUS"; fi
trap qa_cleanup EXIT
qa_names "$PR"
is_true() { [ "${!1:-}" = true ]; }
label="${LABEL:-qa}"
out() { printf 'start=%s\nexists=%s\ndist=%s\nwhy=%s\n' "$start" "$exists" "$dist" "$why"; exit 0; }
start=false exists=false dist=false why=""

# GitHub first: what the pull request is now, with its label and draft state as they are, not as they were when
# the plan ran.
info="$(gh pr view "$PR" --repo "$GITHUB_REPOSITORY" --json state,headRefOid,isDraft,labels </dev/null)" \
  || { qa_say "could not read pull request $PR from GitHub"; exit 1; }
head="$(jq -r '.headRefOid // ""' <<<"$info")"
if [ "$(jq -r .state <<<"$info")" != OPEN ]; then why="the pull request is no longer open"; out; fi
if [ "$head" != "$SHA" ]; then why="the pull request has moved on from ${SHA:0:9} to ${head:0:9}; that push's own run deploys it"; out; fi
forced=false draft=false
if jq -e --arg l "$label" '[.labels[].name] | index($l) != null' <<<"$info" >/dev/null; then forced=true; fi
if jq -e '.isDraft' <<<"$info" >/dev/null; then draft=true; fi

state="$(qa_env_state)" || exit 1
[ "$state" != present ] || exists=true

if [ "$forced" = true ]; then
  start=true why="the $label label forces it on"
elif [ "$draft" = true ]; then
  why="a draft, which gets an environment once it is ready for review"
  if [ "$exists" = true ]; then start=true why="a draft whose environment is refreshed, so it serves the head"
  elif is_true DISPATCHED && ! is_true WOKEN; then start=true why="a draft started by hand"; fi
elif [ "$exists" = true ]; then
  start=true why="its environment is refreshed, so it serves the head"
elif is_true DISPATCHED && ! is_true WOKEN; then
  start=true why="started by hand"
elif [ "${SCOPE:-maybe}" != none ]; then
  start=true why="a user could notice it: ${REASON:-the paths could not be sorted}"
else
  why="no user could notice it: ${REASON:-}"
  # A pull request that waited for a slot no longer needs one.
  was="$(qa_comment_newest "$PR" </dev/null | jq -r '.state // ""')" || was=""
  if [ "$was" = waiting ] || [ "$was" = woken ]; then
    qa_status idle "No longer waiting for a QA environment: no user could notice this change (${REASON:-its paths}). A push that needs one, or the $label label, brings it back."
  fi
fi
[ "$start" = true ] || out

if ! is_true BUILT; then
  start=false why="the QA build failed, so there is nothing to deploy"
  qa_status failed "The QA build of \`$SHA\` failed, so nothing was deployed${PLAN_RUN_URL:+ ([run]($PLAN_RUN_URL))}. The next push tries again."
  out
fi

# What qa-up cannot do yet: it says so, and the job stays green, since nothing is wrong with the pull request.
broadcast="$(qa_config qa.parity.broadcast same)" || exit 1
if [ "$broadcast" = same ]; then
  start=false why="qa.parity.broadcast is \"same\", which qa-up does not wire in yet"
  qa_status skipped "No QA environment yet: this app's mroom.toml sets qa.parity.broadcast = \"same\", which needs mroom's Reverb host. The host exists, but qa-up does not wire environments into it yet. Until it does, set qa.parity.broadcast = \"log\" on the default branch to get QA environments."
  out
fi

# What the plan built follows the pull request's mroom.toml, and qa-up deploys it by the default branch's: when the
# two put the frontend in different places, the build cannot go where qa-up would put it.
where() {
  local backend frontend dist_dir command
  backend="$(qa_config app.backend_dir .)" && frontend="$(qa_config app.frontend_dir .)" || return 1
  # Where the build writes, with build.sh's default for each layout.
  dist_dir="$(qa_config app.build.frontend_dist "$([ "$frontend" = . ] && echo public/build || echo dist)")" \
    && command="$(qa_config app.build.frontend "")" || return 1
  printf '%s|%s|%s|%s' "$backend" "$frontend" "$dist_dir" "${command:+built}"
}
ours="$(where)" || exit 1
theirs_file="$(qa_temp)/mroom.toml"
if ! gh api "repos/$GITHUB_REPOSITORY/contents/mroom.toml?ref=$SHA" -H "Accept: application/vnd.github.raw+json" \
  >"$theirs_file" </dev/null; then
  qa_say "could not read the pull request's mroom.toml from GitHub"
  rm -rf "$(dirname "$theirs_file")"
  exit 1
fi
theirs="$(MROOM_CONFIG="$theirs_file" where 2>/dev/null)" || theirs="unreadable"
rm -rf "$(dirname "$theirs_file")"
if [ "$theirs" != "$ours" ]; then
  start=false why="the pull request's mroom.toml puts the frontend elsewhere than the default branch's"
  qa_status skipped "No QA environment for \`$SHA\`: this pull request changes where mroom.toml says the frontend is built (app.backend_dir, app.frontend_dir, app.build.frontend or app.build.frontend_dist), and qa-up deploys a build by the default branch's mroom.toml. It gets an environment once the change is on the default branch."
  out
fi

# What the plan built: a frontend of its own goes to the go site, and Vite's build inside the Laravel app goes into
# the code put.
if [ -n "$(qa_config app.build.frontend "")" ] && [ -n "$QA_FRONTEND" ]; then dist=true; fi
out
