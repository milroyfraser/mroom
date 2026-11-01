# shellcheck shell=bash
# common.sh — the names and rules the runner sandbox's scripts share (design 8.5). Sourced by sandbox.sh, step.sh,
# check.sh and probe.sh, never run on its own.
#
# The sandbox has two users of its own beside the runner's:
#   mroom-step     untrusted code runs as it: a clean environment, no sudo but the holder's wrapper, and no way
#                  into the runner's home, so no way to the workspace, its git credentials or a runner process.
#   mroom-holder   the only user that can read the secret the job hands the sandbox, which it uses through one
#                  root-owned wrapper.
# MROOM_SANDBOX_ETC and MROOM_SANDBOX_VAR move its folders, for the tests; the sudoers rules name the installed paths.
# shellcheck disable=SC2034  # read by the scripts that source this file

SANDBOX_STEP_USER=mroom-step
SANDBOX_HOLDER_USER=mroom-holder
SANDBOX_ETC="${MROOM_SANDBOX_ETC:-/etc/mroom-sandbox}"
SANDBOX_VAR="${MROOM_SANDBOX_VAR:-/var/lib/mroom-sandbox}"
SANDBOX_OPT=/opt/mroom-sandbox
# The scripts and the holder's wrapper live under /usr/lib, which the distribution keeps root's: on GitHub's images
# /usr/local/bin is writable by every user, and a step could swap a file there for its own.
SANDBOX_LIB=/usr/lib/mroom-sandbox
SANDBOX_STEP_BIN=/usr/local/bin/mroom-step
SANDBOX_HOLDER_BIN=$SANDBOX_LIB/holder
SANDBOX_SUDOERS=/etc/sudoers.d/mroom-sandbox

# A variable name that reads like a credential. step-env refuses such a name, and the probe counts one in the
# step's environment as a leak, with the runner's own families beside it.
SANDBOX_SECRET_NAME='(^|_)(TOKEN|SECRET|KEY|PASSWORD|PASSWD|PASS|CREDENTIALS?|AUTH|COOKIE|SESSION|PAT|DSN)(_|$)'
SANDBOX_RUNNER_NAME='^(GITHUB_|ACTIONS_|RUNNER_|INPUT_|GH_|ANTHROPIC|CLAUDE|OPENAI|AWS_|AZURE_|GOOGLE_|SSH_AUTH_SOCK$|SUDO_)'

# sandbox_env_line <line>: whether one line of step-env is NAME=value with a plain upper-case name that is neither a
# credential's nor one the sandbox sets itself, and a value of printable characters. Prints why when it is not.
sandbox_env_line() {
  local name="${1%%=*}" value="${1#*=}"
  [[ "$1" == *=* && "$name" =~ ^[A-Z][A-Z0-9_]{0,63}$ ]] || { echo "not NAME=value: ${name:0:40}"; return 1; }
  if [[ "$name" =~ $SANDBOX_SECRET_NAME || "$name" =~ $SANDBOX_RUNNER_NAME ]]; then
    echo "$name reads like a credential or a runner variable; the step gets no secret"
    return 1
  fi
  case "$name" in
    PATH | HOME | LANG | MROOM_SANDBOX | MROOM_INPUTS | MROOM_EVIDENCE | MROOM_HOLDER)
      echo "$name is set by the sandbox"
      return 1
      ;;
  esac
  [[ "$value" != *[[:cntrl:]]* ]] || { echo "$name has a control character in its value"; return 1; }
}
