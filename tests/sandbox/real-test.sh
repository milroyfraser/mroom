#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2016  # t_* run through test_case; a $ in single quotes is for the inner shell
# The runner sandbox (design 8.5) on a real, throwaway GitHub runner: what the offline fakes cannot show. sandbox.sh
# makes the users, the sudoers rules and the root-owned copies; check.sh's hostile probe, run through mroom-step, is
# denied everything; the step reaches the secret only through the holder's wrapper; a link in a copied tree hands root
# nothing. Then the sandbox is weakened twice (the runner's home opened, a sudo rule added) and check.sh must fail
# loudly each time. Last, bwrap-probe: bubblewrap works, and the sandbox's sudo hop is refused inside it.
# CI only: it adds users and sudoers rules and closes the runner's home, so tests/run.sh does not pick it up.
set -euo pipefail
SUITE=sandbox-real
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
[ -n "${GITHUB_ACTIONS:-}" ] || { echo "sandbox real-test: runs only on a throwaway GitHub runner" >&2; exit 1; }

RS="$ROOT/lib/runner-sandbox"
# The runner's real home: test_case gives each test a temp HOME, but the sandbox closes, and the probe tries, this one.
RUNNER_HOME="$HOME"
SECRET="secret-$RANDOM$RANDOM$RANDOM"
APP="$(mktemp -d)"
cleanup() { sudo rm -f /etc/sudoers.d/zz-weakened; chmod 0700 "$RUNNER_HOME"; rm -rf "$APP" "$TOP"; }
trap cleanup EXIT

t_it_sets_up_and_holds() {
  export HOME="$RUNNER_HOME"
  mkdir -p "$APP/harness/lib"
  echo 'export default 1;' >"$APP/harness/drive.mjs"
  ln -s /etc/shadow "$APP/harness/lib/shadow"
  # The holder's wrapper proves it reads the secret without printing it.
  cat >"$APP/holder.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$(id -un)" = mroom-holder ] && [ -s /etc/mroom-sandbox/holder/secret ] && echo holder-ok
EOF
  cd "$APP"
  run sudo -E env MROOM_SANDBOX_SECRET="$SECRET" MROOM_SANDBOX_HOLDER=holder.sh MROOM_SANDBOX_COPY=harness \
    MROOM_SANDBOX_PATH="$(dirname "$(command -v node)")" MROOM_SANDBOX_ENV='QA_DB=qa_1' \
    MROOM_SANDBOX_KNOWN_HOSTS='qa.example.test ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJAL4XYtQyl1WalugDy7r5RDPoMgJhIDreu8WeEGPU/k' \
    "$RS/sandbox.sh"
  expect_rc 0; expect_err_has "the secret is readable by mroom-holder only"; expect_err_lacks "$SECRET"

  run /usr/local/lib/mroom-sandbox/check.sh
  expect_rc 0; expect_err_has "the sandbox holds"
  [ "$rc" = 0 ] || echo "$out" >&2

  run mroom-step -- id -un
  expect_out mroom-step
  run mroom-step -- env
  expect_out_has "QA_DB=qa_1"; expect_out_has "MROOM_HOLDER=/usr/local/bin/mroom-holder"
  case "$out" in *GITHUB_* | *"$SECRET"* | *RUNNER_*) fail "the runner's environment reached the step" ;; *) ok ;; esac
  run mroom-step -- node -e 'console.log(process.version)'
  expect_rc 0
  run mroom-step -- sh -c 'sudo -n -u mroom-holder "$MROOM_HOLDER"'
  expect_rc 0; expect_out holder-ok
  run mroom-step -- sh -c 'echo found >"$MROOM_EVIDENCE/result.txt"'
  expect_true "the runner reads the step's evidence" [ "$(cat /var/lib/mroom-sandbox/evidence/result.txt)" = found ]

  expect_true "the secret is the holder's, mode 600" [ "$(sudo stat -c '%U %a' /etc/mroom-sandbox/holder/secret)" = "mroom-holder 600" ]
  run cat /etc/mroom-sandbox/holder/secret
  expect_rc 1
  # (The runner's own sudo is GitHub's, to anything; the runner is trusted code. The step is not.)
  run mroom-step -- sudo -n -u mroom-holder cat /etc/mroom-sandbox/holder/secret
  expect_true "the step gets nothing but the wrapper as the holder" [ "$rc" != 0 ]
  expect_true "the copy is root's" [ "$(stat -c %U /opt/mroom-sandbox/harness/drive.mjs)" = root ]
  expect_true "a link in the copy stays a link" [ -L /opt/mroom-sandbox/harness/lib/shadow ]
  expect_true "root's chown never followed it" [ "$(stat -c '%U:%G %a' /etc/shadow)" = "root:shadow 640" ]
  run mroom-step -- cat /opt/mroom-sandbox/harness/lib/shadow
  expect_true "the step cannot read through it" [ "$rc" != 0 ]

  run sudo -E "$RS/sandbox.sh"
  expect_rc 1; expect_err_has "already set up"
}

t_a_weakened_sandbox_fails_the_check() {
  export HOME="$RUNNER_HOME"
  chmod 0755 "$HOME"
  run /usr/local/lib/mroom-sandbox/check.sh
  chmod 0700 "$HOME"
  expect_rc 1
  expect_out_has "::error::runner-sandbox: the sandbox does not hold"
  expect_out_has "(runner-home)"

  echo 'mroom-step ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/zz-weakened >/dev/null
  sudo chmod 0440 /etc/sudoers.d/zz-weakened
  run /usr/local/lib/mroom-sandbox/check.sh
  sudo rm -f /etc/sudoers.d/zz-weakened
  expect_rc 1
  expect_out_has "(sudo-root)"
  expect_out_has "(sudo-holder)"

  run /usr/local/lib/mroom-sandbox/check.sh
  expect_rc 0
}

t_bwrap_works_and_the_hop_is_refused_inside_it() {
  export HOME="$RUNNER_HOME"
  run bash "$RS/bwrap-probe.sh" setup
  echo "$out"
  expect_rc 0
  run bash "$RS/bwrap-probe.sh" check mroom-step -- true
  echo "$out"
  expect_rc 0
  expect_out_has "ok bwrap --unshare-all works"
  expect_out_has "ok the sudo hop works outside bwrap"
}

test_case setup t_it_sets_up_and_holds
test_case weakened t_a_weakened_sandbox_fails_the_check
test_case bwrap t_bwrap_works_and_the_hop_is_refused_inside_it
finish
