#!/usr/bin/env bash
# check.sh <event.json> — the pull request title check (actions/pr-title). A squash merge makes the title the
# commit on the default branch, so the title must be a Conventional Commit:
#
#   <type>(<scope>): <subject>        feat(export): add a CSV export
#   <type>!: <subject>                feat!: drop the old API      (! marks a breaking change)
#
# The type must be one of MROOM_TITLE_TYPES, the scope may be required (MROOM_TITLE_REQUIRE_SCOPE=true), and
# the subject must match MROOM_TITLE_SUBJECT_PATTERN, an extended regular expression (bash's =~).
#
# It reads the title from the event file, never from a command line, and prints only values it has checked
# (the type, once it is one of the list), so a title can neither run nor send a workflow command.
set -euo pipefail

HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=actions/pr-title/title.sh
source "$HERE/title.sh"
EVENT="${1:?usage: check.sh <event.json>}"
TYPES="${MROOM_TITLE_TYPES-feat fix chore docs refactor test perf style ci build revert}"
REQUIRE_SCOPE="${MROOM_TITLE_REQUIRE_SCOPE:-false}"
SUBJECT_PATTERN="${MROOM_TITLE_SUBJECT_PATTERN-^[A-Za-z].+$}"

fail() { echo "::error title=PR title::$1"; exit 1; }
setup_error() { echo "::error title=PR title::The check's own setup is wrong: $1"; exit 2; }

read -r -d '' -a types <<<"$TYPES" || true
[ "${#types[@]}" -gt 0 ] || setup_error "types is empty."
for type in "${types[@]}"; do
  [[ "$type" =~ ^[a-z]+$ ]] || setup_error "each of types must be lowercase letters."
done
[ -n "$SUBJECT_PATTERN" ] || setup_error "subject-pattern is empty."
case "$REQUIRE_SCOPE" in true | false) ;; *) setup_error "require-scope must be true or false." ;; esac
# [[ =~ ]] gives 2 for a pattern it cannot compile.
rc=0
# shellcheck disable=SC2319  # the condition's own status is the point
[[ "x" =~ $SUBJECT_PATTERN ]] || rc=$?
[ "$rc" -lt 2 ] || setup_error "subject-pattern is not a valid extended regular expression."

title="$(jq -r '.pull_request.title // empty' "$EVENT")" ||
  fail "Could not read the pull request from the event file; the error is above."
[ -n "$title" ] || fail "The pull request has no title."

list="${types[*]}"
example="feat(export): add a CSV export"
cc_parse "$title" ||
  fail "The title must be a Conventional Commit, <type>(<scope>): <subject>, such as '$example'. Types: ${list// /, }."
case " $list " in
  *" $CC_TYPE "*) ;;
  *) fail "The title's type must be one of: ${list// /, }." ;;
esac
if [ "$REQUIRE_SCOPE" = true ] && [ -z "$CC_SCOPE" ]; then
  fail "The title needs a scope after its type, such as '$example'."
fi
[[ "$CC_SUBJECT" =~ $SUBJECT_PATTERN ]] ||
  fail "The subject, after the colon and one space, must match $SUBJECT_PATTERN."

echo "a Conventional Commit title: $CC_TYPE${CC_BREAKING:+, a breaking change}"
