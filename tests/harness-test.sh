#!/usr/bin/env bash
# shellcheck disable=SC2317  # the t_* functions run indirectly, through test_case
# Tests for the test harness itself: a suite that cannot run must fail in CI, and only skip elsewhere.
set -euo pipefail
SUITE=harness
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# suite <file>: a one-line suite whose requirement is never met.
suite() {
  cat >"$1" <<SUITE
#!/usr/bin/env bash
set -euo pipefail
SUITE=never
source "$ROOT/tests/lib.sh"
never() { return 1; }
skip_unless never "the requirement is missing"
echo "should not get here"
SUITE
}

t_skip_fails_in_ci() {
  suite "$T/never-test.sh"
  run env CI=true bash "$T/never-test.sh"; expect_rc 1
  expect_err_has "FAIL [never] the requirement is missing, and CI must run every test"
  expect_out_has "never: 0 passed, 1 failed"
}

t_skip_skips_elsewhere() {
  suite "$T/never-test.sh"
  run env -u CI bash "$T/never-test.sh"; expect_rc 0
  expect_out_has "skip [never] the requirement is missing"
  case "$out" in *"should not get here"*) fail "ran past skip_unless" ;; *) ok ;; esac
}

test_case skip-fails-in-ci t_skip_fails_in_ci
test_case skip-skips-elsewhere t_skip_skips_elsewhere
finish
