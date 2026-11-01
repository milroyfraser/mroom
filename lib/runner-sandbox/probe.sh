#!/usr/bin/env bash
# probe.sh — a hostile stand-in for untrusted code in the runner sandbox (design 8.5). check.sh runs it through
# mroom-step, as the code a job runs would be; it tries what such code would try, and reports what it reached:
#
#   probe.sh --value <planted> --secret <file> --holder-dir <dir> --runner-file <file> --runner-home <dir> --pid <pid>
#            [--read <path>]... [--write <path>]... [--socket <path>]... [--scan <folder>]...
#
# --read: a file the step must not read, or a folder it must not list. --scan: where to look for anything the step
# may write (default: every local disk); it may write only its home, its evidence and the sticky folders (/tmp's
# kind), and anything else it can write counts as reached, since the runner or root may run it next.
#
# One line per check, `denied <check>`, `ok <check>` (something the step must be able to do, and can) or
# `reached <check>: <what>` / `broken <check>: <what>`. It names what it saw, never prints a value it read, and
# exits 0 whatever it found: check.sh decides. A check line missing from its report counts as reached there.
set -uo pipefail

value="" secret="" holder_dir="" runner_file="" runner_home="" pid="" reads=() writes=() sockets=() scans=()
while [ "$#" -ge 2 ]; do
  case "$1" in
    --value) value="$2" ;;
    --secret) secret="$2" ;;
    --holder-dir) holder_dir="$2" ;;
    --runner-file) runner_file="$2" ;;
    --runner-home) runner_home="$2" ;;
    --pid) pid="$2" ;;
    --read) reads+=("$2") ;;
    --write) writes+=("$2") ;;
    --scan) scans+=("$2") ;;
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

for path in ${reads[@]+"${reads[@]}"}; do
  if [ -d "$path" ]; then listable "read:$path" "$path"; else readable "read:$path" "$path"; fi
done

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

# Anything on the disks the step may write: a tool the runner runs next (node, git), a library it loads, a script
# root runs (debconf's Perl, under apt).
if [ "${#scans[@]}" = 0 ]; then
  while IFS= read -r disk; do scans+=("$disk"); done < <(findmnt -rn -o TARGET -t ext2,ext3,ext4,xfs,btrfs,f2fs,vfat 2>/dev/null)
  [ "${#scans[@]}" -gt 0 ] || scans=(/)
fi
found="$(for dir in "${scans[@]}"; do
  find "$dir" -xdev \( -path /proc -o -path /sys -o -path /dev -o -path /run -o -path /tmp -o -path /var/tmp \
    -o -path "${HOME:-/nonexistent}" -o -path "${MROOM_EVIDENCE:-/nonexistent}" \) -prune \
    -o -writable ! -type l ! \( -type d -perm -1000 \) -print 2>/dev/null
done)"
if [ -n "$found" ]; then
  report reached writable "may write $(wc -l <<<"$found" | tr -d ' ') paths, such as $(head -n 3 <<<"$found" | tr '\n' ' ')"
else report denied writable; fi

# What the step must be able to do: write its evidence.
if [ -n "${MROOM_EVIDENCE:-}" ] && probe_file="$(mktemp "$MROOM_EVIDENCE/.mroom-probe.XXXXXX" 2>/dev/null)"; then
  rm -f "$probe_file"
  report ok evidence
else report broken evidence "cannot write MROOM_EVIDENCE (${MROOM_EVIDENCE:-unset})"; fi
exit 0
