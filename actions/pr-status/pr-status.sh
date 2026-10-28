#!/usr/bin/env bash
# pr-status.sh — one status note per pull request, edited in place, and a chat ping when its author must act
# (design section 11, phase 5; actions/pr-status).
#
#   MROOM_PR_STATUS_LIVE=1 pr-status.sh <pr>   what the action runs: writes the note and sends the pings
#   pr-status.sh <pr>                          anyone else: a dry run that prints, as JSON, the note, what it
#                                              would do with it and the pings, and changes nothing
#   pr-status.sh --closed-not-final            the PRs closed in the last day whose note is not final yet
#
# The note is one comment on the PR, by github-actions[bot]: a heading, then a line each for the QA
# environment, CI, the Claude review, the review findings check and browser QA, each naming the commit it
# refers to (render.jq says what each line rests on). Every run rebuilds it from GitHub, so it does not matter
# which event woke the run, or in what order events came. Under the note, a hidden line holds what the next run
# needs:
#
#   <!-- mroom-pr-status pr=42 final=0 sent=aaaaaaa11111:ci:failed,once:ready:ready -->
#
# Pings go to persona.channel and mention the author through the chat user map (persona.chat_users, read from
# the default branch). A ping goes out when a person must act: CI turned red, the review has blocking findings,
# the deploy failed, browser QA failed or could not verify, and once per PR "ready for review". None for a
# draft or a closed PR, nor for one from outside the repository's people: only a PR by its owner, a member or a
# collaborator, from a branch of the repository itself, pings anyone (on a public repository, anyone can open
# one).
#
# What keeps it to one note, and to at most one ping per change:
#   - The note is found by its hidden line. Should that line be lost (a person edited the comment), the note
#     is found by its footer instead and edited in place, never posted again; and since what was sent is lost
#     with the line, this run's pings and the once-per-PR "ready" are recorded as sent without being sent. A
#     failure that comes back later on the same commit could then ping again; anything else is missed.
#   - Should there be two notes (a create whose answer was lost, and a later run that made another), the oldest
#     is the note, the pings any of them recorded count as sent, and the others are edited once to say so.
#   - A ping is recorded in the note before it goes out. When the note cannot be written, no ping goes out;
#     when a ping fails after that, it is missed, not retried.
#   - A closed PR's note shows its final state, and is left alone until the PR reopens. It is marked final only
#     once GitHub took that edit; --closed-not-final lists the PRs still waiting for it, for a retry.
#   - The workflow runs one update per PR at a time (.github/workflows/pr-status.yml), so the read and the
#     write of the note never interleave.
#
# Environment:
#   GH_TOKEN, GITHUB_REPOSITORY           the job token, and owner/name
#   MROOM_CONFIG                          the default branch's mroom.toml
#   SLACK_BOT_TOKEN                       the chat bot's token; without it no pings go out (a notice says so)
#   MROOM_DEFAULT_BRANCH                  where the chat user map is read (the repository's default if unset)
#   MROOM_PR_STATUS_LIVE=1                act: write the note and send pings. Only the action sets it.
#   MROOM_PR_STATUS_DRY_RUN=1             a dry run even with MROOM_PR_STATUS_LIVE=1
#   MROOM_PR_STATUS_REVIEWER              the login that posts the Claude review (claude[bot])
#   MROOM_PR_STATUS_REVIEW_CHECK          the review's check run (claude / review)
#   MROOM_PR_STATUS_FINDINGS_CHECK        the review findings check run (Review findings); empty for none
#   MROOM_PR_STATUS_BROWSER_CHECK         the browser QA check run (none by default, until phase 2b)
#   MROOM_PR_STATUS_QA_WORKFLOW           the app's qa-up workflow file (qa-up.yml)
#   MROOM_PR_STATUS_QA_DEPLOY_JOB         the deploy job in it (QA deploy), which qa-up names
#                                         "QA deploy · PR #<n>" for the PR it resolved
#
# Nothing fails the run: every call has a timeout or a bound, every failure (GitHub's, chat's, a note that
# could not be saved) is a warning, and the exit status is always 0, but for a usage error (2).

set -uo pipefail
umask 077

SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
HERE="$(cd "$(dirname "$SELF")" && pwd)"
MROOM_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/core/util.sh
. "$MROOM_ROOT/lib/core/util.sh"

REPO="${GITHUB_REPOSITORY:-}"
BOT='github-actions[bot]'
MARK='<!-- mroom-pr-status pr='
# The words render.jq ends the note with (its footer), by which a note whose hidden line was lost is found.
FOOTER="Edited in place by mroom's pr-status"
# The line render.jq ends a note with, and the start of its heading: a comment the footer fallback takes over
# must hold both, so a bot comment that only quotes the words is never taken for a note.
FOOTER_LINE="<sub>$FOOTER; each line names the commit it refers to.</sub>"
# The keys the hidden line keeps: the "once" ones, and the newest of the others. An older key is for a commit
# long gone, whose pings cannot come again.
MAX_SENT=200
REVIEWER="${MROOM_PR_STATUS_REVIEWER:-claude[bot]}"
REVIEW_CHECK="${MROOM_PR_STATUS_REVIEW_CHECK:-claude / review}"
# Set and empty: the app has no such check.
FINDINGS_CHECK="${MROOM_PR_STATUS_FINDINGS_CHECK-Review findings}"
BROWSER_CHECK="${MROOM_PR_STATUS_BROWSER_CHECK-}"
QA_WORKFLOW="${MROOM_PR_STATUS_QA_WORKFLOW:-qa-up.yml}"
QA_DEPLOY_JOB="${MROOM_PR_STATUS_QA_DEPLOY_JOB:-QA deploy}"
SLACK_URL=https://slack.com/api/chat.postMessage

warn() { echo "::warning::pr-status: $*" >&2; }
notice() { echo "::notice::pr-status: $*" >&2; }

# cfg <key> <default>: one value from mroom.toml, through the one reader. Fails on a broken mroom.toml.
cfg() { python3 "$MROOM_ROOT/lib/core/config.py" get "$1" --default "$2" "${@:3}"; }

# cfg_opt <key> [--json]: the key's value, or nothing (null with --json) when it is not set; fails on a broken
# mroom.toml, as cfg does.
cfg_opt() {
  local value err rc=0
  err="$(mktemp)"
  value="$(python3 "$MROOM_ROOT/lib/core/config.py" get "$@" 2>"$err")" || rc=$?
  if [ "$rc" = 0 ]; then printf '%s\n' "$value"
  elif [ "$rc" = 1 ] && grep -q "^mroom config: $1 is not set in " "$err"; then [ "${2:-}" != --json ] || echo null
  else cat "$err" >&2; rm -f "$err"; return 1; fi
  rm -f "$err"
}

# settings: what the run reads from mroom.toml and the environment, as JSON on stdout; fails, saying why, when
# mroom.toml cannot be read or an input is malformed.
settings() {
  local name channel users agent pattern url required
  if ! { name="$(cfg persona.name Agent)" && channel="$(cfg_opt persona.channel)" \
    && users="$(cfg persona.chat_users .github/chat-users.json)" && agent="$(cfg_opt github.agent_login)" \
    && pattern="$(cfg_opt issues.id_pattern)" && url="$(cfg_opt issues.url)" \
    && required="$(cfg pr.required_checks '[]' --json)"; }; then
    warn "could not read mroom.toml"; return 1
  fi
  [[ "$REVIEWER" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}(\[bot\])?$ ]] || { warn "the reviewer is not a GitHub login"; return 1; }
  [[ "$QA_WORKFLOW" =~ ^[A-Za-z0-9._-]{1,100}\.ya?ml$ ]] || { warn "the qa-up workflow is not a workflow file name"; return 1; }
  local check
  for check in "$REVIEW_CHECK" "$QA_DEPLOY_JOB"; do
    [[ "$check" =~ ^[^[:cntrl:]]{1,100}$ ]] || { warn "a check or job name must be one line of 1 to 100 characters"; return 1; }
  done
  for check in "$FINDINGS_CHECK" "$BROWSER_CHECK"; do
    [[ "$check" =~ ^[^[:cntrl:]]{0,100}$ ]] || { warn "a check name must be one line of at most 100 characters"; return 1; }
  done
  jq -nc --arg name "$name" --arg channel "$channel" --arg users "$users" --arg agent "$agent" \
    --arg pattern "$pattern" --arg url "$url" --argjson required "$required" --arg reviewer "$REVIEWER" \
    --arg rc "$REVIEW_CHECK" --arg fc "$FINDINGS_CHECK" --arg bc "$BROWSER_CHECK" \
    '{name: $name, channel: $channel, users_path: $users, agent: $agent, id_pattern: $pattern, issue_url: $url,
      required: $required, reviewer: $reviewer, review_check: $rc, findings_check: $fc, browser_check: $bc}'
}

# required_checks <base branch> <mroom.toml's list> — {names, from}: the required checks on the base branch, of
# its rulesets and of its classic branch protection; mroom.toml's pr.required_checks when those name none, or
# ("config-unverified") cannot be read; "unread" when neither gives a list.
required_checks() {
  local rules="" classic="" got=false
  if [[ "$1" =~ ^[A-Za-z0-9._/-]{1,200}$ ]] && rules="$(gh api "repos/$REPO/rules/branches/$1" \
    --jq '[.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context]' 2>/dev/null)" \
    && classic="$(gh api "repos/$REPO/branches/$1" \
    --jq '[(.protection.required_status_checks // {}) | (.checks[]?.context), (.contexts[]?)]' 2>/dev/null)"; then
    got=true
  fi
  jq -nc --argjson got "$got" --arg rules "$rules" --arg classic "$classic" --argjson config "$2" '
    ([$rules, $classic] | map(if . == "" then [] else fromjson end) | add | unique) as $rules
    | if ($rules | length) > 0 then {names: $rules, from: "ruleset"}
      elif ($config | length) > 0 then {names: $config, from: (if $got then "config" else "config-unverified" end)}
      elif $got then {names: [], from: "none"}
      else {names: [], from: "unread"} end'
}

# chat_users <path> <ref> — the chat user map on that ref, keeping only entries that map a login or an email to a
# chat user id; {} when there is none or it cannot be read (pings then name the author instead).
chat_users() {
  local raw
  if ! raw="$(gh api "repos/$REPO/contents/$1?ref=$2" -H 'Accept: application/vnd.github.raw' 2>/dev/null)"; then
    printf '{}'; return 0
  fi
  jq -c 'if type == "object" then with_entries(select((.key | type == "string" and length <= 254 and test("^[^\\s<>|]+$"))
    and (.value | type == "string" and test("^[UW][A-Z0-9]{2,20}$")))) else {} end' <<<"$raw" 2>/dev/null || {
    warn "the chat user map $1 is not JSON; pings name authors instead"; printf '{}'; }
}

# ping_login <pr> <author> <agent login> <users> — whom a ping about the PR mentions: its author, unless that is
# the agents' account (design D22). Then the developer whose session made it, from the PR's first commit, which a
# profile writes under its developer's name: its GitHub account when the map has it, else its email when the map
# has that. Anything else, such as the agents' own commit or a bot's, keeps the agents' account, which the map
# sends to its developer. Later commits never count: a reviewer's committed suggestion or a bot's fix is not the
# session's.
ping_login() {
  local who
  if [ -z "$3" ] || [ "$2" != "$3" ]; then echo "$2"; return 0; fi
  while IFS= read -r who; do
    if [ -n "$who" ] && jq -e --arg w "$who" 'has($w)' <<<"$4" >/dev/null 2>&1; then echo "$who"; return 0; fi
  done < <(gh api "repos/$REPO/pulls/$1/commits?per_page=1" --jq '.[0] | (.author.login // ""), (.commit.author.email // "")' 2>/dev/null || true)
  echo "$2"
}

# qa_run <pr> — the app's latest qa-up run for the PR, with its deploy job, or null. qa-up runs on workflow_run,
# or on a dispatch, so GitHub links its run to no PR: its run-name ends in "PR #<n>" (README, QA environments).
# A run-name can come from a fork's own QA plan, though, so a run counts only when its deploy job, which qa-up
# names after the PR it resolved itself ("QA deploy · PR #<n>"), names this PR. A run whose deploy job names
# another PR is passed over, and so is one whose jobs cannot be read. A run whose deploy job names none (qa-up
# resolved no PR to deploy, and skipped it), or that has none yet, counts as one that deploys nothing: while it
# runs it can only say "planning", and once done, the QA environment comment speaks. A fork's own QA plan can
# make such a run, which can say no more than that. An app without that workflow has no runs. Fails when GitHub
# did not answer.
qa_run() {
  local runs err id run jobs deploy
  err="$(mktemp)"
  if ! runs="$(gh api -X GET "repos/$REPO/actions/workflows/$QA_WORKFLOW/runs" -F per_page=100 --jq "
      [.workflow_runs[] | select(.conclusion != \"skipped\")
       | select(([.pull_requests[]?.number] | index($1)) or ((.display_title // \"\") | endswith(\"PR #$1\")))]
      | sort_by(.created_at) | reverse | .[0:5][] | {id, status, conclusion, html_url} | tojson" 2>"$err")"; then
    if grep -q 'HTTP 404' "$err"; then rm -f "$err"; echo null; return 0; fi
    cat "$err" >&2; rm -f "$err"; return 1
  fi
  rm -f "$err"
  while IFS= read -r run; do
    id="$(jq -r '.id' <<<"$run")"
    [[ "$id" =~ ^[0-9]{1,20}$ ]] || continue
    # Its jobs: the deploy job's own result, since the run also holds the plan and what follows the deploy.
    jobs="$(gh api "repos/$REPO/actions/runs/$id/jobs?per_page=100" --jq "[.jobs[] | {name, status, conclusion, html_url}]" 2>/dev/null)" \
      && [ -n "$jobs" ] || continue
    # A called workflow's job is "<caller job> / <its name>".
    deploy="$(jq -c --arg p "$QA_DEPLOY_JOB · PR #" --arg n "$1" '
      [.[] | (.name | split(" / ") | last) as $name
       | select($name | startswith($p) and (.[($p | length):] | test("^[0-9]{1,9}$")))
       | . + {pr: $name[($p | length):]}] | last
      | if . == null then null elif .pr == $n then del(.name, .pr) else "other" end' <<<"$jobs")" || continue
    [ "$deploy" != '"other"' ] || continue
    jq -c --argjson d "$deploy" '.deploy = $d | del(.id)' <<<"$run"
    return 0
  done <<<"$runs"
  echo null
}

# collect <pr> <settings> — every fact render.jq reads, as one JSON document. The parts go through files: a busy
# PR's comments are too long for a command line.
collect() {
  local pr="$1" s="$2" tmp sha base author login rc=0 branch
  tmp="$(mktemp -d)"
  {
    gh api "repos/$REPO/pulls/$pr" --jq "{number, title: (.title // \"\"), body: (.body // \"\"), url: .html_url,
        author_login: .user.login, draft, state, merged, head_sha: .head.sha, head_ref: .head.ref, base_ref: .base.ref,
        trusted: ((.author_association | IN(\"OWNER\", \"MEMBER\", \"COLLABORATOR\")) and .head.repo.full_name == \"$REPO\")}" >"$tmp/pr" \
      && sha="$(jq -r .head_sha "$tmp/pr")" && [[ "$sha" =~ ^[0-9a-f]{40}$ ]] \
      && base="$(jq -r .base_ref "$tmp/pr")" && author="$(jq -r .author_login "$tmp/pr")" \
      && branch="${MROOM_DEFAULT_BRANCH:-$(gh api "repos/$REPO" --jq .default_branch)}" \
      && chat_users "$(jq -r .users_path <<<"$s")" "$branch" >"$tmp/users" \
      && login="$(ping_login "$pr" "$author" "$(jq -r .agent <<<"$s")" "$(cat "$tmp/users")")" \
      && { { [[ "$login" =~ ^[A-Za-z0-9-]{1,39}(\[bot\])?$ ]] && gh api "users/$login" --jq '{name: (.name // "")}' 2>/dev/null; } \
        || echo '{"name": ""}'; } >"$tmp/user" \
      && required_checks "$base" "$(jq -c .required <<<"$s")" >"$tmp/required" \
      && gh api --paginate "repos/$REPO/commits/$sha/check-runs?per_page=100" \
        --jq '.check_runs[] | {id, name, status, conclusion, html_url, title: .output.title, external_id}' >"$tmp/checks" \
      && gh api --paginate "repos/$REPO/issues/$pr/comments?per_page=100" \
        --jq '.[] | {id, login: .user.login, body: (.body // ""), html_url}' >"$tmp/comments" \
      && qa_run "$pr" >"$tmp/qa" \
      && jq -n --slurpfile pr "$tmp/pr" --slurpfile user "$tmp/user" --slurpfile required "$tmp/required" \
        --slurpfile checks "$tmp/checks" --slurpfile comments "$tmp/comments" --slurpfile qa "$tmp/qa" \
        --slurpfile users "$tmp/users" --argjson s "$s" --arg login "$login" --arg branch "$branch" '
        {pr: ($pr[0] | .author_login = $login | .author_name = (if $user[0].name == "" then $login else $user[0].name end)),
         default_branch: $branch, required: $required[0], checks: $checks, comments: $comments, qa_run: $qa[0], users: $users[0],
         cfg: ($s | {name, reviewer, review_check, findings_check, browser_check, id_pattern, issue_url})}'
  } || rc=1
  rm -rf "$tmp"
  return "$rc"
}

render() { jq -L "$MROOM_ROOT/actions/review-findings" -f "$HERE/render.jq"; }

# read_note <pr> — the PR's note, from the facts on stdin: {id, body, found: marker | footer | none, final, sent,
# dupes: [the other notes' ids]}. found is footer when a note's hidden line was lost or cannot be read; sent then
# holds only what the readable ones recorded. sent keeps the order the keys were recorded in, oldest first.
read_note() {
  jq -c --arg bot "$BOT" --arg mark "$MARK$1 " --arg footer "$FOOTER_LINE" '
    def ordered: reduce .[] as $k ([]; if index([$k]) then . else . + [$k] end);
    [.comments[] | select(.login == $bot)] as $mine
    | ($mark | gsub("(?<c>[.*+?()\\[\\]{}|^$\\\\])"; "\\\(.c)")) as $re
    | [$mine[] | select(.body | contains($mark))
       | . + {state: (first(.body | capture("(^|\n)" + $re + "final=(?<f>[01]) sent=(?<s>[a-z0-9:,-]*) -->$")) // null)}]
      | sort_by(.id) as $marked
    | [$mine[] | select((.body | contains($mark) | not) and (.body | split("\n") | any(. == $footer))
        and (.body | test("^\\S+ \\*\\*[A-Za-z0-9 _-]+\u0027s notes\\*\\* · ")))] as $lost
    | ([$marked[] | .state | select(.) | .s | split(",")[] | select(test("^([0-9a-f]{12}|once):[a-z]+:[a-z-]+$"))] | ordered) as $sent
    | (($marked + $lost) | sort_by(.id)) as $all
    | if ($all | length) == 0 then {id: null, body: null, found: "none", final: false, sent: [], dupes: []}
      elif ($marked | length) > 0 and ([$marked[] | .state] | all(. != null)) then
        {id: $marked[0].id, body: $marked[0].body, found: "marker", final: ($marked[0].state.f == "1"), sent: $sent,
         dupes: [($marked[1:] + $lost)[] | .id]}
      else
        {id: $all[0].id, body: $all[0].body, found: "footer", final: false, sent: $sent, dupes: [$all[1:][] | .id]}
      end'
}

# note_text <render output> <pr> <final> <sent keys as JSON, oldest first> — the note as it is to be: the rendered
# body and the hidden line. The once keys always stay; of the others, the newest MAX_SENT.
note_text() {
  jq -rn --slurpfile out <(printf '%s' "$1") --arg mark "$MARK$2 " --argjson final "$3" --argjson sent "$4" --argjson max "$MAX_SENT" '
    ([$sent[] | select(startswith("once:"))] + ([$sent[] | select(startswith("once:") | not)] | .[-$max:])) as $keep
    | "\($out[0].body)\n\n\($mark)final=\(if $final then 1 else 0 end) sent=\($keep | join(",")) -->"'
}

# note_write <pr> <id or ""> <text> — edits the note, or makes it. The text goes to gh as a JSON request on stdin,
# never as an argument. Returns 1 (and warns) when GitHub refused or did not answer.
note_write() {
  if [ -n "$2" ]; then
    [[ "$2" =~ ^[0-9]{1,20}$ ]] || { warn "the note's id is not a number"; return 1; }
    printf '%s' "$3" | jq -Rs '{body: .}' | gh api -X PATCH "repos/$REPO/issues/comments/$2" --input - >/dev/null \
      || { warn "could not edit the note on PR #$1"; return 1; }
  else
    printf '%s' "$3" | jq -Rs '{body: .}' | gh api -X POST "repos/$REPO/issues/$1/comments" --input - >/dev/null \
      || { warn "could not post the note on PR #$1"; return 1; }
  fi
}

# chat_ping <channel> <mrkdwn> — one message. The token reaches curl through a file descriptor and the message on
# stdin, so neither is in the process list. Returns 1 when Slack refused it or did not answer within 5 seconds.
chat_ping() {
  local -
  set +x
  local resp
  resp="$(jq -nc --arg c "$1" --arg t "$2" '{channel: $c, text: $t, unfurl_links: false, unfurl_media: false}' \
    | curl -sS --max-time 5 -X POST --data-binary @- \
      -K <(printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json; charset=utf-8"\n' "$SLACK_BOT_TOKEN") \
      "$SLACK_URL" 2>/dev/null)" || { warn "chat did not answer"; return 1; }
  jq -e '.ok == true' <<<"$resp" >/dev/null 2>&1 && return 0
  warn "chat refused the ping: $(jq -r '.error // "an answer without a reason"' <<<"$resp" 2>/dev/null | head -c 80)"
  return 1
}

# closed_not_final — the PRs closed in the last day (among the 20 most recently updated closed ones) whose note is
# not final yet, one number per line.
closed_not_final() {
  local since n
  since="$(date -u -d "@$(($(mroom_now) - 86400))" +%Y-%m-%dT%H:%M:%SZ)"
  gh api "repos/$REPO/pulls?state=closed&sort=updated&direction=desc&per_page=20" \
    --jq ".[] | select(.closed_at != null and .closed_at >= \"$since\" and .user.login != \"dependabot[bot]\") | .number" 2>/dev/null \
    | while read -r n; do
        [[ "$n" =~ ^[0-9]{1,9}$ ]] || continue
        gh api --paginate "repos/$REPO/issues/$n/comments?per_page=100" --jq '.[] | {id, login: .user.login, body: (.body // "")}' 2>/dev/null \
          | jq -s '{comments: .}' | read_note "$n" | jq -e '.found != "none" and (.final | not)' >/dev/null && echo "$n"
      done
  return 0
}

main() {
  local pr="${1:-}" s facts out note pending keys sent text action live=false channel n alert key can_chat id
  [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "pr-status: GITHUB_REPOSITORY (owner/name) is not set" >&2; return 2; }
  if [ "$pr" = --closed-not-final ]; then closed_not_final; return 0; fi
  [[ "$pr" =~ ^[1-9][0-9]{0,8}$ ]] || { echo "usage: pr-status.sh <pr> | --closed-not-final" >&2; return 2; }
  [ "${MROOM_PR_STATUS_LIVE:-}" = 1 ] && [ "${MROOM_PR_STATUS_DRY_RUN:-}" != 1 ] && live=true

  s="$(settings)" || return 0
  facts="$(collect "$pr" "$s")" || { warn "could not read PR #$pr from GitHub; the next event tries again"; return 0; }
  if [ "$(jq -r .pr.author_login <<<"$facts")" = "dependabot[bot]" ]; then notice "PR #$pr is Dependabot's"; return 0; fi
  # Its own events run its base branch's copy of the app's workflow, which the persona environment refuses: a note
  # it could not keep current is none at all.
  if [ "$(jq -r '.pr.base_ref == .default_branch' <<<"$facts")" != true ]; then
    notice "PR #$pr is based on another branch than the default; it gets no note"; return 0
  fi
  out="$(render <<<"$facts")" || { warn "could not render PR #$pr"; return 0; }
  note="$(read_note "$pr" <<<"$facts")"
  channel="$(jq -r .channel <<<"$s")"

  # What the notes recorded as sent; with a hidden line lost, this run's pings and the ready one count as sent,
  # unsent.
  sent="$(jq -c .sent <<<"$note")"
  if [ "$(jq -r .found <<<"$note")" = footer ]; then
    warn "PR #$pr: the note's hidden line was lost, so what was pinged is not known; this run's pings are recorded, not sent"
    sent="$(jq -c --slurpfile o <(printf '%s' "$out") '. + [$o[0].alerts[].key, "once:ready:ready"]
      | reduce .[] as $k ([]; if index([$k]) then . else . + [$k] end)' <<<"$sent")"
  fi
  [ "$(jq '.dupes | length' <<<"$note")" = 0 ] || warn "PR #$pr has more than one note; the oldest is kept current"
  pending="$(jq -c --argjson sent "$sent" '[.alerts[] | select(.key as $k | $sent | index($k) | not)]' <<<"$out")"
  n="$(jq length <<<"$pending")"
  # Without a token or a channel nothing is sent, and nothing recorded: the pings go once chat is set up. A dry
  # run still shows them. (${SLACK_BOT_TOKEN:+x}, so a trace never prints the token.)
  can_chat=true
  [ -n "${SLACK_BOT_TOKEN:+x}" ] && [ -n "$channel" ] || can_chat=false
  if [ "$n" -gt 0 ] && [ "$can_chat" != true ] && [ "$live" = true ]; then
    notice "PR #$pr: no chat token or no persona.channel, so $n ping(s) are not sent"
    pending='[]' n=0
  fi
  keys="$(jq -c --argjson p "$pending" '. + [$p[].key] | reduce .[] as $k ([]; if index([$k]) then . else . + [$k] end)' <<<"$sent")"

  action="write"
  if [ "$(jq -r .final <<<"$out")" = true ] && [ "$(jq -r '.found == "marker" and .final and (.dupes | length) == 0' <<<"$note")" = true ]; then
    action="none (PR closed, note final)"
  else
    text="$(note_text "$out" "$pr" "$(jq .final <<<"$out")" "$keys")"
    if [ "$(jq -r .found <<<"$note")" != none ] && [ "$(jq -r .body <<<"$note")" = "$text" ] \
      && [ "$(jq '.dupes | length' <<<"$note")" = 0 ]; then
      action="none (unchanged)"
    elif [ "$(jq -r .found <<<"$note")" = none ]; then
      action=create
    else
      action=edit
    fi
  fi

  if [ "$live" != true ]; then
    [ "${MROOM_PR_STATUS_DRY_RUN:-}" = 1 ] || echo "pr-status: a dry run; only the action (MROOM_PR_STATUS_LIVE=1) writes or pings" >&2
    jq -n --arg action "$action" --arg text "${text:-}" --slurpfile o <(printf '%s' "$out") --argjson pending "$pending" \
      --argjson sent "$sent" --arg channel "$channel" --argjson can "$can_chat" '
      $o[0] as $out
      | {note: {action: $action, body: (if $text == "" then null else $text end)}, final: $out.final, draft: $out.draft,
       chat: {channel: $channel, can_send: $can, pings: $pending,
              already_sent: ([$out.alerts[].key] | map(select(. as $k | $sent | index($k))))}}'
    return 0
  fi

  case "$action" in
    none*) notice "PR #$pr: note $action"; return 0 ;;
  esac
  # The pings are in the note before they go out: when it cannot be written, none go.
  note_write "$pr" "$(jq -r '.id // ""' <<<"$note")" "$text" || {
    [ "$n" = 0 ] || warn "PR #$pr: $n ping(s) not sent, since the note that records them was not saved"
    return 0
  }
  notice "PR #$pr: note $([ "$action" = create ] && echo posted || echo edited)"
  # The other notes, whose keys the note now holds, are edited once to say so: without the hidden line or the
  # footer, they count no more.
  for id in $(jq -r '.dupes[]' <<<"$note"); do
    note_write "$pr" "$id" "_A second copy of this pull request's status note; the first one is kept current._" \
      || warn "PR #$pr: a second copy of the note was left as it is"
  done
  while IFS= read -r alert; do
    [ -n "$alert" ] || continue
    key="$(jq -r .key <<<"$alert")"
    if chat_ping "$channel" "$(jq -r .text <<<"$alert")"; then notice "PR #$pr: pinged $key"
    else warn "PR #$pr: ping $key not sent; it is recorded, so it is not tried again"; fi
  done < <(jq -c '.[]' <<<"$pending")
  return 0
}

# Sourced by the tests for its functions; run, it updates one PR.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
  exit $?
fi
