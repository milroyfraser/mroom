# shellcheck shell=bash
# shellcheck disable=SC2016  # GraphQL variables ($id) are not the shell's
# tracker.sh — the tracker adapter (design section 7): read an issue, list issues, find the issues
# that hold an alert's marker, comment on one, set its state, and create one, on the tracker
# mroom.toml names (issues.tracker). Sourced after api.sh by lib/tracker, never run on its own; needs
# bash 5, curl, jq and python3 3.11. The caller sets MROOM_ROOT.
#
# v1 backends: linear, and none (no tracker: every operation returns 3, so a skill leaves its note on the
# pull request instead). Each function takes the command line's words and prints JSON on stdout.
#
# Exit codes: 0 done; 1 the tracker or the config failed; 2 a usage error; 3 there is no tracker.
#
# The token is the environment variable issues.token_env names (LINEAR_API_KEY by default). The adapter
# reads no file for it. A body (a comment, a description) comes on stdin, never from a path the adapter
# opens, so the guard sees every file a body is read from; a body holding the token itself is refused.

TRACKER_NAME="mroom tracker"
LINEAR_URL="https://api.linear.app/graphql"
TRACKER_MAX_PAGES=100
TRACKER_MAX_BODY=65536
LINEAR_AUTH=""

tracker_say() { echo "$TRACKER_NAME: $*" >&2; }

# tracker_config <key> [<default> | --optional]: one value from the app's mroom.toml, through the one reader;
# with --optional, nothing when the key is not set.
tracker_config() {
  if [ "${2-}" = --optional ]; then
    python3 "$MROOM_ROOT/lib/core/config.py" get "$1" --optional
  elif [ "$#" -ge 2 ]; then
    python3 "$MROOM_ROOT/lib/core/config.py" get "$1" --default "$2"
  else
    python3 "$MROOM_ROOT/lib/core/config.py" get "$1"
  fi
}

# tracker_backend: linear or none, from issues.tracker (none when it is not set).
tracker_backend() { tracker_config issues.tracker none; }

# tracker_none <what>: the answer of every operation without a tracker.
tracker_none() {
  tracker_say "issues.tracker is none, so there is no tracker to $1; leave the note on the pull request instead"
  return 3
}

# tracker_id_ok <id>: the id is safe to send, and matches issues.id_pattern when that is set (as a whole).
tracker_id_ok() {
  local id="$1" pattern
  [[ "$id" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || { tracker_say "not an issue id: ${id:0:80}"; return 2; }
  pattern="$(tracker_config issues.id_pattern --optional)" || return 1
  if [ -n "$pattern" ] && ! [[ "$id" =~ ^($pattern)$ ]]; then
    tracker_say "$id does not match issues.id_pattern ($pattern; read as a POSIX extended regex here, so no \\d)"
    return 2
  fi
}

# tracker_body <token>: reads the body from stdin into $API_TMP/body.in, as it is. Refuses an empty one,
# one over TRACKER_MAX_BODY bytes (counted as bytes, so a long body is refused, never cut short), one with a
# NUL byte, and one that holds the token. Callers hand the file to jq with --rawfile: jq -R splits a
# character that crosses its read buffer, which would garble a long non-ASCII body.
tracker_body() {
  local -
  set +x
  local body size in="$API_TMP/body.in"
  if [ -t 0 ]; then
    tracker_say "the body comes on stdin (for example: < note.md)"
    return 2
  fi
  head -c $((TRACKER_MAX_BODY + 1)) >"$in"
  size="$(wc -c <"$in")"
  if [ "$size" -gt "$TRACKER_MAX_BODY" ]; then
    rm -f "$in"
    tracker_say "the body is longer than $TRACKER_MAX_BODY bytes"
    return 2
  fi
  if [ "$(tr -d '\000' <"$in" | wc -c)" != "$size" ]; then
    rm -f "$in"
    tracker_say "the body holds a NUL byte"
    return 2
  fi
  body="$(cat "$in")"
  if [ -z "${body//[[:space:]]/}" ]; then
    rm -f "$in"
    tracker_say "the body on stdin is empty"
    return 2
  fi
  case "$body" in
    *"$1"*) rm -f "$in"; tracker_say "the body holds the tracker's token; not sent"; return 1 ;;
  esac
}

# ---- Linear -------------------------------------------------------------------------------------

# linear_auth: sets LINEAR_AUTH, the Authorization header value. An API key (lin_api_...) goes as it is,
# any other token (OAuth) as a Bearer token, as Linear asks.
linear_auth() {
  local -
  set +x
  local env token
  [ -n "$LINEAR_AUTH" ] && return 0
  env="$(tracker_config issues.token_env LINEAR_API_KEY)" || return 1
  token="$(api_token "$env" "Linear")" || return 1
  if [[ "$token" == lin_api_* ]]; then LINEAR_AUTH="$token"; else LINEAR_AUTH="Bearer $token"; fi
}

# linear_token: the token alone, for tracker_body. Only after linear_auth.
linear_token() { local -; set +x; printf '%s' "${LINEAR_AUTH#Bearer }"; }

# linear_gql <safe|once> <query> [variables json]: one GraphQL call; prints the answer. Fails when Linear
# answers with an error, or with no data. The variables (a whole description can be among them) reach jq on
# stdin, never as an argument.
linear_gql() {
  local kind="$1" query="$2" vars="${3:-"{}"}" request messages
  linear_auth || return 1
  request="$(printf '%s' "$vars" | jq -c --arg q "$query" '{query: $q, variables: .}')" || {
    tracker_say "could not build the request"; return 1; }
  api_call "$TRACKER_NAME" "$kind" POST "$LINEAR_URL" LINEAR_AUTH "$request" || return 1
  if ! jq -e '.data != null and ((.errors // []) | length == 0)' "$API_TMP/body" >/dev/null 2>&1; then
    messages="$(jq -r '[.errors[]?.message] | join("; ")' "$API_TMP/body" 2>/dev/null)"
    tracker_say "Linear: ${messages:-an answer with no data}"
    return 1
  fi
  cat "$API_TMP/body"
}

# linear_nodes <query> <variables json> <path> [<limit>]: every node of a paginated connection, one per
# line, or the first <limit>. The query takes $after and asks for the connection's nodes and pageInfo
# { hasNextPage endCursor }; <path> is where the connection is in the answer, such as
# .data.issue.comments. Fails on a page with no connection, and after TRACKER_MAX_PAGES pages, so an API
# blip never reads as a shorter list.
linear_nodes() {
  local query="$1" vars="$2" path="$3" limit="${4:-0}" after="" page pages=0 conn v next seen=0
  while :; do
    pages=$((pages + 1))
    ((pages <= TRACKER_MAX_PAGES)) || { tracker_say "more than $TRACKER_MAX_PAGES pages at $path"; return 1; }
    v="$(printf '%s' "$vars" | jq -c --arg a "$after" '. + (if $a == "" then {} else {after: $a} end)')" || return 1
    page="$(linear_gql safe "$query" "$v")" || return 1
    conn="$(jq -c "$path" <<<"$page" 2>/dev/null)"
    if ! jq -e '(.nodes | type == "array") and (.pageInfo | type == "object")' <<<"$conn" >/dev/null 2>&1; then
      tracker_say "Linear: the answer holds no list at $path"
      return 1
    fi
    if [ "$limit" -gt 0 ]; then
      jq -c --argjson n "$((limit - seen))" '.nodes[:$n][]' <<<"$conn"
      seen=$((seen + $(jq '.nodes | length' <<<"$conn")))
      [ "$seen" -lt "$limit" ] || return 0
    else
      jq -c '.nodes[]' <<<"$conn"
    fi
    jq -e '.pageInfo.hasNextPage == true' <<<"$conn" >/dev/null || return 0
    next="$(jq -r '.pageInfo.endCursor // empty' <<<"$conn")"
    [ -n "$next" ] || { tracker_say "Linear: a next page with no cursor at $path"; return 1; }
    [ "$next" != "$after" ] || { tracker_say "Linear: the next page's cursor did not move at $path"; return 1; }
    after="$next"
  done
}

# An issue's first 50 labels: more on one issue is not a case worth a second query.
LINEAR_ISSUE='id identifier title description url branchName priority priorityLabel createdAt updatedAt
  state { id name type } team { id key } creator { name } assignee { name isMe } labels(first: 50) { nodes { name } }'

# linear_issue <id>: the issue's fields (LINEAR_ISSUE) as JSON. Fails when there is no such issue.
linear_issue() {
  local answer
  answer="$(linear_gql safe "query(\$id: String!) { issue(id: \$id) { $LINEAR_ISSUE } }" \
    "$(jq -nc --arg id "$1" '{id: $id}')")" || return 1
  jq -e '.data.issue != null' <<<"$answer" >/dev/null || { tracker_say "Linear has no issue $1"; return 1; }
  jq -c '.data.issue' <<<"$answer"
}

# linear_states <team uuid>: the team's workflow states, one {id, name, type} per line.
linear_states() {
  linear_nodes 'query($t: String!, $after: String) { team(id: $t) { states(first: 100, after: $after) { nodes { id name type } pageInfo { hasNextPage endCursor } } } }' \
    "$(jq -nc --arg t "$1" '{t: $t}')" .data.team.states
}

# linear_state_id <states, one per line> <name>: the id of the state with that name (any case).
linear_state_id() {
  local id
  id="$(jq -rs --arg n "$2" '[.[] | select((.name | ascii_downcase) == ($n | ascii_downcase))][0].id // empty' <<<"$1")"
  if [ -z "$id" ]; then
    tracker_say "the team has no state named '$2' (it has: $(jq -rs '[.[].name] | join(", ")' <<<"$1"))"
    return 1
  fi
  printf '%s' "$id"
}

linear_issue_get() {
  local issue comments
  linear_auth || return 1
  issue="$(linear_issue "$1")" || return 1
  comments="$(linear_nodes 'query($id: String!, $after: String) { issue(id: $id) { comments(first: 50, after: $after) { nodes { body createdAt user { name } } pageInfo { hasNextPage endCursor } } } }' \
    "$(jq -nc --arg id "$1" '{id: $id}')" .data.issue.comments)" || return 1
  # The issue first, then its comments, on stdin: a long description must not become an argument.
  printf '%s\n%s\n' "$issue" "$comments" | jq -sc '.[0] as $i | .[1:] |
    {identifier: $i.identifier, title: $i.title, url: $i.url, branch: $i.branchName,
     state: $i.state.name, state_type: $i.state.type,
     team: $i.team.key, priority: $i.priority, creator: $i.creator.name, assignee: $i.assignee.name,
     assigned_to_me: ($i.assignee.isMe // false),
     labels: [$i.labels.nodes[].name], created_at: $i.createdAt, updated_at: $i.updatedAt,
     description: ($i.description // ""),
     comments: ([.[] | select(. != null) | {by: (.user.name // "an integration"), at: .createdAt, body}] | sort_by(.at))}' \
    || { tracker_say "Linear: the issue could not be read"; return 1; }
}

linear_issue_comment() {
  local -
  set +x
  local issue answer vars
  linear_auth || return 1
  tracker_body "$(linear_token)" || return
  issue="$(linear_issue "$1")" || return 1
  vars="$(jq -nc --rawfile b "$API_TMP/body.in" --arg i "$(jq -r .id <<<"$issue")" '{i: $i, b: $b}')" || return 1
  answer="$(linear_gql once 'mutation($i: String!, $b: String!) { commentCreate(input: {issueId: $i, body: $b}) { success comment { url } } }' "$vars")" || return 1
  jq -e '.data.commentCreate.success == true' <<<"$answer" >/dev/null || { tracker_say "Linear did not add the comment"; return 1; }
  jq -c --arg id "$(jq -r .identifier <<<"$issue")" '{commented: $id, url: .data.commentCreate.comment.url}' <<<"$answer"
}

linear_issue_set_state() {
  local issue states state answer
  linear_auth || return 1
  issue="$(linear_issue "$1")" || return 1
  states="$(linear_states "$(jq -r .team.id <<<"$issue")")" || return 1
  state="$(linear_state_id "$states" "$2")" || return 1
  if [ "$state" = "$(jq -r .state.id <<<"$issue")" ]; then
    jq -c '{identifier, state: .state.name, changed: false}' <<<"$issue"
    return 0
  fi
  answer="$(linear_gql safe 'mutation($i: String!, $s: String!) { issueUpdate(id: $i, input: {stateId: $s}) { success issue { identifier state { name } } } }' \
    "$(jq -nc --arg i "$(jq -r .id <<<"$issue")" --arg s "$state" '{i: $i, s: $s}')")" || return 1
  jq -e '.data.issueUpdate.success == true' <<<"$answer" >/dev/null || { tracker_say "Linear did not change the state"; return 1; }
  jq -c '.data.issueUpdate.issue | {identifier, state: .state.name, changed: true}' <<<"$answer"
}

# linear_issue_list <mine 0|1> <open 0|1> <label or ""> <limit>: the <limit> most recently updated issues, in
# issues.team when it is set, as one JSON list sorted by priority (urgent first, none last), then the most
# recently updated first. An issue older than the first <limit> is not in the list.
linear_issue_list() {
  local mine="$1" open="$2" label="$3" limit="$4" team_key filter nodes
  team_key="$(tracker_config issues.team --optional)" || return 1
  linear_auth || return 1
  filter="$(jq -nc --arg team "$team_key" --arg label "$label" --argjson mine "$mine" --argjson open "$open" '
    {} + (if $team == "" then {} else {team: {key: {eq: $team}}} end)
       + (if $mine == 1 then {assignee: {isMe: {eq: true}}} else {} end)
       + (if $open == 1 then {state: {type: {nin: ["completed", "canceled"]}}} else {} end)
       + (if $label == "" then {} else {labels: {some: {name: {eqIgnoreCase: $label}}}} end)')" || return 1
  nodes="$(linear_nodes 'query($f: IssueFilter, $after: String) { issues(first: 50, after: $after, filter: $f, orderBy: updatedAt) { nodes { identifier title url branchName priority updatedAt state { name type } assignee { name } labels(first: 50) { nodes { name } } } pageInfo { hasNextPage endCursor } } }' \
    "$(jq -nc --argjson f "$filter" '{f: $f}')" .data.issues "$limit")" || return 1
  printf '%s\n' "$nodes" | jq -sc '[.[] | select(. != null) |
    {identifier, title, url, branch: .branchName, state: .state.name, state_type: .state.type, priority,
     assignee: .assignee.name, labels: [.labels.nodes[].name], updated_at: .updatedAt}]
    | sort_by(.updated_at) | reverse | sort_by(if .priority == 0 then 5 else .priority end)' \
    || { tracker_say "Linear: the issues could not be read"; return 1; }
}

# linear_issue_find <marker>: the issues, in issues.team when it is set, whose description holds the marker.
# Linear's search is a plain substring match, so the marker for sentry:10 also finds sentry:1001's issues:
# each description is checked again here, and kept only when the marker ends there (" -->"), or goes on
# with a later alert's ":". One JSON list, the issue filed first at the top. Every page is read, archived
# issues too, so the oldest is never cut off.
linear_issue_find() {
  local marker="$1" team_key filter nodes
  team_key="$(tracker_config issues.team --optional)" || return 1
  linear_auth || return 1
  filter="$(jq -nc --arg team "$team_key" --arg m "$marker" '{description: {contains: $m}}
    + (if $team == "" then {} else {team: {key: {eq: $team}}} end)')" || return 1
  nodes="$(linear_nodes 'query($f: IssueFilter, $after: String) { issues(first: 50, after: $after, filter: $f, orderBy: createdAt, includeArchived: true) { nodes { identifier title url branchName description createdAt state { name type } creator { name } labels(first: 50) { nodes { name } } } pageInfo { hasNextPage endCursor } } }' \
    "$(jq -nc --argjson f "$filter" '{f: $f}')" .data.issues)" || return 1
  printf '%s\n' "$nodes" | jq -sc --arg m "$marker" '[.[] | select(. != null)
    | select((.description // "") as $d | ($d | contains($m + " -->")) or ($d | contains($m + ":")))
    | {identifier, title, url, branch: .branchName, state: .state.name, state_type: .state.type,
       creator: .creator.name, labels: [.labels.nodes[].name], created_at: .createdAt}]
    | sort_by(.created_at)' \
    || { tracker_say "Linear: the issues could not be read"; return 1; }
}

# linear_issue_create <title> <state name or ""> <priority or ""> <label...>: a new issue in issues.team.
linear_issue_create() {
  local -
  set +x
  local title="$1" state_name="$2" priority="$3" team_key team states state="" labels="[]" found answer vars
  shift 3
  team_key="$(tracker_config issues.team --optional)" || return 1
  [ -n "$team_key" ] || { tracker_say "issues.team is not set, so there is no team to create the issue in"; return 1; }
  linear_auth || return 1
  case "$title" in
    *"$(linear_token)"*) tracker_say "the title holds the tracker's token; not sent"; return 1 ;;
  esac
  tracker_body "$(linear_token)" || return
  team="$(linear_gql safe 'query($k: String!) { teams(filter: {key: {eq: $k}}) { nodes { id key } } }' \
    "$(jq -nc --arg k "$team_key" '{k: $k}')" | jq -r '.data.teams.nodes[0].id // empty')" || return 1
  [ -n "$team" ] || { tracker_say "Linear has no team $team_key (issues.team)"; return 1; }
  if [ -n "$state_name" ]; then
    states="$(linear_states "$team")" || return 1
    state="$(linear_state_id "$states" "$state_name")" || return 1
  fi
  if [ "$#" -gt 0 ]; then
    found="$(linear_gql safe 'query($n: [String!]!) { issueLabels(first: 100, filter: {name: {in: $n}}) { nodes { id name team { key } } } }' \
      "$(printf '%s\n' "$@" | jq -Rsc '{n: (split("\n") | map(select(. != "")))}')")" || return 1
    # A label of this team, or of the whole workspace; mroom never creates a label.
    labels="$(jq -c --arg t "$team_key" '[.data.issueLabels.nodes[] | select(.team == null or .team.key == $t)]' <<<"$found")"
    local name
    for name in "$@"; do
      jq -e --arg n "$name" 'any(.[]; .name == $n)' <<<"$labels" >/dev/null \
        || { tracker_say "the team $team_key has no label '$name' (mroom never creates labels)"; return 1; }
    done
    labels="$(jq -c '[.[].id] | unique' <<<"$labels")"
  fi
  vars="$(jq -nc --rawfile d "$API_TMP/body.in" --arg team "$team" --arg t "$title" --arg s "$state" --arg p "$priority" \
      --argjson l "$labels" '{i: ({teamId: $team, title: $t, description: $d}
        + (if $s == "" then {} else {stateId: $s} end)
        + (if $p == "" then {} else {priority: ($p | tonumber)} end)
        + (if ($l | length) == 0 then {} else {labelIds: $l} end))}')" || return 1
  answer="$(linear_gql once 'mutation($i: IssueCreateInput!) { issueCreate(input: $i) { success issue { identifier url } } }' "$vars")" || return 1
  jq -e '.data.issueCreate.success == true' <<<"$answer" >/dev/null || { tracker_say "Linear did not create the issue"; return 1; }
  jq -c '.data.issueCreate.issue | {created: .identifier, url}' <<<"$answer"
}

# ---- The adapter's functions --------------------------------------------------------------------

# issue_get <id>: the issue, with its state, labels, description and every comment.
issue_get() {
  [ "$#" = 1 ] || { tracker_say "usage: get <id>"; return 2; }
  local backend
  backend="$(tracker_backend)" || return 1
  case "$backend" in
    none) tracker_none "read an issue" ;;
    linear) tracker_id_ok "$1" || return; linear_issue_get "$1" ;;
  esac
}

# issue_list [--mine] [--open] [--label <name>] [--limit <n>]: issues in issues.team (or the whole
# workspace when it is not set): --mine those assigned to the token's user, --open those not done or
# canceled, --label those with that label (any case). The --limit most recently updated (50 by default,
# 250 at most), then sorted by priority.
issue_list() {
  local mine=0 open=0 label="" limit=50 backend
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --mine) mine=1; shift ;;
      --open) open=1; shift ;;
      --label | --limit)
        if [ "$#" -lt 2 ] || [[ "$2" == --* ]]; then tracker_say "$1 takes a value"; return 2; fi
        if [ "$1" = --label ]; then label="$2"; else limit="$2"; fi
        shift 2 ;;
      *) tracker_say "list: unknown option '$1'"; return 2 ;;
    esac
  done
  if [ "$mine" = 0 ] && [ -z "$label" ]; then
    tracker_say "list needs --mine or --label, so it never reads a whole backlog"
    return 2
  fi
  if ! [[ "$limit" =~ ^[1-9][0-9]{0,2}$ ]] || [ "$limit" -gt 250 ]; then
    tracker_say "--limit is 1 to 250"
    return 2
  fi
  if [ -n "$label" ] && { [ "${#label}" -gt 80 ] || [[ "$label" == *[[:cntrl:]]* ]]; }; then
    tracker_say "the --label is too long or holds a control character"
    return 2
  fi
  backend="$(tracker_backend)" || return 1
  case "$backend" in
    none) tracker_none "list issues in" ;;
    linear) linear_issue_list "$mine" "$open" "$label" "$limit" ;;
  esac
}

# issue_find_by_marker <key>: the issues whose description holds the persona's hidden marker for an alert
# key, `<!-- mroom-alert key=<key> -->` (a later alert adds `:<kind>:...` after the key). The key is the
# error tracker's name and the error issue's numeric id, such as sentry:1001. Every state, archived too,
# the oldest first; an empty list when none holds it.
issue_find_by_marker() {
  [ "$#" = 1 ] || { tracker_say "usage: find <alert key, such as sentry:1001>"; return 2; }
  [[ "$1" =~ ^[a-z][a-z0-9_-]{0,31}:[0-9]{1,20}$ ]] || {
    tracker_say "not an alert key (the error tracker and the error issue's numeric id, such as sentry:1001): ${1:0:80}"
    return 2
  }
  local backend
  backend="$(tracker_backend)" || return 1
  case "$backend" in
    none) tracker_none "find an issue in" ;;
    linear) linear_issue_find "<!-- mroom-alert key=$1" ;;
  esac
}

# issue_comment <id>: adds the comment on stdin.
issue_comment() {
  [ "$#" = 1 ] || { tracker_say "usage: comment <id> < body"; return 2; }
  local backend
  backend="$(tracker_backend)" || return 1
  case "$backend" in
    none) tracker_none "comment on" ;;
    linear) tracker_id_ok "$1" || return; linear_issue_comment "$1" ;;
  esac
}

# issue_set_state <id> <state name>: moves the issue to the team's state of that name (any case).
issue_set_state() {
  if [ "$#" != 2 ] || [ -z "$2" ]; then tracker_say "usage: state <id> <state name>"; return 2; fi
  local backend
  backend="$(tracker_backend)" || return 1
  case "$backend" in
    none) tracker_none "set a state on" ;;
    linear) tracker_id_ok "$1" || return; linear_issue_set_state "$1" "$2" ;;
  esac
}

# issue_create --allow-create --title <title> [--state <name>] [--priority 0-4] [--label <name>]... < body:
# a new issue in issues.team. Without --allow-create it refuses before any call: filing an issue is a
# step a caller takes on purpose, never by default.
issue_create() {
  local allow="" title="" state="" priority="" labels=() backend
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --allow-create) allow=1; shift ;;
      --title) title="${2-}"; shift 2 || { tracker_say "--title takes a value"; return 2; } ;;
      --state) state="${2-}"; shift 2 || { tracker_say "--state takes a value"; return 2; } ;;
      --priority) priority="${2-}"; shift 2 || { tracker_say "--priority takes a value"; return 2; } ;;
      --label) labels+=("${2-}"); shift 2 || { tracker_say "--label takes a value"; return 2; } ;;
      *) tracker_say "create: unknown option '$1'"; return 2 ;;
    esac
  done
  if [ -z "$allow" ]; then
    tracker_say "create files a new issue, so it needs --allow-create; nothing was sent"
    return 2
  fi
  title="${title//[$'\r\n']/ }"
  [ -n "${title// /}" ] || { tracker_say "create needs --title"; return 2; }
  [ "${#title}" -le 200 ] || { tracker_say "the title is longer than 200 characters"; return 2; }
  [ -z "$priority" ] || [[ "$priority" =~ ^[0-4]$ ]] || { tracker_say "--priority is 0 (none), 1 (urgent) to 4 (low)"; return 2; }
  local l
  for l in ${labels[@]+"${labels[@]}"}; do
    if [ -z "$l" ] || [ "${#l}" -gt 80 ]; then tracker_say "a --label is empty or too long"; return 2; fi
  done
  backend="$(tracker_backend)" || return 1
  case "$backend" in
    none) tracker_none "create an issue in" ;;
    linear) linear_issue_create "$title" "$state" "$priority" ${labels[@]+"${labels[@]}"} ;;
  esac
}
