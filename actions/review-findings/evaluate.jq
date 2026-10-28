# evaluate.jq — the review findings check (actions/review-findings), from a pull request's comments. Pure jq,
# no API calls; review-findings.sh collects the input.
#
#   input:  {head_sha, comments: [{login, body, html_url, created_at}]}
#   args:   --arg reviewer <login>, the GitHub login that posts the Claude review (claude[bot] by default)
#   output: {conclusion: success|failure|neutral, title, summary}
#
# Two things keep it red (failure), either one is enough:
# - the latest Claude review comment ($reviewer's, ending with `<!-- claude-review sha=... -->`, of any
#   commit: a push outside the review's paths gets no new review, so the last one still stands) has open 🔴
#   blocking findings, counted by findings.jq's blocking_count;
# - the latest comment with a "Review findings and how each was resolved" table (posted by the author's
#   session, any author) has a row that is not resolved. A row is resolved when ANY of its cells has ✅ or
#   ➖: the table's columns vary between sessions, so the status column is not looked up by name.
# A review whose format blocking_count doesn't recognise gives neutral (unknown, not red), unless the
# table alone already makes it red. No review and no table at all is neutral too, "Not reviewed yet":
# nothing was checked, so it is never a pass.

include "findings";

# Comment text shown in the check's summary is untrusted: no @mentions (a zero-width space after the
# @ stops the ping), no HTML, one line, bounded.
def safe:
  gsub("[\r\n]+"; " ") | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;") | gsub("@"; "@\u200b")
  | if length > 140 then .[0:140] + "…" else . end;
def sha7: if . == null then "?" else .[0:7] end;
def plural($n; $word): "\($n) \($word)\(if $n == 1 then "" else "s" end)";

def table_heading:
  test("^\\s*(>\\s*)*(#{1,6}\\s+|\\*\\*|__)\\s*(\\*\\*|__)?\\s*review findings and how each was resolved"; "i");
def md_heading: test("^\\s*(>\\s*)*#{1,6}\\s");
# A line with a cell separator: a pipe not escaped as `\|`.
def table_line: test("(^|[^\\\\])\\|");
def separator_row: test("^\\s*\\|?\\s*:?-{1,}:?\\s*(\\|\\s*:?-{1,}:?\\s*)*\\|?\\s*$");
# A row's cells: `\|` is a literal pipe inside a cell, the outer pipes are optional.
def cells:
  gsub("\\\\\\|"; "\u0001")
  | sub("^\\s*\\|"; "") | sub("\\|\\s*$"; "")
  | split("|")
  | map(gsub("\u0001"; "|") | gsub("^\\s+|\\s+$"; ""));

# The table's data rows (each a list of cells): the first block of table lines after the heading,
# before the next heading. The header (the line before the first separator row) and separator rows
# are skipped. No table under the heading means no rows.
def table_rows:
  (split("\n") | map(sub("\r$"; ""))) as $lines
  | (first(range(0; $lines | length) | select($lines[.] | table_heading)) // null) as $h
  | if $h == null then []
    else
      [foreach $lines[$h + 1:][] as $l ({state: "before", out: null};
          if .state == "done" then .out = null
          elif $l | md_heading then .state = "done" | .out = null
          elif $l | table_line then .state = "in" | .out = $l
          elif .state == "in" then .state = "done" | .out = null
          else .out = null end;
          .out // empty)] as $t
      | ($t | map(separator_row)) as $sep
      | [range(0; $t | length)
         | select(($sep[.] | not) and ((. + 1 < ($t | length) and $sep[. + 1]) | not))
         | $t[.] | cells]
    end;
def resolved: any(.[]; test("✅|➖"));

.head_sha as $head
| (.comments // [] | sort_by(.created_at // "")) as $comments
| ([$comments[] | select(.login == $reviewer)
    | . + {sha: (first(.body // "" | capture("<!-- claude-review sha=(?<s>[0-9a-f]{40})").s) // null)}
    | select(.sha != null)] | last) as $review
| ([$comments[] | select(.body // "" | split("\n") | any(.[]; table_heading))] | last) as $table
| (if $review then $review.body | blocking_count else 0 end) as $n
| (if $table then $table.body | table_rows else [] end) as $rows
| [$rows[] | select(resolved | not)] as $open
| (($n != null and $n > 0) or ($open | length) > 0) as $red
| {
    conclusion: (if $red then "failure" elif $n == null or ($review == null and $table == null) then "neutral" else "success" end),
    title: (
      if $red then
        [(if $n != null and $n > 0 then "\(plural($n; "blocking finding")) open in the Claude review" else empty end),
         (if ($open | length) > 0 then "\(plural($open | length; "unresolved row")) in the findings table" else empty end)]
        | join(" · ")
      elif $n == null then "Claude review format not recognised: open findings unknown"
      elif $review == null and $table == null then "Not reviewed yet: no Claude review or findings table"
      else "No open review findings" end),
    summary: (
      [ (if $review == null then "- **Claude review:** no review comment found."
         else "- **Claude review** ([comment](\($review.html_url))) of `\($review.sha | sha7)`"
              + (if $review.sha == $head then " (the head)" else " (an earlier commit; the head is `\($head | sha7)`)" end)
              + ": "
              + (if $n == null then "format not recognised, so its open blocking findings are unknown."
                 elif $n == 0 then "no open blocking findings."
                 else "🔴 \(plural($n; "open blocking finding"))." end)
         end),
        (if $table == null then "- **Findings table:** no \"Review findings and how each was resolved\" comment found."
         else "- **Findings table** ([comment](\($table.html_url))): "
              + (if ($rows | length) == 0 then "no rows."
                 elif ($open | length) == 0 then "all \($rows | length) rows resolved."
                 else "\($open | length) of \(plural($rows | length; "row")) unresolved:" end)
         end),
        ($open[0:15][] | "  - " + (map(select(. != "")) | join(" · ") | safe)),
        (if ($open | length) > 15 then "  - … and \(($open | length) - 15) more" else empty end),
        "",
        "A table row counts as resolved when any of its cells has ✅ or ➖."
      ] | join("\n"))
  }
