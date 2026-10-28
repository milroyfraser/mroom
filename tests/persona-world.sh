#!/usr/bin/env bash
# The world of the persona's tests (tests/persona-test.sh, tests/triage-test.sh): the tracker, the error tracker
# and chat faked as curl (tests/fakes/persona.py), GitHub as gh (tests/fakes/gh), and an app's mroom.toml.
# Sourced after tests/lib.sh, never run on its own. Every id, name and token is made up.
# shellcheck disable=SC2034  # variables here are read by the test files that source this one
# shellcheck disable=SC2016  # jq programs and the fake sleep's $1, not this shell's

LINEAR_TOKEN="lin_api_fakePERSONA0123456789abcdef"
SENTRY_TOKEN="fake-sentry-read-token-0123456789"
CHAT_TOKEN="xoxb-fake-chat-0123456789"
NOW_ISO="2026-10-28T12:00:00Z"
NOW_EPOCH="$(date -u -d "$NOW_ISO" +%s)"

# pworld [<extra mroom.toml lines>]: a fresh world. The tracker holds no issue and the error tracker no alert
# until a test adds them (add_issue, add_alert).
pworld() {
  mkdir -p "$T/bin" "$T/tmp" "$T/state" "$T/gh"
  printf '#!/bin/sh\nexec python3 -I "%s" "$@"\n' "$ROOT/tests/fakes/persona.py" >"$T/bin/curl"
  printf '#!/bin/sh\necho "$1" >>"%s/sleep.log"\n' "$T" >"$T/bin/sleep"
  cp "$ROOT/tests/fakes/gh" "$T/bin/gh"
  chmod +x "$T/bin/curl" "$T/bin/sleep" "$T/bin/gh"
  export PATH="$T/bin:$PATH" TMPDIR="$T/tmp" PERSONA_STATE="$T/world.json" PERSONA_LOG="$T/calls.jsonl"
  export GH_FAKE="$T/gh" MROOM_NOW="$NOW_EPOCH" MROOM_API_RATE_SLEEP=1
  export LINEAR_API_KEY="$LINEAR_TOKEN" SENTRY_AUTH_TOKEN="$SENTRY_TOKEN"
  export MROOM_PERSONA_STATE="$T/state" MROOM_PERSONA_LIVE=1 MROOM_CONFIG="$T/mroom.toml"
  export MROOM_PERSONA_RUN_URL="https://github.com/example/shop/actions/runs/777"
  export GITHUB_REPOSITORY=example/shop GITHUB_RUN_ID=777 GITHUB_OUTPUT="$T/output" GITHUB_STEP_SUMMARY="$T/summary.md"
  export GITHUB_WORKFLOW_REF="example/shop/.github/workflows/alerts.yml@refs/heads/main"
  unset MROOM_PERSONA_ALERTS MROOM_TRIAGE_TRACKER_TOKEN MROOM_TRIAGE_ERRORS_TOKEN SLACK_BOT_TOKEN
  : >"$T/output"
  : >"$T/calls.jsonl"
  {
    printf '[app]\nname = "shop"\n\n'
    printf '[issues]\ntracker = "linear"\nteam = "ENG"\nid_pattern = "ENG-[0-9]+"\nurl = "https://tracker.example.dev/issue/{id}"\n\n'
    printf '[errors]\nprovider = "sentry"\norg = "example-org"\n\n'
    printf '[release]\nproduction_url = "https://shop.example.dev"\n\n'
    printf '[persona]\nname = "Bot One"\nlabel = "found-by-agent"\nstate = "Triage"\nchannel = "C0123456789"\n'
    [ -z "${1:-}" ] || printf '%s\n' "$1"
  } >"$T/mroom.toml"
  jq -n '{viewer: "u-persona", team: {id: "t-1", key: "ENG"},
    states: [{id: "s-backlog", name: "Backlog", type: "backlog"}, {id: "s-triage", name: "Triage", type: "triage"},
             {id: "s-done", name: "Done", type: "completed"}],
    labels: [{id: "l-1", name: "found-by-agent"}], issues: [], next: 1,
    sentry: {projects: [{slug: "web"}], new: [], regressed: [], escalating: [], events: {}}}' >"$T/world.json"
}

# toml <mroom.toml text>: replaces the app's mroom.toml.
toml() { printf '%s\n' "$1" >"$T/mroom.toml"; }

# world_set [<jq option>...] <jq filter>: changes the fake's state.
world_set() { jq "$@" "$T/world.json" >"$T/world.next" && mv "$T/world.next" "$T/world.json"; }

# add_issue <identifier> <creator> <description>: an issue already in the tracker.
add_issue() {
  world_set --arg i "$1" --arg c "$2" --arg d "$3" '.issues += [{id: ("uuid-" + $i), identifier: $i, title: "Earlier",
    description: $d, url: ("https://tracker.example.dev/issue/" + $i), createdAt: "2026-10-01T00:00:00Z",
    creator: $c, assignee: null, state: "s-triage", labels: [], comments: []}]'
}

# add_alert <new|regressed|escalating> <id> <seen at> [<title>]: an error-tracker issue in that search.
add_alert() {
  local first="$3"
  [ "$1" = new ] || first="2026-09-01T00:00:00Z"
  world_set --arg k "$1" --arg id "$2" --arg f "$first" --arg l "$3" --arg t "${4:-TypeError: x is undefined}" \
    '.sentry[$k] += [{id: $id, shortId: ("SHOP-" + $id), title: $t, culprit: "app/checkout",
      permalink: ("https://example-org.sentry.io/issues/" + $id + "/"), level: "error", status: "unresolved",
      substatus: "new", count: "42", userCount: 7, firstSeen: $f, lastSeen: $l,
      firstRelease: {version: "v1.2.0"}, lastRelease: {version: "v1.3.0"}, project: {slug: "web"}}]'
}

# add_event <id> <message>: the latest event of an error-tracker issue, with a user's address in its tags.
add_event() {
  world_set --arg id "$1" --arg m "$2" '.sentry.events[$id] = {eventID: "ev-1", dateCreated: "2026-10-28T11:58:00Z",
    message: $m, title: $m, release: {version: "v1.3.0"},
    tags: [{key: "environment", value: "production"}, {key: "url", value: "https://shop.example.dev/cart?u=pat@example.com"}],
    entries: [{type: "exception", data: {values: [{type: "TypeError", value: $m,
      stacktrace: {frames: [{filename: "src/cart.ts", function: "total", lineNo: 12, inApp: true}]}}]}}]}'
}

# issues: the tracker's issues now. issue <identifier>: one of them.
issues() { jq -c '.issues' "$T/world.json"; }
issue() { jq -c --arg i "$1" '.issues[] | select(.identifier == $i)' "$T/world.json"; }
# ops <service> [<op>]: the calls of that service (and Linear operation) so far.
ops() {
  if [ -n "${2:-}" ]; then jq -c --arg s "$1" --arg o "$2" 'select(.service == $s and .op == $o)' "$T/calls.jsonl"
  else jq -c --arg s "$1" 'select(.service == $s)' "$T/calls.jsonl"; fi
}
count_ops() { ops "$@" | wc -l | tr -d ' '; }
# output_of <name>: the last value written to GITHUB_OUTPUT for that name.
output_of() { sed -n "s/^$1=//p" "$T/output" | tail -n1; }
json_is() { jq -e "$2" <<<"$1" >/dev/null 2>&1; }
lacks() { case "$1" in *"$2"*) return 1 ;; esac; }
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
