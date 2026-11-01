#!/usr/bin/env bash
# check.sh — shows the runner sandbox holds (design 8.5) before untrusted code runs in it, and fails loudly when it
# does not. Run as the runner's user, after sandbox.sh (the runner-sandbox action runs it unless check: false):
#
#   lib/runner-sandbox/check.sh [--socket <path>]...
#
# It plants what untrusted code would go for: a value in its own environment and in a long-lived process's, and a
# file in the runner's home holding it. Then it runs probe.sh through mroom-step, as the job's code would run, and
# reads the report: every check must be denied (or ok, for the evidence the step writes), every check must be there,
# and the planted value must appear nowhere. Writes it tries: the copies, the inputs, the sandbox's /etc, the pinned
# host keys, the sandbox's scripts, every folder on the runner's PATH, the runner's home and the workspace, and then
# anything at all on the local disks but the step's home, its evidence and the sticky folders. Reads it tries, beside
# the planted file: git's config in the workspace and RUNNER_TEMP. MROOM_SANDBOX_SCAN narrows the disk scan, for tests. Sockets: Docker's and containerd's when present,
# and each --socket. MROOM_SANDBOX_STEP names another mroom-step, for the tests.
# Exits 0 when the sandbox holds, 1 when it does not (each failure an ::error:: line), 2 for a bad call.
set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
HERE="$(dirname "$SELF")"
# shellcheck source=lib/runner-sandbox/common.sh
. "$HERE/common.sh"

# sandbox_verdict <report file> <planted value> <check>...: whether the probe's report shows the sandbox holding:
# each named check present and denied or ok, nothing reached or broken, nothing unknown, and the value nowhere.
# Prints one ::error:: line per problem.
sandbox_verdict() {
  local report="$1" value="$2" bad=0 want line result name seen=" "
  shift 2
  if [ -n "$value" ] && grep -qF -- "$value" "$report"; then
    echo "::error::runner-sandbox: the planted value reached the step's report"
    bad=1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    result="${line%% *}" name="${line#* }"
    name="${name%%: *}"
    seen+="$name "
    case "$result" in
      denied | ok) ;;
      reached) echo "::error::runner-sandbox: the sandbox does not hold: untrusted code ${line#*: } ($name)"; bad=1 ;;
      broken) echo "::error::runner-sandbox: the sandbox is broken: $name: ${line#*: }"; bad=1 ;;
      *) echo "::error::runner-sandbox: an unknown probe line: ${line:0:120}"; bad=1 ;;
    esac
  done <"$report"
  for want in "$@"; do
    case "$seen" in
      *" $want "*) ;;
      *) echo "::error::runner-sandbox: the probe reported nothing for $want, so the sandbox is not shown to hold"; bad=1 ;;
    esac
  done
  return "$bad"
}

main() {
  local sockets=() step="${MROOM_SANDBOX_STEP:-$SANDBOX_STEP_BIN}" s
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --socket) [ "$#" -ge 2 ] || { echo "check: --socket takes a path" >&2; exit 2; }; sockets+=("$2"); shift 2 ;;
      *) echo "usage: check.sh [--socket <path>]..." >&2; exit 2 ;;
    esac
  done
  for s in /var/run/docker.sock /run/docker.sock /run/containerd/containerd.sock; do
    if [ -S "$s" ]; then sockets+=("$s"); fi
  done

  local value planted holder report rc=0 args=() w
  value="mroom-probe-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
  planted="$HOME/.mroom-sandbox-probe"
  report="$(mktemp)"
  printf '%s\n' "$value" >"$planted"
  chmod 0644 "$planted"
  # A runner process holding the value in its environment, as the runner's own processes hold the job's tokens.
  MROOM_PROBE_TOKEN="$value" sleep 300 &
  holder=$!
  # shellcheck disable=SC2064  # the paths and pid are fixed now
  trap "kill $holder 2>/dev/null; rm -f '$planted' '$report'" EXIT

  args=(--value "$value" --secret "$SANDBOX_ETC/holder/secret" --holder-dir "$SANDBOX_ETC/holder"
    --runner-file "$planted" --runner-home "$HOME" --pid "$holder")
  local runner_path seen=" "
  IFS=: read -ra runner_path <<<"$PATH"
  for w in "$SANDBOX_OPT" "$SANDBOX_VAR/inputs" "$SANDBOX_ETC" "$SANDBOX_ETC/known_hosts" "$SANDBOX_LIB" /usr/local/bin \
    "$HOME" ${GITHUB_WORKSPACE:+"$GITHUB_WORKSPACE"} "${runner_path[@]}"; do
    # The runner's PATH: each existing folder once, by the name it was given.
    [[ "$w" == /* && "$w" != *[[:space:]]* ]] || continue
    case "$seen" in *" $w "*) continue ;; esac
    seen+="$w "
    args+=(--write "$w")
  done
  for s in ${sockets[@]+"${sockets[@]}"}; do args+=(--socket "$s"); done
  # git's credentials (actions/checkout's persisted token) and the runner's temp files, where actions keep theirs.
  if [ -n "${GITHUB_WORKSPACE:-}" ]; then args+=(--read "$GITHUB_WORKSPACE/.git/config"); fi
  if [ -n "${RUNNER_TEMP:-}" ]; then args+=(--read "$RUNNER_TEMP"); fi
  # Where to look for anything the step may write: every local disk, but for the tests.
  if [ -n "${MROOM_SANDBOX_SCAN:-}" ]; then args+=(--scan "$MROOM_SANDBOX_SCAN"); fi

  MROOM_PROBE_TOKEN="$value" "$step" -- /bin/bash "$HERE/probe.sh" "${args[@]}" >"$report" 2>&1 || rc=$?
  if [ "$rc" != 0 ]; then
    echo "::error::runner-sandbox: the probe did not run through mroom-step (exit $rc): $(grep -m1 . "$report" | cut -c1-160)"
    exit 1
  fi

  local wants=(env-names env-value secret holder-dir runner-file runner-home runner-environ sudo-root sudo-holder writable
    evidence)
  for ((i = 0; i < ${#args[@]}; i++)); do
    case "${args[i]}" in
      --write) wants+=("write:${args[i + 1]}") ;;
      --socket) wants+=("socket:${args[i + 1]}") ;;
      --read) wants+=("read:${args[i + 1]}") ;;
    esac
  done
  if ! sandbox_verdict "$report" "$value" "${wants[@]}"; then
    echo "runner-sandbox: the sandbox does not hold; no untrusted code may run on this runner" >&2
    exit 1
  fi
  echo "runner-sandbox: the sandbox holds (${#wants[@]} checks denied untrusted code what it must not reach)" >&2
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
