#!/usr/bin/env bash
# shellcheck disable=SC2317  # the t_* functions run indirectly, through test_case
# shellcheck disable=SC2016,SC2088  # backquotes and ~ in single quotes are the literal text expected
# Tests for `mroom watchdog run|status|report`. Offline: curl, gh, journalctl, df, timeout and a logging jq
# are fakes in $T/bin that answer from files in $FAKE; /proc is $T/proc (MROOM_PROC) and the clock is
# MROOM_NOW. A failure is posted when two checks in a row see it, so most tests run the watchdog twice.
set -euo pipefail
SUITE=watchdog
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
skip_unless has_box_tools "this host lacks bash 5, flock or GNU date, which box commands need"

T0=1761400000
state_dir() { echo "$HOME/.local/state/mroom"; }

# world: a box with chat, a GitHub repository and two MCP servers, all healthy, and the fakes on PATH.
world() {
  FAKE="$T/fake"
  REAL_JQ="$(command -v jq)"
  export FAKE REAL_JQ
  mkdir -p "$FAKE/http" "$T/bin" "$T/proc/sys/kernel/random" "$HOME/.config/mroom/secrets"
  cat >"$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
# fake curl. The URL comes from the -K config or the arguments. Slack posts go to $FAKE/slack.log and
# heartbeats to $FAKE/heartbeat.log. Any other URL answers from $FAKE/http/<host_path>, a file holding
# "<http code> <curl exit> <content type or -> <redirect or ->", with its body in <host_path>.body; without
# one it answers 200 with a JSON-RPC result.
printf '%s\n' "$*" >>"$FAKE/curl-args.log"
out="" data="" url="" cfg=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -K) cfg="$2"; shift 2 ;;
    --data-binary) data="$2"; shift 2 ;;
    -w | -X | -H | --max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
config=""
if [ -n "$cfg" ]; then config="$(cat "$cfg")"; fi
from_config="$(printf '%s\n' "$config" | sed -n 's/^url = "\(.*\)"$/\1/p')"
if [ -n "$from_config" ]; then url="$from_config"; fi
body=""
if [ "$data" = "@-" ]; then body="$(cat)"; elif [ -n "$data" ]; then body="$(cat "${data#@}")"; fi
case "$url" in
  https://slack.com/api/chat.postMessage)
    printf '%s\n' "$body" >>"$FAKE/slack.log"
    printf '%s\n' "$config" >>"$FAKE/slack-headers.log"
    if [ -f "$FAKE/slack-error" ]; then printf '{"ok":false,"error":"%s"}\n' "$(cat "$FAKE/slack-error")"; else echo '{"ok":true}'; fi
    exit 0
    ;;
  https://beat.example.dev/*) echo "$url" >>"$FAKE/heartbeat.log"; exit 0 ;;
esac
spec="$FAKE/http/$(printf '%s' "${url#*://}" | tr '/:' '__')"
code=200 rc=0 ctype=application/json redirect=-
if [ -f "$spec" ]; then read -r code rc ctype redirect <"$spec"; fi
if [ -n "$out" ]; then
  if [ -f "$spec.body" ]; then cat "$spec.body" >"$out"; else echo '{"jsonrpc":"2.0","id":1,"result":{}}' >"$out"; fi
fi
if [ "$ctype" = - ]; then ctype=""; fi
if [ "$redirect" = - ]; then redirect=""; fi
printf '%s|%s|%s' "$code" "$ctype" "$redirect"
exit "${rc:-0}"
EOF
  cat >"$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
# fake gh: "workflow list" answers from $FAKE/workflows.json, "run list" from $FAKE/runs.json.
printf '%s\n' "$*" >>"$FAKE/gh.log"
if [ -f "$FAKE/gh-fail" ]; then cat "$FAKE/gh-fail" >&2; exit 1; fi
if [ -f "$FAKE/gh-warn" ]; then cat "$FAKE/gh-warn" >&2; fi
case "$1 $2" in
  "workflow list") cat "$FAKE/workflows.json" 2>/dev/null || echo '[]' ;;
  *) cat "$FAKE/runs.json" 2>/dev/null || echo '[]' ;;
esac
EOF
  cat >"$T/bin/journalctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE/journalctl-args.log"
if [ -f "$FAKE/journal-denied" ]; then echo "No journal files were opened due to insufficient permissions." >&2; exit 1; fi
cat "$FAKE/kernel.log" 2>/dev/null || true
EOF
  cat >"$T/bin/df" <<'EOF'
#!/usr/bin/env bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
cat "$FAKE/df.txt"
EOF
  cat >"$T/bin/timeout" <<'EOF'
#!/usr/bin/env bash
if [ -f "$FAKE/timeout-expired" ]; then exit 124; fi
shift
exec "$@"
EOF
  cat >"$T/bin/jq" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE/jq-args.log"
exec "$REAL_JQ" "$@"
EOF
  chmod +x "$T/bin/"*
  export PATH="$T/bin:$PATH" MROOM_PROC="$T/proc" MROOM_NOW="$T0"
  printf 'nr_free_pages 1\noom_kill 3\n' >"$T/proc/vmstat"
  echo boot-a >"$T/proc/sys/kernel/random/boot_id"
  printf '/dev/vda1 100 40 60 40%% /\n/dev/vdb1 100 35 65 35%% /home\n' >"$FAKE/df.txt"
  cat >"$HOME/.config/mroom/box.env" <<'EOF'
MROOM_BOX_NAME=box-one
MROOM_SLACK_LOG_CHANNEL=C0LOG
MROOM_REPO_URL=git@github.com:example/shop.git
MROOM_WATCH_MCP='app=https://mcp.example.dev/mcp docs=https://docs.example.dev/v1/mcp'
EOF
  printf 'SLACK_BOT_TOKEN=xoxb-secret-token\n' >"$HOME/.config/mroom/secrets/slack.env"
  chmod 600 "$HOME/.config/mroom/secrets/slack.env"
}

# http <host/path> <code> [<curl exit> [<content type> [<redirect> [<body>]]]]: how the fake curl answers.
http() {
  local file
  file="$FAKE/http/$(printf '%s' "$1" | tr '/:' '__')"
  echo "$2 ${3:-0} ${4:-application/json} ${5:--}" >"$file"
  if [ -n "${6:-}" ]; then printf '%s' "$6" >"$file.body"; else printf 'not json' >"$file.body"; fi
}
healthy() { rm -f "$FAKE/http/$(printf '%s' "$1" | tr '/:' '__')"*; }
at() { export MROOM_NOW=$((T0 + $1)); }
watch() { run "$MROOM" watchdog run; }
posts() { if [ -f "$FAKE/slack.log" ]; then grep -c . "$FAKE/slack.log"; else echo 0; fi; }
last_post() { tail -n1 "$FAKE/slack.log" | "$REAL_JQ" -r .text; }
saved() { "$REAL_JQ" -r "$1" "$(state_dir)/watchdog.json"; }
expect_posts() { expect_true "expected $1 post(s), got $(posts)" test "$(posts)" = "$1"; }

t_all_clear() {
  world
  watch; expect_rc 0
  expect_out_has "mcp: 2 checked, 0 failing"
  expect_out_has "memory: first check: counting from now"
  expect_out_has "disk: 2 checked, 0 at 90% or more"
  expect_out_has "jobs: 0 checked, 0 failing"
  expect_out_has "workflows: 0 scheduled workflows checked, 0 failing"
  expect_out_has "posted 0 message(s)"
  expect_out_has "failing now: nothing"
  expect_posts 0
  run "$MROOM" watchdog status; expect_rc 0; expect_out_has "nothing is failing"; expect_out_has "chat: posts to C0LOG"
}

t_failure_posted_on_the_second_check_then_recovery() {
  world
  http mcp.example.dev/mcp 500 0 application/json - '{"message":"Invalid key supplied","exception":"LogicException"}'
  watch; expect_rc 0; expect_out_has "mcp: 2 checked, 1 failing"
  expect_out_has "waiting for a second check: mcp:app"
  expect_posts 0
  at 600; watch; expect_rc 0
  expect_posts 1
  run last_post
  expect_out '⚠️ *box-one*: MCP server app (mcp.example.dev) is failing: HTTP 500 `Invalid key supplied`'
  run "$REAL_JQ" -r .channel <(tail -n1 "$FAKE/slack.log"); expect_out "C0LOG"
  at 1200; watch; expect_rc 0
  expect_posts 1
  run "$MROOM" watchdog status; expect_rc 1; expect_out_has "failing since"; expect_out_has "(20m): MCP server app"
  healthy mcp.example.dev/mcp
  at 1800; watch; expect_rc 0
  expect_posts 2
  run last_post; expect_out "✅ *box-one*: MCP server app: OK again after 30m"
  run "$MROOM" watchdog report; expect_rc 0
  expect_out_has "lasted 30m"; expect_out_has "MCP server app (mcp.example.dev) is failing"; expect_out_has "1 failure, 0 events"
}

t_one_bad_check_is_not_posted() {
  world
  http mcp.example.dev/mcp 000 28 - -
  watch; expect_rc 0
  healthy mcp.example.dev/mcp
  at 600; watch; expect_rc 0
  expect_posts 0
  run saved '.pending | length'; expect_out "0"
}

t_mcp_verdicts() {
  world
  export MROOM_WATCH_MCP='up=https://a.test/mcp sse=https://b.test/mcp oauth=https://c.test/mcp denied=https://d.test/mcp rpc=https://e.test/mcp gone=https://f.test/mcp moved=https://g.test/mcp page=https://h.test/mcp post=https://i.test/mcp slow=https://j.test/mcp shut=https://k.test/mcp mute=https://l.test/mcp boom=https://m.test/mcp https://plain.test/x'
  http a.test/mcp 200 0 application/json - '{"jsonrpc":"2.0","id":1,"result":{}}'
  http b.test/mcp 200 28 text/event-stream - $'event: message\ndata: {"jsonrpc":"2.0","id":1,"result":{}}\n'
  http c.test/mcp 401; http d.test/mcp 403
  http e.test/mcp 400 0 application/json - '{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"Unsupported protocol version"}}'
  http f.test/mcp 404 0 text/html; http g.test/mcp 301 0 text/html https://new.test/mcp
  http h.test/mcp 200 0 text/html; http i.test/mcp 405 0 text/plain
  http j.test/mcp 000 28 - -; http k.test/mcp 000 7 - -; http l.test/mcp 000 52 - -
  http m.test/mcp 500 0 application/json - '{"error":"boom"}'
  http plain.test/x 502 0 text/html
  run "$MROOM" watchdog run --dry-run; expect_rc 0
  expect_out_has "mcp: 14 checked, 9 failing"
  expect_out_has 'found: MCP server gone (f.test) is failing: HTTP 404 (`text/html`), an answer that is not an MCP server'"'"'s'
  expect_out_has "found: MCP server moved (g.test) is failing: HTTP 301: it redirects to new.test; list the address it redirects to"
  expect_out_has 'found: MCP server page (h.test) is failing: HTTP 200 (`text/html`), an answer that is not'
  expect_out_has 'found: MCP server post (i.test) is failing: HTTP 405 (`text/plain`)'
  expect_out_has "found: MCP server slow (j.test) is failing: no answer within 10s"
  expect_out_has "found: MCP server shut (k.test) is failing: the connection was refused"
  expect_out_has "found: MCP server mute (l.test) is failing: the server closed the connection without answering"
  expect_out_has 'found: MCP server boom (m.test) is failing: HTTP 500 `boom`'
  expect_out_has "found: MCP server plain.test (plain.test) is failing: HTTP 502"
  case "$out" in *"server up "* | *"server sse"* | *"server oauth"* | *"server denied"* | *"server rpc"*) fail "a server that is up was reported" ;; *) ok ;; esac
}

t_secrets_and_outside_text_stay_off_command_lines() {
  world
  export MROOM_WATCH_MCP='app=https://mcp.example.dev/s/k3y-s3cr3t/mcp'
  http mcp.example.dev/s/k3y-s3cr3t/mcp 500 0 application/json - '{"message":"Invalid key supplied"}'
  watch; at 600; watch; expect_rc 0
  expect_posts 1
  local word
  for word in k3y-s3cr3t "Invalid key supplied" xoxb-secret-token; do
    if grep -qF -- "$word" "$FAKE/curl-args.log" "$FAKE/jq-args.log"; then fail "'$word' was on a command line"; else ok; fi
  done
  if grep -qF k3y-s3cr3t "$FAKE/slack.log"; then fail "the URL's path was posted"; else ok; fi
  expect_true "no token header" grep -qF 'header = "Authorization: Bearer xoxb-secret-token"' "$FAKE/slack-headers.log"
}

t_outside_text_is_escaped_in_code_spans() {
  world
  http mcp.example.dev/mcp 503 0 application/json - '{"message":"<!channel> *bold* `tick` https://evil.test"}'
  watch; at 600; watch; expect_rc 0
  run last_post
  expect_out_has "HTTP 503 \`&lt;!channel&gt; *bold* 'tick' https://evil.test\`"
}

t_memory_kills_and_restarts() {
  world
  watch; expect_rc 0
  printf 'oom_kill 5\n' >"$T/proc/vmstat"
  printf '%s\n' 'Out of memory: Killed process 4242 (php8.4) total-vm:1kB' 'oom_reaper: reaped process 4242 (php8.4)' \
    'Memory cgroup out of memory: Killed process 77 (php8.4)' >"$FAKE/kernel.log"
  at 600; watch; expect_rc 0; expect_out_has "memory: 2 killed since the last check"
  expect_posts 1
  run last_post; expect_out_has "2 processes killed for lack of memory since"; expect_out_has ': `php8.4` ×2'
  expect_true "journalctl was not asked from the last check on" grep -qF -- "-k --since @$T0" "$FAKE/journalctl-args.log"
  echo boot-b >"$T/proc/sys/kernel/random/boot_id"
  printf 'oom_kill 1\n' >"$T/proc/vmstat"
  printf '%s\n' 'Out of memory: Killed process 9 (node)' >"$FAKE/kernel.log"
  at 1200; watch; expect_rc 0
  expect_true "no restart post" grep -qF 'the box restarted between the checks at' "$FAKE/slack.log"
  run last_post; expect_out_has '1 process killed for lack of memory since the box started: `node`'
  run "$MROOM" watchdog report; expect_out_has "0 failures, 3 events"
}

t_memory_without_the_journal_or_a_boot_id() {
  world
  rm "$T/proc/sys/kernel/random/boot_id"
  touch "$FAKE/journal-denied"
  watch
  printf 'oom_kill 4\n' >"$T/proc/vmstat"
  at 600; watch; expect_rc 0
  run last_post; expect_out_has "1 process killed for lack of memory since"
  case "$out" in *": \`"*) fail "named a process without the journal" ;; *) ok ;; esac
  if grep -qF restarted "$FAKE/slack.log"; then fail "reported a restart without a boot id"; else ok; fi
}

t_disk_full() {
  world
  printf '/dev/vda1 100 93 7 93%% /\n/dev/vda1 100 93 7 93%% /\n' >"$FAKE/df.txt"
  watch; expect_out_has "disk: 1 checked, 1 at 90% or more"
  at 600; watch
  run last_post; expect_out "⚠️ *box-one*: the disk at / is 93% full"
}

t_jobs() {
  world
  local jobs
  jobs="$(state_dir)/jobs"
  mkdir -p "$jobs"
  jq -n --argjson t "$T0" '{name: "update", every: 86400, running: false, started: ($t - 60), ended: ($t - 30), exit: 1}' >"$jobs/update.json"
  jq -n --argjson t "$T0" '{name: "reap", every: 3600, running: false, started: ($t - 9000), ended: ($t - 8000), exit: 0}' >"$jobs/reap.json"
  jq -n --argjson t "$T0" '{name: "both", every: 3600, running: false, started: ($t - 9000), ended: ($t - 8000), exit: 2}' >"$jobs/both.json"
  jq -n --argjson t "$T0" '{name: "once", every: null, running: false, started: ($t - 99999), ended: ($t - 99990), exit: 0}' >"$jobs/once.json"
  echo '[]' >"$jobs/broken.json"
  watch; expect_out_has "jobs: 5 checked, 5 failing"
  at 600; watch; expect_rc 0
  expect_posts 5
  expect_true "no failed post" grep -qF 'job update failed (exit 1) at' "$FAKE/slack.log"
  expect_true "no log path" grep -qF '~/.local/state/mroom/jobs/update.log' "$FAKE/slack.log"
  expect_true "no overdue post" grep -q 'job reap has not finished a run since .* (it should run every 1h)' "$FAKE/slack.log"
  expect_true "a failed and overdue job needs both posts" test "$(grep -c 'job both' "$FAKE/slack.log")" = 2
  expect_true "no unreadable record post" grep -qF 'the job record ~/.local/state/mroom/jobs/broken.json cannot be read' "$FAKE/slack.log"
  jq -n --argjson t "$T0" '{name: "update", every: 86400, running: false, started: ($t + 900), ended: ($t + 960), exit: 0}' >"$jobs/update.json"
  at 1200; watch; expect_rc 0
  run last_post; expect_out "✅ *box-one*: job update: OK again after 20m"
}

runs() {
  jq -n '[
    {workflowName: "QA reap", status: "completed", conclusion: "failure", createdAt: "2026-10-25T02:17:00Z", url: "https://github.com/example/shop/actions/runs/3"},
    {workflowName: "QA reap", status: "completed", conclusion: "cancelled", createdAt: "2026-10-24T02:17:00Z", url: "u"},
    {workflowName: "QA reap", status: "completed", conclusion: "failure", createdAt: "2026-10-23T02:17:00Z", url: "u"},
    {workflowName: "QA reap", status: "completed", conclusion: "success", createdAt: "2026-10-22T02:17:00Z", url: "u"},
    {workflowName: "Triage", status: "completed", conclusion: "success", createdAt: "2026-10-25T02:15:00Z", url: "u"},
    {workflowName: "Triage", status: "in_progress", conclusion: "", createdAt: "2026-10-25T02:30:00Z", url: "u"}
  ]' >"$FAKE/runs.json"
  switched_on "QA reap" "Triage"
}

# switched_on <name>...: the workflows that exist and are switched on, as gh workflow list gives them.
switched_on() { jq -n '$ARGS.positional | map({name: ., state: "active"})' --args "$@" >"$FAKE/workflows.json"; }

t_workflows_hourly() {
  world
  runs
  watch; expect_out_has "workflows: 2 scheduled workflows checked, 1 failing"
  expect_true "gh not asked about example/shop" grep -qF -- '-R example/shop --event schedule' "$FAKE/gh.log"
  at 600; watch; expect_out_has "workflows: checked 10m ago"
  expect_true "gh was asked again within the hour" test "$(grep -c 'run list' "$FAKE/gh.log")" = 1
  expect_posts 0
  at 3700; watch; expect_rc 0
  expect_posts 1
  run last_post
  expect_out '⚠️ *box-one*: scheduled workflow `QA reap` failed 2 times in a row, the last time at 2026-10-25 02:17 UTC: https://github.com/example/shop/actions/runs/3'
  jq '[{workflowName: "QA reap", status: "completed", conclusion: "success", createdAt: "2026-10-26T02:17:00Z", url: "u"}] + .' \
    "$FAKE/runs.json" >"$FAKE/runs.new" && mv "$FAKE/runs.new" "$FAKE/runs.json"
  at 7400; watch; expect_rc 0
  run last_post; expect_out '✅ *box-one*: scheduled workflow `QA reap`: OK again after 2h 3m'
}

# failing_workflow: "QA reap" posted as failing after two hourly checks.
failing_workflow() {
  runs
  watch
  at 3700; watch
  expect_posts 1
}

t_deleted_and_switched_off_workflows_are_not_failures() {
  world
  runs
  jq '. + [{workflowName: "Old refresh", status: "completed", conclusion: "failure", createdAt: "2026-10-13T07:01:00Z", url: "u"}]' \
    "$FAKE/runs.json" >"$FAKE/runs.new" && mv "$FAKE/runs.new" "$FAKE/runs.json"
  watch; expect_out_has "workflows: 2 scheduled workflows checked, 1 failing"
  at 3700; watch
  expect_posts 1
  if grep -qF "Old refresh" "$FAKE/slack.log"; then fail "reported a workflow that no longer exists"; else ok; fi
  switched_on "Triage"
  at 7400; watch; expect_rc 0
  run last_post; expect_out_has 'scheduled workflow `QA reap`: OK again after'
}

t_gh_trouble_is_not_a_recovery() {
  world
  failing_workflow
  echo 'HTTP 401: Bad credentials (https://api.github.com/graphql)' >"$FAKE/gh-fail"
  at 7400; watch; expect_rc 0; expect_out_has "workflows: cannot check: gh failed"
  expect_posts 1
  at 11000; watch; expect_rc 0
  expect_posts 2
  run last_post
  expect_out '⚠️ *box-one*: cannot check the scheduled workflows of example/shop: gh failed: `HTTP 401: Bad credentials (https://api.github.com/graphql)`'
  run "$MROOM" watchdog status; expect_out_has 'scheduled workflow `QA reap` failed'
  rm "$FAKE/gh-fail"
  touch "$FAKE/timeout-expired"
  at 14600; watch; expect_out_has "workflows: cannot check: gh did not answer within 60s"
  expect_posts 2
}

t_an_empty_workflow_list_is_not_a_recovery() {
  world
  failing_workflow
  echo '[]' >"$FAKE/workflows.json"
  at 7400; watch; expect_rc 0
  expect_out_has "workflows: cannot check: gh listed no switched-on workflows, although the repository has scheduled runs"
  expect_posts 1
  run saved '.conditions | keys[]'; expect_out "workflow:QA reap"
}

t_gh_warnings_do_not_spoil_its_answer() {
  world
  echo 'A new release of gh is available: 2.80.0' >"$FAKE/gh-warn"
  runs
  watch; expect_out_has "workflows: 2 scheduled workflows checked, 1 failing"
}

t_workflow_out_of_the_window_keeps_its_failure() {
  world
  failing_workflow
  jq '[.[] | select(.workflowName != "QA reap")]' "$FAKE/runs.json" >"$FAKE/runs.new" && mv "$FAKE/runs.new" "$FAKE/runs.json"
  at 7400; watch; expect_rc 0
  expect_posts 1
  run saved '.conditions | keys[]'; expect_out "workflow:QA reap"
}

t_slack_refusal_keeps_messages_and_says_why() {
  world
  echo not_in_channel >"$FAKE/slack-error"
  http mcp.example.dev/mcp 500
  watch; at 600; watch; expect_rc 0
  expect_err_has "Slack did not take 1 message(s) (not_in_channel); they wait for the next run"
  run saved '.outbox | length'; expect_out "1"
  rm "$FAKE/slack-error"
  at 1200; watch; expect_rc 0; expect_out_has "posted 1 message(s)"
  run last_post; expect_out_has "MCP server app"
  run saved '.outbox | length'; expect_out "0"
}

t_outbox_keeps_the_newest_fifty() {
  world
  mkdir -p "$(state_dir)"
  jq -n --argjson t "$T0" '{last_run: $t, oom_kill: 3, boot_id: "boot-a", conditions: {}, pending: {},
    outbox: [range(55) | "old message \(.)"]}' >"$(state_dir)/watchdog.json"
  echo ratelimited >"$FAKE/slack-error"
  at 600; watch; expect_rc 0
  run saved '.outbox | length'; expect_out "50"
  run saved '.outbox[0]'; expect_out_has "6 older messages were not delivered"
  run saved '.outbox[-1]'; expect_out "old message 54"
}

t_without_chat_messages_wait() {
  world
  rm "$HOME/.config/mroom/secrets/slack.env"
  http mcp.example.dev/mcp 500
  watch; at 600; watch; expect_rc 0
  expect_out_has "not posted, because there is no ~/.config/mroom/secrets/slack.env; 1 message(s) wait:"
  run saved '.outbox | length'; expect_out "1"
  run "$MROOM" watchdog status; expect_rc 1; expect_out_has "chat: not set up: there is no ~/.config/mroom/secrets/slack.env"
}

t_token_file_must_be_private() {
  world
  chmod 644 "$HOME/.config/mroom/secrets/slack.env"
  http mcp.example.dev/mcp 500
  watch; at 600; watch; expect_rc 0
  expect_out_has "must belong to you and have mode 600"
  expect_posts 0
}

t_state_is_private() {
  world
  http mcp.example.dev/mcp 500
  watch; at 600; watch
  run stat -c '%a' "$(state_dir)" "$(state_dir)/watchdog.json" "$(state_dir)/watchdog.log"; expect_out $'700\n600\n600'
}

t_dry_run_changes_nothing() {
  world
  http mcp.example.dev/mcp 500
  run "$MROOM" watchdog run --dry-run; expect_rc 0
  expect_out_has "found: MCP server app (mcp.example.dev) is failing: HTTP 500"
  expect_out_has "nothing to post"
  expect_no_file "$(state_dir)/watchdog.json"
  expect_no_file "$FAKE/slack.log"
}

t_unreadable_state_starts_again() {
  world
  mkdir -p "$(state_dir)"
  echo 'not json' >"$(state_dir)/watchdog.json"
  watch; expect_rc 0; expect_err_has "watchdog.json cannot be read; starting again"
  run saved '.version'; expect_out "1"
}

t_status_when_stale_or_never_run() {
  world
  run "$MROOM" watchdog status; expect_rc 1; expect_out_has "has not run on this box yet"
  watch
  at 3600
  run "$MROOM" watchdog status; expect_rc 1; expect_out_has "the watchdog has not run for 1h"
}

t_report_counts_failures_from_before_the_window() {
  world
  mkdir -p "$(state_dir)"
  local old=$((T0 - 40 * 86400))
  {
    jq -nc --argjson t "$old" '{at: $t, type: "start", key: "mcp:app", subject: "MCP server app", message: "MCP server app is failing", since: $t}'
    echo '{"half a line'
    jq -nc --argjson t "$((old + 100))" '{at: $t, type: "start", key: "disk:/", subject: "the disk at /", message: "old and over", since: $t}'
    jq -nc --argjson t "$((old + 200))" '{at: $t, type: "end", key: "disk:/", message: "old and over", since: 0}'
  } >"$(state_dir)/watchdog.log"
  run "$MROOM" watchdog report --since 30d; expect_rc 0
  expect_out_has "still failing   MCP server app is failing"
  case "$out" in *"old and over"*) fail "listed a failure that ended before the window" ;; *) ok ;; esac
  expect_out_has "1 failure, 0 events"
}

t_heartbeat() {
  world
  printf 'https://beat.example.dev/ping/b3at-s3cr3t\n' >"$HOME/.config/mroom/secrets/heartbeat.url"
  chmod 600 "$HOME/.config/mroom/secrets/heartbeat.url"
  watch; expect_rc 0
  expect_true "no heartbeat" grep -qF 'https://beat.example.dev/ping/b3at-s3cr3t' "$FAKE/heartbeat.log"
  if grep -qF b3at-s3cr3t "$FAKE/curl-args.log"; then fail "the heartbeat URL was on a command line"; else ok; fi
}

t_one_run_at_a_time() {
  world
  mkdir -p "$(state_dir)"
  flock -x "$(state_dir)/watchdog.lock" sleep 3 &
  local holder=$!
  sleep 0.5
  MROOM_LOCK_WAIT=1 run "$MROOM" watchdog run; expect_rc 1; expect_err_has "another watchdog run has held the lock for 1s"
  wait "$holder"
}

t_usage() {
  world
  run "$MROOM" watchdog; expect_rc 0; expect_out_has "mroom watchdog run"
  run "$MROOM" watchdog frob; expect_rc 2; expect_err_has "unknown command 'frob'"
  run "$MROOM" watchdog run --loud; expect_rc 2; expect_err_has "unknown option '--loud'"
  run "$MROOM" watchdog report --since soon; expect_rc 2; expect_err_has "--since takes a duration"
}

test_case all-clear t_all_clear
test_case failure-posted-on-the-second-check-then-recovery t_failure_posted_on_the_second_check_then_recovery
test_case one-bad-check-is-not-posted t_one_bad_check_is_not_posted
test_case mcp-verdicts t_mcp_verdicts
test_case secrets-and-outside-text-stay-off-command-lines t_secrets_and_outside_text_stay_off_command_lines
test_case outside-text-is-escaped-in-code-spans t_outside_text_is_escaped_in_code_spans
test_case memory-kills-and-restarts t_memory_kills_and_restarts
test_case memory-without-the-journal-or-a-boot-id t_memory_without_the_journal_or_a_boot_id
test_case disk-full t_disk_full
test_case jobs t_jobs
test_case workflows-hourly t_workflows_hourly
test_case deleted-and-switched-off-workflows-are-not-failures t_deleted_and_switched_off_workflows_are_not_failures
test_case gh-trouble-is-not-a-recovery t_gh_trouble_is_not_a_recovery
test_case an-empty-workflow-list-is-not-a-recovery t_an_empty_workflow_list_is_not_a_recovery
test_case gh-warnings-do-not-spoil-its-answer t_gh_warnings_do_not_spoil_its_answer
test_case workflow-out-of-the-window-keeps-its-failure t_workflow_out_of_the_window_keeps_its_failure
test_case slack-refusal-keeps-messages-and-says-why t_slack_refusal_keeps_messages_and_says_why
test_case outbox-keeps-the-newest-fifty t_outbox_keeps_the_newest_fifty
test_case without-chat-messages-wait t_without_chat_messages_wait
test_case token-file-must-be-private t_token_file_must_be_private
test_case state-is-private t_state_is_private
test_case dry-run-changes-nothing t_dry_run_changes_nothing
test_case unreadable-state-starts-again t_unreadable_state_starts_again
test_case status-when-stale-or-never-run t_status_when_stale_or_never_run
test_case report-counts-failures-from-before-the-window t_report_counts_failures_from_before_the_window
test_case heartbeat t_heartbeat
test_case one-run-at-a-time t_one_run_at_a_time
test_case usage t_usage
finish
