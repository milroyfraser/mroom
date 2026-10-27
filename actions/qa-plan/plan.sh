#!/usr/bin/env bash
# plan.sh <PR> — the path rules for pull request <PR> (actions/qa-plan; design 8.2): lists its changed files through
# GitHub's API and sorts them (scope.sh), printing scope= and reason= for GITHUB_OUTPUT. A renamed file counts with
# both its names, since a file moved out of the app changes the app as much as one moved in. A name that holds a
# control character, a newline among them, is passed on as one line that scope.sh reads as a maybe, so no name can
# split itself into names the rules wave through. A listing that fails is an empty one, which scope.sh also takes
# as a maybe. It reads the pull request as data and runs none of its code.
#
# Environment: GH_TOKEN (pull-requests: read), GITHUB_REPOSITORY, and MROOM_CONFIG, the app's mroom.toml.
set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
HERE="$(dirname "$SELF")"
pr="${1:-}"
[[ "$pr" =~ ^[1-9][0-9]{0,8}$ ]] || { echo "::error::the pull request's number is not a number"; exit 2; }
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}"

files="$(gh api --paginate "repos/$repo/pulls/$pr/files" --jq '.[] | (.filename, (.previous_filename // empty))
  | if test("[[:cntrl:]]") then "\u0001" else . end' </dev/null)" \
  || { echo "::warning::could not list the pull request's files" >&2; files=""; }
"$HERE/scope.sh" <<<"$files"
