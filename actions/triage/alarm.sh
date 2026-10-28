#!/usr/bin/env bash
# alarm.sh — the alarm (actions/triage): when a live triage run failed, the persona pings persona.channel,
# at most once a UTC day, so a broken triage is not only a red run nobody looks at. The workflow's alarm job
# runs it, on its own runner, after the triage job.
#
# What failed comes from the triage job itself: the jobs API names its first failed step. The message says
# which, links the run and the day's issue, and ends with the question for a person.
#
# The dedupe is the tracker's, as triage's is: the day's alarm is an issue the persona files through its
# guard, keyed triage:<yyyymmdd>, and it is filed before the message goes out. A day whose issue exists
# sends nothing; a failure to file it sends nothing either, so a failure costs a missed ping, never one
# every 15 minutes. Without a tracker (mroom tracker exits 3) there is nowhere to record the ping, and
# without persona.channel nowhere to send it: the alarm says so in the job's log and sends nothing.
#
# Environment: MROOM_CONFIG, GH_TOKEN (actions: read), GITHUB_REPOSITORY, GITHUB_RUN_ID, MROOM_PERSONA_LIVE
# (1: it acts; otherwise it prints the message), MROOM_PERSONA_RUN_URL, MROOM_TRIAGE_TRACKER_TOKEN,
# SLACK_BOT_TOKEN, MROOM_TRIAGE_JOB (the triage job's name, "Alert triage"), MROOM_NOW (tests: the time).
set -euo pipefail
TRIAGE_NAME="mroom triage alarm"
# shellcheck source=actions/triage/common.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")/common.sh"
# shellcheck source=lib/core/api.sh
. "$MROOM_ROOT/lib/core/api.sh"
# shellcheck source=lib/core/chat.sh
. "$MROOM_ROOT/lib/core/chat.sh"

triage_tokens
now="${MROOM_NOW:-}"
[[ "$now" =~ ^[0-9]{1,12}$ ]] || now="$(date +%s)"
day="$(date -u -d "@$now" +%Y-%m-%d)"
key="triage:${day//-/}"
job_name="${MROOM_TRIAGE_JOB:-Alert triage}"
run="$(run_link)"

# failed_step: the triage job's first failed step, from the jobs API; empty when it cannot tell.
failed_step() {
  [ -n "${GITHUB_RUN_ID:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ] || return 0
  gh api "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/jobs" --jq '.jobs' 2>/dev/null | jq -r --arg j "$job_name" '
    [.[] | select(.name == $j or (.name | endswith(" / " + $j)))][0] // {}
    | [.steps[]? | select(.conclusion == "failure" or .conclusion == "cancelled" or .conclusion == "timed_out")][0].name // empty' \
    2>/dev/null | head -c 120 || true
}

step="$(failed_step)"
what="the triage job failed"
[ -z "$step" ] || what="the triage job failed at \"$step\""
persona="$(persona_name)"
echo "::error::alert triage did not run: $what${run:+ ($run)}" >&2

channel="$(persona_config persona.channel "")"
if [ -z "$channel" ]; then
  echo "::warning::mroom.toml sets no persona.channel, so the alarm has nowhere to ping" >&2
  exit 0
fi
tracker="$("$MROOM" tracker backend)" || exit 1
if [ "$tracker" = none ]; then
  echo "::warning::there is no tracker (issues.tracker = \"none\"), so the alarm cannot record that it pinged today, and does not ping" >&2
  exit 0
fi

found="$("$MROOM" persona find "$key")" || { triage_say "the tracker could not be searched, so the alarm does not ping"; exit 1; }
if [ "$(jq 'length' <<<"$found")" -gt 0 ]; then
  echo "The alarm already pinged today ($(jq -r '.[0].identifier' <<<"$found")); nothing sent."
  exit 0
fi

{
  echo "Alert triage could not run on $day: $what."
  echo
  [ -z "$run" ] || { echo "The run: $run"; echo; }
  echo "Until a run succeeds, no alert is filed. Each run looks back over its own window only, so alerts from"
  echo "a longer gap are not filed later: look at the error tracker for them."
  echo
  echo "This issue records that $persona pinged about it today, so it pings once a day at most."
} >"$WORK/alarm.md"
answer="$("$MROOM" persona create --key "$key" --title "Alert triage could not run ($day)" <"$WORK/alarm.md")" \
  || { triage_say "the day's issue could not be filed, so the alarm does not ping (a missed ping, never a repeated one)"; exit 1; }

issue="$(jq -r '.created // empty' <<<"$answer")"
url="$(jq -r '.url // empty' <<<"$answer")"
text="$(chat_escape "$persona: alert triage could not run: $what.")"
[ -z "$run" ] || text+=" <$run|Run>."
if [ -n "$url" ] && [[ "$url" =~ ^https://[A-Za-z0-9./_-]+$ ]]; then text+=" <$url|$(chat_escape "$issue")>."; fi
text+=" Who can look before the next run?"
if [ "${MROOM_PERSONA_LIVE:-}" != 1 ]; then
  jq -nc --arg c "$channel" --arg t "$text" '{dry_run: true, would: "ping", channel: $c, text: $t}'
  exit 0
fi
trap api_cleanup EXIT
api_tmp
chat_send "$channel" "$text" || { triage_say "the ping was not sent; $issue records it, so it is not sent again today"; exit 1; }
echo "Pinged: $what ($issue)."
