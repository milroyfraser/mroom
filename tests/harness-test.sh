#!/usr/bin/env bash
# shellcheck disable=SC2317  # the t_* functions run indirectly, through test_case
# Tests for the test harness itself: a suite that cannot run must fail in CI, and only skip elsewhere; tests/run.sh
# runs every suite, the ones it is named, or all but those --skip names, as CI splits them.
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

t_run_sh_runs_all_some_or_all_but_some() {
  # A tests folder of three suites, each saying it ran, beside a copy of run.sh.
  mkdir -p "$T/tests"
  cp "$ROOT/tests/run.sh" "$T/tests/run.sh"
  local name
  for name in alpha beta gamma; do printf '#!/usr/bin/env bash\necho "ran %s"\n' "$name" >"$T/tests/$name-test.sh"; done
  run "$T/tests/run.sh"; expect_rc 0; expect_out_has $'ran alpha\n== beta-test.sh\nran beta\n== gamma-test.sh\nran gamma\nall passed'
  run "$T/tests/run.sh" beta; expect_rc 0; expect_out $'== beta-test.sh\nran beta\nall passed'
  run "$T/tests/run.sh" --skip beta; expect_rc 0
  expect_out $'== alpha-test.sh\nran alpha\n== gamma-test.sh\nran gamma\nall passed'
  run "$T/tests/run.sh" --skip beta --skip alpha; expect_rc 0; expect_out $'== gamma-test.sh\nran gamma\nall passed'
  # A name it has no suite of is a mistake, not a skip.
  run "$T/tests/run.sh" --skip delta; expect_rc 2; expect_err_has "no such test file"
  run "$T/tests/run.sh" --skip; expect_rc 2; expect_err_has "--skip takes a test name"
  # A suite that fails fails the run, after the rest ran.
  printf '#!/usr/bin/env bash\nexit 1\n' >"$T/tests/beta-test.sh"
  run "$T/tests/run.sh"; expect_rc 1; expect_out_has "ran gamma"; expect_out_has "FAILED: beta-test.sh"
}

test_case skip-fails-in-ci t_skip_fails_in_ci
test_case skip-skips-elsewhere t_skip_skips_elsewhere
test_case run-sh t_run_sh_runs_all_some_or_all_but_some
finish
