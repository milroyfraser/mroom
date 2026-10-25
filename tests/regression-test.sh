#!/usr/bin/env bash
# shellcheck disable=SC2317  # the t_* functions run indirectly, through test_case
# Tests for the regression label: actions/regression-label/check.sh (the pull request check) and
# tools/regressions.sh (the two measures it records). Offline: gh is a fake in $T/bin that answers from
# files in $FAKE.
set -euo pipefail
SUITE=regression
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/actions/regression-label/check.sh"
MEASURE="$ROOT/tools/regressions.sh"
NOW=1792900000 # 2026-10-25

world() {
  FAKE="$T/fake"
  export FAKE REPO=example/shop MROOM_NOW="$NOW"
  mkdir -p "$FAKE/api" "$T/bin"
  cat >"$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
# fake gh: "api <path> [--jq <filter>]" answers from $FAKE/api/<path with / as _>.json; "pr list" and
# "release list" from $FAKE/prs.json and $FAKE/releases.json.
printf '%s\n' "$*" >>"$FAKE/gh.log"
case "$1 $2" in
  "pr list") cat "$FAKE/prs.json" ;;
  "release list") cat "$FAKE/releases.json" ;;
  api\ *)
    if [ -f "$FAKE/api-down" ]; then echo "error connecting to api.github.com" >&2; exit 1; fi
    file="$FAKE/api/$(printf '%s' "$2" | tr '/' '_').json"
    [ -f "$file" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    if [ -f "$FAKE/gh-warn" ]; then echo "A new release of gh is available" >&2; fi
    if [ "${3:-}" = --jq ]; then jq -r "$4" "$file"; else cat "$file"; fi
    ;;
  *) echo "fake gh: unexpected: $*" >&2; exit 1 ;;
esac
EOF
  chmod +x "$T/bin/gh"
  export PATH="$T/bin:$PATH"
  release v1.2.3 2026-10-13T10:02:11Z
  echo '{"name": "regression"}' >"$FAKE/api/repos_example_shop_labels_regression.json"
}

# release <tag> <published_at or null>: a release the fake API knows.
release() {
  local at='"'"$2"'"'
  [ "$2" = null ] && at=null
  printf '{"tag_name": "%s", "published_at": %s}\n' "$1" "$at" >"$FAKE/api/repos_example_shop_releases_tags_$1.json"
}

# event <body> [label...]: the pull_request event the check reads.
event() {
  local body="$1"
  shift
  jq -n --arg b "$body" '{pull_request: {body: $b, labels: ($ARGS.positional | map({name: .}))}}' --args "$@" >"$T/event.json"
}

check() { run "$CHECK" "$T/event.json"; }

t_unmarked_pr_passes() {
  world
  event "Fixes the export button." type:bug
  check; expect_rc 0; expect_out "not marked as a regression fix: nothing to check"
  expect_no_file "$FAKE/gh.log"
}

t_label_and_release() {
  world
  event $'## Summary\r\nFixes the export.\r\n\r\nbreaks: v1.2.3\r\n' regression
  check; expect_rc 0; expect_out "regression fix: the problem shipped in v1.2.3 (released 2026-10-13T10:02:11Z)"
}

t_label_needs_a_release() {
  world
  event "Fixes the export." regression
  check; expect_rc 1
  expect_out "::error title=regression label::This PR has the regression label but names no release. Add a line 'Breaks: v1.2.3' with the release that shipped the problem."
}

t_release_needs_the_label() {
  world
  event $'Breaks: v1.2.3' type:bug
  check; expect_rc 1; expect_out_has "names the release it fixes (v1.2.3) but has no regression label"
  expect_out_has "gh label create regression"
}

t_release_must_be_one_tag() {
  world
  local bad
  for bad in 'v1.2.3 and v1.2.4' "\$(touch $T/ran)" '../../secrets' 'v1.2.3?x=1'; do
    event "Breaks: $bad" regression
    check; expect_rc 1; expect_out "::error title=regression label::The Breaks line must name one release tag, such as 'Breaks: v1.2.3'."
  done
  expect_no_file "$T/ran"
}

t_release_must_exist_and_be_published() {
  world
  event "Breaks: v9.9.9" regression
  check; expect_rc 1; expect_out_has "v9.9.9 is not a published release of example/shop."
  release v2.0.0 null
  event "Breaks: v2.0.0" regression
  check; expect_rc 1; expect_out_has "v2.0.0 is a draft release of example/shop"
  touch "$FAKE/api-down"
  event "Breaks: v1.2.3" regression
  check; expect_rc 1; expect_out_has "Could not look up the release v1.2.3 of example/shop; run the check again."
}

t_reported() {
  world
  event $'Breaks: v1.2.3\nReported: 2026-10-14T08:00Z' regression
  check; expect_rc 0; expect_out_has ", first reported 2026-10-14T08:00Z"
  event $'Breaks: v1.2.3\nReported: 2026-10-13' regression
  check; expect_rc 0; expect_out_has "first reported 2026-10-13"
  event $'Breaks: v1.2.3\nReported: 2026-10-12T23:00:00Z' regression
  check; expect_rc 1; expect_out_has "Reported (2026-10-12T23:00:00Z) is before v1.2.3 was released"
  event $'Breaks: v1.2.3\nReported: 2026-12-01' regression
  check; expect_rc 1; expect_out_has "Reported (2026-12-01) is in the future."
  event $'Breaks: v1.2.3\nReported: yesterday at noon' regression
  check; expect_rc 1; expect_out_has "The Reported line must be a date or a UTC time"
  case "$out" in *yesterday*) fail "echoed the PR's text" ;; *) ok ;; esac
}

t_body_cannot_send_workflow_commands() {
  world
  event $'::add-mask::x\n::set-output name=a::b\nBreaks: v1.2.3' regression
  check; expect_rc 0
  case "$out" in *"::add-mask"* | *"::set-output"*) fail "printed text from the PR body" ;; *) ok ;; esac
}

t_gh_warnings_are_not_the_date() {
  world
  touch "$FAKE/gh-warn"
  event $'Breaks: v1.2.3\nReported: 2026-10-14' regression
  check; expect_rc 0; expect_out "regression fix: the problem shipped in v1.2.3 (released 2026-10-13T10:02:11Z), first reported 2026-10-14"
}

t_custom_label() {
  world
  event "Breaks: v1.2.3" prod-bug
  REGRESSION_LABEL=prod-bug run "$CHECK" "$T/event.json"; expect_rc 0; expect_out_has "regression fix"
}

t_measures() {
  world
  jq -n '[
    {number: 12, title: "fix: export", url: "u", createdAt: "2026-10-15T09:00:00Z", body: "Breaks: v1.2.3\nReported: 2026-10-13T16:02:11Z"},
    {number: 11, title: "fix: totals", url: "u", createdAt: "2026-10-14T10:02:11Z", body: "Breaks: v1.2.3"},
    {number: 13, title: "fix: login", url: "u", createdAt: "2026-10-21T00:00:00Z", body: "Breaks: v1.3.0"},
    {number: 14, title: "fix: old", url: "u", createdAt: "2026-10-22T00:00:00Z", body: "Breaks: v0.9.0"}
  ]' >"$FAKE/prs.json"
  jq -n '[
    {tagName: "v1.4.0", publishedAt: "2026-10-22T08:00:00Z", isDraft: false},
    {tagName: "v1.3.0", publishedAt: "2026-10-20T12:00:00Z", isDraft: false},
    {tagName: "v1.2.3", publishedAt: "2026-10-13T10:02:11Z", isDraft: false},
    {tagName: "v1.5.0", publishedAt: "", isDraft: true},
    {tagName: "v1.0.0", publishedAt: "2026-06-01T00:00:00Z", isDraft: false}
  ]' >"$FAKE/releases.json"
  run "$MEASURE" example/shop 2026-10-01; expect_rc 0
  expect_out_has "Regression fixes merged since 2026-10-01 in example/shop:"
  expect_out_has "  #11  v1.2.3, released 2026-10-13 10:02 UTC, reported after 1d: fix: totals"
  expect_out_has "  #12  v1.2.3, released 2026-10-13 10:02 UTC, reported after 6h: fix: export"
  expect_out_has "  #13  v1.3.0, released 2026-10-20 12:00 UTC, reported after 12h: fix: login"
  expect_out_has "  #14  v0.9.0: not a published release of this repository: fix: old"
  expect_out_has "Releases published since 2026-10-01: 3; with a reported problem: 2"
  expect_out_has "Production problems per release: 1 (3 over 3)"
  expect_out_has "Time from a release to the first report of a problem: median 12h, longest 1d (3 problems)"
  if grep -q -- '--label regression --search merged:>=2026-10-01' "$FAKE/gh.log"; then ok; else fail "gh was not asked for the label"; fi
}

t_measures_with_nothing() {
  world
  echo '[]' >"$FAKE/prs.json"
  echo '[{"tagName": "v1.2.3", "publishedAt": "2026-10-13T10:02:11Z", "isDraft": false}]' >"$FAKE/releases.json"
  run "$MEASURE" example/shop 2026-10-01; expect_rc 0
  expect_out_has "  none"
  expect_out_has "Production problems per release: 0 (0 over 1)"
  expect_out_has "Time from a release to the first report of a problem: no problems reported"
  run "$MEASURE" example/shop 1 October; expect_rc 2; expect_err_has "<since> must be a date"
  rm "$FAKE/api/repos_example_shop_labels_regression.json"
  run "$MEASURE" example/shop 2026-10-01; expect_rc 0
  expect_out_has "Production problems per release: not recorded: example/shop has no regression label yet"
  expect_out_has "Time from a release to the first report of a problem: not recorded"
}

t_titles_are_cleaned() {
  world
  jq -n '[{number: 7, title: "fix: \u001b[2Jwipe the screen", url: "u", createdAt: "2026-10-14T10:02:11Z", body: "Breaks: v1.2.3"}]' >"$FAKE/prs.json"
  echo '[{"tagName": "v1.2.3", "publishedAt": "2026-10-13T10:02:11Z", "isDraft": false}]' >"$FAKE/releases.json"
  run "$MEASURE" example/shop 2026-10-01; expect_rc 0
  expect_out_has "#7  v1.2.3, released 2026-10-13 10:02 UTC, reported after 1d: fix:  [2Jwipe the screen"
  case "$out" in *$'\e'*) fail "printed a control character from a PR title" ;; *) ok ;; esac
}

test_case unmarked-pr-passes t_unmarked_pr_passes
test_case label-and-release t_label_and_release
test_case label-needs-a-release t_label_needs_a_release
test_case release-needs-the-label t_release_needs_the_label
test_case release-must-be-one-tag t_release_must_be_one_tag
test_case release-must-exist-and-be-published t_release_must_exist_and_be_published
test_case reported t_reported
test_case body-cannot-send-workflow-commands t_body_cannot_send_workflow_commands
test_case gh-warnings-are-not-the-date t_gh_warnings_are_not_the_date
test_case custom-label t_custom_label
test_case measures t_measures
test_case measures-with-nothing t_measures_with_nothing
test_case titles-are-cleaned t_titles_are_cleaned
finish
