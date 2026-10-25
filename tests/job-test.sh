#!/usr/bin/env bash
# shellcheck disable=SC2317  # the t_* functions run indirectly, through test_case
# Tests for `mroom job run|list`: the record a box job leaves, its log, and the lock against overlap.
set -euo pipefail
SUITE=job
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
skip_unless has_box_tools "this host lacks bash 5, flock or GNU date, which box commands need"

jobs_dir() { echo "$HOME/.local/state/mroom/jobs"; }

t_records_a_run() {
  export MROOM_NOW=1761400000
  run "$MROOM" job run nightly --every 1d -- sh -c 'echo hello; echo oops >&2'
  expect_rc 0; expect_out_has "job nightly: exit 0"
  run jq -r '[.name, .every, .running, .started, .ended, .exit] | map(tostring) | join(" ")' "$(jobs_dir)/nightly.json"
  expect_out "nightly 86400 false 1761400000 1761400000 0"
  run cat "$(jobs_dir)/nightly.log"
  expect_out_has "hello"; expect_out_has "oops"; expect_out_has "== exit 0 after 0s"
}

t_failure_keeps_its_code() {
  run "$MROOM" job run broken -- sh -c 'exit 3'
  expect_rc 3; expect_out_has "job broken: exit 3"
  run jq -r '.exit, .every' "$(jobs_dir)/broken.json"; expect_out $'3\nnull'
}

t_list() {
  export MROOM_NOW=1761400000
  run "$MROOM" job list; expect_rc 0; expect_out_has "no jobs have run yet"
  "$MROOM" job run good --every 1h -- true >/dev/null
  "$MROOM" job run bad -- false >/dev/null || true
  run "$MROOM" job list; expect_rc 0
  expect_out_has "good"; expect_out_has "1h"; expect_out_has "bad"; expect_out_has "failed"
  export MROOM_NOW=$((1761400000 + 3 * 3600))
  run "$MROOM" job list; expect_out_has "overdue"
}

t_overlap_exits_at_once() {
  mkdir -p "$T/w"
  "$MROOM" job run slow -- sh -c "touch '$T/w/started'; while [ ! -f '$T/w/go' ]; do sleep 0.1; done" >/dev/null &
  local pid=$! i=0
  while [ ! -f "$T/w/started" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  run "$MROOM" job run slow -- true; expect_rc 0; expect_out "job slow is already running"
  run jq -r .running "$(jobs_dir)/slow.json"; expect_out "true"
  touch "$T/w/go"
  wait "$pid"
  run jq -r .running "$(jobs_dir)/slow.json"; expect_out "false"
}

t_lock_not_left_to_children() {
  # A process the command leaves running must not hold the lock, or the job would never run again.
  run "$MROOM" job run spawner -- sh -c 'sleep 3 & echo spawned'; expect_rc 0
  run "$MROOM" job run spawner -- true; expect_rc 0; expect_out_has "job spawner: exit 0"
}

t_log_rotates() {
  mkdir -p "$(jobs_dir)"
  head -c 1100000 /dev/zero >"$(jobs_dir)/big.log"
  run "$MROOM" job run big -- echo fresh; expect_rc 0
  expect_file "$(jobs_dir)/big.log.1"
  run cat "$(jobs_dir)/big.log"; expect_out_has "fresh"
}

t_files_are_private() {
  run "$MROOM" job run quiet -- echo secret-output; expect_rc 0
  run stat -c '%a' "$(jobs_dir)" "$(jobs_dir)/quiet.json" "$(jobs_dir)/quiet.log" "$(jobs_dir)/quiet.lock"
  expect_out $'700\n600\n600\n600'
}

t_unreadable_records() {
  mkdir -p "$(jobs_dir)"
  echo '[]' >"$(jobs_dir)/odd.json"
  run "$MROOM" job run odd -- true; expect_rc 0; expect_out_has "job odd: exit 0"
  run jq -r .name "$(jobs_dir)/odd.json"; expect_out "odd"
  echo 'not json' >"$(jobs_dir)/junk.json"
  run "$MROOM" job list; expect_rc 0; expect_out_has "junk                 unreadable record: ~/.local/state/mroom/jobs/junk.json"
}

t_usage() {
  run "$MROOM" job run; expect_rc 2; expect_err_has "run needs a job name"
  run "$MROOM" job run Bad -- true; expect_rc 2; expect_err_has "a job name is lowercase"
  run "$MROOM" job run x --every soon -- true; expect_rc 2; expect_err_has "--every takes a duration"
  run "$MROOM" job run x; expect_rc 2; expect_err_has "needs a command after --"
  run "$MROOM" job frob; expect_rc 2; expect_err_has "unknown command 'frob'"
  run "$MROOM" job help; expect_rc 0; expect_out_has "mroom job run <name>"
}

test_case records-a-run t_records_a_run
test_case failure-keeps-its-code t_failure_keeps_its_code
test_case list t_list
test_case overlap-exits-at-once t_overlap_exits_at_once
test_case lock-not-left-to-children t_lock_not_left_to_children
test_case log-rotates t_log_rotates
test_case files-are-private t_files_are_private
test_case unreadable-records t_unreadable_records
test_case usage t_usage
finish
