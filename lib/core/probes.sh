# shellcheck shell=bash
# probes.sh — what the watchdog checks (lib/watchdog), and how a check reports what it finds. Sourced by
# lib/watchdog after util.sh, chat.sh and jobs.sh; uses its TMP, NOW, DRY, BOX, SUMMARY and settings.
#
# A probe calls failing for each failure it finds, event for each thing that happened once, and sets
# SUMMARY[<probe>] to one line. Findings go to files in $TMP, never to a command line.

# one_line <text>: control characters as spaces, at most 300 characters.
one_line() { local s="${1//[$'\001'-$'\037'$'\177']/ }"; printf '%s' "${s:0:300}"; }

# code <outside text>: the text as a Slack code span, so it can neither link nor format anything.
code() {
  local tick='`' quote="'"
  local s="${1//"$tick"/"$quote"}"
  printf '`%s`' "$(one_line "$s")"
}

plural() { if [ "$1" = 1 ]; then echo "1 $2"; else echo "$1 $3"; fi; }

host_of() { local h="${1#*://}"; printf '%s\n' "${h%%/*}"; }

# failing <key> <subject> <message>: one failure this run found. The subject names what failed ("MCP
# server app"); the message says what is wrong. Findings go to a file, never a command line.
failing() { printf '%s\x1f%s\x1f%s\n' "$(one_line "$1")" "$(one_line "$2")" "$(one_line "$3")" >>"$TMP/failing"; }

# event <message>: something that happened once (a kill, a restart).
event() { printf '%s\n' "$(one_line "$1")" >>"$TMP/events"; }

state_get() { jq -r "$1" "$TMP/state.json"; }

# carry_over <prefix> [<file of names to skip>]: keeps the failures with that key prefix that this run
# could not check, so a check that did not happen never reads as a recovery. A carried failure stays as it
# was: it neither starts nor ends.
carry_over() {
  local skip="${2:-/dev/null}"
  jq -r --arg p "$1" --rawfile skip "$skip" '
      ($skip | split("\n") | map(select(length > 0)) | map({key: ($p + .), value: true}) | from_entries) as $checked
      | ((.conditions // {}) + (.pending // {})) | to_entries[]
      | select((.key | startswith($p)) and ($checked[.key] | not))
      | [.key, .value.subject, (.value.latest // .value.message), "carried"] | join("\u001f")' "$TMP/state.json" >>"$TMP/failing"
}

# ---- probes -------------------------------------------------------------------------------------

curl_reason() {
  case "$1" in
    28) echo "no answer within ${MCP_TIMEOUT}s" ;;
    6) echo "its host name does not resolve" ;;
    7) echo "the connection was refused" ;;
    35 | 51 | 58 | 60) echo "the TLS handshake failed" ;;
    52) echo "the server closed the connection without answering" ;;
    56) echo "the connection broke while the answer came in" ;;
    *) echo "no answer (curl exit $1)" ;;
  esac
}

jsonrpc_answer() { jq -e '.jsonrpc == "2.0"' "$1" >/dev/null 2>&1 || grep -q '^data:.*"jsonrpc"' "$1" 2>/dev/null; }

error_detail() {
  jq -r '(.message // (.error | if type == "object" then .message else . end) // empty) | tostring' "$1" 2>/dev/null \
    | head -n1 | cut -c1-120 || true
}

# mcp_verdict <http code> <content type> <redirect URL> <curl exit> <body file>: prints why the server
# counts as failing, or returns 1 when it is up.
mcp_verdict() {
  local status="$1" ctype="$2" redirect="$3" rc="$4" body="$5" detail
  if [ "$status" = 401 ] || [ "$status" = 403 ]; then return 1; fi
  if [[ "$status" =~ ^[24][0-9][0-9]$ ]] && jsonrpc_answer "$body"; then return 1; fi
  case "$status" in
    000 | "") curl_reason "$rc" ;;
    3??) echo "HTTP $status: it redirects${redirect:+ to $(host_of "$redirect")}; list the address it redirects to" ;;
    5??)
      detail="$(error_detail "$body")"
      echo "HTTP $status${detail:+ $(code "$detail")}"
      ;;
    *) echo "HTTP $status${ctype:+ ($(code "$ctype"))}, an answer that is not an MCP server's" ;;
  esac
}

probe_mcp() {
  local list="${BOX[MROOM_WATCH_MCP]:-}" item name url out status ctype redirect rc reason checked=0 failed=0 items=()
  if [ -z "$list" ]; then SUMMARY[mcp]="off (MROOM_WATCH_MCP is not set)"; return 0; fi
  read -ra items <<<"$list"
  for item in "${items[@]}"; do
    if [[ "$item" =~ ^([a-z0-9][a-z0-9_-]*)=(https?://.+)$ ]]; then
      name="${BASH_REMATCH[1]}" url="${BASH_REMATCH[2]}"
    else
      url="$item" name="$(host_of "$item")"
    fi
    checked=$((checked + 1))
    rc=0
    # The URL reaches curl through a file descriptor, never its arguments: a URL may hold a key in its path.
    out="$(curl -sS -o "$TMP/mcp-body" -w '%{http_code}|%{content_type}|%{redirect_url}' --max-time "$MCP_TIMEOUT" \
      --data-binary @"$TMP/mcp-init" \
      -K <(printf 'url = "%s"\nrequest = "POST"\nheader = "Content-Type: application/json"\nheader = "Accept: application/json, text/event-stream"\n' "$url") \
      2>/dev/null)" || rc=$?
    IFS='|' read -r status ctype redirect <<<"$out"
    if reason="$(mcp_verdict "${status:-000}" "$ctype" "$redirect" "$rc" "$TMP/mcp-body")"; then
      failed=$((failed + 1))
      failing "mcp:$name" "MCP server $name" "MCP server $name ($(host_of "$url")) is failing: $reason"
    fi
    rm -f "$TMP/mcp-body"
  done
  SUMMARY[mcp]="$checked checked, $failed failing"
}

# oom_victims <since epoch>: the killed processes' names, as code spans with counts, from the kernel log;
# nothing when the box user may not read it.
oom_victims() {
  command -v journalctl >/dev/null 2>&1 || return 0
  local n name parts=()
  while read -r n name; do
    [ -n "$name" ] || continue
    if ((n > 1)); then parts+=("$(code "$name") ×$n"); else parts+=("$(code "$name")"); fi
  done < <({ timeout "$JOURNAL_TIMEOUT" journalctl -k --since "@$1" -o cat --no-pager 2>/dev/null || true; } \
    | sed -n 's/.*Killed process [0-9][0-9]* (\([^)]*\)).*/\1/p' | sort | uniq -c | sort -rn)
  [ "${#parts[@]}" -gt 0 ] || return 0
  printf '%s' "${parts[0]}"
  if [ "${#parts[@]}" -gt 1 ]; then printf ', %s' "${parts[@]:1}"; fi
}

probe_memory() {
  local count boot last_boot last_count last_run killed=0 names since
  count="$(awk '$1 == "oom_kill" { print $2 }' "$PROC/vmstat" 2>/dev/null || true)"
  boot="$(cat "$PROC/sys/kernel/random/boot_id" 2>/dev/null || true)"
  if ! [[ "$count" =~ ^[0-9]+$ ]]; then SUMMARY[memory]="off (no oom_kill in $PROC/vmstat)"; return 0; fi
  NEW_BOOT="$boot" NEW_OOM="$count"
  last_boot="$(state_get '.boot_id // empty')"
  last_count="$(state_get '.oom_kill // empty')"
  last_run="$(state_get '.last_run // empty')"
  if [ -z "$last_count" ] || [ -z "$last_run" ]; then
    SUMMARY[memory]="first check: counting from now"
    return 0
  fi
  since="since $(utc_text "$last_run")"
  if [ -n "$boot" ] && [ -n "$last_boot" ] && [ "$boot" != "$last_boot" ]; then
    event "the box restarted between the checks at $(utc_text "$last_run") and $(utc_text "$NOW")"
    killed="$count" since="since the box started"
  elif ((count > last_count)); then
    killed=$((count - last_count))
  fi
  if ((killed > 0)); then
    names="$(oom_victims "$last_run")"
    event "$(plural "$killed" process processes) killed for lack of memory $since${names:+: $names}"
  fi
  SUMMARY[memory]="$killed killed since the last check"
}

probe_disk() {
  local mount pct seen=" " checked=0 full=0
  while read -r mount pct; do
    [[ "$pct" =~ ^[0-9]+$ ]] || continue
    case "$seen" in *" $mount "*) continue ;; esac
    seen+="$mount "
    checked=$((checked + 1))
    if ((pct >= DISK_FULL_PCT)); then
      full=$((full + 1))
      failing "disk:$mount" "the disk at $mount" "the disk at $mount is $pct% full"
    fi
  done < <(df -P / "$HOME" 2>/dev/null | awk 'NR > 1 { sub("%", "", $5); print $6, $5 }')
  SUMMARY[disk]="$checked checked, $full at ${DISK_FULL_PCT}% or more"
}

probe_jobs() {
  local dir file checked=0 bad=0 files=()
  dir="$(jobs_dir)"
  shopt -s nullglob
  files=("$dir"/*.json)
  shopt -u nullglob
  for file in "${files[@]}"; do
    checked=$((checked + 1))
    if ! job_read "$file"; then
      bad=$((bad + 1))
      failing "job-record:$(basename "$file" .json)" "the job record $(basename "$file")" \
        "the job record $(home_short "$file") cannot be read, so that job is not watched"
      continue
    fi
    if job_failed; then
      bad=$((bad + 1))
      failing "job:$JOB_NAME:failed" "job $JOB_NAME" \
        "job $JOB_NAME failed (exit $JOB_EXIT) at $(utc_text "$JOB_ENDED"); log: $(home_short "${file%.json}.log")"
    fi
    if job_overdue "$NOW"; then
      bad=$((bad + 1))
      failing "job:$JOB_NAME:overdue" "job $JOB_NAME (not running)" \
        "job $JOB_NAME has not finished a run since $(utc_text "${JOB_ENDED:-$JOB_STARTED}") (it should run every $(dur_text "$JOB_EVERY"))"
    fi
  done
  SUMMARY[jobs]="$checked checked, $bad failing"
}

# github_repo <clone URL>: owner/repo for a github.com URL, or nothing.
github_repo() {
  [[ "$1" =~ ^(git@github\.com:|ssh://git@github\.com/|https://github\.com/)([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)$ ]] || return 0
  local repo="${BASH_REMATCH[2]}"
  printf '%s\n' "${repo%.git}"
}

# workflow_streaks <runs.json>: per workflow that still exists and is switched on, its name, how many of
# its newest finished scheduled runs failed before the newest success, when the newest ran, and its URL.
# Cancelled and skipped runs do not count either way. Fails when the files are not gh's JSON.
workflow_streaks() {
  jq -r --slurpfile workflows "$TMP/workflows.json" '
    ($workflows[0] | map(select(.state == "active") | .name)) as $active
    | map(select(.workflowName as $n | $active | index($n)))
    | group_by(.workflowName)[]
    | map(select(.status == "completed" and (.conclusion | IN("cancelled", "skipped", "neutral") | not)))
    | sort_by(.createdAt) | reverse | select(length > 0)
    | (first(range(length) as $i | select(.[$i].conclusion == "success") | $i) // length) as $streak
    | [(.[0].workflowName | gsub("[[:cntrl:]]"; " ")), $streak, (.[0].createdAt | fromdateiso8601), .[0].url]
    | map(tostring) | join("\u001f")' "$1"
}

# fetch_runs <repo>: the repository's switched-on workflows into $TMP/workflows.json and its newest 1,000
# scheduled runs into $TMP/runs.json, or a line saying why that failed. gh's warnings go to their own file,
# so they never spoil its JSON.
fetch_runs() {
  local rc=0 err
  command -v gh >/dev/null 2>&1 || { echo "gh is not installed"; return 0; }
  { timeout "$GH_TIMEOUT" gh workflow list -R "$1" --limit 500 --json name,state >"$TMP/workflows.json" &&
    timeout "$GH_TIMEOUT" gh run list -R "$1" --event schedule --limit 1000 \
      --json workflowName,conclusion,status,createdAt,url >"$TMP/runs.json"; } 2>"$TMP/gh.err" || rc=$?
  [ "$rc" = 0 ] && return 0
  if [ "$rc" = 124 ]; then echo "gh did not answer within ${GH_TIMEOUT}s"; return 0; fi
  err="$(head -n1 "$TMP/gh.err")"
  if [ -n "$err" ]; then echo "gh failed: $(code "$err")"; else echo "gh failed (exit $rc)"; fi
}

# listed_nothing: true when gh listed no switched-on workflows although the repository has scheduled runs.
# An answer like that is a fault, and must not end every workflow failure.
listed_nothing() {
  jq -e --slurpfile runs "$TMP/runs.json" \
    'map(select(.state == "active")) | length == 0 and ($runs[0] | length > 0)' "$TMP/workflows.json" >/dev/null 2>&1
}

probe_workflows() {
  local repo checked why streaks name streak at url count=0 failed=0
  repo="$(github_repo "${BOX[MROOM_REPO_URL]:-}")"
  if [ -z "$repo" ]; then SUMMARY[workflows]="off (MROOM_REPO_URL is not a github.com repository)"; return 0; fi
  checked="$(state_get '.workflows_checked // 0')"
  if [ "$DRY" = false ] && ((NOW >= checked && NOW - checked < WORKFLOWS_EVERY)); then
    carry_over 'workflow:'
    carry_over 'probe:workflows'
    NEW_WORKFLOWS_CHECKED="$checked"
    SUMMARY[workflows]="checked $(dur_text $((NOW - checked))) ago; checked once an hour"
    return 0
  fi
  NEW_WORKFLOWS_CHECKED="$NOW"
  why="$(fetch_runs "$repo")"
  if [ -z "$why" ] && listed_nothing; then
    why="gh listed no switched-on workflows, although the repository has scheduled runs"
  elif [ -z "$why" ] && ! streaks="$(workflow_streaks "$TMP/runs.json" 2>/dev/null)"; then
    why="gh's answer was not the JSON expected"
  fi
  if [ -n "$why" ]; then
    carry_over 'workflow:'
    failing "probe:workflows" "the scheduled workflow check" "cannot check the scheduled workflows of $repo: $why"
    SUMMARY[workflows]="cannot check: $why"
    return 0
  fi
  : >"$TMP/workflows-seen"
  while IFS=$'\x1f' read -r name streak at url; do
    [ -n "$name" ] || continue
    count=$((count + 1))
    printf '%s\n' "$name" >>"$TMP/workflows-seen"
    [ "$streak" -gt 0 ] || continue
    failed=$((failed + 1))
    if [ "$streak" = 1 ]; then streak="once"; else streak="$streak times in a row"; fi
    failing "workflow:$name" "scheduled workflow $(code "$name")" \
      "scheduled workflow $(code "$name") failed $streak, the last time at $(utc_text "$at"): $url"
  done <<<"$streaks"
  # A failing workflow that was deleted or switched off is no longer a failure, so it ends. One pushed out of
  # the newest 1,000 scheduled runs keeps its failure: only a success ends that.
  jq -r --slurpfile workflows "$TMP/workflows.json" '
      ($workflows[0] | map(select(.state == "active") | .name)) as $active
      | ((.conditions // {}) + (.pending // {})) | keys[] | select(startswith("workflow:")) | ltrimstr("workflow:")
      | select(. as $n | $active | index($n) | not)' "$TMP/state.json" >>"$TMP/workflows-seen"
  carry_over 'workflow:' "$TMP/workflows-seen"
  SUMMARY[workflows]="$count scheduled workflows checked, $failed failing"
}
