#!/usr/bin/env bash
# probe.sh — a hostile stand-in for untrusted code in the runner sandbox (design 8.5). check.sh runs it through
# mroom-step, as the code a job runs would be; it tries what such code would try, and reports what it reached:
#
#   probe.sh --value <planted> --secret <file> --holder-dir <dir> --runner-file <file> --runner-home <dir> --pid <pid>
#            [--write <path>]... [--socket <path>]...
#
# One line per check, `denied <check>`, `ok <check>` (something the step must be able to do, and can) or
# `reached <check>: <what>` / `broken <check>: <what>`. It names what it saw, never prints a value it read, and
# exits 0 whatever it found: check.sh decides. A check line missing from its report counts as reached there.
set -uo pipefail

value="" secret="" holder_dir="" runner_file="" runner_home="" pid="" writes=() sockets=()
while [ "$#" -ge 2 ]; do
  case "$1" in
    --value) value="$2" ;;
    --secret) secret="$2" ;;
    --holder-dir) holder_dir="$2" ;;
    --runner-file) runner_file="$2" ;;
    --runner-home) runner_home="$2" ;;
    --pid) pid="$2" ;;
    --write) writes+=("$2") ;;
    --socket) sockets+=("$2") ;;
    *) echo "probe: unknown option $1" >&2; exit 2 ;;
  esac
  shift 2
done
[ "$#" = 0 ] || { echo "probe: $1 takes a value" >&2; exit 2; }

# The same name rules as common.sh, copied so the probe needs nothing from the trusted side to run.
secret_name='(^|_)(TOKEN|SECRET|KEY|PASSWORD|PASSWD|PASS|CREDENTIALS?|AUTH|COOKIE|SESSION|PAT|DSN)(_|$)'
runner_name='^(GITHUB_|ACTIONS_|RUNNER_|INPUT_|GH_|ANTHROPIC|CLAUDE|OPENAI|AWS_|AZURE_|GOOGLE_|SSH_AUTH_SOCK$|SUDO_)'

report() { printf '%s %s%s\n' "$1" "$2" "${3:+: $3}"; }

# A credential's or the runner's variable in the step's environment; names only.
leaked=""
while IFS= read -r name; do
  if [[ "$name" =~ $secret_name || "$name" =~ $runner_name ]]; then leaked+="$name "; fi
done < <(compgen -e)
if [ -n "$leaked" ]; then report reached env-names "$leaked"; else report denied env-names; fi

# The value the runner planted, anywhere in the environment.
if [ -n "$value" ] && env | grep -qF -- "$value"; then report reached env-value "the planted value is in the environment"
else report denied env-value; fi

# readable <check> <file>: a file the step must not read.
readable() {
  if [ -n "$2" ] && head -c1 -- "$2" >/dev/null 2>&1; then report reached "$1" "read $2"; else report denied "$1"; fi
}
listable() {
  if [ -n "$2" ] && ls -A -- "$2" >/dev/null 2>&1; then report reached "$1" "listed $2"; else report denied "$1"; fi
}
readable secret "$secret"
listable holder-dir "$holder_dir"
readable runner-file "$runner_file"
listable runner-home "$runner_home"
# A runner process's environment holds what the job's steps hold (tokens included).
readable runner-environ "${pid:+/proc/$pid/environ}"

# No root, and the holder only through its wrapper.
if sudo -n true >/dev/null 2>&1; then report reached sudo-root "sudo -n true"; else report denied sudo-root; fi
if [ -n "$secret" ] && sudo -n -u mroom-holder cat -- "$secret" >/dev/null 2>&1; then
  report reached sudo-holder "cat as mroom-holder"
elif sudo -n -u mroom-holder sh -c true >/dev/null 2>&1; then report reached sudo-holder "a shell as mroom-holder"
else report denied sudo-holder; fi

# Writes outside what the step owns: a new file in a folder, or opening a file to append (which changes nothing).
for path in ${writes[@]+"${writes[@]}"}; do
  if [ -d "$path" ]; then
    if probe_file="$(mktemp "$path/.mroom-probe.XXXXXX" 2>/dev/null)"; then
      rm -f "$probe_file"
      report reached "write:$path" "made a file in it"
    else report denied "write:$path"; fi
  elif [ -e "$path" ] && (: >>"$path") 2>/dev/null; then report reached "write:$path" "opened it to write"
  else report denied "write:$path"; fi
done

# A socket another user's service listens on (Docker's gives root): connecting needs write access to it.
for path in ${sockets[@]+"${sockets[@]}"}; do
  if [ -S "$path" ] && [ -w "$path" ]; then report reached "socket:$path" "may connect"; else report denied "socket:$path"; fi
done

# What the step must be able to do: write its evidence.
if [ -n "${MROOM_EVIDENCE:-}" ] && probe_file="$(mktemp "$MROOM_EVIDENCE/.mroom-probe.XXXXXX" 2>/dev/null)"; then
  rm -f "$probe_file"
  report ok evidence
else report broken evidence "cannot write MROOM_EVIDENCE (${MROOM_EVIDENCE:-unset})"; fi
exit 0
