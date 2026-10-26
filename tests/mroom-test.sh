#!/usr/bin/env bash
# shellcheck disable=SC2317  # the t_* functions run indirectly, through test_case
# Tests for the bin/mroom front door: help, version, and the commands that arrive in later phases.
set -euo pipefail
SUITE=mroom
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

t_help() {
  run "$MROOM" help; expect_rc 0; expect_out_has "mroom config get <dotted.key>"; expect_out_has "mroom version"
  run "$MROOM"; expect_rc 0; expect_out_has "mroom help"
}

t_version() {
  run "$MROOM" version; expect_rc 0; expect_out "$(cat "$ROOT/VERSION")"
  run "$MROOM" --version; expect_out "$(cat "$ROOT/VERSION")"
  run "$MROOM" version --source; expect_rc 0; expect_out_has "not installed"
  if [[ "$(cat "$ROOT/VERSION")" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then ok; else fail "VERSION is not X.Y.Z"; fi
}

t_later_phases() {
  local cmd
  for cmd in status sessions resume restart doctor site update wt user keys env init guard default; do
    run "$MROOM" "$cmd"; expect_rc 1; expect_err_has "$cmd: not yet: phase 1"
  done
}

t_unknown() {
  run "$MROOM" frobnicate; expect_rc 2; expect_err_has "unknown command 'frobnicate'"
}

test_case help t_help
test_case version t_version
test_case later-phases t_later_phases
test_case unknown t_unknown
finish
