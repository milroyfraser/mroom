#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2016  # t_* run through test_case; a $ in single quotes is for the inner shell
# The runner sandbox (design 8.5) on a real, throwaway GitHub runner: what the offline fakes cannot show. sandbox.sh
# makes the users, the sudoers rules and the root-owned copies; check.sh's hostile probe, run through mroom-step, is
# denied everything; the step reaches the secret only through the holder's wrapper; a link in a copied tree hands root
# nothing. Then the sandbox is weakened three times (the runner's home opened, a sudo rule added, a tool made writable
# by every user again) and check.sh must fail loudly each time. Last, bwrap-probe: bubblewrap works, and the sandbox's sudo hop is refused inside it.
# CI only: it adds users and sudoers rules and closes the runner's home, so tests/run.sh does not pick it up.
set -euo pipefail
SUITE=sandbox-real
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
[ -n "${GITHUB_ACTIONS:-}" ] || { echo "sandbox real-test: runs only on a throwaway GitHub runner" >&2; exit 1; }

RS="$ROOT/lib/runner-sandbox"
# The runner's real home: test_case gives each test a temp HOME, but the sandbox closes, and the probe tries, this one.
RUNNER_HOME="$HOME"
# A tool the image leaves writable by every user (GitHub's runs chmod -R 777 on /usr/local/bin), which the runner runs.
TOOL="$(readlink -f /usr/local/bin/node 2>/dev/null || true)"
[ -f "$TOOL" ] || TOOL="$(readlink -f "$(command -v node)")"
SECRET="secret-$RANDOM$RANDOM$RANDOM"
APP="$(mktemp -d)"
cleanup() { sudo rm -f /etc/sudoers.d/zz-weakened; sudo chmod o-w "$TOOL"; chmod 0700 "$RUNNER_HOME"; rm -rf "$APP" "$TOP"; }
trap cleanup EXIT

# step_body: the step's output without the ::stop-commands:: markers mroom-step puts around it in a GitHub job.
step_body() { out="$(grep -Ev -e '^$' -e '^::stop-commands::[0-9a-f]{32}$' -e '^::[0-9a-f]{32}::$' <<<"$out" || true)"; }

no_leak() { ! grep -rqs -e "$SECRET" -e 'root:' "$1"; }

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
  echo "before the sandbox: $(stat -c '%A %U' "$TOOL") $TOOL"
  cd "$APP"
  run sudo -E env MROOM_SANDBOX_RUNNER_PATH="$PATH" MROOM_SANDBOX_SECRET="$SECRET" MROOM_SANDBOX_HOLDER=holder.sh MROOM_SANDBOX_COPY=harness \
    MROOM_SANDBOX_PATH="$(dirname "$(command -v node)")" MROOM_SANDBOX_ENV='QA_DB=qa_1' \
    MROOM_SANDBOX_KNOWN_HOSTS='qa.example.test ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJAL4XYtQyl1WalugDy7r5RDPoMgJhIDreu8WeEGPU/k' \
    "$RS/sandbox.sh"
  expect_rc 0; expect_err_has "the secret is readable by mroom-holder only"; expect_err_lacks "$SECRET"

  run /usr/lib/mroom-sandbox/check.sh
  expect_rc 0; expect_err_has "the sandbox holds"
  [ "$rc" = 0 ] || echo "$out" >&2

  run mroom-step -- id -un
  expect_true "the step's output is wrapped in ::stop-commands::" grep -Eqx '::stop-commands::[0-9a-f]{32}' <<<"$out"
  step_body
  expect_out mroom-step
  run mroom-step -- env
  expect_out_has "QA_DB=qa_1"; expect_out_has "MROOM_HOLDER=/usr/lib/mroom-sandbox/holder"
  case "$out" in *GITHUB_* | *"$SECRET"* | *RUNNER_*) fail "the runner's environment reached the step" ;; *) ok ;; esac
  run mroom-step -- node -e 'console.log(process.version)'
  expect_rc 0
  run mroom-step -- sh -c 'sudo -n -u mroom-holder "$MROOM_HOLDER"'
  step_body
  expect_rc 0; expect_out holder-ok
  run mroom-step -- sh -c 'echo found >"$MROOM_EVIDENCE/result.txt"'
  expect_true "the runner reads the step's evidence" [ "$(cat /var/lib/mroom-sandbox/evidence/result.txt)" = found ]

  expect_true "no folder on the runner's PATH is left writable by all" \
    [ -z "$(IFS=:; for d in $PATH; do [ -d "$d" ] && find -H "$d" -maxdepth 0 -perm -o+w; done)" ]
  expect_true "nor a folder above one (GitHub's /opt)" [ -z "$(find /opt /usr/local -maxdepth 0 -perm -o+w)" ]
  expect_true "the secret is the holder's, mode 600" [ "$(sudo stat -c '%U %a' /etc/mroom-sandbox/holder/secret)" = "mroom-holder 600" ]
  run cat /etc/mroom-sandbox/holder/secret
  expect_rc 1
  # (The runner's own sudo is GitHub's, to anything; the runner is trusted code. The step is not.)
  run mroom-step -- sudo -n -u mroom-holder cat /etc/mroom-sandbox/holder/secret
  expect_true "the step gets nothing but the wrapper as the holder" [ "$rc" != 0 ]
  expect_true "the copy is root's" [ "$(stat -c %U /usr/lib/mroom-sandbox/copies/harness/drive.mjs)" = root ]
  expect_true "a link in the copy stays a link" [ -L /usr/lib/mroom-sandbox/copies/harness/lib/shadow ]
  expect_true "root's chown never followed it" [ "$(stat -c '%U:%G %a' /etc/shadow)" = "root:shadow 640" ]
  run mroom-step -- cat /usr/lib/mroom-sandbox/copies/harness/lib/shadow
  expect_true "the step cannot read through it" [ "$rc" != 0 ]

  # The tool the runner runs next: the step cannot change it, whatever the image left.
  run mroom-step -- /bin/sh -c ': >>"$1"' _ "$TOOL"
  expect_true "the step cannot append to $TOOL" [ "$rc" != 0 ]
  expect_true "$TOOL is no longer writable by every user" [ -z "$(find "$TOOL" -perm -o+w)" ]

  # The holder's wrapper takes no arguments unless the job says so.
  run mroom-step -- /bin/sh -c 'sudo -n -u mroom-holder "$MROOM_HOLDER" --extra'
  expect_true "the wrapper refuses arguments by default" [ "$rc" != 0 ]

  # Nothing the step starts outlives it.
  run mroom-step -- /bin/sh -c 'nohup sleep 300 >/dev/null 2>&1 &'
  expect_rc 0
  expect_true "the step's background process was killed" [ -z "$(pgrep -u mroom-step || true)" ]
  run mroom-step -- /bin/sh -c 'nohup sudo -n -u mroom-holder "$MROOM_HOLDER" >/dev/null 2>&1 &'
  expect_true "and the holder's" [ -z "$(pgrep -u mroom-holder || true)" ]

  # --collect: a link the step left gives only what the step itself could read.
  printf 'runner-only-%s\n' "$SECRET" >"$HOME/runner-only"
  run mroom-step -- /bin/sh -c 'ln -s "$1" "$MROOM_EVIDENCE/leak"; ln -s /etc/shadow "$MROOM_EVIDENCE/shadow"' _ "$HOME/runner-only"
  mkdir -p "$TOP/collected"
  run mroom-step --collect "$TOP/collected"
  expect_rc 0
  expect_true "the evidence came" [ "$(cat "$TOP/collected/result.txt")" = found ]
  expect_true "no link came" [ -z "$(find "$TOP/collected" -type l)" ]
  expect_true "nothing of the runner's or root's came" no_leak "$TOP/collected"
  rm -f "$HOME/runner-only"

  run sudo -E "$RS/sandbox.sh"
  expect_rc 1; expect_err_has "already set up"
}

t_a_weakened_sandbox_fails_the_check() {
  export HOME="$RUNNER_HOME"
  chmod 0755 "$HOME"
  run /usr/lib/mroom-sandbox/check.sh
  chmod 0700 "$HOME"
  expect_rc 1
  expect_out_has "::error::runner-sandbox: the sandbox does not hold"
  expect_out_has "(runner-home)"

  echo 'mroom-step ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/zz-weakened >/dev/null
  sudo chmod 0440 /etc/sudoers.d/zz-weakened
  run /usr/lib/mroom-sandbox/check.sh
  sudo rm -f /etc/sudoers.d/zz-weakened
  expect_rc 1
  expect_out_has "(sudo-root)"
  expect_out_has "(sudo-holder)"

  # A tool left writable by every user again: the probe's disk scan finds it.
  sudo chmod o+w "$TOOL"
  run /usr/lib/mroom-sandbox/check.sh
  sudo chmod o-w "$TOOL"
  expect_rc 1
  expect_out_has "(writable)"
  expect_out_has "$TOOL"

  run /usr/lib/mroom-sandbox/check.sh
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
