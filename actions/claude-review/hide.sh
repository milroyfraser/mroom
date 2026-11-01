#!/usr/bin/env bash
# hide.sh <comments.json> — folds the reviewer's earlier comments on the pull request as outdated, before a new
# review is posted, so only the newest one shows. comments.json is what prepare.sh wrote. A comment that cannot
# be folded stays as it is: the new review still counts, since review findings reads the latest one.
# Env: MROOM_REVIEWER, GH_TOKEN.
set -euo pipefail

COMMENTS="${1:?usage: hide.sh <comments.json>}"
[[ "${MROOM_REVIEWER:-}" =~ ^[A-Za-z0-9][A-Za-z0-9-]*(\[bot\])?$ ]] ||
  { echo "::error title=Claude review::reviewer must be a GitHub login, such as claude[bot]." >&2; exit 1; }

hidden=0 kept=0
while IFS= read -r node_id; do
  [[ "$node_id" =~ ^[A-Za-z0-9_=-]+$ ]] || continue
  # shellcheck disable=SC2016  # $id is GraphQL's
  if gh api graphql -f query='
    mutation($id: ID!) {
      minimizeComment(input: {subjectId: $id, classifier: OUTDATED}) { minimizedComment { isMinimized } }
    }' -f id="$node_id" >/dev/null; then
    hidden=$((hidden + 1))
  else
    kept=$((kept + 1))
  fi
done < <(jq -r --arg r "$MROOM_REVIEWER" '.[] | select(.user.login == $r) | .node_id // empty' "$COMMENTS")
echo "folded $hidden earlier comment(s) of $MROOM_REVIEWER"
[ "$kept" = 0 ] || echo "::warning title=Claude review::could not fold $kept earlier comment(s)"
