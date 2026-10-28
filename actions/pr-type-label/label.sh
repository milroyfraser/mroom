#!/usr/bin/env bash
# label.sh <event.json> — the type label (actions/pr-type-label). Labels a pull request by its Conventional
# Commit title, so the release notes keep their groups without anyone labelling by hand:
#
#   feat        the feature label (type:feature)
#   fix         the bug label (type:bug)
#   any other   the chore label (type:chore)
#
# A title edit moves the label: it takes off the other two type labels and adds the one the title wants. A title
# with no Conventional Commit type changes nothing; the title check reports it.
#
# It reads the pull request's number and title from the event file and its labels, as they are now, from GitHub.
# It prints only the label names it was given. Env: REPO
# (owner/repo) and GH_TOKEN for gh; MROOM_LABEL_FEATURE, MROOM_LABEL_BUG and MROOM_LABEL_CHORE, the three names.
set -euo pipefail

HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=actions/pr-title/title.sh
source "$HERE/../pr-title/title.sh"
EVENT="${1:?usage: label.sh <event.json>}"
REPO="${REPO:?REPO (owner/repo) is not set}"
FEATURE="${MROOM_LABEL_FEATURE-type:feature}"
BUG="${MROOM_LABEL_BUG-type:bug}"
CHORE="${MROOM_LABEL_CHORE-type:chore}"

fail() { echo "::error title=PR type label::$1"; exit 1; }

for label in "$FEATURE" "$BUG" "$CHORE"; do
  [[ "$label" =~ ^[^[:cntrl:]]{1,50}$ ]] || fail "Each label name must be 1 to 50 characters."
done
# GitHub matches label names without regard to case, and so does this check.
if [ "${FEATURE,,}" = "${BUG,,}" ] || [ "${FEATURE,,}" = "${CHORE,,}" ] || [ "${BUG,,}" = "${CHORE,,}" ]; then
  fail "The three label names must differ."
fi

{ number="$(jq -r '.pull_request.number' "$EVENT")" &&
  title="$(jq -r '.pull_request.title // empty' "$EVENT")"; } ||
  fail "Could not read the pull request from the event file; the error is above."
[[ "$number" =~ ^[1-9][0-9]*$ ]] || fail "The event file names no pull request."

if ! cc_parse "$title"; then
  echo "no Conventional Commit type in the title; the title check reports it"
  exit 0
fi
case "$(cc_kind)" in
  feature) want="$FEATURE" ;;
  bug) want="$BUG" ;;
  *) want="$CHORE" ;;
esac

# The labels as they are now, not as the event saw them: a re-run reuses the event, and a person may have changed
# the labels since. The workflow runs one label job per pull request at a time, the newest title last.
labels="$(gh api --paginate "repos/$REPO/issues/$number/labels" --jq '.[].name')" ||
  fail "Could not read the pull request's labels; run the check again."

# live <name>: the label as the pull request has it, matched without regard to case, or nothing.
live() { grep -ixF -m 1 -- "$1" <<<"$labels" || true; }
has() { [ -n "$(live "$1")" ]; }
errors="$(mktemp)"
trap 'rm -f "$errors"' EXIT
for label in "$FEATURE" "$BUG" "$CHORE"; do
  if [ "$label" != "$want" ] && has "$label"; then
    encoded="$(live "$label" | jq -rR '@uri')"
    # A 404: someone took it off in the meantime.
    if ! gh api -X DELETE "repos/$REPO/issues/$number/labels/$encoded" >/dev/null 2>"$errors" &&
      ! grep -q "HTTP 404" "$errors"; then
      fail "Could not take the label $label off; run the check again."
    fi
    echo "took off $label"
  fi
done
if has "$want"; then
  echo "already labelled $want"
else
  gh api -X POST "repos/$REPO/issues/$number/labels" -f "labels[]=$want" >/dev/null ||
    fail "Could not add the label $want; run the check again."
  echo "labelled $want"
fi
