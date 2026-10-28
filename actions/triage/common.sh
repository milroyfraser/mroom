# shellcheck shell=bash
# shellcheck disable=SC2034  # MROOM and WORK are read by the scripts that source this file
# common.sh — what triage.sh, alarm.sh and switch-off.sh share (actions/triage): mroom's root, the tokens
# under the names mroom.toml gives them, the run's folder and its outputs. Sourced, never run on its own.
#
# The action hands the tokens over as MROOM_TRIAGE_TRACKER_TOKEN and MROOM_TRIAGE_ERRORS_TOKEN; the adapters
# read them from the variables issues.token_env and errors.token_env name (LINEAR_API_KEY and
# SENTRY_AUTH_TOKEN by default), so they are moved there, and the hand-over names are cleared.

SELF="$(readlink -f "${BASH_SOURCE[1]}" 2>/dev/null || echo "${BASH_SOURCE[1]}")"
MROOM_ROOT="$(cd "$(dirname "$SELF")/../.." && pwd)"
export MROOM_ROOT
MROOM="$MROOM_ROOT/bin/mroom"
# shellcheck source=lib/core/persona.sh
. "$MROOM_ROOT/lib/core/persona.sh"

triage_say() { echo "${TRIAGE_NAME:-mroom triage}: $*" >&2; }

# triage_tokens: each token under the variable its adapter reads.
triage_tokens() {
  local -
  set +x
  local name
  if [ -n "${MROOM_TRIAGE_TRACKER_TOKEN:-}" ]; then
    name="$(persona_config issues.token_env LINEAR_API_KEY)" || return 1
    printf -v "$name" '%s' "$MROOM_TRIAGE_TRACKER_TOKEN"
    export "${name?}"
  fi
  if [ -n "${MROOM_TRIAGE_ERRORS_TOKEN:-}" ]; then
    name="$(persona_config errors.token_env SENTRY_AUTH_TOKEN)" || return 1
    printf -v "$name" '%s' "$MROOM_TRIAGE_ERRORS_TOKEN"
    export "${name?}"
  fi
  unset MROOM_TRIAGE_TRACKER_TOKEN MROOM_TRIAGE_ERRORS_TOKEN
}

# The run's folder: the guard's state (counts, markers-lost, actions.jsonl) and triage's own files.
MROOM_PERSONA_STATE="${MROOM_PERSONA_STATE:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/mroom-persona}"
export MROOM_PERSONA_STATE
mkdir -p "$MROOM_PERSONA_STATE"
WORK="$MROOM_PERSONA_STATE"

# output <name=value>: a step output, on a runner.
output() { [ -z "${GITHUB_OUTPUT:-}" ] || printf '%s\n' "$1" >>"$GITHUB_OUTPUT"; }

# summary <file>: the file, redacted, on the run's summary page (it quotes alert text).
summary() {
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || { persona_text redact <"$1" >&2; return 0; }
  persona_text redact <"$1" >>"$GITHUB_STEP_SUMMARY" || echo "_(the summary could not be redacted, so it is not shown)_" >>"$GITHUB_STEP_SUMMARY"
}

# run_link: the run's link, when it is a GitHub run's.
run_link() {
  local run="${MROOM_PERSONA_RUN_URL:-}"
  [[ "$run" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/actions/runs/[0-9]+(/attempts/[0-9]+)?$ ]] && printf '%s' "$run"
  return 0
}
