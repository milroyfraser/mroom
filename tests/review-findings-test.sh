#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2016  # t_* run through test_case; a $ in single quotes is the YAML's or jq's own
# Tests for review findings: the evaluation (actions/review-findings/evaluate.jq, with findings.jq), the script
# that posts the check run (review-findings.sh), and the shape of the reusable workflow. Offline: gh is a fake
# in $T/bin that answers from $FAKE and logs each call.
set -euo pipefail
SUITE=review-findings
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

A="$ROOT/actions/review-findings"
WF="$ROOT/.github/workflows/review-findings.yml"
HEAD="aaaaaaa1$(printf '1%.0s' {1..32})"
OLD="bbbbbbb2$(printf '2%.0s' {1..32})"

# evaluate <comments as a JSON array> [reviewer]: what evaluate.jq makes of them, in $out.
evaluate() {
  out="$(jq -n --arg head "$HEAD" --argjson c "$1" '{head_sha: $head, comments: $c}' |
    jq -L "$A" --arg reviewer "${2:-claude[bot]}" -f "$A/evaluate.jq")"
}
# verdict <what it means> <jq expression that must hold for $out>
verdict() {
  if jq -e "$2" >/dev/null <<<"$out"; then ok; else rc=0 err=""; fail "$1: $2"; fi
}

# A comment as the API gives it; created_at orders them.
comment() { jq -n --arg login "$1" --arg at "$2" --arg body "$3" '{login: $login, created_at: $at, body: $body, html_url: "https://gh/c/\($at)"}'; }
review() { comment "${4:-claude[bot]}" "$1" "$2"$'\n\n'"<!-- claude-review sha=$3 -->"; }
list() { jq -s . "$@"; }

FULL_RED=$'## Code review\n\n### 🔴 Blocking\n\n- `a.php:3` — SQL built from input.\n- `b.php:9` — no auth check.\n\n### 🟡 Optional\n\n- naming'
FOLLOWUP_OK=$'## Follow-up review\n\n- ✅ `a.php:3` — fixed, now bound.\n- 💬 `b.php:9` — answered: the route is behind the gate.'
FOLLOWUP_OPEN=$'## Follow-up review\n\n1. ✅ `a.php:3` — fixed.\n2. ❌ `b.php:9` — still open: no check added.\n\n🔴 `c.php:1` — new: the token is logged.'
UNREADABLE=$'Looks fine overall, a few thoughts below.\n\nNothing else.'
NONE_BLOCKING=$'No blocking findings.\n\n🟡 a name could be clearer.'
TABLE_HEAD=$'## Review findings and how each was resolved\n\nReview of the whole PR.\n\n| # | Finding | Resolution |\n|---|---|---|'

t_reviews() {
  evaluate '[]'
  verdict "no comments" '.conclusion == "neutral" and (.title | test("Not reviewed yet: no Claude review or findings table")) and (.summary | test("no review comment found")) and (.summary | test("no \"Review findings"))'
  evaluate "$(list <(review 2026-01-01T00:00:00Z "$FULL_RED" "$HEAD"))"
  verdict "two open 🔴" '.conclusion == "failure" and (.title | startswith("2 blocking findings open")) and (.summary | test("https://gh/c/2026-01-01T00:00:00Z")) and (.summary | test("`aaaaaaa` \\(the head\\)"))'
  evaluate "$(list <(review 2026-01-01T00:00:00Z "$FULL_RED" "$OLD") <(review 2026-01-02T00:00:00Z "$FOLLOWUP_OK" "$HEAD"))"
  verdict "a follow-up all ✅/💬 replaces the red review" '.conclusion == "success" and .title == "No open review findings" and (.summary | test("2026-01-02")) and (.summary | test("2026-01-01") | not)'
  evaluate "$(list <(review 2026-01-01T00:00:00Z "$FULL_RED" "$OLD") <(review 2026-01-02T00:00:00Z "$FOLLOWUP_OPEN" "$HEAD"))"
  verdict "a follow-up with one ❌ and one new 🔴" '.conclusion == "failure" and (.title | startswith("2 blocking findings open"))'
  evaluate "$(list <(review 2026-01-01T00:00:00Z "$FOLLOWUP_OK" "$OLD") <(review 2026-01-02T00:00:00Z "$FULL_RED" "$OLD"))"
  verdict "only the latest review counts, and an earlier commit is named" '.conclusion == "failure" and (.summary | test("`bbbbbbb` \\(an earlier commit; the head is `aaaaaaa`\\)"))'
  evaluate "$(list <(review 2026-01-02T00:00:00Z "$FOLLOWUP_OK" "$HEAD") <(review 2026-01-01T00:00:00Z "$FULL_RED" "$OLD"))"
  verdict "latest by created_at, not list order" '.conclusion == "success"'
  evaluate "$(list <(review 2026-01-01T00:00:00Z "$NONE_BLOCKING" "$HEAD"))"
  verdict "No blocking findings first" '.conclusion == "success"'
  evaluate "$(list <(comment someone 2026-01-03T00:00:00Z "$FULL_RED"))"
  verdict "🔴 text from another author, no marker: not a review" '.conclusion == "neutral"'
  evaluate "$(list <(review 2026-01-03T00:00:00Z "$FULL_RED" "$HEAD" someone))"
  verdict "the marker from another author: not a review" '.conclusion == "neutral"'
  evaluate "$(list <(review 2026-01-01T00:00:00Z "$UNREADABLE" "$HEAD"))"
  verdict "an unreadable review" '.conclusion == "neutral" and (.title | test("not recognised")) and (.summary | test("format not recognised"))'
  evaluate "$(list <(review 2026-01-01T00:00:00Z "$UNREADABLE" "$HEAD") <(comment dev 2026-01-02T00:00:00Z "$TABLE_HEAD"$'\n| 1 | thing | open |'))"
  verdict "an unreadable review plus an open row: failure wins" '.conclusion == "failure"'
}

t_another_reviewer() {
  evaluate "$(list <(review 2026-01-01T00:00:00Z "$FULL_RED" "$HEAD" 'review-bot[bot]'))" 'review-bot[bot]'
  verdict "the reviewer input is not read" '.conclusion == "failure"'
  evaluate "$(list <(review 2026-01-01T00:00:00Z "$FULL_RED" "$HEAD"))" 'review-bot[bot]'
  verdict "claude[bot] counts when another reviewer is named" '.conclusion == "neutral"'
}

t_tables() {
  evaluate "$(list <(comment dev 2026-01-02T00:00:00Z "$TABLE_HEAD"$'\n| 1 | SQL built from input | ✅ Fixed |\n| 2 | No auth check | Will do later |\n| 3 | Naming | ➖ No change needed |'))"
  verdict "a row lacking ✅/➖" '.conclusion == "failure" and .title == "1 unresolved row in the findings table"
    and (.summary | test("1 of 3 rows unresolved")) and (.summary | test("2 · No auth check · Will do later"))
    and (.summary | test("SQL built") | not)'
  evaluate "$(list <(comment dev 2026-01-02T00:00:00Z "$TABLE_HEAD"$'\n| 1 | a | ✅ Fixed |\n| 2 | b | ➖ Not applicable |'))"
  verdict "all ✅/➖" '.conclusion == "success" and (.summary | test("all 2 rows resolved"))'
  evaluate "$(list <(comment dev 2026-01-02T00:00:00Z "$TABLE_HEAD"))"
  verdict "zero data rows" '.conclusion == "success" and (.summary | test("no rows"))'
  # Escaped pipes stay in a cell; ✅ in any column resolves a row; ragged pipes and spaces.
  local odd=$'**Review findings and how each was resolved:**\n\n|   Severity | Finding |   Status   |\n| :--- | :---: | ---: |\n|  🔴  |  `a \\| b` in the parser  |  still open  |\n🟡 | ✅ fixed in the finding column | |\n|   🔴 | x | ➖ |'
  evaluate "$(list <(comment dev 2026-01-02T00:00:00Z "$odd"))"
  verdict "bold heading, escaped pipes, emoji in another column" '.conclusion == "failure" and (.summary | test("1 of 3 rows unresolved"))
    and (.summary | test("🔴 · `a \\| b` in the parser · still open"))'
  evaluate "$(list <(comment dev 2026-01-01T00:00:00Z "$TABLE_HEAD"$'\n| 1 | a | open |') \
    <(comment dev2 2026-01-02T00:00:00Z "$(tr '[:upper:]' '[:lower:]' <<<"${TABLE_HEAD/## /### }")"$'\n| 1 | a | ✅ fixed |'))"
  verdict "a newer table replaces an older one (heading in any case)" '.conclusion == "success" and (.summary | test("2026-01-02"))'
  evaluate "$(list <(comment dev 2026-01-02T00:00:00Z "$TABLE_HEAD"$'\n| 1 | a | ✅ |\n\nNotes after.\n\n| other | table |\n|---|---|\n| x | open |'))"
  verdict "rows stop at the end of the first table" '.conclusion == "success"'
  evaluate "$(list <(comment dev 2026-01-02T00:00:00Z $'## Review findings\n\n| # | Finding | Resolution |\n|---|---|---|\n| 1 | a | open |'))"
  verdict "another heading is not the findings table" '.conclusion == "neutral" and (.summary | test("no \"Review findings and how"))'
}

t_summary_is_safe_and_bounded() {
  evaluate "$(list <(comment dev 2026-01-02T00:00:00Z "$TABLE_HEAD"$'\n| 1 | ping @someone and @org/team <script>alert(1)</script> & co | open |'))"
  verdict "mentions and HTML" '(.summary | test("@[a-z]") | not) and (.summary | test("@​someone")) and (.summary | test("@​org/team"))
    and (.summary | test("<script") | not) and (.summary | test("&lt;script&gt;alert\\(1\\)&lt;/script&gt; &amp; co"))'
  local rows
  rows="$(for i in $(seq 1 30); do printf '\n| %s | finding %s | open |' "$i" "$i"; done)"
  evaluate "$(list <(review 2026-01-01T00:00:00Z "$FULL_RED" "$HEAD") <(comment dev 2026-01-02T00:00:00Z "$TABLE_HEAD$rows"))"
  verdict "both red, bounded" '.conclusion == "failure" and .title == "2 blocking findings open in the Claude review · 30 unresolved rows in the findings table"
    and (.summary | split("\n") | length) <= 22 and (.summary | test("… and 15 more"))'
}

world() {
  FAKE="$T/fake"
  export FAKE REPO=example/shop
  mkdir -p "$FAKE" "$T/bin"
  list <(review 2026-01-01T00:00:00Z "$FULL_RED" "$HEAD") >"$FAKE/comments.json"
  jq -n '[{state: "closed", head: {sha: "'"$HEAD"'"}, number: 6}, {state: "open", head: {sha: "'"$OLD"'"}, number: 8},
    {state: "open", head: {sha: "'"$HEAD"'"}, number: 7}]' >"$FAKE/pulls.json"
  cat >"$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
# fake gh: logs each call to $FAKE/gh.log. pulls/<N> answers the head from $FAKE/head (null without it),
# issues/<N>/comments from $FAKE/comments.json (the API's shape), commits/<sha>/pulls from $FAKE/pulls.json, and
# a POST to check-runs keeps its input in $FAKE/posted. With $FAKE/down every call fails.
printf '%s\n' "$*" >>"$FAKE/gh.log"
if [ -f "$FAKE/down" ]; then echo "error connecting to api.github.com" >&2; exit 1; fi
jqf="" path="" method=GET
shift
while [ "$#" -gt 0 ]; do
  case "$1" in
    --jq) jqf="$2"; shift 2 ;;
    -X) method="$2"; shift 2 ;;
    --input) shift 2 ;;
    --paginate) shift ;;
    *) path="$1"; shift ;;
  esac
done
answer() { jq -r "($jqf) | if type == \"string\" then . else tojson end"; }
case "$method $path" in
  "GET repos/example/shop/pulls/"*)
    if [ -f "$FAKE/head" ]; then jq -n --arg s "$(cat "$FAKE/head")" '{head: {sha: $s}}' | answer; else echo null; fi ;;
  "GET repos/example/shop/issues/"*/comments\?per_page=100)
    jq '[.[] | {user: {login: .login}, body, html_url, created_at}]' "$FAKE/comments.json" | answer ;;
  "GET repos/example/shop/commits/"*/pulls) answer <"$FAKE/pulls.json" ;;
  "POST repos/example/shop/check-runs") cat >"$FAKE/posted"; jq -r .conclusion "$FAKE/posted" | sed 's|$|: https://gh/run|' ;;
  *) echo "fake gh: unexpected: $method $path" >&2; exit 1 ;;
esac
EOF
  chmod +x "$T/bin/gh"
  echo "$HEAD" >"$FAKE/head"
  export PATH="$T/bin:$PATH"
}

script() { run "$A/review-findings.sh" "$@"; }

t_dry_run_and_post() {
  world
  REVIEW_FINDINGS_DRY_RUN=1 script 7; expect_rc 0
  verdict "the dry run's check run" ".name == \"Review findings\" and .head_sha == \"$HEAD\" and .status == \"completed\" and .conclusion == \"failure\" and (.output.title | length > 0) and (.output.summary | length > 0)"
  expect_no_file "$FAKE/posted"
  script 7; expect_rc 0; expect_out "failure: https://gh/run"
  out="$(cat "$FAKE/posted")"
  verdict "the posted check run" ".name == \"Review findings\" and .head_sha == \"$HEAD\" and .conclusion == \"failure\""
  expect_true "did not read the head from the pull request" grep -qx "api repos/example/shop/pulls/7 --jq .head.sha" "$FAKE/gh.log"
  # Another reviewer and another check name.
  MROOM_REVIEWER='review-bot[bot]' MROOM_CHECK_NAME="Open findings" REVIEW_FINDINGS_DRY_RUN=1 script 7
  verdict "the inputs are not read" '.name == "Open findings" and .conclusion == "neutral"'
}

t_events() {
  world
  echo '{"pull_request": {"number": 7}}' >"$T/event.json"
  REVIEW_FINDINGS_DRY_RUN=1 script --event "$T/event.json"; expect_rc 0
  verdict "a pull request event" ".head_sha == \"$HEAD\""
  echo '{"issue": {"number": 7, "pull_request": {}}}' >"$T/event.json"
  REVIEW_FINDINGS_DRY_RUN=1 script --event "$T/event.json"; expect_rc 0
  verdict "a pull request's comment" ".head_sha == \"$HEAD\""
  rm -f "$FAKE/gh.log"
  echo '{"issue": {"number": 7}}' >"$T/event.json"
  script --event "$T/event.json"; expect_rc 0; expect_out_has "no open pull request for this event"
  expect_no_file "$FAKE/gh.log"
  echo '{"workflow_run": {"head_sha": "'"$OLD"'", "pull_requests": [{"number": 7}]}}' >"$T/event.json"
  REVIEW_FINDINGS_DRY_RUN=1 script --event "$T/event.json"; expect_rc 0
  verdict "a review run that names its pull request" ".head_sha == \"$HEAD\""
  # A fork's pull request: the review run names none, its head commit finds it (the open one with that head).
  echo '{"workflow_run": {"head_sha": "'"$HEAD"'", "pull_requests": []}}' >"$T/event.json"
  REVIEW_FINDINGS_DRY_RUN=1 script --event "$T/event.json"; expect_rc 0
  verdict "a review run found by its commit" ".head_sha == \"$HEAD\""
  expect_true "did not check pull request 7" grep -qx "api repos/example/shop/pulls/7 --jq .head.sha" "$FAKE/gh.log"
  expect_true "checked a closed or another pull request" eval '! grep -qE "pulls/(6|8) " "$FAKE/gh.log"'
  echo '{"workflow_run": {"head_sha": "not-a-sha", "pull_requests": []}}' >"$T/event.json"
  script --event "$T/event.json"; expect_rc 0; expect_out_has "nothing to check"
  echo '{"pull_request": {"number": "7; x"}}' >"$T/event.json"
  script --event "$T/event.json"; expect_rc 1; expect_err_has "Not a pull request number"
}

t_pr_for_sha() {
  world
  script --pr-for-sha "$HEAD"; expect_rc 0; expect_out 7
  script --pr-for-sha "$HEAD; x"; expect_rc 2
}

t_refusals_and_failures() {
  world
  script '7; rm -rf /'; expect_rc 2; expect_err_has "usage"
  REPO='' GITHUB_REPOSITORY='' script 7; expect_rc 2; expect_err_has "REPO (owner/repo) is not set"
  MROOM_REVIEWER='a b' script 7; expect_rc 2; expect_err_has "reviewer must be a GitHub login"
  MROOM_CHECK_NAME=$'a\nb' script 7; expect_rc 2; expect_err_has "check-name must be one line"
  rm "$FAKE/head"
  script 7; expect_rc 1; expect_err_has "No head commit for pull request 7"
  echo "$HEAD" >"$FAKE/head"
  touch "$FAKE/down"
  script 7; expect_rc 1; expect_err_has "Could not read pull request 7"
  expect_no_file "$FAKE/posted"
}

t_large_comments_go_through_stdin() {
  world
  # Over Linux's 128 KiB limit on one argument and macOS's 1 MiB for them all; the fixture is made from files
  # for the same reason.
  head -c 700000 /dev/zero | tr '\0' 'x' >"$T/big"
  jq -n --rawfile big "$T/big" --arg red "$FULL_RED" --arg head "$HEAD" '[
    {login: "claude[bot]", created_at: "2026-01-01T00:00:00Z", html_url: "https://gh/c/1",
     body: ($red + "\n\n" + $big + "\n\n<!-- claude-review sha=\($head) -->")},
    {login: "dev", created_at: "2026-01-02T00:00:00Z", html_url: "https://gh/c/2", body: $big}]' >"$FAKE/comments.json"
  expect_true "the fixture is not large" [ "$(wc -c <"$FAKE/comments.json")" -gt 1400000 ]
  REVIEW_FINDINGS_DRY_RUN=1 script 7; expect_rc 0
  verdict "a large comment" '.conclusion == "failure"'
}

# job <workflow file> <job id>: the lines of that job, up to the next job.
job() { awk -v id="  $2:" '$0 == id { on = 1; next } on && /^  [a-z][a-z0-9-]*:$/ { exit } on' "$1"; }
has() { grep -qxF -- "$2" <<<"$1"; }

t_workflow_shape() {
  local lines
  lines="$(job "$WF" check)"
  expect_true "the check checks out more than mroom" [ "$(grep -c 'uses: actions/checkout' "$WF")" = 1 ]
  expect_true "the check does not check out mroom" has "$lines" '          repository: ${{ job.workflow_repository }}'
  expect_true "the check does not check out mroom at this file's commit" has "$lines" '          ref: ${{ job.workflow_sha }}'
  expect_true "the checkout keeps the token" has "$lines" '          persist-credentials: false'
  expect_true "the check holds a secret" eval '! grep -q "secrets\." "$WF" "$A/action.yml"'
  expect_true "the workflow names an environment" eval '! grep -q "environment:" "$WF"'
  expect_true "the check's permissions changed" \
    [ "$(awk '/^    permissions:$/ { on = 1; next } on && /^    [a-z]/ { exit } on' <<<"$lines" | sed 's/ *#.*//')" = \
      $'      contents: read\n      pull-requests: read\n      issues: read\n      checks: write' ]
  expect_true "the workflow's own permissions are more than contents: read" \
    [ "$(sed -n '/^permissions:$/,/^$/p' "$WF")" = $'permissions:\n  contents: read' ]
  expect_true "two checks of one pull request run side by side" grep -qF '      group: mroom-review-findings-${{ github.event.pull_request.number || github.event.issue.number || github.event.workflow_run.pull_requests[0].number || github.event.workflow_run.head_sha }}' <<<"$lines"
  expect_true "a newer check does not replace an older one" has "$lines" "      cancel-in-progress: true"
  expect_true "an issue's comments wake the check" grep -qF "github.event.issue.pull_request && (" <<<"$lines"
  expect_true "the reviewer's comments do not wake the check" grep -qF "github.event.comment.user.login == inputs.reviewer" <<<"$lines"
  expect_true "a table edited away does not wake the check" grep -qF "contains(github.event.changes.body.from, 'how each was resolved')" <<<"$lines"
  local input
  for input in reviewer check-name; do
    expect_true "the workflow does not pass $input" grep -qF "          $input: \${{ inputs.$input }}" "$WF"
    expect_true "the action does not use $input" grep -qF "\${{ inputs.$input }}" "$A/action.yml"
    expect_true "the default of $input differs" [ "$(awk -v k="      $input:" '$0 == k { on = 1; next } on && /default:/ { sub(/^ *default: /, ""); print; exit }' "$WF")" = \
      "$(awk -v k="  $input:" '$0 == k { on = 1; next } on && /default:/ { sub(/^ *default: /, ""); print; exit }' "$A/action.yml")" ]
  done
  expect_true "the script is not executable" test -x "$A/review-findings.sh"
  expect_true "the action does not read the event file" grep -qF -- '--event "$GITHUB_EVENT_PATH"' "$A/action.yml"
}

test_case reviews t_reviews
test_case another-reviewer t_another_reviewer
test_case tables t_tables
test_case summary-safe t_summary_is_safe_and_bounded
test_case dry-run-and-post t_dry_run_and_post
test_case events t_events
test_case pr-for-sha t_pr_for_sha
test_case refusals t_refusals_and_failures
test_case large-comments t_large_comments_go_through_stdin
test_case workflow-shape t_workflow_shape
finish
