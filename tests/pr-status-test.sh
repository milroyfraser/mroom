#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2329,SC2016  # t_* run through test_case; a $ in single quotes is jq's own
# Tests for the PR status notes and their pings (actions/pr-status): what render.jq makes of a PR's facts, and what
# pr-status.sh does with the note and the pings across runs. Offline: GitHub (as gh) and chat (as curl) are one
# fake world, tests/fakes/pr-status.py, which keeps what the calls change, so a second run sees the first one's
# note. Every id, name and token is made up.
set -euo pipefail
SUITE=pr-status
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
skip_unless has_tomllib "python3 has no tomllib (needs 3.11+)"

A="$ROOT/actions/pr-status"
WF="$ROOT/.github/workflows/pr-status.yml"
HEAD="aaaaaaa1$(printf '1%.0s' {1..32})"
OLD="bbbbbbb2$(printf '2%.0s' {1..32})"
CHAT_TOKEN="xoxb-fake-chat-0123456789"
GH="https://github.com/example/shop"
QA_READY=$'### QA environment\n<!-- mroom-qa: ready -->\n\n| | |\n|---|---|\n| App | https://42.qa.example.dev |\n| API | https://api.42.qa.example.dev |\n\nUpdated for `'"$HEAD"'`. Every push that needs it refreshes it.'

# world [<extra mroom.toml lines>]: a green PR #42 by dev1: required checks pass, a review with no blocking
# findings, the environment up at the head, browser QA passed. Each test changes it with world_set.
world() {
  mkdir -p "$T/bin" "$T/tmp"
  printf '#!/bin/sh\nexec python3 -I "%s" gh "$@"\n' "$ROOT/tests/fakes/pr-status.py" >"$T/bin/gh"
  printf '#!/bin/sh\nexec python3 -I "%s" curl "$@"\n' "$ROOT/tests/fakes/pr-status.py" >"$T/bin/curl"
  chmod +x "$T/bin/gh" "$T/bin/curl"
  export PATH="$T/bin:$PATH" TMPDIR="$T/tmp" PRS_STATE="$T/world.json" PRS_LOG="$T/calls.jsonl" PRS_ARGV="$T/argv.jsonl"
  export GITHUB_REPOSITORY=example/shop GH_TOKEN=fake-gh-token MROOM_CONFIG="$T/mroom.toml" MROOM_NOW=1793188800
  export SLACK_BOT_TOKEN="$CHAT_TOKEN" MROOM_PR_STATUS_LIVE=1
  unset MROOM_PR_STATUS_DRY_RUN MROOM_DEFAULT_BRANCH
  : >"$T/calls.jsonl"
  : >"$T/argv.jsonl"
  {
    printf '[app]\nname = "shop"\n\n'
    printf '[issues]\nid_pattern = "SHOP-[0-9]+"\nurl = "https://tracker.example.dev/issue/{id}"\n\n'
    printf '[persona]\nname = "Bot One"\nchannel = "C0123456789"\n\n'
    printf '[github]\nagent_login = "shop-agents"\n'
    [ -z "${1:-}" ] || printf '%s\n' "$1"
  } >"$T/mroom.toml"
  jq -n --arg head "$HEAD" --arg gh "$GH" --arg qa "$QA_READY" '{
    repo: "example/shop", default_branch: "main", next_id: 900,
    pulls: {"42": {number: 42, title: "feat(SHOP-12): a cart", body: "Adds a cart.\n\nIssue: SHOP-12",
      html_url: "\($gh)/pull/42", user: {login: "dev1"}, draft: false, state: "open", merged: false, closed_at: null,
      updated_at: "2026-10-28T11:00:00Z", head: {sha: $head, ref: "shop-12-cart"}, base: {ref: "main"}, labels: []}},
    commits: {"42": [{author: {login: "dev1"}, commit: {author: {email: "dev1@example.dev"}}},
                     {author: {login: "reviewer9"}, commit: {author: {email: "r9@example.dev"}}}]},
    users: {dev1: {name: "Dev One"}, dev2: {name: "Dev <Two>"}},
    rules: {main: [{type: "pull_request"}, {type: "required_status_checks",
      parameters: {required_status_checks: [{context: "test"}, {context: "lint"}]}}]},
    check_runs: {($head): [
      {id: 1, name: "test", status: "completed", conclusion: "success", html_url: "\($gh)/runs/1", output: {title: null}},
      {id: 2, name: "lint", status: "completed", conclusion: "success", html_url: "\($gh)/runs/2", output: {title: null}},
      {id: 3, name: "claude / review", status: "completed", conclusion: "success", html_url: "\($gh)/runs/3", output: {title: null}},
      {id: 4, name: "Review findings", status: "completed", conclusion: "success", html_url: "\($gh)/runs/4", output: {title: "No open findings"}},
      {id: 5, name: "QA (browser)", status: "completed", conclusion: "success", html_url: "\($gh)/runs/5", external_id: "554", output: {title: "3 pass"}}]},
    comments: {"42": [
      {id: 10, user: {login: "github-actions[bot]"}, body: $qa, html_url: "\($gh)/pull/42#c10", created_at: "2026-10-28T10:00:00Z"},
      {id: 11, user: {login: "claude[bot]"}, body: "No blocking findings.\n\n<!-- claude-review sha=\($head) -->",
       html_url: "\($gh)/pull/42#c11", created_at: "2026-10-28T10:30:00Z"}]},
    runs: {"qa-up.yml": [{id: 9, status: "completed", conclusion: "success", html_url: "\($gh)/actions/runs/9",
      display_title: "QA environment · PR #42", created_at: "2026-10-28T09:00:00Z", pull_requests: []}]},
    jobs: {"9": [{name: "qa / QA paths", status: "completed", conclusion: "success", html_url: "\($gh)/job/8"},
                 {name: "qa / QA deploy", status: "completed", conclusion: "success", html_url: "\($gh)/job/9"}]},
    contents: {".github/chat-users.json": "{\"dev1\": \"U0000000001\", \"dev2@example.dev\": \"U0000000002\", \"shop-agents\": \"U0000000009\", \"evil\": \"<!channel>\"}"}}' \
    >"$T/world.json"
}

# world_set [<jq option>...] <jq filter>: changes the fake's state.
world_set() { jq "$@" "$T/world.json" >"$T/world.next" && mv "$T/world.next" "$T/world.json"; }
check_set() { world_set --arg h "$HEAD" --argjson c "$1" '.check_runs[$h] |= map(if .name == $c.name then . + $c else . end)'; }
comment_add() { world_set --arg b "$2" --arg l "$1" '.comments["42"] += [{id: (.next_id), user: {login: $l}, body: $b,
  html_url: "https://github.com/example/shop/pull/42#c\(.next_id)", created_at: "2026-10-28T11:30:00Z"}] | .next_id += 1'; }
review_body() { world_set --arg b "$1" '(.comments["42"][] | select(.user.login == "claude[bot]")).body = $b'; }
qa_body() { world_set --arg b "$1" '(.comments["42"][] | select(.id == 10)).body = $b'; }
pr_set() { world_set "$@"; }

# rendered: what render.jq makes of the world's facts now, in $out (through the script's own collect).
rendered() {
  rc=0
  out="$(bash -c 'source "$1"; s="$(settings)" && collect 42 "$s" | render' _ "$A/pr-status.sh" 2>"$T/.err")" || rc=$?
  err="$(cat "$T/.err")"
}
# has_json <what it means> <jq expression that must hold for $out>
has_json() { if jq -e "$2" >/dev/null 2>&1 <<<"$out"; then ok; else fail "$1: $2"; fi; }
# line <label>: the jq expression for that section's line of the note.
line() { printf '(.body | split("\\n") | map(select(startswith("- **%s:**"))) | first)' "$1"; }
keys() { printf '(.alerts | map(.key))'; }

status() { run "$A/pr-status.sh" "$@"; }
notes() { jq -c '[.comments["42"][] | select(.user.login == "github-actions[bot]" and (.body | contains("<!-- mroom-pr-status pr=42 ")))]' "$T/world.json"; }
note_body() { jq -r '[.comments["42"][] | select(.user.login == "github-actions[bot]" and (.body | contains("mroom'"'"'s pr-status")))] | first | .body' "$T/world.json"; }
pings() { jq -c 'select(.service == "slack")' "$T/calls.jsonl"; }
count() { "$@" | wc -l | tr -d ' '; }
writes() { jq -c 'select(.service == "github" and .method != "GET")' "$T/calls.jsonl"; }
# jqt <jq option or filter>... <file or nothing>: jq -e, quietly.
jqt() { jq -e "$@" >/dev/null; }
expect_eq() { if [ "$2" = "$3" ]; then ok; else fail "$1: expected [$3], got [$2]"; fi; }

# --- The note ------------------------------------------------------------------------------------------------

t_green() {
  world; rendered; expect_rc 0
  has_json "heading" '.body | split("\n")[0] == "✅ **Bot One'"'"'s notes** · ready for review"'
  has_json "environment links and commit" "$(line Environment)"' == "- **Environment:** ✅ [app](https://42.qa.example.dev) · [API](https://api.42.qa.example.dev) · [comment](https://github.com/example/shop/pull/42#c10) · `aaaaaaa`"'
  has_json "CI count, linked to the checks" "$(line CI)"' == "- **CI:** ✅ 2/2 required pass · [checks](https://github.com/example/shop/pull/42/checks) · `aaaaaaa`"'
  has_json "review" "$(line "Claude review")"' == "- **Claude review:** ✅ [no blocking findings](https://github.com/example/shop/pull/42#c11) · `aaaaaaa`"'
  has_json "findings" "$(line "Review findings")"' == "- **Review findings:** ✅ [No open findings](https://github.com/example/shop/runs/4) · `aaaaaaa`"'
  has_json "browser QA, its run from external_id" "$(line "Browser QA")"' == "- **Browser QA:** ✅ 3 pass · [run](https://github.com/example/shop/actions/runs/554) · `aaaaaaa`"'
  has_json "no open question" '.body | contains("Open question") | not'
  has_json "the footer pr-status.sh finds a lost note by" '.body | contains("Edited in place by mroom'"'"'s pr-status")'
  has_json "no chat markup in the note" '.body | test("<https?:|<@") | not'
  has_json "one ready ping, saying what was verified, mentioning the author, linking the PR and issue" '.alerts == [{key: "once:ready:ready",
    text: "<@U0000000001> ✅ Ready for review on `aaaaaaa`: 2/2 required checks pass, Claude review: no blocking findings, review findings resolved, environment deployed at this commit, browser QA passed · <https://github.com/example/shop/pull/42|PR #42 · feat(SHOP-12): a cart> · <https://tracker.example.dev/issue/SHOP-12|SHOP-12>"}]'
}

t_issue() {
  world; pr_set '.pulls["42"].body = "Nothing here mentions SHOP-3 at the start.\n> **Linear**: shop-7 extra"'; rendered
  has_json "a label line, quoted, bold, lower case: upper-cased" '.issue.identifier == "SHOP-7"'
  pr_set '.pulls["42"].body = "see SHOP-3 here"'; rendered
  has_json "an id mid-line is not a link; the title's scope is next" '.issue.identifier == "SHOP-12"'
  pr_set '.pulls["42"].title = "fix: no scope"'; rendered
  has_json "the branch name last" '.issue == {identifier: "SHOP-12", url: "https://tracker.example.dev/issue/SHOP-12"}'
  pr_set '.pulls["42"].head.ref = "feature/shop-99-x"'; rendered
  has_json "a branch after a prefix" '.issue.identifier == "SHOP-99"'
  pr_set '.pulls["42"].head.ref = "cart"'; rendered
  has_json "none: null, and the ping links only the PR" '.issue == null and (.alerts[0].text | endswith("|PR #42 · fix: no scope>"))'
  world; toml_drop issues; rendered
  has_json "no issues.id_pattern: no issue" '.issue == null'
}
toml_drop() { python3 - "$T/mroom.toml" "$1" <<'EOF'
import sys, re
p, table = sys.argv[1:]
text = open(p).read()
open(p, "w").write(re.sub(r"\[" + table + r"\]\n(?:[^\[\n][^\n]*\n|\n)*", "", text))
EOF
}

t_ci() {
  world; check_set '{"name": "lint", "conclusion": "failure"}'; check_set '{"name": "test", "status": "in_progress", "conclusion": null}'; rendered
  has_json "failing names, still running" "$(line CI)"' == "- **CI:** ❌ failing: [lint](https://github.com/example/shop/runs/2) · 1 still running · [checks](https://github.com/example/shop/pull/42/checks) · `aaaaaaa`"'
  has_json "red heading" '.body | startswith("🔴 **Bot One'"'"'s notes** · needs the author")'
  has_json "one ping with the evidence and the question; no ready" '.alerts == [{key: "aaaaaaa11111:ci:failed",
    text: "<@U0000000001> ❌ CI failing on `aaaaaaa`: <https://github.com/example/shop/runs/2|lint> · <https://github.com/example/shop/pull/42|PR #42 · feat(SHOP-12): a cart> · <https://tracker.example.dev/issue/SHOP-12|SHOP-12>. Flaky, or a real regression? Re-run: <https://github.com/example/shop/runs/2|lint>."}]'
  world; check_set '{"name": "lint", "conclusion": "cancelled"}'; rendered
  has_json "a cancelled required check: pending, no ping" "($(line CI) | contains(\"⏳ 1/2 required pass · 1 cancelled\")) and .alerts == []"
  world; check_set '{"name": "lint", "conclusion": "skipped"}'; rendered
  has_json "a skipped one: not counted, still ready" "($(line CI) | contains(\"✅ 1/1 required pass\")) and $(keys) == [\"once:ready:ready\"]"
  world; world_set '.check_runs[.pulls["42"].head.sha] |= map(select(.name != "lint"))'; rendered
  has_json "a required check not reported yet: pending" "$(line CI) | contains(\"⏳ 1/2 required pass · 1 not reported yet\")"
  world; world_set '.check_runs[.pulls["42"].head.sha] += [{id: 99, name: "lint", status: "completed", conclusion: "failure", html_url: "https://github.com/example/shop/runs/99"}]'; rendered
  has_json "a re-run counts by its latest run" "$(line CI) | contains(\"[lint](https://github.com/example/shop/runs/99)\")"
}

t_required_list() {
  world '[pr]
required_checks = ["test"]'
  world_set '.rules.main = [{type: "pull_request"}]'; rendered
  has_json "no required checks in the rules: mroom.toml's list" "$(line CI) | startswith(\"- **CI:** ✅ 1/1 required pass · [checks]\")"
  world_set '.fail = ["GET rules/branches"]'; rendered
  has_json "rules unreadable: mroom.toml's list, said so" "$(line CI) | contains(\"the list is mroom.toml's (the ruleset did not answer)\")"
  world; world_set '.fail = ["GET rules/branches"]'; rendered
  has_json "rules unreadable and no list: unknown, never a pass, not ready" "($(line CI) | startswith(\"- **CI:** ❓ unknown: \")) and .alerts == [] and (.body | startswith(\"⏳\"))"
  world; world_set '.rules.main = []'; rendered
  has_json "no required checks anywhere: said, and ready" "($(line CI) | startswith(\"- **CI:** no required checks\")) and (.alerts[0].text | contains(\": no required checks, Claude review\"))"
}

t_review() {
  world; review_body $'## Code review\n\n### 🔴 Blocking\n\n- `a.php:3` — SQL from input.\n- `b.php:9` — no auth.\n\n### 🟡 Optional\n\n- naming\n\n<!-- claude-review sha='"$HEAD"' -->'; rendered
  has_json "blocking findings counted" "$(line "Claude review")"' == "- **Claude review:** 🔴 [2 blocking](https://github.com/example/shop/pull/42#c11) · `aaaaaaa`"'
  has_json "one blocking ping, ending in the question; no ready" "$(keys)"' == ["aaaaaaa11111:review:blocking"] and (.alerts[0].text | endswith("Fix them, or reply on the review with why one does not apply?"))'
  world; review_body $'Looks fine overall.\n\n<!-- claude-review sha='"$HEAD"' -->'; rendered
  has_json "an unreadable review: unknown, no ping, not ready" "($(line "Claude review") | startswith(\"- **Claude review:** ❓ unknown: \")) and .alerts == [] and (.body | startswith(\"⏳\"))"
  world; review_body $'No blocking findings.\n\n<!-- claude-review sha='"$OLD"' -->'; check_set '{"name": "claude / review", "status": "in_progress", "conclusion": null}'; rendered
  has_json "a review of an older commit, the head's running: reviewing" "$(line "Claude review") | startswith(\"- **Claude review:** ⏳ reviewing\")"
  check_set '{"name": "claude / review", "status": "completed", "conclusion": "skipped"}'
  review_body $'### 🔴 Blocking\n\n- `a.php:3` — SQL.\n\n<!-- claude-review sha='"$OLD"' -->'; rendered
  has_json "the head's review skipped: the earlier review's blocking findings still hold, with a question" \
    "($(line "Claude review") | contains(\"[1 blocking](\") and contains(\"(of an earlier commit)\")) and (.body | contains(\"**Open question:** the latest review is of \`bbbbbbb\`\"))"
  has_json "keyed on the reviewed commit" "$(keys) == [\"bbbbbbb22222:review:blocking\"]"
  world; world_set '.comments["42"] |= map(select(.user.login != "claude[bot]"))'; check_set '{"name": "claude / review", "conclusion": "skipped"}'; rendered
  has_json "skipped with no review at all: not run, still ready" "($(line "Claude review") | startswith(\"- **Claude review:** not run (the review skipped this PR)\")) and $(keys) == [\"once:ready:ready\"]"
  has_json "the ready ping says the review did not run" '.alerts[0].text | contains("Claude review not run")'
  world; world_set '.comments["42"] |= map(select(.user.login != "claude[bot]"))'; rendered
  has_json "the run passed but posted nothing: unknown, with a question" "($(line "Claude review") | contains(\"unknown: the run passed but posted no review\")) and (.body | contains(\"Open question\"))"
  world; review_body $'No blocking findings.\n\n<!-- claude-review sha='"$HEAD"' -->'; world_set '(.comments["42"][] | select(.user.login == "claude[bot]")).user.login = "someone"'; check_set '{"name": "claude / review", "conclusion": "failure"}'; rendered
  has_json "a review comment by anyone but the reviewer does not count" "$(line "Claude review") | startswith(\"- **Claude review:** ❌ review run failed\")"
}

t_environment() {
  world; world_set '.jobs["9"][1] += {conclusion: "failure"}'; rendered
  has_json "the deploy job failed: line, link and ping" "($(line Environment) | startswith(\"- **Environment:** ❌ deploy failed · [run](https://github.com/example/shop/job/9)\")) and $(keys) == [\"aaaaaaa11111:env:failed\"]"
  world; world_set '.runs["qa-up.yml"][0].status = "in_progress" | .jobs["9"][1] += {status: "in_progress", conclusion: null}'; rendered
  has_json "deploying; browser QA waits" "($(line Environment) | startswith(\"- **Environment:** ⏳ deploying\")) and .alerts == []"
  world; world_set '.runs["qa-up.yml"][0].status = "in_progress" | .jobs["9"] = [.jobs["9"][0]]'; rendered
  has_json "no deploy job yet: planning" "($(line Environment) | startswith(\"- **Environment:** ⏳ planning · [run](https://github.com/example/shop/actions/runs/9)\")) and .alerts == []"
  world; world_set '.runs["qa-up.yml"][0].status = "in_progress" | .jobs["9"][1] += {status: "completed", conclusion: "success"}'; rendered
  has_json "the deploy done while the run goes on: not deploying" "$(line Environment) | startswith(\"- **Environment:** ✅\")"
  world; qa_body $'### QA environment\n<!-- mroom-qa: waiting since=2026-10-28T09:00:00Z -->\n\nAll 3 QA environment slots are in use.'; rendered
  has_json "waiting for a slot: pending, browser QA waits, not ready" "($(line Environment) | startswith(\"- **Environment:** ⏳ waiting for a QA environment slot\")) and .alerts == []"
  world; qa_body "${QA_READY//$HEAD/$OLD}"; rendered
  has_json "an environment of an older commit: shown, not ready, with a question" "($(line Environment) | startswith(\"- **Environment:** ⚠️\") and endswith(\"\`bbbbbbb\`\")) and .alerts == [] and (.body | contains(\"the environment serves \`bbbbbbb\`, the head is \`aaaaaaa\`\"))"
  world; qa_body $'### QA environment\n<!-- mroom-qa: failed -->\n\nThe deploy of `'"$OLD"'` failed: the migration. The next push tries again.'
  world_set '.jobs["9"][1].conclusion = "skipped"'; rendered
  has_json "a failed environment, said by the comment: keyed on its commit" "($(line Environment) | startswith(\"- **Environment:** ❌ deploy failed · [why]\")) and $(keys) == [\"bbbbbbb22222:env:failed\"]"
  world; qa_body $'### QA environment\n<!-- mroom-qa: removed -->\n\nRemoved: closed.'; world_set '.runs["qa-up.yml"] = []'; rendered
  has_json "removed: says so, and does not hold the PR" "($(line Environment) == \"- **Environment:** removed · [why](https://github.com/example/shop/pull/42#c10)\") and $(keys) == [\"once:ready:ready\"]"
  world; world_set '.runs["qa-up.yml"] = [] | .comments["42"] |= map(select(.id != 10))'; check_set '{"name": "QA (browser)", "conclusion": "skipped", "output": {"title": "No browser test needed"}}'; rendered
  has_json "no plan and no environment: not requested, ready" "($(line Environment) == \"- **Environment:** not requested (no QA plan has run on this PR)\") and (.alerts[0].text | contains(\"browser QA not needed\"))"
  world; world_set '.comments["42"] |= map(select(.id != 10))'; rendered
  has_json "a passed deploy with no comment: unknown, never a pass, with a question" "($(line Environment) | startswith(\"- **Environment:** ❓ unknown: \")) and .alerts == [] and (.body | contains(\"Open question\"))"
  world; world_set '.comments["42"] |= map(select(.id != 10)) | .jobs["9"][1].conclusion = "skipped"'; check_set '{"name": "QA (browser)", "conclusion": "skipped"}'; rendered
  has_json "the plan said no: not needed, ready" "($(line Environment) | startswith(\"- **Environment:** not needed\")) and $(keys) == [\"once:ready:ready\"]"
  world; world_set '.runs["qa-up.yml"] += [{id: 7, status: "completed", conclusion: "failure", html_url: "x", display_title: "QA environment · PR #4", created_at: "2026-10-28T11:00:00Z", pull_requests: []}]'; rendered
  has_json "another PR's run (PR #4 for #42) is not this one's" "$(line Environment) | startswith(\"- **Environment:** ✅\")"
  world; world_set '.fail = ["GET actions/workflows"]'; rendered
  expect_out ""
  expect_err_has "HTTP 502"
}

t_no_qa_workflow() {
  world; world_set '.runs = {} | .comments["42"] |= map(select(.id != 10))'; check_set '{"name": "QA (browser)", "conclusion": "skipped"}'
  # The fake answers 404 for a workflow it has no runs list for.
  world_set '.fail = []'; rendered
  has_json "an app without the qa-up workflow: not requested" "$(line Environment) | startswith(\"- **Environment:** not requested\")"
}

t_browser() {
  world; world_set '.check_runs[.pulls["42"].head.sha] |= map(select(.name != "QA (browser)"))'; rendered
  has_json "an environment up and no browser check yet: pending, no ready" "($(line "Browser QA") | startswith(\"- **Browser QA:** ⏳ waiting for the QA (browser) check\")) and .alerts == []"
  world; check_set '{"name": "QA (browser)", "conclusion": "failure", "output": {"title": "2 pass · 1 fail"}}'; rendered
  has_json "failed: line and ping" "($(line "Browser QA") | startswith(\"- **Browser QA:** ❌ 2 pass · 1 fail · [run]\")) and $(keys) == [\"aaaaaaa11111:browser:failed\"]"
  has_json "CI green but browser QA failed: an open question" '.body | contains("**Open question:** CI is green but browser QA failed on `aaaaaaa`")'
  world; check_set '{"name": "QA (browser)", "conclusion": "neutral", "output": {"title": "fixtures missing"}}'; rendered
  has_json "not verified: ping" "$(keys) == [\"aaaaaaa11111:browser:not-verified\"]"
  world; check_set '{"name": "QA (browser)", "conclusion": "neutral", "output": {"title": "waiting for a QA environment slot"}}'; rendered
  has_json "waiting for a slot: pending, no ping" "($(line "Browser QA") | startswith(\"- **Browser QA:** ⏳\")) and .alerts == []"
  world; check_set '{"name": "QA (browser)", "conclusion": "skipped", "output": {"title": "No browser test needed"}}'; rendered
  has_json "skipped: ready, not needed" "($(line "Browser QA") | startswith(\"- **Browser QA:** not run: No browser test needed\")) and (.alerts[0].text | contains(\"browser QA not needed\"))"
  world; check_set '{"name": "QA (browser)", "external_id": "x; rm", "html_url": "https://github.com/example/shop/runs/5"}'; rendered
  has_json "an external_id that is no run id: the check's own link" "$(line "Browser QA") | contains(\"[run](https://github.com/example/shop/runs/5)\")"
}

t_findings() {
  world; check_set '{"name": "Review findings", "conclusion": "failure", "output": {"title": "1 open finding"}}'; rendered
  has_json "open findings: red, not ready, no ping of their own" "($(line "Review findings") | startswith(\"- **Review findings:** 🔴 [1 open finding]\")) and .alerts == []"
  world; check_set '{"name": "Review findings", "status": "in_progress", "conclusion": null}'; rendered
  has_json "checking: not ready" '.alerts == [] and (.body | startswith("⏳"))'
  world; check_set '{"name": "Review findings", "conclusion": "neutral", "output": {"title": "Not reviewed yet"}}'; rendered
  has_json "not reviewed yet while a review exists: unknown, not ready" '.alerts == [] and (.body | startswith("⏳"))'
  world; world_set '.comments["42"] |= map(select(.user.login != "claude[bot]"))'; check_set '{"name": "claude / review", "conclusion": "skipped"}'
  check_set '{"name": "Review findings", "conclusion": "neutral", "output": {"title": "Not reviewed yet"}}'; rendered
  has_json "not reviewed yet on a PR the review skipped: not run, ready" "($(line "Review findings") | startswith(\"- **Review findings:** not run: \")) and $(keys) == [\"once:ready:ready\"]"
}

t_final_and_draft() {
  world; pr_set '.pulls["42"] += {state: "closed", merged: true}'; rendered
  has_json "merged: final, purple, environment removed, no pings" '.final and (.body | startswith("🟣 **Bot One'"'"'s notes** · merged")) and (.body | contains("- **Environment:** removed\n")) and .alerts == []'
  pr_set '.pulls["42"].merged = false'; rendered
  has_json "closed unmerged" '.final and (.body | startswith("⚫ **Bot One'"'"'s notes** · closed"))'
  world; pr_set '.pulls["42"].draft = true'; check_set '{"name": "lint", "conclusion": "failure"}'; rendered
  has_json "draft: noted, marked, no pings" '(.body | startswith("⏸ **Bot One'"'"'s notes** · draft")) and (.body | contains("❌ failing")) and .alerts == [] and .draft'
}

t_escaping() {
  world '[pr]
required_checks = ["test", "@team **x** <b>"]'
  world_set '.fail = ["GET rules/branches"] | .check_runs[.pulls["42"].head.sha] += [{id: 30, name: "@team **x** <b>", status: "completed", conclusion: "failure", html_url: "https://github.com/example/shop/runs/30"}]'
  check_set '{"name": "QA (browser)", "conclusion": "failure", "output": {"title": "@everyone [x](https://evil.example) `y`"}}'
  pr_set '.pulls["42"].title = "<!here> & <https://evil.example|click>"'; rendered
  has_json "a check name in the note: escaped, no mention" "$(line CI) | contains(\"[@\u200bteam \\\\*\\\\*x\\\\*\\\\* \\\\<b\\\\>](https://github.com/example/shop/runs/30)\")"
  has_json "a check title in the note: escaped, no link, no mention" "$(line "Browser QA") | contains(\"@\u200beveryone \\\\[x\\\\](https://evil.example) \\\\\`y\\\\\`\")"
  has_json "the title in a ping: no broadcast, no link of its own" '[.alerts[].text | contains("&lt;!here&gt; &amp; &lt;https://evil.example¦click&gt;")] | all'
  has_json "no ping holds a raw <!" '[.alerts[].text | contains("<!")] | any | not'
  world_set '.pulls["42"].user.login = "dev2"'; rendered
  has_json "an unmapped author is named, escaped" '.alerts[0].text | startswith("Dev &lt;Two&gt; ")'
}

t_who() {
  world; pr_set '.pulls["42"].user.login = "shop-agents"'; rendered
  has_json "the agents' PR: its first commit's developer, by login" '.alerts[0].text | startswith("<@U0000000001> ")'
  world_set '.commits["42"][0] = {author: {login: "dev2"}, commit: {author: {email: "dev2@example.dev"}}}'; rendered
  has_json "by email when the map has no login for them" '.alerts[0].text | startswith("<@U0000000002> ")'
  world_set '.commits["42"][0] = {author: null, commit: {author: {email: "nobody@example.dev"}}}'; rendered
  has_json "a first commit the map does not know: the agents' account's developer" '.alerts[0].text | startswith("<@U0000000009> ")'
  world_set '.commits["42"] = [{author: {login: "shop-agents"}, commit: {author: {email: "a@example.dev"}}}, {author: {login: "dev1"}, commit: {author: {email: "dev1@example.dev"}}}]'; rendered
  has_json "a later commit never counts" '.alerts[0].text | startswith("<@U0000000009> ")'
  world; pr_set '.pulls["42"].user.login = "evil"'; rendered
  has_json "a map entry that is not a chat user id is dropped" '.alerts[0].text | startswith("evil ")'
  world_set '.contents[".github/chat-users.json"] = "not json"'; rendered
  has_json "a map that is not JSON: names instead" '.alerts[0].text | startswith("evil ")'
  expect_err_has "is not JSON"
  world; toml_drop github; pr_set '.pulls["42"].user.login = "shop-agents"'; rendered
  has_json "without github.agent_login, the author is pinged as is" '.alerts[0].text | startswith("<@U0000000009> ")'
  expect_eq "no commit lookup without github.agent_login" "$(grep -c 'pulls/42/commits' "$T/calls.jsonl" || true)" 0
}

# --- Across runs ---------------------------------------------------------------------------------------------

t_one_note_one_ping() {
  world
  status 42; expect_rc 0
  expect_eq "one note posted" "$(notes | jq length)" 1
  expect_eq "one ping" "$(count pings)" 1
  expect_true "the ping is the ready one, to persona.channel, with the bot token" \
    jqt --arg t "$CHAT_TOKEN" '.body.channel == "C0123456789" and (.body.text | contains("Ready for review")) and .auth == "Bearer \($t)" and .body.unfurl_links == false' <<<"$(pings)"
  expect_true "the hidden line records it" grep -q '<!-- mroom-pr-status pr=42 final=0 sent=once:ready:ready -->' <<<"$(note_body)"
  : >"$T/calls.jsonl"
  status 42
  expect_eq "unchanged: no write" "$(count writes)" 0
  expect_eq "unchanged: no ping" "$(count pings)" 0
  expect_err_has "note none (unchanged)"
  expect_true "the token never on a command line" bash -c '! grep -q "xoxb-fake-chat" "$1"' _ "$T/argv.jsonl"
}

t_change_edits_in_place() {
  world; status 42
  local id; id="$(notes | jq '.[0].id')"
  check_set '{"name": "lint", "conclusion": "failure"}'; : >"$T/calls.jsonl"
  status 42
  expect_eq "still one note" "$(notes | jq length)" 1
  expect_eq "the same one, edited" "$(notes | jq '.[0].id')" "$id"
  expect_eq "one PATCH, no POST" "$(writes | jq -r .method | tr '\n' ' ')" "PATCH "
  expect_eq "one ping, the CI one" "$(pings | jq -r '.body.text | split(" ")[1:3] | join(" ")')" "❌ CI"
  expect_true "recorded with the ready one" grep -q 'sent=once:ready:ready,aaaaaaa11111:ci:failed -->' <<<"$(note_body)"
  : >"$T/calls.jsonl"; status 42
  expect_eq "the same failure again: no ping" "$(count pings)" 0
  check_set '{"name": "lint", "conclusion": "success"}'; : >"$T/calls.jsonl"; status 42
  expect_eq "green again: ready does not go twice" "$(count pings)" 0
  world_set --arg o "$OLD" '.pulls["42"].head.sha = $o | .check_runs[$o] = [{id: 1, name: "test", status: "completed", conclusion: "success", html_url: "u"},
    {id: 2, name: "lint", status: "completed", conclusion: "failure", html_url: "u2"}]'
  : >"$T/calls.jsonl"; status 42
  expect_true "a new head commit's failure pings again" jqt 'select(.body.text | contains("CI failing on `bbbbbbb`"))' <<<"$(pings)"
}

t_marker_lost() {
  world; check_set '{"name": "lint", "conclusion": "failure"}'; status 42
  local id; id="$(notes | jq '.[0].id')"
  # A person edits the note and drops the hidden line.
  world_set --argjson id "$id" '(.comments["42"][] | select(.id == $id)).body |= (split("\n<!-- mroom-pr-status")[0])'
  check_set '{"name": "test", "conclusion": "failure"}'; : >"$T/calls.jsonl"
  status 42
  expect_eq "found by its footer, edited in place: no second note" "$(jq '[.comments["42"][] | select(.user.login == "github-actions[bot]")] | length' "$T/world.json")" 2
  expect_eq "the same comment" "$(notes | jq '.[0].id')" "$id"
  expect_eq "no ping: what was sent is not known" "$(count pings)" 0
  expect_err_has "hidden line was lost"
  expect_true "the line is back, with this run's pings recorded" grep -q 'sent=aaaaaaa11111:ci:failed -->' <<<"$(note_body)"
  : >"$T/calls.jsonl"; status 42
  expect_eq "and they never go out later" "$(count pings)" 0
  world_set --argjson id "$id" '(.comments["42"][] | select(.id == $id)).body |= sub("final=0 sent="; "final=9 sent=")'
  : >"$T/calls.jsonl"; status 42
  expect_eq "an unreadable hidden line counts as lost too: no ping, no new note" "$(count pings) $(notes | jq length)" "0 1"
}

t_two_notes() {
  world; check_set '{"name": "lint", "conclusion": "failure"}'
  comment_add "github-actions[bot]" $'old\n\n<sub>Edited in place by mroom\'s pr-status; x</sub>\n\n<!-- mroom-pr-status pr=42 final=0 sent=once:ready:ready -->'
  comment_add "github-actions[bot]" $'newer\n\n<!-- mroom-pr-status pr=42 final=0 sent=aaaaaaa11111:ci:failed -->'
  local first; first="$(notes | jq '.[0].id')"
  status 42
  expect_eq "no ping either note recorded" "$(count pings)" 0
  expect_eq "no third note" "$(notes | jq length)" 2
  expect_true "the oldest is the one kept current, with both notes' keys" \
    jqt --argjson id "$first" '.comments["42"][] | select(.id == $id) | .body | contains("sent=once:ready:ready,aaaaaaa11111:ci:failed -->")' "$T/world.json"
  expect_err_has "more than one note"
}

t_other_prs_notes() {
  world
  comment_add "github-actions[bot]" $'x\n\n<!-- mroom-pr-status pr=4 final=1 sent=once:ready:ready -->'
  comment_add "dev1" $'pasted\n\nEdited in place by mroom\'s pr-status\n<!-- mroom-pr-status pr=42 final=0 sent=once:ready:ready -->'
  status 42
  expect_eq "a note for PR #4, and a person's paste, are not this note: the ready ping goes" "$(count pings)" 1
}

t_write_fails() {
  world; world_set '.fail = ["POST issues/42/comments"]'
  status 42; expect_rc 0
  expect_eq "no note" "$(notes | jq length)" 0
  expect_eq "and so no ping" "$(count pings)" 0
  expect_err_has "ping(s) not sent, since the note that records them was not saved"
  world_set '.fail = []'; : >"$T/calls.jsonl"; status 42
  expect_eq "the next run: one note, one ping" "$(notes | jq length) $(count pings)" "1 1"
}

t_lost_answer() {
  world; world_set '.lose_response = ["POST issues/42/comments"]'
  status 42
  expect_eq "the note was made, but its answer lost: no ping" "$(notes | jq length) $(count pings)" "1 0"
  world_set '.lose_response = []'; : >"$T/calls.jsonl"; status 42
  expect_eq "the next run finds it by its hidden line: no second note, and the ping it recorded never goes" "$(notes | jq length) $(count pings)" "1 0"
}

t_ping_fails() {
  world; world_set '.slack_error = "channel_not_found"'
  status 42; expect_rc 0
  expect_err_has "chat refused the ping: channel_not_found"
  expect_err_has "it is recorded, so it is not tried again"
  world_set '.slack_error = null'; : >"$T/calls.jsonl"; status 42
  expect_eq "not tried again" "$(count pings)" 0
  world; world_set '.down = ["slack"]'; status 42
  expect_err_has "chat did not answer"
}

t_no_chat() {
  world; unset SLACK_BOT_TOKEN
  status 42
  expect_err_has "no chat token or no persona.channel, so 1 ping(s) are not sent"
  expect_true "not recorded" grep -q 'sent= -->' <<<"$(note_body)"
  export SLACK_BOT_TOKEN="$CHAT_TOKEN"; : >"$T/calls.jsonl"; status 42
  expect_eq "sent once chat is set up" "$(count pings)" 1
  world; toml_drop persona; status 42
  expect_eq "no persona.channel: no ping" "$(count pings)" 0
  expect_true "the default name" grep -q "Agent's notes" <<<"$(note_body)"
}

t_closed() {
  world; status 42
  local id; id="$(notes | jq '.[0].id')"
  pr_set '.pulls["42"] += {state: "closed", merged: true, closed_at: "2026-10-28T11:00:00Z"}'
  world_set --argjson id "$id" '.fail = ["PATCH issues/comments/\($id)"]'; : >"$T/calls.jsonl"
  status 42
  expect_err_has "could not edit the note"
  run "$A/pr-status.sh" --closed-not-final
  expect_out "42"
  world_set '.fail = []'; status 42
  expect_true "final once GitHub took it" grep -q 'final=1 sent=once:ready:ready -->' <<<"$(note_body)"
  expect_true "merged in the heading" grep -q "^🟣 \*\*Bot One's notes\*\* · merged" <<<"$(note_body)"
  run "$A/pr-status.sh" --closed-not-final; expect_out ""
  check_set '{"name": "lint", "conclusion": "failure"}'; : >"$T/calls.jsonl"; status 42
  expect_eq "a final note is left alone, and a closed PR pings nobody" "$(count writes) $(count pings)" "0 0"
  expect_err_has "note none (PR closed, note final)"
  pr_set '.pulls["42"] += {state: "open", merged: false}'; : >"$T/calls.jsonl"; status 42
  expect_true "reopened: current again" grep -q 'final=0' <<<"$(note_body)"
  expect_eq "and its failure pings" "$(count pings)" 1
  pr_set '.pulls["42"] += {state: "closed", closed_at: "2026-10-26T11:00:00Z"}'
  world_set --argjson id "$id" '.fail = ["PATCH issues/comments/\($id)"]'; status 42
  run "$A/pr-status.sh" --closed-not-final
  expect_out ""
}

t_github_down() {
  world; world_set '.down = ["github"]'
  status 42; expect_rc 0
  expect_err_has "could not read PR #42 from GitHub"
  expect_eq "nothing written, nothing pinged" "$(count pings)" 0
}

t_dry_run() {
  world; unset MROOM_PR_STATUS_LIVE
  status 42; expect_rc 0
  expect_err_has "a dry run"
  expect_true "prints what it would do" jqt '.note.action == "create" and (.note.body | contains("<!-- mroom-pr-status pr=42 final=0 sent=once:ready:ready -->")) and (.chat.pings | map(.key)) == ["once:ready:ready"]' <<<"$out"
  expect_eq "writes nothing, pings nobody" "$(count writes) $(count pings)" "0 0"
  export MROOM_PR_STATUS_LIVE=1 MROOM_PR_STATUS_DRY_RUN=1; status 42
  expect_eq "DRY_RUN wins over LIVE" "$(count writes) $(count pings)" "0 0"
  unset MROOM_PR_STATUS_DRY_RUN; status 42
  export MROOM_PR_STATUS_DRY_RUN=1; status 42
  expect_true "after a live run: unchanged, and already sent" jqt '.note.action == "none (unchanged)" and .chat.pings == [] and .chat.already_sent == ["once:ready:ready"]' <<<"$out"
}

t_dependabot() {
  world; pr_set '.pulls["42"].user.login = "dependabot[bot]"'
  status 42; expect_rc 0
  expect_err_has "Dependabot's"
  expect_eq "nothing written" "$(count writes)" 0
}

t_usage() {
  world
  status; expect_rc 2
  status 0042x; expect_rc 2
  status '42;x'; expect_rc 2
  GITHUB_REPOSITORY="" run "$A/pr-status.sh" 42; expect_rc 2
  world '[persona]
channel = "#nope"'
  status 42; expect_rc 0
  expect_err_has "could not read mroom.toml"
  expect_eq "a broken mroom.toml writes nothing" "$(count writes)" 0
  world; MROOM_PR_STATUS_REVIEWER='x y' run "$A/pr-status.sh" 42
  expect_err_has "the reviewer is not a GitHub login"
}

t_sent_trimmed() {
  world
  local keys; keys="once:ready:ready,$(for i in $(seq 1 250); do printf '%012x:ci:failed,' "$i"; done)"
  comment_add "github-actions[bot]" $'x\n\n<!-- mroom-pr-status pr=42 final=0 sent='"${keys%,}"' -->'
  check_set '{"name": "lint", "conclusion": "failure"}'; status 42
  local line; line="$(note_body | tail -n1)"
  expect_true "the once key stays" grep -q 'sent=once:ready:ready,' <<<"$line"
  expect_eq "200 others at most, the newest kept" "$(tr ',' '\n' <<<"${line#*sent=}" | grep -c ':ci:')" 200
  expect_true "this run's key is among them" grep -q 'aaaaaaa11111:ci:failed -->' <<<"$line"
  expect_true "the oldest went" bash -c '! grep -q "000000000001:ci" <<<"$1"' _ "$line"
}

# --- The action and the workflow -----------------------------------------------------------------------------

t_shape() {
  local wf; wf="$(cat "$WF")"
  expect_true "the update job runs in the persona environment, without a deployment" grep -qE '^      name: persona$' "$WF"
  expect_true "one update per PR at a time, never cancelled" grep -q 'cancel-in-progress: false' "$WF"
  expect_true "checks out the default branch's mroom.toml only" grep -q 'sparse-checkout: /mroom.toml' "$WF"
  expect_true "never the PR's head" bash -c '! grep -qE "head\.(sha|ref)|pull_request\.head" "$1"' _ "$WF"
  expect_true "mroom at the commit of this file" grep -q 'ref: ${{ job.workflow_sha }}' <<<"$wf"
  expect_true "live in the action only" grep -q "MROOM_PR_STATUS_LIVE: '1'" "$A/action.yml"
  expect_true "the chat token goes in through env, not a command line" grep -q 'SLACK_BOT_TOKEN: ${{ inputs.chat-token }}' "$A/action.yml"
  expect_true "the footer render.jq writes is the one pr-status.sh finds" bash -c 'grep -q "def footer: \"Edited in place by mroom'"'"'s pr-status\";" "$1/render.jq" && grep -q "^FOOTER=\"Edited in place by mroom'"'"'s pr-status\"" "$1/pr-status.sh"' _ "$A"
}

test_case green t_green
test_case issue t_issue
test_case ci t_ci
test_case required-list t_required_list
test_case review t_review
test_case environment t_environment
test_case no-qa-workflow t_no_qa_workflow
test_case browser t_browser
test_case findings t_findings
test_case final-and-draft t_final_and_draft
test_case escaping t_escaping
test_case who t_who
test_case one-note-one-ping t_one_note_one_ping
test_case change-edits-in-place t_change_edits_in_place
test_case marker-lost t_marker_lost
test_case two-notes t_two_notes
test_case other-prs-notes t_other_prs_notes
test_case write-fails t_write_fails
test_case lost-answer t_lost_answer
test_case ping-fails t_ping_fails
test_case no-chat t_no_chat
test_case closed t_closed
test_case github-down t_github_down
test_case dry-run t_dry_run
test_case dependabot t_dependabot
test_case usage t_usage
test_case sent-trimmed t_sent_trimmed
test_case shape t_shape
finish
