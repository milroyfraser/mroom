# shellcheck shell=bash
# title.sh — reads a Conventional Commit title, for the pull request checks: the title check (check.sh here),
# the type label (actions/pr-type-label) and the auto-tag (actions/auto-tag). Sourced, never run.
#
#   <type>(<scope>)!: <subject>      the scope and the ! are optional; ! marks a breaking change
#
# A title is one line. The type is lowercase letters; the scope is any text without parentheses.

# shellcheck disable=SC2034  # the CC_* variables are read by the scripts that source this one
CC_RE='^([a-z]+)(\(([^()]+)\))?(!)?: (.*)$'

# cc_parse <title>: sets CC_TYPE, CC_SCOPE (without its parentheses), CC_BREAKING (! or empty) and CC_SUBJECT.
# Returns 1 when the title has no such shape. It checks only the shape: which types a repository allows, and
# what a subject must look like, are the title check's.
cc_parse() {
  CC_TYPE="" CC_SCOPE="" CC_BREAKING="" CC_SUBJECT=""
  case "$1" in *$'\n'* | *$'\r'*) return 1 ;; esac
  [[ "$1" =~ $CC_RE ]] || return 1
  CC_TYPE="${BASH_REMATCH[1]}" CC_SCOPE="${BASH_REMATCH[3]}" CC_BREAKING="${BASH_REMATCH[4]}"
  CC_SUBJECT="${BASH_REMATCH[5]}"
}

# cc_kind: what the parsed title is for the release notes: feature (feat), bug (fix) or chore (any other type).
cc_kind() {
  case "$CC_TYPE" in
    feat) echo feature ;;
    fix) echo bug ;;
    *) echo chore ;;
  esac
}

# cc_commit_title <commit message>: the pull request title a merge commit carries. A squash merge's first line is
# the title with " (#<N>)" after it; a merge commit's first line is "Merge pull request #<N> from <branch>" and
# the title is the next line that is not empty. Any other commit's first line is its title.
cc_commit_title() {
  local first rest line
  first="${1%%$'\n'*}"
  if [[ "$first" =~ ^Merge\ pull\ request\ \#[0-9]+\ from\  ]]; then
    rest="${1#"$first"}"
    while IFS= read -r line; do
      [ -n "$line" ] && { first="$line"; break; }
    done <<<"$rest"
  fi
  first="${first%$'\r'}"
  [[ "$first" =~ ^(.*)\ \(\#[0-9]+\)$ ]] && first="${BASH_REMATCH[1]}"
  printf '%s\n' "$first"
}
