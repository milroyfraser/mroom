#!/usr/bin/env bash
# check.sh <event.json> — the regression label check (actions/regression-label). A pull request that fixes a
# production problem carries the `regression` label and names, in its body, the release that caused it:
#
#   Breaks: v1.2.3
#   Reported: 2026-10-20T09:15Z      optional: when the problem was first reported (a date, or a UTC time);
#                                    without it, the measure uses the time the PR was opened
#
# A line inside an HTML comment or a fenced code block does not count, so a PR template can show these
# lines as an example. body.jq reads the body, for this check and for tools/regressions.sh alike.
#
# The check fails when the label and the Breaks line do not come together, when the release does not exist,
# or when the Reported time is malformed, earlier than the release, or in the future. Together they record
# two measures of the design (section 1.2): production problems per release, and the time from a release
# to the first report of a problem (tools/regressions.sh counts both).
#
# It reads the PR from the event file, never from a command line, and prints only values it has checked,
# so text in a PR body can neither run nor send a workflow command. Env: REPO (owner/repo) and GH_TOKEN for
# the release lookup through gh; REGRESSION_LABEL (default regression); MROOM_NOW (epoch seconds) in tests.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVENT="${1:?usage: check.sh <event.json>}"
LABEL="${REGRESSION_LABEL:-regression}"
REPO="${REPO:?REPO (owner/repo) is not set}"
TAG_RE='^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'

fail() { echo "::error title=regression label::$1"; exit 1; }

# field <Name>: the rest of the PR body's first "Name: ..." line that a reader sees (body.jq), or nothing.
field() { jq -r -L "$HERE" --arg name "$1" 'include "body"; .pull_request.body | field($name)' "$EVENT"; }

# epoch_of <date or UTC time>: seconds since 1970, or a failure for anything else. jq does the arithmetic,
# so the check needs no GNU date.
epoch_of() {
  jq -nr --arg t "$1" '
    $t | if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") then . + "T00:00:00Z"
         elif test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}Z$") then sub("Z$"; ":00Z")
         elif test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") then .
         else error("not a date") end
    | fromdateiso8601' 2>/dev/null
}

labeled="$(jq -r --arg l "$LABEL" '[.pull_request.labels[]?.name] | index($l) != null' "$EVENT")"
breaks="$(field Breaks)"
reported="$(field Reported)"

if [ "$labeled" != true ] && [ -z "$breaks" ]; then
  echo "not marked as a regression fix: nothing to check"
  exit 0
fi
if [ -z "$breaks" ]; then
  fail "This PR has the $LABEL label but names no release. Add a line 'Breaks: v1.2.3' with the release that shipped the problem."
fi
if ! [[ "$breaks" =~ $TAG_RE ]]; then
  fail "The Breaks line must name one release tag, such as 'Breaks: v1.2.3'."
fi
if [ "$labeled" != true ]; then
  fail "This PR names the release it fixes ($breaks) but has no $LABEL label. Add the label; create it once with: gh label create $LABEL --color B60205 --description 'Fixes a production problem a release caused'"
fi

# gh's warnings go to their own file, so they can never be read as the release's date.
errors="$(mktemp)"
trap 'rm -f "$errors"' EXIT
if ! published="$(gh api "repos/$REPO/releases/tags/$breaks" --jq '.published_at // empty' 2>"$errors")"; then
  if grep -q "HTTP 404" "$errors"; then fail "$breaks is not a published release of $REPO."; fi
  fail "Could not look up the release $breaks of $REPO; run the check again."
fi
[ -n "$published" ] || fail "$breaks is a draft release of $REPO, not a published one."

if [ -n "$reported" ]; then
  when="$(epoch_of "$reported")" ||
    fail "The Reported line must be a date or a UTC time, such as 'Reported: 2026-10-20' or 'Reported: 2026-10-20T09:15Z'."
  released="$(epoch_of "$published")"
  now="${MROOM_NOW:-$(date +%s)}"
  latest="$when"
  # A date with no time stands for the whole day, so a problem reported on release day passes.
  if [[ "$reported" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then latest=$((when + 86399)); fi
  ((latest >= released)) || fail "Reported ($reported) is before $breaks was released ($published)."
  ((when <= now)) || fail "Reported ($reported) is in the future."
fi

echo "regression fix: the problem shipped in $breaks (released $published)${reported:+, first reported $reported}"
