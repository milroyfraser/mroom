#!/usr/bin/env bash
# switch-off.sh — the stop that outlasts a run (actions/triage): when the tracker did not keep the hidden
# markers on an issue triage filed, this turns the app's triage workflow off and asks a person once. Without
# the markers, every run would file the same alerts again, every 15 minutes; turned off, the workflow runs
# no more until a person turns it on again, so the ping goes out once. The workflow's switch-off job runs it,
# with an actions: write token the triage job never holds.
#
#   switch-off.sh <issue id>
#
# Environment: MROOM_CONFIG, GH_TOKEN (actions: write), GITHUB_REPOSITORY, GITHUB_WORKFLOW_REF (the app's
# workflow, which called mroom's), MROOM_PERSONA_RUN_URL, SLACK_BOT_TOKEN. Always exits 1, so the run shows
# red: a person must look, whether the workflow was turned off (the log says which) or not.
set -euo pipefail
TRIAGE_NAME="mroom triage switch-off"
# shellcheck source=actions/triage/common.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")/common.sh"
# shellcheck source=lib/core/api.sh
. "$MROOM_ROOT/lib/core/api.sh"
# shellcheck source=lib/core/chat.sh
. "$MROOM_ROOT/lib/core/chat.sh"

issue="${1:-}"
[[ "$issue" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || { triage_say "usage: switch-off.sh <issue id>"; exit 2; }
repo="${GITHUB_REPOSITORY:-}"
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { triage_say "GITHUB_REPOSITORY is not owner/name"; exit 2; }
# owner/repo/.github/workflows/<file>@<ref>: the app's own workflow, the one that runs on a schedule.
workflow="${GITHUB_WORKFLOW_REF:-}"
workflow="${workflow%%@*}"
workflow="${workflow##*/}"
[[ "$workflow" =~ ^[A-Za-z0-9_.-]+\.ya?ml$ ]] || { triage_say "GITHUB_WORKFLOW_REF names no workflow file"; exit 2; }

disabled=false
gh workflow disable "$workflow" --repo "$repo" && disabled=true
run="$(run_link)"
persona="$(persona_name)"
if $disabled; then
  text="$(chat_escape "$persona: alert triage switched itself off: the tracker did not keep the hidden markers on $issue, so every run would file the same alerts again.")"
  echo "::error::the tracker did not keep the hidden markers on $issue; $workflow is turned off" >&2
else
  text="$(chat_escape "$persona: alert triage could NOT switch itself off: the tracker did not keep the hidden markers on $issue, so every run will file the same alerts again.")"
  echo "::error::the tracker did not keep the hidden markers on $issue, and $workflow could not be turned off" >&2
fi
[ -z "$run" ] || text+=" <$run|Run>."
if $disabled; then
  text+=" Who checks how the tracker stores the markers (mroom's README, \"Alert triage\") before turning $(chat_escape "$workflow") on again?"
else
  text+=" Can someone turn $(chat_escape "$workflow") off by hand (Actions, the workflow, Disable workflow)?"
fi

channel="$(persona_config persona.channel "")"
if [ -z "$channel" ]; then
  echo "::warning::mroom.toml sets no persona.channel, so no one is pinged" >&2
elif [ -z "${SLACK_BOT_TOKEN:-}" ]; then
  echo "::warning::the persona environment has no chat token, so no one is pinged" >&2
else
  trap api_cleanup EXIT
  api_tmp
  chat_send "$channel" "$text" || echo "::warning::the ping was not sent" >&2
fi
exit 1
