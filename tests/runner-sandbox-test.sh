#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2016  # t_* run through test_case; a $ in single quotes is a fake's own
# Tests for the runner sandbox (design 8.5), offline: lib/runner-sandbox and actions/runner-sandbox. sandbox.sh's inputs
# are refused before anything changes; mroom-step (step.sh) runs its command through a fake sudo with env -i and only
# the variables it names; the probe, run as the test's own user, reaches what that user can reach and reports each,
# so a broken sandbox fails check.sh loudly; check.sh's verdict reads fake reports; bwrap-probe.sh reads a fake bwrap.
# What only a real runner shows (users, sudoers, the probe denied everything) is tests/sandbox/real-test.sh, in CI.
set -euo pipefail
SUITE=runner-sandbox
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RS="$ROOT/lib/runner-sandbox"

# fake_bin <name> <body>: a script on PATH, in $T/bin.
fake_bin() {
  mkdir -p "$T/bin"
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"$T/bin/$1"
  chmod +x "$T/bin/$1"
  export PATH="$T/bin:$PATH"
}

# world: a set-up sandbox's folders in $T, as sandbox.sh leaves them, which MROOM_SANDBOX_ETC and _VAR then name.
world() {
  mkdir -p "$T/etc/holder" "$T/var/inputs" "$T/var/evidence"
  : >"$T/etc/env"
  : >"$T/etc/path"
  export MROOM_SANDBOX_ETC="$T/etc" MROOM_SANDBOX_VAR="$T/var"
}

# --- common.sh ---

t_step_env_takes_plain_names_and_refuses_credentials() {
  # shellcheck source=lib/runner-sandbox/common.sh
  . "$RS/common.sh"
  local line
  for line in 'APP_URL=https://qa.example.test' 'QA_DB=qa_12' 'EMPTY=' 'MONKEY_BUSINESS=x=y'; do
    expect_true "accepts $line" sandbox_env_line "$line"
  done
  for line in 'GH_TOKEN=x' 'API_KEY=x' 'DB_PASSWORD=x' 'AWS_REGION=x' 'GITHUB_SHA=x' 'CLAUDE_CODE_OAUTH=x' 'SENTRY_DSN=x' \
    'PATH=/bin' 'HOME=/x' 'MROOM_HOLDER=/x' 'lower=x' 'NOEQUALS' '1BAD=x' "TAB=a$(printf '\t')b"; do
    expect_true "refuses $line" bash -c '. "$1"; ! sandbox_env_line "$2" >/dev/null' _ "$RS/common.sh" "$line"
  done
}

# --- sandbox.sh: every input checked before anything changes ---

t_setup_refuses_bad_inputs_before_changing_anything() {
  mkdir -p "$T/app/harness" "$T/elsewhere"
  ln -s "$T/elsewhere" "$T/app/link"
  ln -s "$T/app/harness" "$T/app/hlink"
  echo 'echo hi' >"$T/app/wrapper.sh"
  cd "$T/app"
  run env MROOM_SANDBOX_SECRET=s3cret "$RS/sandbox.sh"
  expect_rc 2; expect_err_has "needs MROOM_SANDBOX_HOLDER"; expect_err_lacks s3cret
  run env MROOM_SANDBOX_HOLDER=missing.sh "$RS/sandbox.sh"
  expect_rc 2; expect_err_has "not a regular file"
  run env MROOM_SANDBOX_HOLDER=hlink "$RS/sandbox.sh"
  expect_rc 2; expect_err_has "not a regular file"
  run env MROOM_SANDBOX_KNOWN_HOSTS='qa.example.test ssh-ed25519 AAAA; rm' "$RS/sandbox.sh"
  expect_rc 2; expect_err_has "MROOM_SANDBOX_KNOWN_HOSTS"
  local path
  for path in ../etc /abs harness/../x ./harness missing link link/x hlink; do
    run env MROOM_SANDBOX_COPY="$path" "$RS/sandbox.sh"
    expect_rc 2; expect_err_has "MROOM_SANDBOX_COPY"
  done
  run env MROOM_SANDBOX_PATH='relative/bin' "$RS/sandbox.sh"
  expect_rc 2; expect_err_has "MROOM_SANDBOX_PATH"
  run env MROOM_SANDBOX_PATH="$T/app:/usr/bin" "$RS/sandbox.sh"
  expect_rc 2; expect_err_has "MROOM_SANDBOX_PATH"
  run env MROOM_SANDBOX_PATH="$T/nowhere" "$RS/sandbox.sh"
  expect_rc 2; expect_err_has "no such folder"
  run env MROOM_SANDBOX_ENV=$'QA_DB=qa_1\nGH_TOKEN=ghp_x' "$RS/sandbox.sh"
  expect_rc 2; expect_err_has "GH_TOKEN reads like a credential"; expect_err_lacks ghp_x
}

t_setup_needs_root_through_sudo() {
  [ "$(id -u)" != 0 ] || { ok; return; }
  mkdir -p "$T/app/harness"
  echo 'echo hi' >"$T/app/wrapper.sh"
  cd "$T/app"
  # Good inputs get as far as the root check, and nothing is written.
  run env MROOM_SANDBOX_SECRET=s MROOM_SANDBOX_HOLDER=wrapper.sh MROOM_SANDBOX_COPY=$'harness/\n' \
    MROOM_SANDBOX_PATH=/usr/bin MROOM_SANDBOX_ENV='QA_DB=qa_1' \
    MROOM_SANDBOX_KNOWN_HOSTS='qa.example.test ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJAL4XYtQyl1WalugDy7r5RDPoMgJhIDreu8WeEGPU/k' \
    "$RS/sandbox.sh"
  expect_rc 1; expect_err_has "run as root"
}

# --- step.sh (mroom-step) ---

# argv_sudo: a fake sudo that writes each argument on a line of $T/argv, then runs what follows `env -i …` as is.
argv_sudo() {
  fake_bin sudo 'printf "%s\n" "$@" >"'"$T"'/argv"; pwd >"'"$T"'/cwd"'
}

t_step_runs_as_the_step_user_with_a_clean_environment() {
  world
  argv_sudo
  printf 'QA_DB=qa_12\nAPP_URL=https://12.qa.example.test\n' >"$T/etc/env"
  printf '/opt/node/bin\nbad:entry\n' >"$T/etc/path"
  echo 'recipe' >"$T/recipe.mjs"
  run env GH_TOKEN=ghp_secret "$RS/step.sh" --input "$T/recipe.mjs" -- node drive.mjs 'a b'
  expect_rc 0
  local argv
  argv="$(cat "$T/argv")"
  expect_true "sudo -n -u mroom-step -- env -i" [ "$(head -n 6 "$T/argv" | tr '\n' ' ')" = "-n -u mroom-step -- env -i " ]
  expect_true "PATH from the sandbox's folders" grep -qx 'PATH=/opt/node/bin:/usr/local/bin:/usr/bin:/bin' "$T/argv"
  expect_true "the step's variables" grep -qx 'QA_DB=qa_12' "$T/argv"
  expect_true "the sandbox's own" grep -qx "MROOM_INPUTS=$T/var/inputs" "$T/argv"
  expect_true "MROOM_EVIDENCE" grep -qx "MROOM_EVIDENCE=$T/var/evidence" "$T/argv"
  expect_true "the command last, its arguments kept" [ "$(tail -n 3 "$T/argv" | tr '\n' '|')" = "node|drive.mjs|a b|" ]
  case "$argv" in *ghp_secret*) fail "the runner's token reached the step's command line" ;; *) ok ;; esac
  expect_true "the input copied" cmp -s "$T/recipe.mjs" "$T/var/inputs/recipe.mjs"
  expect_true "runs from the sandbox's folder" [ "$(cat "$T/cwd")" = "$(cd "$T/var" && pwd)" ]
}

t_step_refuses_bad_calls() {
  world
  argv_sudo
  echo x >"$T/bad name.mjs"
  echo x >"$T/.hidden"
  run "$RS/step.sh" node; expect_rc 2; expect_err_has usage
  run "$RS/step.sh" --; expect_rc 2; expect_err_has usage
  run "$RS/step.sh" --input "$T/missing" -- true; expect_rc 2; expect_err_has "--input takes a file"
  run "$RS/step.sh" --input "$T/bad name.mjs" -- true; expect_rc 2; expect_err_has "an input's name"
  run "$RS/step.sh" --input "$T/.hidden" -- true; expect_rc 2; expect_err_has "an input's name"
  run "$RS/step.sh" -- GH_TOKEN=x true; expect_rc 2; expect_err_has "has an '='"
  printf 'GH_TOKEN=planted\n' >"$T/etc/env"
  run "$RS/step.sh" -- true; expect_rc 2; expect_err_has "a bad line"; expect_err_lacks planted
  expect_no_file "$T/argv"
  rm "$T/etc/env"
  run "$RS/step.sh" -- true; expect_rc 2; expect_err_has "not set up"
}

t_step_passes_the_commands_status() {
  world
  fake_bin sudo 'exit 7'
  run "$RS/step.sh" -- true
  expect_rc 7
}

# --- probe.sh, as the test's own user: it reaches what that user can, and says so ---

probe() { run bash "$RS/probe.sh" "$@"; }
has_line() { grep -qx -- "$1" <<<"$out"; }
has_prefix() { grep -q -- "^$1" <<<"$out"; }

t_probe_reports_what_it_reaches() {
  fake_bin sudo 'exit 0'
  mkdir -p "$T/home" "$T/holder" "$T/open" "$T/evidence"
  echo planted-v4lue >"$T/home/planted"
  echo key >"$T/holder/secret"
  echo pinned >"$T/known_hosts"
  probe --value planted-v4lue --secret "$T/holder/secret" --holder-dir "$T/holder" --runner-file "$T/home/planted" \
    --runner-home "$T/home" --pid $$ --write "$T/open" --write "$T/known_hosts"
  expect_rc 0
  expect_true "env-names" has_prefix 'reached env-names: '
  expect_true "secret" has_prefix 'reached secret: '
  expect_true "holder-dir" has_prefix 'reached holder-dir: '
  expect_true "runner-file" has_prefix 'reached runner-file: '
  expect_true "runner-home" has_prefix 'reached runner-home: '
  expect_true "sudo-root" has_prefix 'reached sudo-root: '
  expect_true "sudo-holder" has_prefix 'reached sudo-holder: '
  expect_true "write to a folder" has_prefix "reached write:$T/open: "
  expect_true "write to a file" has_prefix "reached write:$T/known_hosts: "
  expect_true "evidence unset" has_prefix 'broken evidence: '
  expect_true "the write probe left nothing behind" [ -z "$(ls -A "$T/open")" ]
  expect_true "known_hosts unchanged" [ "$(cat "$T/known_hosts")" = pinned ]
  case "$out" in *planted-v4lue* | *key*pinned*) fail "the probe printed a value it read" ;; *) ok ;; esac
  # The planted value in its environment.
  run env MROOM_PROBE=planted-v4lue bash "$RS/probe.sh" --value planted-v4lue
  expect_true "env-value" has_prefix 'reached env-value: '
  case "$out" in *planted-v4lue*) fail "the probe printed the planted value" ;; *) ok ;; esac
}

t_probe_reports_denied_when_it_cannot() {
  [ "$(id -u)" != 0 ] || { ok; return; }
  fake_bin sudo 'echo "sudo: a password is required" >&2; exit 1'
  mkdir -p "$T/home" "$T/holder" "$T/ro" "$T/evidence"
  echo planted >"$T/home/planted"
  echo key >"$T/holder/secret"
  chmod 000 "$T/holder/secret" "$T/home/planted" "$T/holder" "$T/home"
  chmod 555 "$T/ro"
  run env -i PATH="$T/bin:/usr/bin:/bin" MROOM_EVIDENCE="$T/evidence" bash "$RS/probe.sh" --value planted \
    --secret "$T/holder/secret" --holder-dir "$T/holder" --runner-file "$T/home/planted" --runner-home "$T/home" \
    --pid 999999999 --write "$T/ro" --write "$T/nowhere"
  chmod 700 "$T/holder" "$T/home"
  expect_rc 0
  local check
  for check in env-names env-value secret holder-dir runner-file runner-home runner-environ sudo-root sudo-holder \
    "write:$T/ro" "write:$T/nowhere"; do
    expect_true "denied $check" has_line "denied $check"
  done
  expect_true "ok evidence" has_line 'ok evidence'
  expect_true "the evidence probe left nothing behind" [ -z "$(ls -A "$T/evidence")" ]
}

t_probe_tries_sockets() {
  command -v python3 >/dev/null || { ok; return; }
  python3 -c 'import socket, sys; s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$T/open.sock"
  python3 -c 'import socket, sys; s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$T/closed.sock"
  chmod 666 "$T/open.sock"
  chmod 444 "$T/closed.sock"
  probe --socket "$T/open.sock" --socket "$T/closed.sock" --socket "$T/missing.sock"
  expect_true "an open socket" has_prefix "reached socket:$T/open.sock: "
  if [ "$(id -u)" != 0 ]; then expect_true "a closed socket" has_line "denied socket:$T/closed.sock"; fi
  expect_true "a missing socket" has_line "denied socket:$T/missing.sock"
}

t_probe_refuses_a_bad_call() {
  probe --nope x; expect_rc 2
  probe --value; expect_rc 2
}

# --- check.sh: its verdict, and a broken sandbox failing it loudly ---

ALL=(env-names env-value secret holder-dir runner-file runner-home runner-environ sudo-root sudo-holder evidence)

verdict() {
  printf '%s\n' "$1" >"$T/report"
  shift
  run bash -c '. "$1"; shift; sandbox_verdict "$@"' _ "$RS/check.sh" "$T/report" v4lue "$@"
}

all_denied() {
  local c
  for c in "${ALL[@]}"; do
    if [ "$c" = evidence ]; then echo "ok evidence"; else echo "denied $c"; fi
  done
}

t_the_verdict_passes_only_a_report_where_all_is_denied() {
  verdict "$(all_denied; echo 'denied write:/opt/x')" "${ALL[@]}" write:/opt/x
  expect_rc 0; expect_out ""
  verdict "$(all_denied | sed 's/^denied runner-file$/reached runner-file: read \/home\/runner\/p/')" "${ALL[@]}"
  expect_rc 1; expect_out_has "::error::runner-sandbox: the sandbox does not hold: untrusted code read /home/runner/p (runner-file)"
  verdict "$(all_denied | grep -v '^denied sudo-root$')" "${ALL[@]}"
  expect_rc 1; expect_out_has "reported nothing for sudo-root"
  verdict "$(all_denied | sed 's/^ok evidence$/broken evidence: cannot write/')" "${ALL[@]}"
  expect_rc 1; expect_out_has "the sandbox is broken: evidence"
  verdict "$(all_denied; echo 'leaked v4lue')" "${ALL[@]}"
  expect_rc 1; expect_out_has "the planted value reached"; expect_out_has "an unknown probe line"
  verdict "$(all_denied; echo 'bash: probe.sh: Permission denied')" "${ALL[@]}"
  expect_rc 1; expect_out_has "an unknown probe line"
  verdict "" "${ALL[@]}"
  expect_rc 1; expect_out_has "reported nothing for env-names"
}

t_a_broken_sandbox_fails_the_check_loudly() {
  world
  # A "sandbox" that runs the step as the runner's own user, environment and all.
  fake_bin fake-step 'shift; exec "$@"'
  fake_bin sudo 'exit 1'
  run env MROOM_SANDBOX_STEP="$T/bin/fake-step" bash "$RS/check.sh"
  expect_rc 1
  expect_out_has "::error::runner-sandbox: the sandbox does not hold"
  expect_out_has "(env-names)"
  expect_out_has "(runner-file)"
  expect_out_has "(runner-home)"
  expect_out_has "(write:$HOME)"
  expect_err_has "no untrusted code may run on this runner"
  expect_no_file "$HOME/.mroom-sandbox-probe"
}

t_a_step_that_cannot_run_fails_the_check() {
  world
  fake_bin fake-step 'echo "sudo: a password is required" >&2; exit 1'
  run env MROOM_SANDBOX_STEP="$T/bin/fake-step" bash "$RS/check.sh"
  expect_rc 1
  expect_out_has "the probe did not run through mroom-step (exit 1): sudo: a password is required"
  run bash "$RS/check.sh" --what
  expect_rc 2
}

# --- bwrap-probe.sh, against a fake bwrap ---

# fake_bwrap: --unshare-all exits $ALL_RC; the Claude Code call prints $INSIDE_OUT and exits $INSIDE_RC.
fake_bwrap() {
  fake_bin bwrap 'case " $* " in
  *" --unshare-all "*) [ "${ALL_RC:-0}" = 0 ] || echo "bwrap: setting up uid map: Permission denied" >&2; exit "${ALL_RC:-0}" ;;
  *" --unshare-user "*) [ -z "${INSIDE_OUT:-}" ] || echo "$INSIDE_OUT" >&2; exit "${INSIDE_RC:-0}" ;;
esac
exit 99'
  fake_bin hop 'exit "${HOP_RC:-0}"'
}

t_bwrap_probe_reads_the_hop_inside_bwrap() {
  fake_bwrap
  run env ALL_RC=1 bash "$RS/bwrap-probe.sh" check hop
  expect_rc 1; expect_out_has "fail bwrap --unshare-all"
  run env HOP_RC=1 bash "$RS/bwrap-probe.sh" check hop
  expect_rc 0; expect_out_has "::warning::bwrap-probe: inconclusive: the sudo hop fails outside bwrap too"
  run env INSIDE_RC=1 INSIDE_OUT='sudo: The "no new privileges" flag is set, which prevents sudo from running as root.' \
    bash "$RS/bwrap-probe.sh" check hop
  expect_rc 0; expect_out_has "is refused by sudo"; expect_out_has "so the scrub stays off"
  run env INSIDE_RC=1 INSIDE_OUT='sudo-rs: cannot change user: no new privileges' bash "$RS/bwrap-probe.sh" check hop
  expect_rc 0; expect_out_has "is refused by sudo"
  run env INSIDE_RC=0 bash "$RS/bwrap-probe.sh" check hop
  expect_rc 0; expect_out_has "::warning::bwrap-probe: the sudo hop works inside bwrap"
  run env INSIDE_RC=1 INSIDE_OUT='bwrap: execvp hop: No such file' bash "$RS/bwrap-probe.sh" check hop
  expect_rc 0; expect_out_has "inconclusive: bwrap did not get as far as sudo"
  run bash "$RS/bwrap-probe.sh" check; expect_rc 2
  run bash "$RS/bwrap-probe.sh" nope; expect_rc 2
}

# --- the action ---

has_yaml() { python3 -c 'import yaml' >/dev/null 2>&1; }

t_the_action_takes_no_secret_as_an_input_and_runs_the_script() {
  local yml="$ROOT/actions/runner-sandbox/action.yml"
  run python3 - "$yml" <<'EOF'
import sys, yaml
a = yaml.safe_load(open(sys.argv[1]))
inputs = a["inputs"]
assert not any("secret" in k or "key" == k for k in inputs), inputs
assert inputs["check"]["default"] == "true"
steps = a["runs"]["steps"]
assert "lib/runner-sandbox/sandbox.sh" in steps[0]["run"] and steps[0]["run"].startswith("sudo -E ")
assert "MROOM_SANDBOX_SECRET" not in steps[0].get("env", {})
assert steps[1]["if"] == "inputs.check == 'true'" and "check.sh" in steps[1]["run"]
EOF
  expect_rc 0
  expect_file "$ROOT/lib/runner-sandbox/sandbox.sh"
}

test_case step-env t_step_env_takes_plain_names_and_refuses_credentials
test_case setup-inputs t_setup_refuses_bad_inputs_before_changing_anything
test_case setup-root t_setup_needs_root_through_sudo
test_case step t_step_runs_as_the_step_user_with_a_clean_environment
test_case step-bad t_step_refuses_bad_calls
test_case step-status t_step_passes_the_commands_status
test_case probe-reaches t_probe_reports_what_it_reaches
test_case probe-denied t_probe_reports_denied_when_it_cannot
test_case probe-sockets t_probe_tries_sockets
test_case probe-bad t_probe_refuses_a_bad_call
test_case verdict t_the_verdict_passes_only_a_report_where_all_is_denied
test_case broken t_a_broken_sandbox_fails_the_check_loudly
test_case step-fails t_a_step_that_cannot_run_fails_the_check
test_case bwrap t_bwrap_probe_reads_the_hop_inside_bwrap
skip_unless has_yaml "python3 has no yaml module (PyYAML)"
test_case action t_the_action_takes_no_secret_as_an_input_and_runs_the_script
finish
