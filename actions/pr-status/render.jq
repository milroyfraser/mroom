# render.jq — a pull request's status note, and the chat pings it calls for, from the facts pr-status.sh
# collects. Pure: no API calls, so tests/pr-status-test.sh runs it on fixtures.
#
#   {pr: {number, title, url, author_login, author_name, state, merged, draft, head_sha, head_ref, body,
#         trusted},                       trusted: by the repository's owner, a member or a collaborator, from a
#                                         branch of the repository itself; only such a PR pings anyone
#    required: {names: [check names], from: ruleset | config | config-unverified | unread | none},
#    checks: [{id, name, status, conclusion, html_url, title, external_id}],   check runs on the head commit
#    comments: [{id, login, body, html_url}],                                  the PR's comments, oldest first
#    qa_run: {status, conclusion, html_url, deploy: {status, conclusion, html_url} | null} | null,
#                                                       the app's latest qa-up run for this PR, and its deploy job
#    users: {<GitHub login or commit email>: <chat user id>},
#    cfg: {name, reviewer, review_check, findings_check, browser_check, id_pattern, issue_url}}
#                                         an empty findings_check or browser_check: the app has no such check
#
# Out: {final, draft, body, alerts: [{key, text}]}.
#   body    the note (GitHub Markdown): a heading, then one line per section, each naming the commit it refers
#           to. pr-status.sh adds the hidden state line under it.
#   alerts  the pings the current state asks for (Slack mrkdwn, mentioning the author), each keyed
#           "<sha>:<kind>:<outcome>", so pr-status.sh sends each at most once; "ready" is keyed
#           "once:ready:ready", so it goes out once per PR.
#
# Every line says what it rests on: the commit, and a link to the check, run or comment. What was not checked
# says "not run" or "unknown: <what is missing>", never a pass, and an unknown or pending section keeps the PR
# from ready. Text that does not come from mroom (check names, check titles) is escaped: no Markdown, no
# mentions.

# blocking_count: shared with the review findings check (actions/review-findings/findings.jq).
include "findings";

# The line pr-status.sh finds a note by when its hidden line is lost. pr-status.sh holds the same words.
def footer: "Edited in place by mroom's pr-status";

def sha7: "`\(.[0:7])`";
def latest($checks; $name): [$checks[] | select(.name == $name)] | max_by(.id);

# Markdown, for the note: an escaped text, with a zero-width space after every @ that does not follow a letter,
# digit or _ (an address keeps its @), so no text in it mentions anyone, and in every :// and www., so none is a
# link of its own; and a link with such a label.
def md: tostring | gsub("[\r\n\t]+"; " ") | gsub("&"; "&amp;") | gsub("(?<c>[\\\\`*_\\[\\]<>|#~])"; "\\\(.c)")
  | gsub("(?<![A-Za-z0-9_])@"; "@\u200b") | gsub("://"; ":\u200b//") | gsub("(?<![A-Za-z])(?<w>[Ww]{3})\\."; "\(.w)\u200b.");
def mdlink($url; $label): "[\($label | md)](\($url))";

# Slack mrkdwn: an escaped text, and a link with an escaped label (a | would end the label early).
def esc: tostring | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");
def link($url; $label): "<\($url)|\($label | esc | gsub("\\|"; "¦"))>";

# The PR's issue on the tracker, for the pings: the first id that matches issues.id_pattern, in a `<Label>: <id>`
# line of the body (at the start of a line, so an example in the prose does not count), then the Conventional
# Commit scope of the title (`fix(SHOP-12): …`), then the branch name (`shop-12-…`, after any `feature/` prefix).
# null without both issues.id_pattern and issues.url. A match ignores case; it is upper-cased when that is still
# an id.
def issue($pr; $cfg):
  if ($cfg.id_pattern // "") == "" or ($cfg.issue_url // "") == "" then null
  else
    "(?<id>\($cfg.id_pattern))" as $id
    | (first(($pr.body // "") | capture("(^|\\n)[ \\t>*_-]*[A-Za-z][A-Za-z ]{0,20}[*_]*:[\\s*_\\[]*\($id)(?![A-Za-z0-9_-])"; "i").id)
       // first(($pr.title // "") | capture("^[a-z]+\\(\\s*\($id)\\s*\\)!?:"; "i").id)
       // first(($pr.head_ref // "") | capture("(^|/)\($id)(-|$)"; "i").id)
       // null)
    | if . == null then null
      else (if ascii_upcase | test("^(\($cfg.id_pattern))$") then ascii_upcase else . end) as $i
        | {identifier: $i, url: ($cfg.issue_url | sub("\\{id\\}"; $i | @uri))}
      end
  end;

# Each section: {label, kind, state: ok|pending|fail|unknown|none, line (Markdown), sha, question (Markdown, for
# an "Open question:" line), alert: {outcome, text, evidence, ask} (Slack mrkdwn)}.

# The PR's QA environment, from the one comment qa-up, qa-down and qa-reap keep (lib/core/qa.sh, qa_comment): its
# hidden line holds the state, and a ready one names the commit it serves and its addresses. While the app's
# qa-up run for the PR runs, its deploy job says whether it is still planning or deploying.
def qa_comment($f): [$f.comments[] | select(.login == "github-actions[bot]" and (.body | startswith("### QA environment\n")))] | last;
def qa_state($c): first(($c.body // "") | capture("\n<!-- mroom-qa: (?<s>[a-z]+)( [^\n]*)? -->\n").s) // null;
def qa_serves($c): first(($c.body // "") | capture("Updated for `(?<s>[0-9a-f]{7,40})`").s) // null;
def qa_commit($c): first(($c.body // "") | capture("`(?<s>[0-9a-f]{40})`").s) // null;
def qa_url($c; $row): first(($c.body // "") | capture("\n\\| \($row) \\| (?<u>https://[a-z0-9.-]+(:[0-9]+)?) \\|").u) // null;
def environment($f):
  $f.pr as $pr | $f.qa_run as $run
  | ($run.deploy // null) as $d
  | (($d // $run // {}).html_url // $run.html_url // null) as $run_url
  | qa_comment($f) as $c
  | qa_state($c) as $st
  | qa_serves($c) as $serves
  | ($c.html_url // null) as $why
  | (if $st == "ready" and $serves != null then
       ($pr.head_sha | startswith($serves)) as $current
       | ([(qa_url($c; "App") | select(.) | mdlink(.; "app")), (qa_url($c; "API") | select(.) | mdlink(.; "API")),
           mdlink($why; "comment")] | join(" · ")) as $links
       | {state: (if $current then "ok" else "pending" end),
          line: "\(if $current then "✅" else "⚠️" end) \($links)", sha: $serves,
          question: (if $current or ($run != null and $run.status != "completed") then null else
            "the environment serves \($serves | sha7), the head is \($pr.head_sha | sha7). Is a deploy queued, or did it not run? Next check: \(mdlink($run_url // $why; "the latest qa-up run"))." end)}
     else null end) as $up
  | if $run == null and $c == null then {state: "none", line: "not requested (no QA plan has run on this PR)"}
    elif $run != null and $run.status != "completed" and $d == null then
      {state: "pending", line: "⏳ planning · \(mdlink($run.html_url; "run"))"}
    elif $run != null and $run.status != "completed" and $d.status != "completed" then
      {state: "pending", line: "⏳ deploying · \(mdlink($d.html_url; "run"))"}
    elif $d != null and ($d.conclusion | IN("failure", "timed_out", "startup_failure")) then
      # Keyed on the commit the comment says failed, when it says so: the head may have moved on since.
      {state: "fail", line: ("❌ deploy failed · \(mdlink($d.html_url; "run"))" + (if $why then " · \(mdlink($why; "comment"))" else "" end)),
       sha: (if $st == "failed" then qa_commit($c) else null end),
       alert: {outcome: "failed", text: "❌ QA deploy failed", evidence: link($d.html_url; "run"),
               ask: "This branch (build, migration) or the box? Next check: the failing step in \(link($d.html_url; "the run"))."}}
    elif $d != null and $d.conclusion == "cancelled" then
      {state: "pending", line: "⏳ deploy cancelled, a newer one follows · \(mdlink($d.html_url; "run"))"}
    elif $st == "ready" and $up != null then $up
    elif $st == "waiting" or $st == "woken" then
      {state: "pending", line: "⏳ waiting for a QA environment slot · \(mdlink($why; "why"))"}
    elif $st == "failed" then
      {state: "fail", line: "❌ deploy failed · \(mdlink($why; "why"))", sha: qa_commit($c),
       alert: {outcome: "failed", text: "❌ QA deploy failed", evidence: link($why; "the environment comment"),
               ask: "This branch (build, migration) or the box? Next check: the run the comment links."}}
    elif $st == "removing" then {state: "none", line: "being removed · \(mdlink($why; "why"))"}
    elif $st == "removed" then {state: "none", line: "removed · \(mdlink($why; "why"))"}
    elif $st == "idle" then {state: "none", line: "not needed now · \(mdlink($why; "why"))"}
    elif $st == "skipped" then {state: "none", line: "skipped · \(mdlink($why; "why"))"}
    elif $c != null then
      {state: "unknown", line: "❓ unknown: the QA environment comment has no state mroom knows · \(mdlink($why; "comment"))"}
    elif $d != null and $d.conclusion == "success" then
      {state: "unknown", line: "❓ unknown: the deploy passed but left no QA environment comment · \(mdlink($d.html_url; "run"))",
       question: "the deploy finished without its `### QA environment` comment. Did writing it fail? Next check: its last step in \(mdlink($d.html_url; "the run"))."}
    else
      {state: "none", line: "not needed (the QA plan found nothing a user could notice) · \(mdlink($run_url; "run"))"}
    end
  | {label: "Environment", kind: "env"} + .;

# The required checks. Only failure, timed_out and action_required fail (and ping). A skipped one is not counted,
# as GitHub does not wait on it; a cancelled (or stale) one is pending, since a re-run follows.
def ci($f):
  $f.required as $req
  | if $req.from == "unread" then
      {state: "unknown", line: "❓ unknown: the required checks could not be read (the ruleset did not answer, and mroom.toml sets no pr.required_checks) · \(mdlink("\($f.pr.url)/checks"; "checks"))"}
    elif ($req.names | length) == 0 then {state: "none", line: "no required checks · \(mdlink("\($f.pr.url)/checks"; "checks"))"}
    else
      [$req.names[] as $n | {name: $n, run: latest($f.checks; $n)}
       | select(.run.status != "completed" or .run.conclusion != "skipped")] as $all
      | [$all[] | select(.run.status == "completed")] as $done
      | [$done[] | select(.run.conclusion | IN("failure", "timed_out", "action_required"))] as $failed
      | [$done[] | select(.run.conclusion | IN("success", "neutral"))] as $ok
      | ([$done[] | select(.run.conclusion | IN("cancelled", "stale"))] | length) as $cancelled
      | ($all | length) as $total
      | ([$all[] | select(.run == null)] | length) as $missing
      | ($total - ($done | length) - $missing) as $running
      | ((if $running > 0 then " · \($running) still running" else "" end)
         + (if $missing > 0 then " · \($missing) not reported yet" else "" end)
         + (if $cancelled > 0 then " · \($cancelled) cancelled" else "" end)
         + " · \(mdlink("\($f.pr.url)/checks"; "checks"))"
         + (if $req.from == "config-unverified" then " · the list is mroom.toml's (the ruleset did not answer)" else "" end)) as $more
      | if ($failed | length) > 0 then
          {state: "fail",
           line: "❌ failing: \($failed | map(mdlink(.run.html_url; .name)) | join(", "))\($more)",
           alert: {outcome: "failed", text: "❌ CI failing", evidence: ($failed | map(link(.run.html_url; .name)) | join(", ")),
                   ask: "Flaky, or a real regression? Re-run: \(link($failed[0].run.html_url; $failed[0].name))."}}
        elif ($ok | length) == $total then {state: "ok", line: "✅ \($total)/\($total) required pass\($more)", count: "\($total)/\($total)"}
        else {state: "pending", line: "⏳ \($ok | length)/\($total) required pass\($more)"}
        end
    end
  | {label: "CI", kind: "ci", sha: $f.pr.head_sha} + .;

# What a review comment says, for its own commit. $head is set when the review is of an older commit than the head.
def verdict($c; $head):
  ($c.body | blocking_count) as $n
  | (if $head then " (of an earlier commit)" else "" end) as $note
  | if $n == null then {state: "unknown", line: "❓ unknown: blocking count unreadable, the format is new · \(mdlink($c.html_url; "review"))\($note)"}
    elif $n == 0 then {state: "ok", line: "✅ \(mdlink($c.html_url; "no blocking findings"))\($note)"}
    else
      {state: "fail", line: "🔴 \(mdlink($c.html_url; "\($n) blocking"))\($note)",
       alert: {outcome: "blocking", text: "🔴 Claude review: \($n) blocking finding\(if $n == 1 then "" else "s" end)",
               evidence: link($c.html_url; "review"),
               ask: "Fix \(if $n == 1 then "it" else "them" end), or reply on the review with why one does not apply?"}}
    end
  | .sha = $c.sha
  | if $head then
      .question = "the latest review is of \($c.sha | sha7), not the head \($head | sha7). Did this push skip review (no paths it covers)? Next check: the review run on the head."
    else . end;

def review($f):
  $f.pr.head_sha as $head
  | [$f.comments[] | select(.login == $f.cfg.reviewer)
     | . + {sha: (first(.body | capture("<!-- claude-review sha=(?<s>[0-9a-f]{40}) -->").s) // null)}
     | select(.sha != null)] as $reviews
  | ([$reviews[] | select(.sha == $head)] | last) as $current
  | latest($f.checks; $f.cfg.review_check) as $run
  | if $current != null then verdict($current; null)
    elif $run != null and $run.status != "completed" then {state: "pending", line: "⏳ reviewing · \(mdlink($run.html_url; "run"))", sha: $head}
    elif $run != null and $run.conclusion == "cancelled" then {state: "pending", line: "⏳ cancelled, a newer review follows · \(mdlink($run.html_url; "run"))", sha: $head}
    elif $run != null and $run.conclusion == "success" then
      {state: "unknown", line: "❓ unknown: the run passed but posted no review · \(mdlink($run.html_url; "run"))", sha: $head,
       question: "the review run finished without a comment. Did posting it fail? Next check: \(mdlink($run.html_url; "the run's")) log."}
    elif $run != null and $run.conclusion == "skipped" and ($reviews | length) == 0 then
      {state: "none", line: "not run (the review skipped this PR) · \(mdlink($run.html_url; "run"))"}
    elif $run != null and $run.conclusion != "skipped" then {state: "fail", line: "❌ review run failed · \(mdlink($run.html_url; "run"))", sha: $head}
    # No review of the head: its paths skipped this push (a docs-only one, say). The latest review still
    # stands, so its open blocking findings keep the PR from ready.
    elif ($reviews | length) > 0 then verdict($reviews | last; $head)
    else {state: "none", line: "not run (no Claude review on this PR)"}
    end
  | {label: "Claude review", kind: "review"} + .;

# The review findings check (actions/review-findings): open 🔴 findings in the latest review, or unresolved rows
# in a findings table. It never pings (the review section does), but anything but green keeps the PR from ready.
# "Not reviewed yet" (neutral) on a PR the review never ran on is "not run", like the review line; anywhere
# else a neutral is unknown and holds the PR back.
def findings($f; $review):
  (if $f.cfg.findings_check == "" then null else latest($f.checks; $f.cfg.findings_check) end) as $run
  | ($run.html_url // null) as $url
  | ($run.title // null) as $title
  | if $f.cfg.findings_check == "" then {state: "none", line: "not set up"}
    # The check follows the review: while there is one, its missing check is still to come.
    elif $run == null and ($review.state != "none") then {state: "pending", line: "⏳ waiting for the \($f.cfg.findings_check | md) check on this commit"}
    elif $run == null then {state: "none", line: "not run (no \($f.cfg.findings_check | md) check on this commit)"}
    elif $run.status != "completed" then {state: "pending", line: "⏳ checking · \(mdlink($url; "check"))"}
    elif $run.conclusion == "success" then {state: "ok", line: "✅ \(mdlink($url; $title // "none open"))"}
    elif $run.conclusion == "failure" then {state: "fail", line: "🔴 \(mdlink($url; $title // "open findings"))"}
    elif $run.conclusion == "neutral" and ($title // "" | startswith("Not reviewed yet")) and $review.state == "none" then
      {state: "none", line: "not run: \(mdlink($url; $title))"}
    else {state: "unknown", line: "❓ unknown: \(mdlink($url; $title // "unreadable"))"}
    end
  | {label: "Review findings", kind: "findings", sha: (if $run == null then null else $f.pr.head_sha end)} + .;

# The browser QA check on the head commit (phase 2b): its conclusion, the row counts in its title, and its run,
# from the check's external_id when that is a run id (GitHub points a check the job token created at the run
# that created it, not the one that ran the test). $env is the Environment section: while an environment exists
# or is coming for this PR, a missing or unfinished check on the head is pending, never "not run", so "ready"
# cannot go out between the deploy and the browser run.
def browser($f; $env):
  $f.pr as $pr
  | (if $f.cfg.browser_check == "" then null else latest($f.checks; $f.cfg.browser_check) end) as $run
  | ($pr.url | sub("/pull/[0-9]+$"; "")) as $repo
  | (if $run == null then null
     elif ($run.external_id // "" | tostring | test("^[0-9]{1,20}$")) then "\($repo)/actions/runs/\($run.external_id)"
     else $run.html_url end) as $run_url
  | ($run.title // null) as $title
  | def summary($default): ($title // $default | md) + " · " + mdlink($run_url; "run");
    ($f.qa_run != null and $f.qa_run.status != "completed") as $planning
  | (($env.state == "ok" or $env.state == "pending") or $planning) as $expected
  | ($f.cfg.browser_check | md) as $name
  | if $f.cfg.browser_check == "" then {state: "none", line: "not set up"}
    elif $run == null and $expected then
      {state: "pending", line: "⏳ waiting for the \($name) check on this commit"}
    elif $run == null then {state: "none", line: "not run (no \($name) check on this commit)"}
    elif $run.status != "completed" then {state: "pending", line: "⏳ running · \(mdlink($run_url; "run"))"}
    elif $run.conclusion == "neutral" and ($title // "" | test("waiting for a QA environment slot")) then
      {state: "pending", line: "⏳ \(summary("waiting for a QA environment slot"))"}
    elif $run.conclusion == "success" then {state: "ok", line: "✅ \(summary("passed"))"}
    elif $run.conclusion == "skipped" then {state: "none", skipped: true, line: "not run: \(summary("skipped"))"}
    elif $run.conclusion == "neutral" then
      {state: "fail", line: "⚠️ not verified: \(summary("reason not given"))",
       alert: {outcome: "not-verified", text: "⚠️ Browser QA not verified", evidence: link($run_url; $title // "run"),
               ask: "What blocked it: the environment, the fixtures or the agent? Next check: \(link($run_url; "the run"))."}}
    elif $run.conclusion == "cancelled" then {state: "pending", line: "⏳ cancelled, a newer run follows · \(mdlink($run_url; "run"))"}
    else
      {state: "fail", line: "❌ \(summary("failed"))", target: $run_url,
       alert: {outcome: "failed", text: "❌ Browser QA failed", evidence: link($run_url; $title // "run"),
               ask: "A real regression, or a wrong expectation in the test? Next check: the failing row in \(link($run_url; "the run"))."}}
    end
  | {label: "Browser QA", kind: "browser", sha: (if $run == null then null else $pr.head_sha end)} + .;

# Signals that disagree across sections, as Open questions. $k: the sections by kind.
def cross_questions($k; $head):
  if $k.ci.state == "ok" and $k.browser.state == "fail" and $k.browser.alert.outcome == "failed" then
    ["CI is green but browser QA failed on \($head | sha7). Which test should have caught it? Next check: the failing row in \(mdlink($k.browser.target; "the run"))."]
  else [] end;

. as $f
| $f.pr as $pr
| $f.cfg as $cfg
| issue($pr; $cfg) as $issue
| ($pr.state == "closed") as $final
| ($pr.draft == true and ($final | not)) as $draft
| environment($f) as $env
| review($f) as $review
# Browser QA last, next to what it waits on.
| [$env, ci($f), $review, findings($f; $review), browser($f; $env)] as $sections
| ($sections | map({key: .kind, value: .}) | from_entries) as $k
| ($sections | map(select(.state == "fail")) | length > 0) as $failing
# Ready only on what was verified: an unknown or pending section keeps a PR from ready.
| ($sections | all(.state == "ok" or .state == "none")) as $ready
| ([$sections[] | .question // empty] + cross_questions($k; $pr.head_sha)) as $questions
| (if ($f.users[$pr.author_login] // "") != "" then "<@\($f.users[$pr.author_login])>" else ($pr.author_name | esc) end) as $who
# Every ping links the PR and, when there is one, its issue.
| (" · " + link($pr.url; "PR #\($pr.number) · \($pr.title)")
   + (if $issue then " · " + link($issue.url; $issue.identifier) else "" end)) as $where
| (if $pr.merged then ["🟣", "merged"]
   elif $final then ["⚫", "closed"]
   elif $draft then ["⏸", "draft"]
   elif $failing then ["🔴", "needs the author"]
   elif $ready then ["✅", "ready for review"]
   else ["⏳", "in progress"] end) as $head
| ([ "\($head[0]) **\($cfg.name)'s notes** · \($head[1])", "" ]
   + [ $sections[]
       | if $final and .kind == "env" and .state != "none" then .line = "removed" | .sha = null else . end
       | "- **\(.label):** \(.line)" + (if .sha then " · \(.sha | sha7)" else "" end) ]
   + (if $final or ($questions | length) == 0 then [] else [""] + [$questions[] | "**Open question:** \(.)"] end)
   + [ "", "<sub>\(footer); each line names the commit it refers to.</sub>" ]
  | join("\n")) as $body
| { final: $final,
    draft: $draft,
    issue: $issue,
    body: $body,
    # No pings for a draft or a closed PR, nor for one from outside the repository's people (on a public
    # repository, anyone's). A failure ping ends with the question for the author.
    alerts: (if $final or $draft or ($pr.trusted | not) then []
             else [ $sections[] | select(.alert)
                    | (.sha // $pr.head_sha) as $sha
                    | {key: "\($sha[0:12]):\(.kind):\(.alert.outcome)",
                       text: "\($who) \(.alert.text) on \($sha | sha7): \(.alert.evidence)\($where). \(.alert.ask)"} ]
                  + (if $ready then
                       [{key: "once:ready:ready",
                         text: ("\($who) ✅ Ready for review on \($pr.head_sha | sha7): "
                           + ([ (if $k.ci.state == "ok" then "\($k.ci.count) required checks pass" else "no required checks" end),
                                (if $k.review.state == "none" then "Claude review not run" else "Claude review: no blocking findings" end),
                                (if $k.findings.state == "ok" then "review findings resolved" else empty end),
                                (if $k.env.state == "ok" then "environment deployed at this commit" else empty end),
                                (if $k.browser.state == "ok" then "browser QA passed"
                                 elif $k.browser.skipped then "browser QA not needed" else "browser QA not run" end) ]
                              | join(", "))
                           + $where)}]
                     else [] end)
             end) }
