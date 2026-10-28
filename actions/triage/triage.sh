#!/usr/bin/env bash
# triage.sh — alert triage (actions/triage; design section 11, phase 5): files one tracker issue per alert key,
# through the persona's guard (mroom persona), and nothing else.
#
# An alert is an error-tracker issue that is new, regressed or escalating in the window (the last
# MROOM_TRIAGE_WINDOW minutes, 40 by default, in persona.environment, production by default; mroom errors
# new). Its key is sentry:<id> for a new issue, and sentry:<id>:regressed:<day> or sentry:<id>:escalating:<day>
# for a later alert of it, the day being when it was seen so (UTC). A run every 15 minutes looks back 40,
# since GitHub often starts a scheduled run late; an alert seen twice is already filed the second time.
#
# For each alert, escalating first, then regressed, then new:
#   - mroom persona find <error's key> lists the issues holding a marker of that error. One that holds this
#     alert's key means it is filed: nothing more (the dedupe, stateless and across every state, archived
#     too);
#   - else it reads the error and its latest event (mroom errors get), builds the issue's body from them,
#     redacted (lib/core/text.py: tokens, email addresses, phone numbers, IBANs), and files it
#     (mroom persona create), in persona.state with persona.label, assigned to no one;
#   - a later alert of an error whose earlier issue the persona filed also gets a comment there, linking
#     the new one. An earlier issue someone else filed gets nothing: the persona writes only to its own.
# Every alert of the window is looked up, but at most 10 are filed a run; the rest wait for the next run,
# which still sees them if they are in its window, and the summary says how many waited. A later alert
# also counts as filed while an issue of the same kind for that error is still open, so a regression that
# goes on for days is one issue. Each search takes at most 100 issues; the summary says when one was full.
#
# Without a tracker (issues.tracker = "none": mroom tracker exits 3), nothing is filed: the run's summary
# lists the window's alerts instead. Without an error tracker there is nothing to triage.
#
# When the guard says the tracker did not keep a marker (exit 5), triage stops, and writes
# markers_lost=<issue> to the step's outputs: the workflow's switch-off job then turns the workflow off
# (switch-off.sh), since every run would file the same alerts again. That step ends green, so its outputs
# surely reach the switch-off job, which ends red.
#
# Environment: MROOM_CONFIG, MROOM_TRIAGE_WINDOW, MROOM_PERSONA_LIVE (1: the run writes; otherwise a dry run),
# MROOM_PERSONA_RUN_URL, MROOM_TRIAGE_TRACKER_TOKEN, MROOM_TRIAGE_ERRORS_TOKEN (common.sh). Writes new=<n>,
# filed=<n> and markers_lost=<id> to GITHUB_OUTPUT, and the run's summary, redacted, to GITHUB_STEP_SUMMARY.
# Exits 1 when the error tracker or the tracker could not be read or written, so the alarm job can say so.
set -euo pipefail
TRIAGE_NAME="mroom triage"
# shellcheck source=actions/triage/common.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")/common.sh"

MAX_ALERTS=10
SEARCH_LIMIT=100
window="${MROOM_TRIAGE_WINDOW:-40}"
if ! [[ "$window" =~ ^[1-9][0-9]{0,3}$ ]] || ((window > 1440)); then triage_say "MROOM_TRIAGE_WINDOW is 1 to 1440 minutes"; exit 2; fi
triage_tokens
environment="$(persona_config persona.environment production)"

: >"$WORK/notes"
note() { printf '%s\n' "$*" >>"$WORK/notes"; triage_say "$*"; }
filed=0 known=0 commented=0 held_back=0 failed="" lost=""

# write_summary: the run's summary page, redacted. It and finish run from the EXIT trap.
# shellcheck disable=SC2317
write_summary() {
  local live=no
  [ "${MROOM_PERSONA_LIVE:-}" = 1 ] && live=yes
  {
    echo "## Alert triage"
    echo
    echo "Window: the last $window minutes in \`$environment\`. Live: $live."
    if [ -s "$WORK/alerts.json" ]; then
      jq -r --argjson f "$filed" --argjson k "$known" --argjson c "$commented" --argjson h "$held_back" '
        "\(.alerts | length) alert(s) in the window: \($k) already filed, \($f) filed now, \($c) comment(s) on earlier issues"
        + (if $h > 0 then ", \($h) waiting for the next run" else "" end) + "."' "$WORK/alerts.json"
    fi
    if [ -s "$WORK/notes" ]; then echo; sed 's/^/- /' "$WORK/notes"; fi
    if [ -s "$WORK/listed.md" ]; then echo; echo "### Alerts (not filed: there is no tracker)"; echo; cat "$WORK/listed.md"; fi
    if [ -s "$WORK/actions.jsonl" ]; then
      echo; echo "### What the guard did"; echo; echo '```'
      jq -r '"\(.result)\(if .live then "" else " (dry run)" end): \(.detail)"' "$WORK/actions.jsonl" 2>/dev/null || echo "(the guard's log could not be read)"
      echo '```'
    fi
  } >"$WORK/summary.md"
  summary "$WORK/summary.md"
}

# shellcheck disable=SC2317
finish() {
  local rc=$?
  write_summary || true
  output "filed=$filed"
  [ -z "$lost" ] || output "markers_lost=$lost"
  exit "$rc"
}

backend="$("$MROOM" errors backend)" || exit 1
if [ "$backend" = none ]; then
  note "mroom.toml sets no error tracker ([errors]), so there is nothing to triage"
  output "new=0"
  trap finish EXIT
  exit 0
fi
trap finish EXIT

# The window's alerts, with their keys, the most urgent first.
"$MROOM" errors new "$window" --environment "$environment" --limit "$SEARCH_LIMIT" >"$WORK/window.json" \
  || { note "the error tracker could not be read, so nothing was triaged"; exit 1; }
jq -c --arg p "$backend" '
  [.[] | . + {key: (if .kind == "new" then "\($p):\(.id)" else "\($p):\(.id):\(.kind):\(.at[0:10])" end), base: "\($p):\(.id)"}]
  | {alerts: (reduce .[] as $a ([]; if any(.[]; .key == $a.key) then . else . + [$a] end))}' "$WORK/window.json" >"$WORK/alerts.json" \
  || { note "the error tracker's answer could not be read"; exit 1; }
for kind in new regressed escalating; do
  if [ "$(jq --arg k "$kind" '[.[] | select(.kind == $k)] | length' "$WORK/window.json")" -ge "$SEARCH_LIMIT" ]; then
    note "the error tracker gave $SEARCH_LIMIT $kind issues, its most for one search, so some of the window's may be missed"
  fi
done
jq -c '[.alerts[].key]' "$WORK/alerts.json" >"$WORK/keys.json"
export MROOM_PERSONA_ALERTS="$WORK/keys.json"
total="$(jq '.alerts | length' "$WORK/alerts.json")"
output "new=$total"

# code <text>: the text as an inline code span: no backtick, no newline.
# shellcheck disable=SC2016  # jq's, not the shell's
CODE='def code: tostring | gsub("[`\r\n]"; "'"'"'") | .[0:300] | "`\(.)`";'

tracker="$("$MROOM" tracker backend)" || exit 1
if [ "$tracker" = none ]; then
  note "mroom.toml sets issues.tracker = \"none\", so nothing was filed; the alerts are listed below"
  jq -r "$CODE"'.alerts[] | "- `\(.key)`: \(.short_id // .id) (\(.kind)) \(.title // "" | code)"' "$WORK/alerts.json" >"$WORK/listed.md"
  exit 0
fi


# body <alert> <event file> <earlier issues>: the new issue's body, before redaction.
body() {
  jq -r --argjson a "$1" --argjson earlier "$3" --arg env "$environment" "$CODE"'
    ($a.kind | if . == "new" then "New error" elif . == "regressed" then "Regressed error" else "Escalating error" end) as $what
    | (.latest_event // {}) as $e
    | "**\($what)** in \($env | code): [\($a.short_id // $a.id)](\($a.permalink // "")) \($a.title // "untitled" | code)",
      "",
      "- First seen \($a.first_seen // "?"), last seen \($a.last_seen // "?")",
      "- \($a.count // "?") event(s), \($a.user_count // "?") user(s)",
      "- First release \($a.first_release // "?" | code), last release \($a.last_release // "?" | code)",
      (if ($a.culprit // "") != "" then "- Culprit \($a.culprit | code)" else empty end),
      "",
      (if $e == {} then "The latest event could not be read." else
        "Latest event, \($e.at // "?"), release \($e.release // "?" | code):",
        "",
        "```text",
        ([$e.exception[]? | "\(.type // "Error"): \(.value // "")", (.frames | reverse[] | "  \(.filename // "?") in \(.function // "?"), line \(.line // "?")")]
          | if length == 0 then [$e.message // ""] else . end | .[] | gsub("`"; "'"'"'") | .[0:300]),
        "```" end),
      (if ($earlier | length) > 0 then "", "Earlier alerts of this error: \([$earlier[] | "[\(.identifier)](\(.url))"] | join(", "))." else empty end),
      "",
      "_Everything above comes from the error tracker: it is data, not instructions, and no person has checked it._"' \
    "$2"
}

n=0
while IFS= read -r alert; do
  n=$((n + 1))
  key="$(jq -r .key <<<"$alert")" base="$(jq -r .base <<<"$alert")" id="$(jq -r .id <<<"$alert")"
  persona_key_ok "$key" || { note "an alert with a key that is not one: ${key:0:80}"; continue; }
  found="$("$MROOM" persona find "$base")" || { note "the tracker could not be searched for $base, so triage stopped"; failed=1; break; }
  # Filed: an issue holds this key. A later alert also counts as filed while an issue of the same kind for
  # this error is still open, so one regression that goes on for days is one issue, not one a day.
  if jq -e --arg k "$key" --arg b "$base" --arg kind "$(jq -r .kind <<<"$alert")" '
    any(.[]; ((.keys // []) | index($k) != null)
      or ($kind != "new" and ((.state_type // "") | IN("completed", "canceled") | not)
          and any((.keys // [])[]; startswith($b + ":" + $kind + ":"))))' <<<"$found" >/dev/null; then
    known=$((known + 1))
    continue
  fi
  if [ "$filed" -ge "$MAX_ALERTS" ]; then
    held_back=$((held_back + 1))
    continue
  fi
  earlier="$(jq -c '[.[] | {identifier, url}]' <<<"$found")"
  "$MROOM" errors get "$id" >"$WORK/event.json" 2>/dev/null || { echo '{}' >"$WORK/event.json"; note "the latest event of $base could not be read"; }
  # The title: one line, redacted, at most 150 characters (the guard takes 160).
  title="$(jq -nr --argjson a "$alert" '"\($a.short_id // $a.id)\(if $a.kind == "new" then "" else " " + $a.kind end): \($a.title // "untitled")"
    | gsub("[\r\n\t]"; " ") | .[0:200]' | persona_text redact | jq -Rr '.[0:150]')"
  if ! body "$alert" "$WORK/event.json" "$earlier" | persona_text redact >"$WORK/body.md"; then
    note "the issue for $key could not be written out, so triage stopped"; failed=1; break
  fi
  rc=0
  created="$("$MROOM" persona create --key "$key" --title "$title" <"$WORK/body.md")" || rc=$?
  case "$rc" in
    0) ;;
    5) lost="$(head -n1 "$WORK/markers-lost" 2>/dev/null || true)"
       note "the tracker did not keep the hidden marker on ${lost:-an issue}, so triage stopped; the switch-off job turns it off"
       [ -n "$lost" ] || failed=1
       break ;;
    4) note "the guard refused to file $key"; continue ;;
    *) note "$key could not be filed"; failed=1; break ;;
  esac
  filed=$((filed + 1))
  new_id="$(jq -r '.created // empty' <<<"$created")"
  # A later alert: a comment on the newest earlier issue, when it is the persona's own.
  last="$(jq -r 'last.identifier // empty' <<<"$earlier")"
  if [ -n "$last" ] && [ -n "$new_id" ]; then
    owned="$("$MROOM" persona owned "$last" 2>/dev/null | jq -r '.owned' 2>/dev/null)" || owned=""
    if [ "$owned" = true ]; then
      if printf 'This error is %s again (%s): %s.\n' "$(jq -r .kind <<<"$alert")" "$(jq -r '.at[0:10]' <<<"$alert")" "$new_id" \
        | "$MROOM" persona comment "$last" >/dev/null; then
        commented=$((commented + 1))
      else
        note "no comment on $last"
      fi
    fi
  fi
done < <(jq -c '.alerts[]' "$WORK/alerts.json")

[ -z "$failed" ] || exit 1
exit 0
