#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2329,SC2016  # t_* run through test_case; a ${{ }} in single quotes is the workflow's own
# Tests for the privacy check (tools/privacy_check.py) and its workflow (.github/workflows/privacy.yml):
#   - a hit in an added line, a path, a commit's author, committer and message, the title, the body and the branch
#     name, each named by its place and the entry's number, and never by the word (case-blind);
#   - the ways a change could hide a word from git's usual diff (a NUL byte, a binary path, the change's own
#     .gitattributes, an empty file, quoted paths, a "++" line, a 0x1e byte, UTF-16, a user's diff.noprefix), and a
#     deleted path that is no hit;
#   - where the list comes from: the variable, its file, .private-words (never a link, never in Actions), and the
#     values refused; no list passes with a notice;
#   - in Actions: every entry masked first, escaped annotations, no entry count;
#   - the workflow: same-repository pull requests on the default branch only, the privacy environment, read-only
#     permissions, a pinned checkout of this file's own commit, the pull request fetched into a bare repository as
#     data, python3 -I; a pull request that changes the script, or a PYTHONPATH, never runs its own code.
set -euo pipefail
SUITE=privacy
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/tools/privacy_check.py"
WF="$ROOT/.github/workflows/privacy.yml"
# Made-up words: entry 1 a plain word, entry 2 a regular expression, after a blank line that is not counted.
WORDS=$'zebrafjord\n\nquokka[0-9]+\n'

g() { git -c user.name=test -c user.email=test@example.dev -c commit.gpgsign=false "$@"; }

# repo: a repository in $T/repo with one commit on the branch base, then a branch work checked out.
repo() {
  unset PR_TITLE PR_BODY PR_HEAD_REF GITHUB_ACTIONS
  mkdir -p "$T/repo" && cd "$T/repo"
  g init -q -b base
  printf 'hello\n' >README
  g add README && g commit -q -m 'chore: start'
  g checkout -q -b work
}

# change <file> <text> <message>: adds a line to the file and commits it.
change() { printf '%s\n' "$2" >>"$1"; g add "$1"; g commit -q -m "$3"; }

check() { run python3 "$CHECK" --base base --head HEAD; }

# expect_no_words: neither entry, nor anything they match here, is in stdout or stderr, in any case, but in the
# ::add-mask:: lines Actions takes and never shows.
expect_no_words() {
  if printf '%s\n%s\n' "$out" "$err" | grep -v '^::add-mask::' | grep -qiE 'zebrafjord|quokka'; then
    fail "the output names a private word"
  else
    ok
  fi
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
  # In Actions the log says no count.
  export GITHUB_ACTIONS=true
  check
  expect_rc 0
  case "$out" in *entries*) fail "the Actions log counts the entries" ;; *) ok ;; esac
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
  export MROOM_PRIVATE_WORDS_FILE="$T/words"
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
  unset PR_TITLE PR_BODY PR_HEAD_REF GITHUB_ACTIONS
  export MROOM_PRIVATE_WORDS="$WORDS"
  run python3 -I -c 'import importlib.util, sys
spec = importlib.util.spec_from_file_location("privacy_check", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(len(m.private_words(sys.argv[2])))' "$CHECK" "$T"
  expect_out 2
  expect_true "skills-check.py loads tools/privacy_check.py by its path" \
    grep -q 'spec_from_file_location("privacy_check", os.path.join(root, "tools", "privacy_check.py"))' "$ROOT/tests/skills-check.py"
  expect_true "skills-check.py reads the list through private_words" grep -q 'privacy_check.private_words(root)' \
    "$ROOT/tests/skills-check.py"
}


t_hit_in_author_committer_and_branch() {
  repo
  printf 'plain\n' >d.txt && g add d.txt
  git -c user.name=Zebrafjord -c user.email=me@example.dev -c commit.gpgsign=false commit -q -m 'docs: d'
  printf 'more\n' >>d.txt && g add d.txt
  GIT_COMMITTER_NAME=someone GIT_COMMITTER_EMAIL=quokka2@example.dev g commit -q -m 'docs: e'
  export MROOM_PRIVATE_WORDS="$WORDS"
  check
  expect_rc 1
  expect_out_has 'author: matches entry 1 of the private list'
  expect_out_has 'committer: matches entry 2 of the private list'
  expect_no_words
  # The branch name: the checked-out one locally, $PR_HEAD_REF when set.
  g checkout -q -b zebrafjord-fix
  check
  expect_out_has 'the branch name: matches entry 1 of the private list'
  g checkout -q work
  export PR_HEAD_REF=fix/quokka9
  check
  expect_out_has 'the branch name: matches entry 2 of the private list'
  expect_no_words
}

# hidden <what> <expected place>: the change in the repository so far hides a word; the check finds it.
hidden() {
  export MROOM_PRIVATE_WORDS="$WORDS"
  check
  if [ "$rc" = 1 ]; then ok; else fail "$1: missed (rc $rc)"; fi
  expect_out_has "$2"
  expect_no_words
}

t_hidden_nul_byte() { repo; printf 'x\0y\nzebrafjord\n' >data.txt; g add data.txt; g commit -q -m 'docs: data'; hidden "a NUL byte" 'data.txt:2: matches entry 1'; }
t_hidden_binary_path() { repo; printf 'x\0y\n' >zebrafjord.dat; g add -A; g commit -q -m 'docs: data'; hidden "a binary file's path" 'the path of changed file 1'; }
t_hidden_gitattributes() {
  repo; printf '* -diff\n' >.gitattributes; printf 'zebrafjord\n' >b.txt; g add -A; g commit -q -m 'docs: b'
  hidden "the change's own .gitattributes" 'b.txt:1: matches entry 1'
}
t_hidden_empty_file() { repo; mkdir zebrafjord; : >zebrafjord/.gitkeep; g add -A; g commit -q -m 'docs: keep'; hidden "an empty file's path" 'the path of changed file 1'; }
t_hidden_tab_path() { repo; printf 'zebrafjord\n' >$'tab\tname.txt'; g add -A; g commit -q -m 'docs: tab'; hidden "a path with a tab" $'tab\tname.txt:1: matches entry 1'; }
t_hidden_quote_path() { repo; printf 'zebrafjord\n' >'quote"name.txt'; g add -A; g commit -q -m 'docs: quote'; hidden "a path with a quote" 'quote"name.txt:1: matches entry 1'; }
t_hidden_plus_plus_line() { repo; printf '++ a list item\nzebrafjord\n' >c.md; g add c.md; g commit -q -m 'docs: c'; hidden "a '++ ' line" 'c.md:2: matches entry 1'; }
t_hidden_record_separator() {
  repo; printf 'plain\n' >e.txt; g add e.txt; g commit -q -m "$(printf 'docs: e\n\nsee\036 zebrafjord')"
  hidden "a 0x1e byte in a message" 'message line 3: matches entry 1'
}
t_hidden_utf16() {
  repo; printf 'zebrafjord\n' | iconv -f UTF-8 -t UTF-16 >g.txt; g add g.txt; g commit -q -m 'docs: g'
  hidden "a UTF-16 file" 'g.txt:1: matches entry 1'
}
t_hidden_noprefix() {
  repo; printf 'zebrafjord\n' >h.txt; g add h.txt; g commit -q -m 'docs: h'
  export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=diff.noprefix GIT_CONFIG_VALUE_0=true GIT_CONFIG_KEY_1=diff.relative GIT_CONFIG_VALUE_1=true
  mkdir sub && cd sub
  hidden "a user's diff.noprefix and diff.relative" 'h.txt:1: matches entry 1'
}
t_a_deleted_leak_is_no_hit() {
  repo
  printf 'gone\n' >zebrafjord.txt; g add zebrafjord.txt; g commit -q -m 'docs: leak'
  g checkout -q base && g merge -q --ff-only work && g checkout -q -b work2
  g rm -q zebrafjord.txt && g commit -q -m 'docs: remove the leak'
  export MROOM_PRIVATE_WORDS="$WORDS"
  check
  expect_rc 0
}

t_list_sources_refused() {
  repo
  change notes.txt 'plain' 'docs: plain'
  export MROOM_PRIVATE_WORDS="$T/no/such/words"
  check
  expect_rc 2
  expect_err_has 'reads like a path'
  unset MROOM_PRIVATE_WORDS
  export MROOM_PRIVATE_WORDS_FILE="$T/no-such-file"
  check
  expect_rc 2
  expect_err_has 'names no file'
  unset MROOM_PRIVATE_WORDS_FILE
  printf 'zebrafjord\n' >"$T/outside.txt" && ln -s "$T/outside.txt" .private-words
  check
  expect_rc 2
  expect_err_has 'is a link'
  expect_no_words
}

# In Actions only the secret counts: a .private-words the pull request carries is never read, and an empty secret
# passes with a notice.
t_actions_never_reads_private_words_file() {
  repo
  printf 'plain\n' >.private-words && printf 'plain here\n' >a.txt && g add -f .private-words a.txt && g commit -q -m 'docs: a'
  export GITHUB_ACTIONS=true MROOM_PRIVATE_WORDS=''
  check
  expect_rc 0
  expect_out_has '::notice::no private words, so the privacy check is skipped'
}

t_actions_masks_first_and_escapes() {
  repo
  printf 'quokka1\n' >'a,b:c.txt' && printf 'quokka2\n' >$'new\nline.txt' && g add -A && g commit -q -m 'docs: one'
  export MROOM_PRIVATE_WORDS=$'zebrafjord\nquokka[0-9]+\n50%\r' GITHUB_ACTIONS=true
  check
  expect_rc 1
  # The masks come first, one per entry, each escaped, and nothing else names an entry.
  expect_true "the first three lines are the masks" [ "$(printf '%s\n' "$out" | head -3)" = $'::add-mask::zebrafjord\n::add-mask::quokka[0-9]+\n::add-mask::50%25' ]
  expect_true "no other line is a mask" [ "$(grep -c '^::add-mask::' <<<"$out")" = 3 ]
  expect_out_has '::error file=a%2Cb%3Ac.txt,line=1::a,b:c.txt:1: matches entry 2 of the private list'
  expect_out_has '::error file=new%0Aline.txt,line=1::new%0Aline.txt:1: matches entry 2 of the private list'
  expect_no_words
}

# --- The workflow ---------------------------------------------------------------------------------------------
# has <what> <fixed line>: the workflow holds the line, whole, after its indentation.
has() { if grep -qxE " *$(printf '%s' "$2" | sed 's/[][\.*^$+?(){}|/]/\\&/g')" "$WF"; then ok; else fail "privacy.yml: $1 ($2)"; fi; }

t_workflow_shape() {
  has "runs on pull_request_target, so its own copy is the default branch's" 'pull_request_target:'
  has "re-runs when the title or body is edited" 'types: [opened, synchronize, reopened, edited]'
  if grep -qE '^  (pull_request|push|workflow_run|workflow_dispatch):' "$WF"; then fail "privacy.yml has another trigger"; else ok; fi
  # Same-repository pull requests on the default branch only: a fork's annotations would be public.
  has "skips a fork's pull request" "github.event.pull_request.head.repo.full_name == github.repository &&"
  has "only for a pull request on the default branch" 'github.event.pull_request.base.ref == github.event.repository.default_branch &&'
  has "skips Dependabot" "github.actor != 'dependabot[bot]'"
  expect_true "the condition is the job's" grep -qzE 'name: privacy
    if: >-
' "$WF"
  # The secret lives in an environment that admits the default branch alone.
  expect_true "the privacy environment, no deployment" grep -qE '^    environment:$' "$WF"
  has "the environment is privacy" 'name: privacy'
  has "no deployment" 'deployment: false'
  # Read-only.
  has "contents: read" 'contents: read'
  if grep -vE '^ *#' "$WF" | grep -qE ': *write\b|write-all'; then fail "privacy.yml asks for a write permission"; else ok; fi
  # The check from this file's own commit, through a checkout pinned by its full commit id.
  local uses
  uses="$(grep -E '^ +(- )?uses: ' "$WF" | sed 's/^ *\(- \)\{0,1\}uses: //')"
  expect_true "every action is pinned by a full commit id" bash -c '! grep -vqE "^[^@]+@[0-9a-f]{40}( #.*)?$" <<<"$1"' _ "$uses"
  expect_true "the check is checked out at this file's commit into base/" \
    grep -qE '^ +path: base$' <<<"$(grep -A1 -F 'ref: ${{ github.workflow_sha }}' "$WF")"
  expect_true "no checkout keeps credentials" \
    [ "$(grep -c 'uses: actions/checkout' "$WF")" = "$(grep -c 'persist-credentials: false' "$WF")" ]
  if grep -qF 'github.event.pull_request.head.sha }}' <<<"$(grep -A1 'ref:' "$WF")"; then fail "the pull request is checked out"; else ok; fi
  # The pull request is fetched by its two commits into a bare repository, and the check runs there with -I.
  has "a bare repository" 'git init -q --bare pr.git'
  has "fetches the two commits" 'git -C pr.git fetch -q --no-tags "$REPO" "$BASE_SHA" "$HEAD_SHA"'
  has "the check runs in pr.git" 'working-directory: pr.git'
  has "the check runs isolated, from base/" 'run: python3 -I ../base/tools/privacy_check.py --base "$BASE_SHA" --head "$HEAD_SHA"'
  expect_true "one step runs the check" [ "$(grep -c 'privacy_check.py' <<<"$(grep -E '^ +run: ' "$WF")")" = 1 ]
  # The secret only in the check's own step; nothing traces commands; ci.yml holds none of it.
  expect_true "the secret is read once" [ "$(grep -vE '^ *#' "$WF" | grep -c 'secrets\.')" = 1 ]
  has "the secret reaches the check" 'MROOM_PRIVATE_WORDS: ${{ secrets.MROOM_PRIVATE_WORDS }}'
  has "the branch name reaches the check" 'PR_HEAD_REF: ${{ github.event.pull_request.head.ref }}'
  if grep -vE '^ *#' "$WF" | grep -qE 'set -[a-z]*x|bash -x|echo|cat '; then fail "a step traces or prints"; else ok; fi
  if grep -q MROOM_PRIVATE_WORDS "$ROOT/.github/workflows/ci.yml"; then fail "ci.yml holds the private words"; else ok; fi
}

# The workflow's own steps, in the layout it makes: base/ the default branch's script; the pull request, which
# changes tools/privacy_check.py to print the list and pass, fetched into pr.git; a PYTHONPATH that would shadow
# argparse. The default branch's copy runs, masks the list and fails the hit; no code of the pull request runs.
t_the_pull_requests_code_never_runs() {
  local fetch cmd
  fetch="$(grep -E '^ +git (init -q --bare pr\.git|-C pr\.git fetch )' "$WF" | sed 's/^ *//')"
  cmd="$(sed -n 's/^ *run: \(python3 .*privacy_check\.py.*\)$/\1/p' "$WF")"
  expect_true "the fetch is found" [ "$(grep -c . <<<"$fetch")" = 2 ]
  expect_true "the check's command is found" [ -n "$cmd" ]
  unset PR_TITLE PR_BODY PR_HEAD_REF
  mkdir -p "$T/base/tools" && cp "$CHECK" "$T/base/tools/"
  mkdir -p "$T/src" && cd "$T/src"
  g init -q -b base
  printf 'hello\n' >README && g add README && g commit -q -m 'chore: start'
  g checkout -q -b work
  mkdir -p tools
  printf '%s\n' 'import os, sys' 'print("PR COPY RAN", os.environ.get("MROOM_PRIVATE_WORDS"))' 'sys.exit(0)' >tools/privacy_check.py
  printf '%s\n' 'print("PR MODULE RAN")' >tools/argparse.py && cp tools/argparse.py argparse.py
  change notes.txt 'quokka5' 'docs: one'
  g add -A && g commit -q -m 'docs: tools'
  mkdir -p "$T/evil" && printf '%s\n' 'print("PYTHONPATH RAN")' >"$T/evil/argparse.py"
  export REPO="$T/src" BASE_SHA HEAD_SHA GITHUB_ACTIONS=true MROOM_PRIVATE_WORDS="$WORDS" PYTHONPATH="$T/evil"
  BASE_SHA="$(git rev-parse base)" HEAD_SHA="$(git rev-parse work)"
  cd "$T"
  run bash -c "$fetch"
  expect_rc 0
  cd "$T/pr.git"
  expect_true "pr.git is bare" [ "$(git rev-parse --is-bare-repository)" = true ]
  run bash -c "$cmd"
  expect_rc 1
  expect_out_has '::add-mask::zebrafjord'
  expect_out_has '::error file=notes.txt,line=1::notes.txt:1: matches entry 2 of the private list'
  case "$out $err" in *"PR COPY RAN"* | *"PR MODULE RAN"* | *"PYTHONPATH RAN"*) fail "code from outside base/ ran" ;; *) ok ;; esac
  expect_no_words
  # And with no secret: a notice, and a pass.
  export MROOM_PRIVATE_WORDS=''
  run bash -c "$cmd"
  expect_rc 0
  expect_out_has '::notice::no private words'
}

test_case hit-in-a-line t_hit_in_a_line
test_case hit-in-a-commit-message t_hit_in_a_commit_message_and_case_blind
test_case hit-in-title-and-body t_hit_in_title_and_body
test_case hit-in-author-committer-branch t_hit_in_author_committer_and_branch
test_case matching-path t_a_matching_path_is_never_printed
test_case annotations t_annotations_in_actions
test_case no-hit t_no_hit
test_case removed-line t_a_removed_line_is_no_hit
test_case deleted-leak t_a_deleted_leak_is_no_hit
test_case hidden-nul t_hidden_nul_byte
test_case hidden-binary-path t_hidden_binary_path
test_case hidden-gitattributes t_hidden_gitattributes
test_case hidden-empty-file t_hidden_empty_file
test_case hidden-tab-path t_hidden_tab_path
test_case hidden-quote-path t_hidden_quote_path
test_case hidden-plus-plus t_hidden_plus_plus_line
test_case hidden-record-separator t_hidden_record_separator
test_case hidden-utf16 t_hidden_utf16
test_case hidden-noprefix t_hidden_noprefix
test_case no-list t_no_list_passes_with_a_notice
test_case list-from-a-file t_list_from_a_file
test_case list-from-gitignored-file t_list_from_the_gitignored_file
test_case list-sources-refused t_list_sources_refused
test_case actions-no-private-words-file t_actions_never_reads_private_words_file
test_case actions-masks t_actions_masks_first_and_escapes
test_case bad-entry t_a_bad_entry_fails_without_naming_it
test_case skills-check-list t_skills_check_reads_the_same_list
test_case workflow t_workflow_shape
test_case pr-code-never-runs t_the_pull_requests_code_never_runs
finish
