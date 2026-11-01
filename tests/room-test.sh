#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2329  # the t_* functions run indirectly, through test_case
# Tests for `mroom room snapshot|watch|build`: the Room's facts per pull request, the gate that waits for a change,
# and the split of the page into a small page and its code. Offline: GitHub is tests/fakes/gh.
set -euo pipefail
SUITE=room
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# world: the fake gh on PATH, answering from $T/gh.
world() {
  mkdir -p "$T/bin" "$T/gh"
  ln -sfn "$ROOT/tests/fakes/gh" "$T/bin/gh"
  export PATH="$T/bin:$ORIG_PATH" GH_FAKE="$T/gh"
}

# pr <n> <state> <mergeStateStatus> <runs json> [comments]: the fake's answer for that pull request.
pr() {
  jq -n --argjson n "$1" --arg s "$2" --arg m "$3" --argjson runs "$4" --argjson c "${5:-0}" \
    '{number: $n, state: $s, isDraft: false, headRefOid: "abcdef1234567890", mergeStateStatus: $m,
      reviewDecision: "REVIEW_REQUIRED", statusCheckRollup: $runs, comments: [range($c)] | map({}), reviews: []}' \
    >"$T/gh/pr-$1.json"
}

OK_RUN='{"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"SUCCESS"}'
CANCELLED_RUN='{"__typename":"CheckRun","name":"old","status":"COMPLETED","conclusion":"CANCELLED"}'
FAILED_RUN='{"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"FAILURE"}'
RUNNING_RUN='{"__typename":"CheckRun","name":"e2e","status":"IN_PROGRESS","conclusion":null}'
STATUS_FAIL='{"__typename":"StatusContext","context":"deploy","state":"ERROR"}'

checks_of() { jq -r --argjson n "$1" 'select(.pr == $n) | .checks' <<<"$out"; }

t_snapshot_checks() {
  world
  pr 1 OPEN CLEAN "[$OK_RUN,$CANCELLED_RUN]"
  pr 2 OPEN BLOCKED "[$OK_RUN,$FAILED_RUN,$STATUS_FAIL]"
  pr 3 OPEN BLOCKED "[$OK_RUN,$RUNNING_RUN]"
  pr 4 OPEN BEHIND "[$FAILED_RUN]"
  pr 5 MERGED UNKNOWN "[$OK_RUN]"
  pr 6 OPEN CLEAN "[]"
  run "$MROOM" room snapshot --repo o/r 1 2 3 4 5 6
  expect_rc 0
  expect_true "a cancelled run is not a failure" [ "$(checks_of 1)" = green ]
  expect_true "a failing run or status is red" [ "$(checks_of 2)" = red ]
  expect_true "a run still going is running" [ "$(checks_of 3)" = running ]
  expect_true "behind main wins" [ "$(checks_of 4)" = behind ]
  expect_true "a merged pull request has no checks" [ "$(checks_of 5)" = null ]
  expect_true "no runs yet is running" [ "$(checks_of 6)" = running ]
  run "$MROOM" room snapshot --repo o/r 2
  expect_out_has '"failing":["deploy","lint"]'
  expect_out_has '"head":"abcdef123456"'
  expect_true "one line per pull request" [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ]
}

t_watch_records_then_heartbeat() {
  world
  pr 1 OPEN CLEAN "[$OK_RUN]"
  run "$MROOM" room watch --repo o/r --every 1 --max 1 --state "$T/w.txt" 1
  expect_rc 0; expect_out "heartbeat: no change in 1s"
  expect_true "the first run records the state" grep -q '"pr":1' "$T/w.txt"
}

t_watch_reports_only_changes() {
  world
  pr 1 OPEN CLEAN "[$OK_RUN]"
  pr 2 OPEN CLEAN "[$OK_RUN]"
  "$MROOM" room watch --repo o/r --every 1 --max 1 --state "$T/w.txt" 1 2 >/dev/null
  pr 2 OPEN BLOCKED "[$FAILED_RUN]" 1
  run "$MROOM" room watch --repo o/r --every 1 --max 30 --state "$T/w.txt" 1 2
  expect_rc 0
  expect_out_has 'changed {"pr":2,'
  expect_out_has '"checks":"red"'
  case "$out" in *'"pr":1,'*) fail "an unchanged pull request was reported" ;; *) ok ;; esac
  run "$MROOM" room watch --repo o/r --every 1 --max 1 --state "$T/w.txt" 1 2
  expect_out "heartbeat: no change in 1s"
}

t_watch_unreachable() {
  world
  pr 1 OPEN CLEAN "[$OK_RUN]"
  touch "$T/gh/down"
  run "$MROOM" room watch --repo o/r --every 1 --max 60 --state "$T/w.txt" 1
  expect_rc 1; expect_out_has "unreachable: error connecting to api.github.com"
}

t_default_state_is_private() {
  world
  pr 1 OPEN CLEAN "[$OK_RUN]"
  run "$MROOM" room watch --repo o/r --every 1 --max 1 1
  expect_rc 0
  local f
  f="$(ls "$HOME/.local/state/mroom/room/"watch-*.txt)"
  expect_true "the state file is the box user's alone" [ "$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f")" = 600 ]
}

t_usage() {
  run "$MROOM" room snapshot; expect_rc 2; expect_err_has "name at least one pull request"
  run "$MROOM" room snapshot 12x; expect_rc 2; expect_err_has "a pull request is its number"
  run "$MROOM" room snapshot --repo 'o/r;x' 1; expect_rc 2; expect_err_has "--repo is <owner/repo>"
  run "$MROOM" room snapshot --every 5 1; expect_rc 2; expect_err_has "--every is a watch option"
  run "$MROOM" room watch --every 0 1; expect_rc 2; expect_err_has "whole seconds"
  run "$MROOM" room nope; expect_rc 2; expect_err_has "unknown subcommand"
  run "$MROOM" room build; expect_rc 2; expect_err_has "needs a folder"
}

t_build_splits_the_page() {
  run "$MROOM" room build "$T/out"
  expect_rc 0; expect_out_has "stamp "
  local f
  for f in index.html room.css room-1.js room-version.txt; do expect_file "$T/out/$f"; done
  expect_true "the page links its code" grep -q '<script src="room-1.js"></script>' "$T/out/index.html"
  expect_true "the page links its styles" grep -q '<link rel="stylesheet" href="room.css">' "$T/out/index.html"
  expect_true "the page carries the stamp" grep -q "content=\"$(cat "$T/out/room-version.txt")\"" "$T/out/index.html"
  expect_true "the page is small" [ "$(wc -c <"$T/out/index.html")" -lt 16384 ]
  # Nothing is lost: every line of the source is in one of the files.
  local src="$ROOT/plugin/skills/implement/room/room.html"
  expect_true "every line of the source survives" diff \
    <(grep -vxE '</?style>|</?script>' "$src" | sort) \
    <(cat "$T/out/index.html" "$T/out/room.css" "$T/out"/room-*.js | grep -vE 'name="mroom-room"|href="room.css"|src="room-[0-9]+.js"' | sort)
}

t_build_keeps_other_files() {
  mkdir -p "$T/site"; echo keep >"$T/site/index.html"
  run "$MROOM" room build "$T/site"; expect_rc 1; expect_err_has "holds other files"
  run cat "$T/site/index.html"; expect_out "keep"
  "$MROOM" room build "$T/again" >/dev/null
  echo note >"$T/again/notes.txt"
  run "$MROOM" room build "$T/again"; expect_rc 1; expect_err_has "holds other files"
  rm "$T/again/notes.txt"
  run "$MROOM" room build "$T/again"; expect_rc 0
}

t_build_refuses_inline_blocks() {
  printf '<title>x</title>\n<script>var a = 1;</script>\n' >"$T/page.html"
  run "$MROOM" room build "$T/out" --from "$T/page.html"
  expect_rc 1; expect_err_has "not alone on their lines"
  printf '<title>x</title>\n<style>\nbody{}\n' >"$T/open.html"
  run "$MROOM" room build "$T/out" --from "$T/open.html"
  expect_rc 1; expect_err_has "never closes"
}

test_case snapshot-checks t_snapshot_checks
test_case watch-records-then-heartbeat t_watch_records_then_heartbeat
test_case watch-reports-only-changes t_watch_reports_only_changes
test_case watch-unreachable t_watch_unreachable
test_case default-state-is-private t_default_state_is_private
test_case usage t_usage
test_case build-splits-the-page t_build_splits_the_page
test_case build-keeps-other-files t_build_keeps_other_files
test_case build-refuses-inline-blocks t_build_refuses_inline_blocks
finish
