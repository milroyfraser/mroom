#!/usr/bin/env bash
# shellcheck disable=SC2317  # t_* run through test_case
# Tests for lib/memory-preflight: how many QA environments the box's memory holds, the check that stops work the box
# cannot hold, `mroom memory-preflight`, and the gate's memory operation. Offline: each case writes a meminfo file
# and points MROOM_PROC at its folder; nothing on the host is read.
set -euo pipefail
SUITE=memory
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
skip_unless has_box_tools "this host lacks bash 5, flock or GNU date, which box commands need"
# shellcheck source=lib/memory-preflight
. "$ROOT/lib/memory-preflight"

# meminfo <total MB> <available MB> <swap free MB>: a meminfo as Linux writes it, in kB.
meminfo() {
  mkdir -p "$T/proc"
  printf 'MemTotal:       %s kB\nMemFree:          123456 kB\nMemAvailable:   %s kB\nSwapTotal:       2097148 kB\nSwapFree:       %s kB\n' \
    "$(($1 * 1024))" "$(($2 * 1024))" "$(($3 * 1024))" >"$T/proc/meminfo"
  export MROOM_PROC="$T/proc"
}
slots() { run memory_slots "$@"; }
preflight() { run memory_preflight "$@"; }

t_slots_follow_the_memory_up_to_the_limit() {
  # total, reserve, per environment, at most: what is left after the reserve, in whole environments.
  slots 8192 4096 1024 5; expect_rc 0; expect_out 4
  slots 16384 4096 1024 5; expect_out 5
  slots 65536 4096 1024 5; expect_out 5
  slots 65536 4096 1024 40; expect_out 40
  slots 65536 4096 1024 100; expect_out 60
  slots 7900 4096 1024 5; expect_out 3
  slots 5119 4096 1024 5; expect_out 0
  slots 5120 4096 1024 5; expect_out 1
  slots 4096 4096 1024 5; expect_out 0
  slots 2048 4096 1024 5; expect_out 0
  slots 8192 0 2048 5; expect_out 4
  slots 8192 0 1 3; expect_out 3
  slots 8192 4096 0 5; expect_rc 1; expect_out 0
}

t_read_takes_megabytes_from_meminfo() {
  meminfo 7936 3300 2000
  memory_read
  expect_true "MemTotal" [ "$MEM_TOTAL" = 7936 ]
  expect_true "MemAvailable" [ "$MEM_AVAILABLE" = 3300 ]
  expect_true "SwapFree" [ "$MEM_SWAP_FREE" = 2000 ]
  # A line missing, or one not in kB, is not read.
  printf 'MemTotal: 1 kB\nMemAvailable: 1 kB\n' >"$T/proc/meminfo"
  expect_true "a meminfo without SwapFree read" eval '! memory_read'
  printf 'MemTotal: 1 MB\nMemAvailable: 1 kB\nSwapFree: 0 kB\n' >"$T/proc/meminfo"
  expect_true "a figure in another unit read" eval '! memory_read'
  rm "$T/proc/meminfo"
  expect_true "a missing meminfo read" eval '! memory_read'
}

t_fits_counts_available_ram_and_free_swap() {
  meminfo 7936 3300 2000; memory_read
  expect_true "5300 MB do not hold 4096" memory_fits 4096
  expect_true "5300 MB hold 5301" eval '! memory_fits 5301'
  expect_true "exactly enough is enough" memory_fits 5300
}

# The pilot's cases, as mroom memory_preflight has them.
t_preflight_stops_work_the_box_cannot_hold() {
  meminfo 7936 3300 2000
  preflight 4096 "the frontend build"
  expect_rc 0; expect_out "memory ok: 3300 MB available + 2000 MB free swap (need 4096 MB)"
  meminfo 7936 3300 0
  preflight 4096 "the frontend build"
  expect_rc 1; expect_out ""
  expect_err_has "refusing: the frontend build needs about 4096 MB, and the box has 3300 MB of RAM available plus 0 MB of free swap."
  expect_err_has "MROOM_SKIP_MEMORY_CHECK=1"
  meminfo 7936 4096 0
  preflight 4096 build; expect_rc 0
  meminfo 7936 500 500
  preflight 1500 build; expect_rc 1; expect_err_has "needs about 1500 MB"
  meminfo 7936 100 0
  MROOM_SKIP_MEMORY_CHECK=1 preflight 4096 build; expect_rc 0; expect_out ""; expect_err_empty
  printf 'MemTotal: 1 kB\n' >"$T/proc/meminfo"
  preflight 4096 build; expect_rc 0; expect_err_has "memory check skipped: cannot read MemTotal, MemAvailable and SwapFree"
}

t_the_command() {
  meminfo 7936 3300 0
  run "$MROOM" memory-preflight 4096 "the build"; expect_rc 1; expect_err_has "refusing: the build needs about 4096 MB"
  run "$MROOM" memory-preflight 3000; expect_rc 0; expect_out_has "memory ok: 3300 MB available"
  run "$MROOM" memory-preflight 3400; expect_rc 1; expect_err_has "refusing: this needs about 3400 MB"
  run "$MROOM" memory-preflight; expect_rc 2; expect_err_has "usage: mroom memory-preflight <MB> [<what>]"
  run "$MROOM" memory-preflight 0; expect_rc 2
  run "$MROOM" memory-preflight 4G; expect_rc 2
  run "$MROOM" memory-preflight 10 a b; expect_rc 2
}

gate() { run env SSH_ORIGINAL_COMMAND="$1" "$MROOM" gate provision; }

t_the_gates_memory() {
  mkdir -p "$HOME/.config/mroom"
  printf 'MROOM_APP_NAME=shop\n' >"$HOME/.config/mroom/box.env"
  meminfo 7936 3300 2000
  gate memory
  expect_rc 0; expect_out $'total_mb=7936\navailable_mb=3300\nswap_free_mb=2000\nreserve_mb=4096'
  printf 'MROOM_APP_NAME=shop\nMROOM_QA_RESERVE_MB=2048\n' >"$HOME/.config/mroom/box.env"
  gate memory; expect_rc 0; expect_out_has "reserve_mb=2048"
  gate "memory 12"; expect_rc 1; expect_err_has "memory takes 0 argument(s), got 1"
  printf 'MemTotal: 1 kB\n' >"$T/proc/meminfo"
  gate memory; expect_rc 1; expect_err_has "memory: cannot read MemTotal, MemAvailable and SwapFree"
  expect_true "the request is not logged" grep -q 'request: memory' "$HOME/.local/state/mroom/gate.log"
  # A reserve that is not a number of MB is refused with box.env.
  printf 'MROOM_APP_NAME=shop\nMROOM_QA_RESERVE_MB=4G\n' >"$HOME/.config/mroom/box.env"
  meminfo 7936 3300 2000
  gate memory; expect_rc 1; expect_err_has "MROOM_QA_RESERVE_MB must be a whole number of MB"
}

test_case slots t_slots_follow_the_memory_up_to_the_limit
test_case read t_read_takes_megabytes_from_meminfo
test_case fits t_fits_counts_available_ram_and_free_swap
test_case preflight t_preflight_stops_work_the_box_cannot_hold
test_case command t_the_command
test_case gate-memory t_the_gates_memory
finish
