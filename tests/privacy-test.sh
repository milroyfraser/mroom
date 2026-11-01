#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2329  # the t_* functions run indirectly, through test_case
# Tests for the privacy check (tools/privacy_check.py): a hit in an added line, a path, a commit message and the
# pull request's title and body, each named by its place and the entry's number; no hit; no list (no secret);
# the list from a file, from the variable itself and from the gitignored .private-words; an entry that is not a
# regular expression; and no entry of the list ever in the output.
set -euo pipefail
SUITE=privacy
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/tools/privacy_check.py"
# Made-up words: entry 1 a plain word, entry 2 a regular expression, after a blank line that is not counted.
WORDS=$'zebrafjord\n\nquokka[0-9]+\n'

g() { git -c user.name=test -c user.email=test@example.dev -c commit.gpgsign=false "$@"; }

# repo: a repository in $T/repo with one commit on the branch base, then a branch work checked out.
repo() {
  unset PR_TITLE PR_BODY GITHUB_ACTIONS
  mkdir -p "$T/repo" && cd "$T/repo"
  g init -q -b base
  printf 'hello\n' >README
  g add README && g commit -q -m 'chore: start'
  g checkout -q -b work
}

# change <file> <text> <message>: adds a line to the file and commits it.
change() { printf '%s\n' "$2" >>"$1"; g add "$1"; g commit -q -m "$3"; }

check() { run python3 "$CHECK" --base base --head HEAD; }

# expect_no_words: neither entry, nor anything they match here, is in stdout or stderr.
expect_no_words() {
  local both="$out $err"
  case "$both" in *zebrafjord* | *quokka* | *Zebrafjord*) fail "the output names a private word" ;; *) ok ;; esac
}

t_hit_in_a_line() {
  repo
  change notes.txt 'one' 'docs: one'
  change notes.txt 'two with quokka42 in it' 'docs: two'
  export MROOM_PRIVATE_WORDS="$WORDS"
  check
  expect_rc 1
  expect_out_has 'notes.txt:2: matches entry 2 of the private list'
  expect_no_words
}

t_hit_in_a_commit_message_and_case_blind() {
  repo
  change notes.txt 'plain' $'docs: plain\n\nasked by ZebraFjord'
  export MROOM_PRIVATE_WORDS="$WORDS"
  check
  expect_rc 1
  expect_out_has 'message line 3: matches entry 1 of the private list'
  expect_no_words
}

t_hit_in_title_and_body() {
  repo
  change notes.txt 'plain' 'docs: plain'
  export MROOM_PRIVATE_WORDS="$WORDS" PR_TITLE='docs: for zebrafjord' PR_BODY=$'TL;DR\n\nsee quokka7'
  check
  expect_rc 1
  expect_out_has 'PR title: matches entry 1 of the private list'
  expect_out_has 'PR body line 3: matches entry 2 of the private list'
  expect_no_words
}

t_a_matching_path_is_never_printed() {
  repo
  change zebrafjord.txt 'plain' 'docs: plain'
  export MROOM_PRIVATE_WORDS="$WORDS"
  check
  expect_rc 1
  expect_out_has 'the path of changed file 1: matches entry 1 of the private list'
  expect_no_words
}

t_annotations_in_actions() {
  repo
  change notes.txt 'quokka1' 'docs: one'
  export MROOM_PRIVATE_WORDS="$WORDS" GITHUB_ACTIONS=true PR_TITLE=zebrafjord
  check
  expect_rc 1
  expect_out_has '::error file=notes.txt,line=1::notes.txt:1: matches entry 2 of the private list'
  expect_out_has '::error::PR title: matches entry 1 of the private list'
  expect_no_words
}

t_no_hit() {
  repo
  change notes.txt 'nothing to see' 'docs: nothing'
  export MROOM_PRIVATE_WORDS="$WORDS" PR_TITLE='docs: nothing' PR_BODY='plain'
  check
  expect_rc 0
  expect_out_has 'privacy: no hits (2 entries'
  expect_no_words
}

t_a_removed_line_is_no_hit() {
  repo
  g checkout -q base && change notes.txt 'quokka9' 'docs: one' && g checkout -q work && g merge -q --ff-only base
  printf 'clean\n' >notes.txt && g add notes.txt && g commit -q -m 'docs: clean'
  export MROOM_PRIVATE_WORDS="$WORDS"
  check
  expect_rc 0
}

t_no_list_passes_with_a_notice() {
  repo
  change notes.txt 'zebrafjord' 'docs: zebrafjord'
  check
  expect_rc 0
  expect_out_has 'privacy check is skipped'
  export GITHUB_ACTIONS=true MROOM_PRIVATE_WORDS=''
  check
  expect_rc 0
  expect_out_has '::notice::no private words'
}

t_list_from_a_file() {
  repo
  change notes.txt 'zebrafjord' 'docs: plain'
  printf '%s' "$WORDS" >"$T/words"
  export MROOM_PRIVATE_WORDS="$T/words"
  check
  expect_rc 1
  expect_out_has 'notes.txt:1: matches entry 1 of the private list'
  expect_no_words
}

t_list_from_the_gitignored_file() {
  repo
  change notes.txt 'quokka3' 'docs: plain'
  printf '%s' "$WORDS" >.private-words
  check
  expect_rc 1
  expect_out_has 'notes.txt:1: matches entry 2 of the private list'
  expect_no_words
  expect_true ".private-words is gitignored" git -C "$ROOT" check-ignore -q .private-words
}

t_a_bad_entry_fails_without_naming_it() {
  repo
  change notes.txt 'plain' 'docs: plain'
  export MROOM_PRIVATE_WORDS=$'zebrafjord\nquokka(['
  check
  expect_rc 1
  expect_out_has 'entry 2 of the list is not a valid regular expression'
  expect_no_words
}

t_skills_check_reads_the_same_list() {
  unset PR_TITLE PR_BODY GITHUB_ACTIONS
  export MROOM_PRIVATE_WORDS="$WORDS"
  run python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); from privacy_check import private_words; print(len(private_words(sys.argv[2])))' \
    "$ROOT/tools" "$T"
  expect_out 2
  expect_true "skills-check.py reads the list through private_words" grep -q 'from privacy_check import private_words' \
    "$ROOT/tests/skills-check.py"
}

test_case hit-in-a-line t_hit_in_a_line
test_case hit-in-a-commit-message t_hit_in_a_commit_message_and_case_blind
test_case hit-in-title-and-body t_hit_in_title_and_body
test_case matching-path t_a_matching_path_is_never_printed
test_case annotations t_annotations_in_actions
test_case no-hit t_no_hit
test_case removed-line t_a_removed_line_is_no_hit
test_case no-list t_no_list_passes_with_a_notice
test_case list-from-a-file t_list_from_a_file
test_case list-from-gitignored-file t_list_from_the_gitignored_file
test_case bad-entry t_a_bad_entry_fails_without_naming_it
test_case skills-check-list t_skills_check_reads_the_same_list
finish
