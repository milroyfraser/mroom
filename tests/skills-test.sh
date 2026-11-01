#!/usr/bin/env bash
# Tests the plugin's workflow skills and commands (plugin/skills/*/SKILL.md, plugin/commands/*.md) as a
# contract:
#   - each has valid frontmatter, a unique name and a description, and the set is the one mroom ships;
#   - every `mroom` command, `/mroom:` skill and mroom.toml key a skill names exists;
#   - every skill keeps the safety rules, and none runs a merge, an approval, a release, a deploy, a secret
#     read or a tracker call except through `mroom tracker` and `mroom errors`;
#   - a skill that calls `mroom tracker` or `mroom errors` says what to do when it exits 3 (no tracker);
#   - every lookup of an issue's pull request, and every list of pull requests' heads, asks whether each is
#     from a fork, a skill that resumes earlier work never takes a fork's pull request or someone else's
#     branch for it, implement stacks only on a pull request whose branch is in the repository, and none
#     checks a pull request's head out by its number or applies its change as a patch;
#   - the release skill asks before it drafts, only drafts, and the settings fragments still ask on a release;
#   - implement publishes its Session Room first, and room/ holds the page and its README, each keeping the
#     footer copyright and naming no host but github.com and Google Fonts;
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
