#!/usr/bin/env bash
# step.sh — runs one untrusted command in the runner sandbox (design 8.5), as mroom-step with a clean environment.
# sandbox.sh installs it as /usr/local/bin/mroom-step; the runner's user runs it:
#
#   mroom-step [--input <file>]... -- <command> [<arg>...]
#
# Each --input file is copied into /var/lib/mroom-sandbox/inputs first, so the step never needs the runner's files.
# The command runs from /var/lib/mroom-sandbox through `sudo -u mroom-step env -i`, with only:
#   PATH            sandbox.sh's MROOM_SANDBOX_PATH folders, then /usr/local/bin:/usr/bin:/bin
#   HOME, LANG      mroom-step's home, C.UTF-8
#   MROOM_SANDBOX=1, MROOM_INPUTS, MROOM_EVIDENCE (the folder the step writes for the runner to read)
#   MROOM_HOLDER    /usr/lib/mroom-sandbox/holder, when the sandbox has a holder: run it with `sudo -n -u mroom-holder`
#   the NAME=value lines of MROOM_SANDBOX_ENV, read as data and never sourced
# It exits with the command's status, or 2 for a bad call.
set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
# shellcheck source=lib/runner-sandbox/common.sh
. "$(dirname "$SELF")/common.sh"

die() { echo "mroom-step: $*" >&2; exit 2; }
usage="usage: mroom-step [--input <file>]... -- <command> [<arg>...]"

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
exec sudo -n -u "$SANDBOX_STEP_USER" -- env -i \
  PATH="$path" HOME="${home:-/home/$SANDBOX_STEP_USER}" LANG=C.UTF-8 MROOM_SANDBOX=1 \
  MROOM_INPUTS="$SANDBOX_VAR/inputs" MROOM_EVIDENCE="$SANDBOX_VAR/evidence" ${vars[@]+"${vars[@]}"} \
  "$@"
