#!/usr/bin/env bash
# Tests the plugin's workflow skills and commands (plugin/skills/*/SKILL.md, plugin/commands/*.md) as a
# contract:
#   - each has valid frontmatter, a unique name and a description, and the set is the one mroom ships;
#   - every `mroom` command, `/mroom:` skill and mroom.toml key a skill names exists;
#   - every skill keeps the safety rules, and none runs a merge, an approval, a release, a deploy, a secret
#     read or a tracker call except through `mroom tracker` and `mroom errors`;
#   - a skill that calls `mroom tracker` or `mroom errors` says what to do when it exits 3 (no tracker);
#   - every lookup of an issue's pull request, and every `gh pr list`, `view` or `status` that reads pull
#     requests' heads, asks whether each is from a fork; a skill that resumes earlier work never takes a
#     fork's pull request or someone else's branch for it; implement stacks only on a pull request whose
#     branch is in the repository, in a parent's worktree only on the repository's own branch; and none
#     checks a pull request's head out by its number, fetches from another repository or by a commit id,
#     or applies a pull request's change as a patch;
#   - the release skill asks before it drafts, only drafts, and the settings fragments still ask on a release;
#   - no skill builds the body of a `forge-api --secret` write on a command line (jq -n or --arg holding the
#     value, a here-document, echo, printf or an inline --data), and forge says why and shows the ways that work;
#   - implement publishes its Session Room first, and room/ holds the page and its README, each keeping the
#     footer copyright and naming no host but github.com and Google Fonts;
#   - the Room is published with a db rule that lets only its owner and Editors write, and the page tells
#     Claude which card changed without quoting a row;
#   - the Room decides whether a card is blocked in one place, so no verdict it shows (the card's tabs, the
#     next-step box) reads Go for a blocked card, and an Issue card keeps its QA placeholder once its PR opens;
#   - no skill names a host, address, id or person (and none of the words in $MROOM_PRIVATE_WORDS, a file
#     of one case-insensitive regular expression per line, kept outside the repository).
#
#   tests/skills-test.sh            (SKILLS_DIR and COMMANDS_DIR override the folders, for mutation checks)
set -euo pipefail
SUITE=skills
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v jq >/dev/null 2>&1 || { echo "  FAIL [$SUITE] needs jq" >&2; exit 1; }

export SKILLS_DIR="${SKILLS_DIR:-$ROOT/plugin/skills}" COMMANDS_DIR="${COMMANDS_DIR:-$ROOT/plugin/commands}"
export MROOM_ROOT_DIR="$ROOT"

# The checks are in tests/skills-check.py: one line per check, "ok <what>" or "FAIL <what>".
results="$(python3 "$ROOT/tests/skills-check.py")"

while IFS= read -r line; do
  case "$line" in
    "ok "*) ok ;;
    "FAIL "*) CURRENT=skills; rc=0; out=""; err=""; fail "${line#FAIL }" ;;
    *) CURRENT=skills; rc=0; out="$line"; err=""; fail "unexpected output from the checks" ;;
  esac
done <<<"$results"
[ -n "$results" ] || { CURRENT=skills; rc=0; out=""; err=""; fail "the checks printed nothing"; }
finish
