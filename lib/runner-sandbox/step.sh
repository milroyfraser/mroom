#!/usr/bin/env bash
# step.sh — runs one untrusted command in the runner sandbox (design 8.5), as mroom-step with a clean environment.
# sandbox.sh installs it as /usr/local/bin/mroom-step; the runner's user runs it:
#
#   mroom-step [--input <file>]... -- <command> [<arg>...]
#   mroom-step --collect <empty folder>
#
# Each --input file is copied into /var/lib/mroom-sandbox/inputs first, so the step never needs the runner's files.
# The command runs from /var/lib/mroom-sandbox through `sudo -u mroom-step env -i`, with only:
#   PATH            sandbox.sh's MROOM_SANDBOX_PATH folders, then /usr/local/bin:/usr/bin:/bin
#   HOME, LANG      mroom-step's home, C.UTF-8
#   MROOM_SANDBOX=1, MROOM_INPUTS, MROOM_EVIDENCE (the folder the step writes for the runner to read)
#   MROOM_HOLDER    /usr/lib/mroom-sandbox/holder, when the sandbox has a holder: run it with `sudo -n -u mroom-holder`
#   the NAME=value lines of MROOM_SANDBOX_ENV, read as data and never sourced
# Every process the step user and the holder have is killed before the command and after it, so nothing the step
# started outlives it to watch the next one; so run one step at a time. In a GitHub job (GITHUB_ACTIONS=true) the
# step's output is wrapped in ::stop-commands::, so it cannot give the runner a workflow command.
#
# --collect copies the evidence into a folder of the runner's: read as mroom-step (`tar -h`, so a link the step left
# gives only what the step itself could read), unpacked by the runner as plain files. Read evidence only this way:
# reading the folder in place, the runner would follow such a link to its own files.
# It exits with the command's status, or 2 for a bad call.
set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
# shellcheck source=lib/runner-sandbox/common.sh
. "$(dirname "$SELF")/common.sh"

die() { echo "mroom-step: $*" >&2; exit 2; }
usage="usage: mroom-step [--input <file>]... -- <command> [<arg>...] | --collect <empty folder>"

# stop_all: kill every process the step user has (pkill spares itself).
# stop_user <user>: kill every process the user has, as that user (`kill -KILL -1` reaches all of them, a child
# forked a moment ago included), again until none is left. stop_all: the step's, and the holder's, so a wrapper the
# step started in the background cannot outlive it either.
stop_user() {
  local round
  for ((round = 1; round <= 50; round++)); do
    sudo -n -u "$1" -- /usr/bin/kill -KILL -1 >/dev/null 2>&1 || true
    pgrep -u "$1" >/dev/null 2>&1 || return 0
    sleep 0.1
  done
  die "$1 still has processes after 50 rounds of kill -KILL -1"
}
stop_all() { stop_user "$SANDBOX_STEP_USER"; stop_user "$SANDBOX_HOLDER_USER"; }

if [ "${1:-}" = --collect ]; then
  [[ "$#" = 2 && -d "$2" && ! -L "$2" && -O "$2" ]] || die "--collect takes an empty folder of yours"
  [ -z "$(ls -A "$2")" ] || die "--collect takes an empty folder: $2"
  [ -d "$SANDBOX_VAR/evidence" ] || die "the runner sandbox is not set up (run the runner-sandbox action first)"
  # Absolute before the cd below: a relative name would then mean a folder in the evidence, which the step owns
  # and could have made a link to the runner's home.
  dest="$(CDPATH='' cd -P -- "$2" && pwd -P)"
  stop_all
  cd "$SANDBOX_VAR/evidence"
  # The step's tar names files the step chose in its warnings: they stay out of the job log, where a line could be a
  # workflow command.
  sudo -n -u "$SANDBOX_STEP_USER" -- /usr/bin/tar -chf - --hard-dereference --ignore-failed-read . 2>/dev/null \
    | tar -xf - -C "$dest" --no-same-owner --no-same-permissions
  exit 0
fi

inputs=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --input)
      [[ "$#" -ge 2 && -f "$2" ]] || die "--input takes a file: ${2:-}"
      [[ "$(basename "$2")" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$ ]] || die "an input's name must be letters, digits, '.', '_' or '-': $(basename "$2")"
      inputs+=("$2")
      shift 2
      ;;
    --) shift; break ;;
    *) die "$usage" ;;
  esac
done
[[ "$#" -ge 1 && -n "$1" ]] || die "$usage"
# env would take a NAME=value command as one more variable.
[[ "$1" != *=* ]] || die "the command has an '=' in its name: $1"
[[ -d "$SANDBOX_VAR/inputs" && -f "$SANDBOX_ETC/env" ]] || die "the runner sandbox is not set up (run the runner-sandbox action first)"

for f in ${inputs[@]+"${inputs[@]}"}; do install -m 0644 "$f" "$SANDBOX_VAR/inputs/$(basename "$f")"; done

path=""
while IFS= read -r line; do
  [[ "$line" == /* && "$line" != *:* ]] && path+="$line:"
done <"$SANDBOX_ETC/path"
path+="/usr/local/bin:/usr/bin:/bin"

vars=()
while IFS= read -r line || [ -n "$line" ]; do
  [ -z "$line" ] && continue
  # sandbox.sh checked these when it wrote them; checked again, since a bad line would reach the step as a variable.
  sandbox_env_line "$line" >/dev/null || die "a bad line in $SANDBOX_ETC/env: ${line%%=*}"
  vars+=("$line")
done <"$SANDBOX_ETC/env"
if [ -x "$SANDBOX_HOLDER_BIN" ]; then vars+=("MROOM_HOLDER=$SANDBOX_HOLDER_BIN"); fi

home="$(getent passwd "$SANDBOX_STEP_USER" 2>/dev/null | cut -d: -f6)" || true
cd "$SANDBOX_VAR"
stop_all
# In a GitHub job the step's output reaches the job log, where a line like ::add-mask:: or ::error:: is a command
# to the runner: between ::stop-commands::<token> and ::<token>:: none is. The step's stderr joins its stdout
# there, so it falls inside the markers too.
token=""
if [ "${GITHUB_ACTIONS:-}" = true ]; then
  token="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  echo "::stop-commands::$token"
fi
rc=0
if [ -n "$token" ]; then
  sudo -n -u "$SANDBOX_STEP_USER" -- /usr/bin/env -i \
    PATH="$path" HOME="${home:-/home/$SANDBOX_STEP_USER}" LANG=C.UTF-8 MROOM_SANDBOX=1 \
    MROOM_INPUTS="$SANDBOX_VAR/inputs" MROOM_EVIDENCE="$SANDBOX_VAR/evidence" ${vars[@]+"${vars[@]}"} \
    "$@" 2>&1 || rc=$?
  # Everything the step left running is gone before commands resume: a background writer could still print one
  # until then. Should the kill itself fail, the marker still comes, and then the failure.
  killed=0
  (stop_all) || killed=$?
  echo
  echo "::$token::"
  [ "$killed" = 0 ] || exit "$killed"
  exit "$rc"
else
  sudo -n -u "$SANDBOX_STEP_USER" -- /usr/bin/env -i \
    PATH="$path" HOME="${home:-/home/$SANDBOX_STEP_USER}" LANG=C.UTF-8 MROOM_SANDBOX=1 \
    MROOM_INPUTS="$SANDBOX_VAR/inputs" MROOM_EVIDENCE="$SANDBOX_VAR/evidence" ${vars[@]+"${vars[@]}"} \
    "$@" || rc=$?
fi
stop_all
exit "$rc"
