#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2016  # t_* run through test_case; a $ in single quotes is the YAML's or eval's own
# Tests for the PR checks: the title check (actions/pr-title/check.sh), the type label
# (actions/pr-type-label/label.sh), the title reader they share with the auto-tag (actions/pr-title/title.sh),
# the release notes template, and the shape of the reusable workflow that runs them (.github/workflows/
# pr-checks.yml). Offline: gh is a fake in $T/bin that logs each call and answers from $FAKE.
set -euo pipefail
SUITE=pr-checks
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/actions/pr-title/check.sh"
LABEL="$ROOT/actions/pr-type-label/label.sh"
W="$ROOT/.github/workflows"

world() {
  FAKE="$T/fake"
  export FAKE REPO=example/shop
  mkdir -p "$FAKE" "$T/bin"
  cat >"$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
# fake gh: logs "api -X <method> <path> [-f <field>]" calls; fails every call with $FAKE/down.
printf '%s\n' "$*" >>"$FAKE/gh.log"
if [ -f "$FAKE/down" ]; then echo "error connecting to api.github.com" >&2; exit 1; fi
[ "$1" = api ] || { echo "fake gh: unexpected: $*" >&2; exit 1; }
echo '[]'
EOF
  chmod +x "$T/bin/gh"
  export PATH="$T/bin:$PATH"
}

# event <title> [label...]: the pull_request event the scripts read.
event() {
  local title="$1"
  shift
  jq -n --arg t "$title" '{pull_request: {number: 42, title: $t, labels: ($ARGS.positional | map({name: .}))}}' \
    --args "$@" >"$T/event.json"
}

check() { run "$CHECK" "$T/event.json"; }
label() { run "$LABEL" "$T/event.json"; }
log() { cat "$FAKE/gh.log" 2>/dev/null || true; }

t_good_titles_pass() {
  world
  local title
  for title in "feat: add a CSV export" "fix(SHOP-12): keep the filter" "chore(deps)!: drop Node 18" \
    "feat!: a new API" "revert: feat: add a CSV export" "docs(read me): say how"; do
    event "$title"
    check; expect_rc 0; expect_out_has "a Conventional Commit title: "
  done
  event "feat(api)!: a new API"
  check; expect_out "a Conventional Commit title: feat, a breaking change"
}

t_bad_titles_fail() {
  world
  local title
  for title in "Add a CSV export" "feat add a CSV export" "feat:add a CSV export" "feat:  add" "feat: " \
    "Feat: add" "feat(): add" "feat(a(b)): add" "feat: 1 more" "feat!(api): add" "WIP feat: add"; do
    event "$title"
    check; expect_rc 1; expect_out_has "::error title=PR title::"
  done
  event "Add a CSV export"
  check
  expect_out "::error title=PR title::The title must be a Conventional Commit, <type>(<scope>): <subject>, such as 'feat(export): add a CSV export'. Types: feat, fix, chore, docs, refactor, test, perf, style, ci, build, revert."
  event "wip: add a CSV export"
  check; expect_rc 1; expect_out_has "The title's type must be one of: feat, fix, chore"
  event "feat: 1 more"
  check; expect_out "::error title=PR title::The subject, after the colon and one space, must match ^[A-Za-z].+$."
}

t_the_title_is_never_printed() {
  world
  local title
  for title in '::add-mask::x' 'feat(::set-output name=a::b): x' 'zzz: ::warning::hi' 'feat: ::error::x' \
    "\$(touch $T/ran): x"; do
    event "$title"
    check
    case "$out" in *"::add-mask"* | *"set-output"* | *"::warning"* | *"::error::"* | *"touch"*) fail "printed the title: $title" ;; *) ok ;; esac
  done
  expect_no_file "$T/ran"
}

t_settings() {
  world
  event "feat: add"
  MROOM_TITLE_REQUIRE_SCOPE=true check; expect_rc 1; expect_out_has "The title needs a scope after its type"
  event "feat(SHOP-1): add"
  MROOM_TITLE_REQUIRE_SCOPE=true check; expect_rc 0
  MROOM_TITLE_TYPES=$'fix\nchore' check; expect_rc 1; expect_out_has "must be one of: fix, chore."
  event "chore: add"
  MROOM_TITLE_TYPES=$'  fix\n  chore\n' check; expect_rc 0
  event "fix: lowercase only"
  MROOM_TITLE_SUBJECT_PATTERN='^[a-z]' check; expect_rc 0
  event "fix: Upper"
  MROOM_TITLE_SUBJECT_PATTERN='^[a-z]' check; expect_rc 1
}

t_a_wrong_setup_is_its_own_error() {
  world
  event "feat: add"
  MROOM_TITLE_TYPES='feat Fix' check; expect_rc 2; expect_out_has "setup is wrong: each of types must be lowercase"
  MROOM_TITLE_TYPES=' ' check; expect_rc 2; expect_out_has "types is empty"
  MROOM_TITLE_REQUIRE_SCOPE=yes check; expect_rc 2; expect_out_has "require-scope must be true or false"
  MROOM_TITLE_SUBJECT_PATTERN='([a-z' check; expect_rc 2; expect_out_has "subject-pattern is not a valid"
}

t_an_unreadable_event_fails() {
  world
  echo 'not json' >"$T/event.json"
  check; expect_rc 1; expect_out_has "Could not read the pull request from the event file"
  echo '{"pull_request": {"number": 42}}' >"$T/event.json"
  check; expect_rc 1; expect_out_has "The pull request has no title."
}

t_label_by_type() {
  world
  event "feat(api): add"
  label; expect_rc 0; expect_out "labelled type:feature"
  expect_true "did not add type:feature" [ "$(log)" = "api -X POST repos/example/shop/issues/42/labels -f labels[]=type:feature" ]
  rm -f "$FAKE/gh.log"
  event "fix!: keep the filter"
  label; expect_out "labelled type:bug"
  rm -f "$FAKE/gh.log"
  event "docs: say how"
  label; expect_out "labelled type:chore"
}

t_a_title_edit_moves_the_label() {
  world
  event "fix: keep the filter" type:feature "type:chore" regression
  label; expect_rc 0
  expect_true "did not move the label" [ "$(log)" = "$(printf '%s\n' \
    "api -X DELETE repos/example/shop/issues/42/labels/type%3Afeature" \
    "api -X DELETE repos/example/shop/issues/42/labels/type%3Achore" \
    "api -X POST repos/example/shop/issues/42/labels -f labels[]=type:bug")" ]
  expect_out_has "took off type:feature"
}

t_a_right_label_is_left_alone() {
  world
  event "feat: add" type:feature regression
  label; expect_rc 0; expect_out "already labelled type:feature"
  expect_no_file "$FAKE/gh.log"
  # GitHub's label names match without regard to case.
  event "feat: add" Type:Feature
  label; expect_rc 0; expect_out "already labelled type:feature"
  expect_no_file "$FAKE/gh.log"
}

t_no_type_no_label() {
  world
  event "Add a CSV export" type:bug
  label; expect_rc 0; expect_out "no Conventional Commit type in the title; the title check reports it"
  expect_no_file "$FAKE/gh.log"
}

t_custom_label_names() {
  world
  event "feat: add" "kind: chore"
  MROOM_LABEL_FEATURE="kind: feature" MROOM_LABEL_CHORE="kind: chore" label; expect_rc 0
  expect_true "did not use the names it was given" [ "$(log)" = "$(printf '%s\n' \
    "api -X DELETE repos/example/shop/issues/42/labels/kind%3A%20chore" \
    "api -X POST repos/example/shop/issues/42/labels -f labels[]=kind: feature")" ]
  MROOM_LABEL_BUG="type:Feature" label; expect_rc 1; expect_out_has "The three label names must differ."
  MROOM_LABEL_BUG="" label; expect_rc 1; expect_out_has "Each label name must be 1 to 50 characters"
  MROOM_LABEL_BUG=$'a\nb' label; expect_rc 1; expect_out_has "Each label name must be 1 to 50 characters"
}

t_label_failures_are_errors() {
  world
  event "feat: add" type:bug
  touch "$FAKE/down"
  label; expect_rc 1; expect_out_has "Could not take the label type:bug off; run the check again."
  event "feat: add"
  label; expect_rc 1; expect_out_has "Could not add the label type:feature; run the check again."
  echo '{"pull_request": {"title": "feat: add"}}' >"$T/event.json"
  label; expect_rc 1; expect_out_has "The event file names no pull request."
}

t_title_reader() {
  # shellcheck source=actions/pr-title/title.sh
  source "$ROOT/actions/pr-title/title.sh"
  expect_true "a squash merge's title" [ "$(cc_commit_title $'feat(api): add (#12)\n\n* one\n* two')" = "feat(api): add" ]
  expect_true "a merge commit's title" \
    [ "$(cc_commit_title $'Merge pull request #12 from me/branch\n\nfix: keep the filter\n\nmore')" = "fix: keep the filter" ]
  expect_true "a merge commit with no title" \
    [ "$(cc_commit_title 'Merge pull request #12 from me/branch')" = "Merge pull request #12 from me/branch" ]
  expect_true "a plain commit's first line" [ "$(cc_commit_title $'chore: bump\r\nbody')" = "chore: bump" ]
  expect_true "only a trailing pull request number goes" [ "$(cc_commit_title 'fix: (#3) stays')" = "fix: (#3) stays" ]
  cc_parse "feat(a b)!: x y"
  expect_true "did not read the parts" [ "$CC_TYPE|$CC_SCOPE|$CC_BREAKING|$CC_SUBJECT|$(cc_kind)" = "feat|a b|!|x y|feature" ]
  cc_parse "fix: x"; expect_true "fix is not a bug" [ "$(cc_kind)" = bug ]
  cc_parse "perf: x"; expect_true "perf is not a chore" [ "$(cc_kind)" = chore ]
  expect_true "a title with a new line parses" eval '! cc_parse $'"'"'feat: a\nb'"'"
}

t_release_notes_group_by_the_default_labels() {
  local file labels
  for file in "$ROOT/templates/release.yml" "$ROOT/.github/release.yml"; do
    labels="$(sed -n 's/^ *- "\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$file")"
    for name in type:feature type:bug type:chore regression; do
      expect_true "$file has no group for $name" grep -qxF "$name" <<<"$labels"
    done
    # Each default label of the workflow and the action is a group.
    while IFS= read -r name; do
      expect_true "$file has no group for the default $name" grep -qxF "$name" <<<"$labels"
    done < <(grep -hoE 'default: type:[a-z]+' "$W/pr-checks.yml" "$ROOT/actions/pr-type-label/action.yml" | sed 's/default: //' | sort -u)
  done
  expect_true "mroom's own release notes differ from the template" cmp -s "$ROOT/templates/release.yml" "$ROOT/.github/release.yml"
}

# job <workflow file> <job id>: the lines of that job, up to the next job.
job() { awk -v id="  $2:" '$0 == id { on = 1; next } on && /^  [a-z][a-z0-9-]*:$/ { exit } on' "$1"; }
has() { grep -qxF -- "$2" <<<"$1"; }

t_the_workflow_runs_mroom_never_the_pull_requests_code() {
  local name lines
  for name in check-title type-label; do
    lines="$(job "$W/pr-checks.yml" "$name")"
    expect_true "$name does not check out mroom's repository" has "$lines" '          repository: ${{ job.workflow_repository }}'
    expect_true "$name does not check out mroom at this file's commit" has "$lines" '          ref: ${{ job.workflow_sha }}'
    expect_true "$name keeps the token in the checkout" has "$lines" '          persist-credentials: false'
    expect_true "$name checks out more than mroom" [ "$(grep -c 'uses: actions/checkout' <<<"$lines")" = 1 ]
  done
  expect_true "pr-checks holds a secret" eval '! grep -q "secrets\." "$W/pr-checks.yml"'
  expect_true "pr-checks names an environment" eval '! grep -q "^    environment:" "$W/pr-checks.yml"'
  expect_true "pr-checks runs its steps without pipefail" eval 'grep -A2 -x "defaults:" "$W/pr-checks.yml" | grep -qx "    shell: bash"'
}

t_only_the_label_job_writes() {
  local title labels
  title="$(job "$W/pr-checks.yml" check-title)" labels="$(job "$W/pr-checks.yml" type-label)"
  expect_true "check-title may do more than read the code" \
    [ "$(awk '/^    permissions:$/ { on = 1; next } on && /^    [a-z]/ { exit } on' <<<"$title")" = "      contents: read" ]
  expect_true "type-label may do more than label" \
    [ "$(awk '/^    permissions:$/ { on = 1; next } on && /^    [a-z]/ { exit } on' <<<"$labels" | sed 's/ #.*//')" = $'      contents: read\n      pull-requests: write' ]
  expect_true "type-label runs for a fork's pull request" grep -qF "github.event.pull_request.head.repo.full_name == github.repository" <<<"$labels"
  expect_true "type-label runs for Dependabot" grep -qF "github.actor != 'dependabot[bot]'" <<<"$labels"
  expect_true "type-label runs with labels off" grep -qF "inputs.labels &&" <<<"$labels"
  expect_true "the workflow's own permissions are more than contents: read" \
    [ "$(sed -n '/^permissions:$/,/^$/p' "$W/pr-checks.yml")" = $'permissions:\n  contents: read' ]
}

t_each_input_reaches_its_action() {
  local action input
  for action in pr-title pr-type-label auto-tag; do
    while IFS= read -r input; do
      expect_true "$action declares $input but never uses it" \
        grep -qE "inputs\.$input([^a-z0-9-]|\$)" "$ROOT/actions/$action/action.yml"
    done < <(awk '/^inputs:$/ { on = 1; next } on && /^[a-z]/ { exit } on && /^  [a-z][a-z0-9-]*:$/ { sub(/^  /, ""); sub(/:$/, ""); print }' "$ROOT/actions/$action/action.yml")
    expect_true "$action's script is not executable" \
      test -x "$ROOT/actions/$action/$(grep -o '\$GITHUB_ACTION_PATH/[a-z.-]*' "$ROOT/actions/$action/action.yml" | sed 's|.*/||')"
  done
  # Each workflow input goes to the action with the same name.
  for input in types require-scope subject-pattern feature-label bug-label chore-label; do
    expect_true "pr-checks does not pass $input" grep -qF "          $input: \${{ inputs.$input }}" "$W/pr-checks.yml"
  done
  for input in tag-prefix breaking-bump other-bump dry-run; do
    expect_true "auto-tag does not pass $input" grep -qF "          $input: \${{ inputs.$input }}" "$W/auto-tag.yml"
  done
  # The defaults agree between each workflow and its action.
  for input in types subject-pattern feature-label bug-label chore-label; do
    local action_file="$ROOT/actions/pr-title/action.yml"
    case "$input" in *-label) action_file="$ROOT/actions/pr-type-label/action.yml" ;; esac
    expect_true "the default of $input differs" [ "$(awk -v k="      $input:" '$0 == k { on = 1; next } on && /default:/ { sub(/^ *default: /, ""); print; exit }' "$W/pr-checks.yml")" = \
      "$(awk -v k="  $input:" '$0 == k { on = 1; next } on && /default:/ { sub(/^ *default: /, ""); print; exit }' "$action_file")" ]
  done
}

t_the_auto_tag_runs_only_for_the_default_branch() {
  local tag
  tag="$(job "$W/auto-tag.yml" tag)"
  expect_true "auto-tag runs for more than a push to the default branch" has "$tag" \
    "    if: github.event_name == 'push' && github.ref == format('refs/heads/{0}', github.event.repository.default_branch)"
  expect_true "auto-tag runs side by side" has "$tag" "      group: mroom-auto-tag"
  expect_true "a newer auto-tag cancels a running one" has "$tag" "      cancel-in-progress: false"
  expect_true "auto-tag checks out a shallow app" has "$tag" "          fetch-depth: 0"
  expect_true "auto-tag tags another commit than the pushed one" has "$tag" '          ref: ${{ github.sha }}'
  expect_true "auto-tag may do more than push" \
    [ "$(awk '/^    permissions:$/ { on = 1; next } on && /^    [a-z]/ { exit } on' <<<"$tag" | sed 's/ #.*//')" = "      contents: write" ]
  expect_true "auto-tag holds a secret" eval '! grep -q "secrets\." "$W/auto-tag.yml"'
  expect_true "auto-tag runs its steps without pipefail" eval 'grep -A2 -x "defaults:" "$W/auto-tag.yml" | grep -qx "    shell: bash"'
  expect_true "the auto-tag is on by default" eval '! grep -rqE "uses: \./\.github/workflows/auto-tag\.yml" "$W"'
}

test_case good-titles-pass t_good_titles_pass
test_case bad-titles-fail t_bad_titles_fail
test_case title-never-printed t_the_title_is_never_printed
test_case settings t_settings
test_case wrong-setup t_a_wrong_setup_is_its_own_error
test_case unreadable-event t_an_unreadable_event_fails
test_case label-by-type t_label_by_type
test_case title-edit-moves-label t_a_title_edit_moves_the_label
test_case right-label-left-alone t_a_right_label_is_left_alone
test_case no-type-no-label t_no_type_no_label
test_case custom-label-names t_custom_label_names
test_case label-failures t_label_failures_are_errors
test_case title-reader t_title_reader
test_case release-notes t_release_notes_group_by_the_default_labels
test_case runs-mroom-only t_the_workflow_runs_mroom_never_the_pull_requests_code
test_case only-label-job-writes t_only_the_label_job_writes
test_case inputs-reach-actions t_each_input_reaches_its_action
test_case auto-tag-default-branch t_the_auto_tag_runs_only_for_the_default_branch
finish
