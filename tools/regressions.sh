#!/usr/bin/env bash
# regressions.sh <owner/repo> [<since YYYY-MM-DD>] — the two measures the regression label records (design
# section 1.2): production problems per release, and the time from a release to the first report of a
# problem it caused.
#
# It reads the merged pull requests that carry the regression label, with their "Breaks: <release>" and
# optional "Reported: <date or UTC time>" lines (without Reported, the time the PR was opened counts), and
# the releases published since <since> (default: 90 days ago). A problem counts toward the release it names.
#
#   tools/regressions.sh example/shop 2026-07-01
#
# Env: REGRESSION_LABEL (default regression). Needs gh (signed in) and jq.
set -euo pipefail

REPO="${1:?usage: regressions.sh <owner/repo> [<since YYYY-MM-DD>]}"
LABEL="${REGRESSION_LABEL:-regression}"
NOW="${MROOM_NOW:-$(date +%s)}"
SINCE="${2:-$(jq -nr --argjson now "$NOW" '$now - 90 * 86400 | strftime("%Y-%m-%d")')}"
if ! [[ "$SINCE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "regressions.sh: <since> must be a date, YYYY-MM-DD" >&2
  exit 2
fi

prs="$(gh pr list -R "$REPO" --state merged --label "$LABEL" --search "merged:>=$SINCE" --limit 1000 \
  --json number,title,body,createdAt,url)"
releases="$(gh release list -R "$REPO" --limit 1000 --json tagName,publishedAt,isDraft)"
# Without the label nothing is recorded, and "0 problems" would read as good news.
recording=true
gh api "repos/$REPO/labels/$(jq -rn --arg l "$LABEL" '$l | @uri')" >/dev/null 2>&1 || recording=false

jq -nr --argjson prs "$prs" --argjson releases "$releases" --arg since "$SINCE" --arg repo "$REPO" \
  --arg label "$LABEL" --argjson recording "$recording" '
  def epoch:
    if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") then . + "T00:00:00Z"
    elif test("T[0-9]{2}:[0-9]{2}Z$") then sub("Z$"; ":00Z")
    else sub("\\.[0-9]+Z$"; "Z") end
    | fromdateiso8601;
  def field($name):
    (.body // "") | gsub("\r"; "") | split("\n")
    | map(select(test("^\\s*" + $name + ":"; "i"))) | (first // "")
    | sub("^[^:]*:\\s*"; "") | sub("\\s+$"; "");
  def dur:
    floor | if . < 60 then "\(.)s"
    elif . < 3600 then "\(. / 60 | floor)m"
    elif . < 86400 then "\(. / 3600 | floor)h" + (. % 3600 / 60 | floor | if . > 0 then " \(.)m" else "" end)
    else "\(. / 86400 | floor)d" + (. % 86400 / 3600 | floor | if . > 0 then " \(.)h" else "" end) end;
  def utc: strftime("%Y-%m-%d %H:%M UTC");
  def median: sort | if length == 0 then null elif length % 2 == 1 then .[length / 2 | floor]
    else (.[length / 2 - 1] + .[length / 2]) / 2 end;
  def clean: gsub("[[:cntrl:]]"; " ");

  ($since + "T00:00:00Z" | fromdateiso8601) as $from
  | ($releases | map(select(.isDraft | not) | {key: .tagName, value: (.publishedAt | epoch)}) | from_entries) as $released
  | [$prs[] | {number, url, title: (.title | clean), breaks: field("Breaks"), reported: field("Reported"),
               opened: (.createdAt | epoch)}
      | .released = $released[.breaks]
      | .reported_at = (if .reported == "" then .opened else (.reported | try epoch catch null) end)
      | .delay = (if .released and .reported_at then ([.reported_at - .released, 0] | max) else null end)]
    | sort_by(.number) as $fixes
  | ($fixes | map(select(.delay != null and .released >= $from))) as $counted
  | ($released | to_entries | map(select(.value >= $from)) | length) as $nreleases
  | ($counted | map(.breaks) | unique | length) as $broken
  | "Regression fixes merged since \($since) in \($repo):",
    (if ($fixes | length) == 0 then "  none" else empty end),
    ($fixes[] | "  #\(.number)  " + (
       if .released == null then "\(.breaks | clean): not a published release of this repository"
       elif .reported_at == null then "\(.breaks), released \(.released | utc): its Reported line is not a date"
       else "\(.breaks), released \(.released | utc), reported after \(.delay | dur)" end)
       + ": \(.title)"),
    "Releases published since \($since): \($nreleases); with a reported problem: \($broken)",
    if $recording | not then
      "Production problems per release: not recorded: \($repo) has no \($label) label yet",
      "Time from a release to the first report of a problem: not recorded"
    else
    "Production problems per release: "
      + (if $nreleases == 0 then "no releases" else
          "\(($counted | length) / $nreleases * 100 | round / 100) (\($counted | length) over \($nreleases))" end),
    "Time from a release to the first report of a problem: "
      + (if ($counted | length) == 0 then "no problems reported"
         else "median \($counted | map(.delay) | median | dur), longest \($counted | map(.delay) | max | dur) (\($counted | length) problems)" end)
    end
'
