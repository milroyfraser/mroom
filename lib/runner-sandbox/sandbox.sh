#!/usr/bin/env bash
# sandbox.sh — sets up the runner sandbox (design 8.5) on a throwaway GitHub runner, so the untrusted code a job runs
# there (a PR's harness, a recipe an agent wrote) reaches no token, key or file it does not need. Run as root, from
# the trusted checkout (the default branch's), before any untrusted code runs:
#
#   sudo -E lib/runner-sandbox/sandbox.sh      (the runner-sandbox action does this)
#
# Environment:
#   MROOM_SANDBOX_SECRET       a secret only the holder may read, such as the gate's SSH key; empty for none
#   MROOM_SANDBOX_HOLDER       the trusted wrapper that uses it, run as the holder (required with a secret)
#   MROOM_SANDBOX_HOLDER_ARGS  none (the default): sudo lets the wrapper run with no arguments at all; any: with any,
#                              for a wrapper that checks each one against its own allowlist (README, "The holder")
#   MROOM_SANDBOX_KNOWN_HOSTS  pinned SSH host key lines for the holder's wrapper; root-owned, so not even the holder
#                              can change which host it trusts
#   MROOM_SANDBOX_COPY         paths below the current folder, one per line, copied root-owned and read-only into
#                              /usr/lib/mroom-sandbox/copies at the same relative path (a harness and the packages it loads)
#   MROOM_SANDBOX_PATH         absolute folders, one per line, put first on the step's PATH (node's, for example)
#   MROOM_SANDBOX_ENV          NAME=value lines the step gets; never a credential (common.sh refuses those names)
#   MROOM_SANDBOX_EPHEMERAL    1 on a self-hosted runner that is thrown away after the job; refused otherwise
#   MROOM_SANDBOX_RUNNER_PATH  the runner's PATH (sudo replaces PATH); /usr/local/bin and /usr/local/sbin always count
#
# What it builds:
#   mroom-step      runs the untrusted code (mroom-step, step.sh): env -i, no sudo but mroom-holder as the holder,
#                   and the runner's home closed (0700), so it reads no workspace, credential or runner process.
#   mroom-holder    the only user that can read the secret ($ETC/holder/secret, 0600), through
#                   /usr/lib/mroom-sandbox/holder, a root-owned copy of MROOM_SANDBOX_HOLDER.
#   the disks       nothing left writable by every user (GitHub's images run chmod -R 777 on /usr/local/bin,
#                   /usr/local/lib/node_modules, /opt and /usr/share), or a step could change a tool (node, git,
#                   debconf's Perl, which apt runs as root) that the runner or root runs next; /tmp, /var/tmp and
#                   other sticky folders stay as they are
#   /usr/lib/mroom-sandbox/copies             the copies, root-owned
#   /var/lib/mroom-sandbox/inputs  written by the runner (mroom-step --input), read-only to the step
#   /var/lib/mroom-sandbox/evidence  written by the step; the runner takes it with `mroom-step --collect`, never
#                   by reading it in place, where a link the step left would lead it to its own files
# The runner may run anything as mroom-step and only the wrapper as mroom-holder; mroom-step only the wrapper.
# sudo resets the environment on each hop. It refuses to run twice: a sandbox is set up once, on a fresh runner.
# Exits 2 for a bad input, 1 when it cannot set up.
set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
HERE="$(dirname "$SELF")"
# shellcheck source=lib/runner-sandbox/common.sh
. "$HERE/common.sh"
LIB="$SANDBOX_LIB"

die() { echo "runner-sandbox: $1" >&2; exit "${2:-2}"; }

secret="${MROOM_SANDBOX_SECRET:-}" holder="${MROOM_SANDBOX_HOLDER:-}" known="${MROOM_SANDBOX_KNOWN_HOSTS:-}"
copies=() paths=() envs=() line="" why=""
holder_args="${MROOM_SANDBOX_HOLDER_ARGS:-none}"
here="$(pwd -P)"

# --- Inputs, all checked before anything changes ---

if [ -n "$secret" ] && [ -z "$holder" ]; then die "MROOM_SANDBOX_SECRET needs MROOM_SANDBOX_HOLDER, the wrapper that uses it"; fi
case "$holder_args" in none | any) ;; *) die "MROOM_SANDBOX_HOLDER_ARGS is none or any: $holder_args" ;; esac
if [ -n "$holder" ]; then
  [[ -f "$holder" && ! -L "$holder" ]] || die "MROOM_SANDBOX_HOLDER is not a regular file: $holder"
  holder="$(readlink -f "$holder")"
fi
if [ -n "$known" ]; then
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    [[ "$line" =~ ^[^[:space:]#]+\ (ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|ssh-rsa)\ [A-Za-z0-9+/=]+$ ]] \
      || die "MROOM_SANDBOX_KNOWN_HOSTS: not a '<host> <key type> <key>' line: ${line:0:60}"
  done <<<"$known"
fi
while IFS= read -r line; do
  line="${line%/}"
  [ -z "$line" ] && continue
  # Untrusted trees may be copied (a PR's harness), so a path must stay inside this folder with no link on the way,
  # or root would copy what the link points at and leave it readable to all.
  case "/$line/" in */../* | */./* | //*) die "MROOM_SANDBOX_COPY: not a plain relative path: $line" ;; esac
  [ -e "$line" ] || die "MROOM_SANDBOX_COPY: no such path: $line"
  [ "$(readlink -f "$line")" = "$here/$line" ] || die "MROOM_SANDBOX_COPY: $line goes through a link"
  copies+=("$line")
done <<<"${MROOM_SANDBOX_COPY:-}"
while IFS= read -r line; do
  [ -z "$line" ] && continue
  [[ "$line" == /* && "$line" != *:* && "$line" != *[[:space:]]* ]] || die "MROOM_SANDBOX_PATH: not an absolute folder: $line"
  [ -d "$line" ] || die "MROOM_SANDBOX_PATH: no such folder: $line"
  paths+=("$line")
done <<<"${MROOM_SANDBOX_PATH:-}"
while IFS= read -r line; do
  [ -z "$line" ] && continue
  why="$(sandbox_env_line "$line")" || die "MROOM_SANDBOX_ENV: $why"
  envs+=("$line")
done <<<"${MROOM_SANDBOX_ENV:-}"

[ "$(id -u)" = 0 ] || die "run as root (sudo -E)" 1
runner="${SUDO_USER:-}"
[[ -n "$runner" && "$runner" != root ]] || die "run through sudo from the runner's user, which SUDO_USER names" 1
if [ "${RUNNER_ENVIRONMENT:-}" = self-hosted ] && [ "${MROOM_SANDBOX_EPHEMERAL:-}" != 1 ]; then
  die "a self-hosted runner keeps the sandbox's users, secret and sudoers after the job; set MROOM_SANDBOX_EPHEMERAL=1 only on one thrown away after it" 1
fi
[ ! -e "$SANDBOX_SUDOERS" ] || die "already set up on this runner ($SANDBOX_SUDOERS exists); a sandbox is set up once" 1
[ ! -e "$LIB" ] || die "$LIB exists already" 1
command -v visudo >/dev/null || die "visudo is missing" 1

# --- Users, and the runner's home closed ---

for user in "$SANDBOX_STEP_USER" "$SANDBOX_HOLDER_USER"; do
  ! id "$user" >/dev/null 2>&1 || die "the user $user exists already; the sandbox makes its own users, on a fresh runner" 1
  # A system user: a uid below the ordinary ones, so no file a person or an earlier user left already has it.
  useradd --system --create-home --shell /usr/sbin/nologin "$user"
done
home="$(getent passwd "$runner" | cut -d: -f6)"
[ -d "$home" ] || die "no home for $runner" 1
# The runner's home holds the workspace (and git's credentials in it), temp files and tool state.
chmod 0700 "$home"

# --- Nothing on the box's disks left writable by the step ---

# world_writable <path>: whether every user may write it. sticky <folder>: whether only an entry's owner may rename it.
world_writable() { [ -n "$(find "$1" -maxdepth 0 -perm -o+w)" ]; }
sticky() { [ -k "$1" ]; }
# existing <path>: the path, or the nearest folder above it that exists, with links resolved.
existing() {
  local p="$1"
  while [ ! -e "$p" ]; do p="$(dirname "$p")"; done
  readlink -f "$p"
}

# Every file and folder on a local disk that every user may write, but sticky folders (/tmp's kind, where a user may
# add entries but not touch others'), links (whose own mode means nothing) and what the kernel or the runtime serves.
mapfile -t disks < <(findmnt -rn -o TARGET -t ext2,ext3,ext4,xfs,btrfs,f2fs,vfat 2>/dev/null || true)
[ "${#disks[@]}" -gt 0 ] || disks=(/)
swept="$(mktemp)"
for disk in "${disks[@]}"; do
  find "$disk" -xdev \( -path /proc -o -path /sys -o -path /dev -o -path /run -o -path /tmp -o -path /var/tmp \
    -o -path "$home" \) -prune -o -perm -o+w ! -type l ! \( -type d -perm -1000 \) -print0 2>/dev/null >>"$swept" || true
done
if [ -s "$swept" ]; then
  # A file that went between find and chmod is no matter; any other failure is.
  if ! xargs -0 -r chmod o-w -- <"$swept" 2>"$swept.err"; then
    if grep -v 'No such file or directory' "$swept.err" | grep -q .; then
      die "could not close every path: $(grep -v 'No such file or directory' "$swept.err" | head -n 3 | tr '\n' ' ')" 1
    fi
  fi
  rm -f "$swept.err"
  echo "runner-sandbox: closed $(tr -cd '\0' <"$swept" | wc -c) paths every user could write, such as $(tr '\0' '\n' <"$swept" | head -n 3 | tr '\n' ' ')" >&2
fi
rm -f "$swept"

# Nothing outside their homes may already belong to the sandbox's users: the step owns what it owns.
uids=(-uid "$(id -u "$SANDBOX_STEP_USER")" -o -uid "$(id -u "$SANDBOX_HOLDER_USER")")
for disk in "${disks[@]}"; do
  owned="$(find "$disk" -xdev \( -path /proc -o -path /sys -o -path /dev -o -path /run \
    -o -path "$(getent passwd "$SANDBOX_STEP_USER" | cut -d: -f6)" -o -path "$(getent passwd "$SANDBOX_HOLDER_USER" | cut -d: -f6)" \) \
    -prune -o \( "${uids[@]}" \) -print 2>/dev/null | head -n 3)" || true
  [ -z "$owned" ] || die "files outside their homes already belong to the sandbox's users: $(tr '\n' ' ' <<<"$owned")" 1
done

# The runner's PATH and the step's: each folder, or for one that does not exist yet the nearest above it (where the
# step could make it), and each folder above, must be closed: in an open folder the step could rename the one below
# away and put its own in its place. A sticky one above keeps others' entries, so it may stay, but not as the folder
# itself, where a new file is enough; that is refused rather than closed, since closing /tmp would break the runner.
IFS=: read -ra runner_path <<<"/usr/local/bin:/usr/local/sbin:${MROOM_SANDBOX_RUNNER_PATH:-}"
trusted_path=()
for dir in "${runner_path[@]}" ${paths[@]+"${paths[@]}"}; do
  [[ "$dir" == /* ]] || continue
  dir="$(existing "$dir")"
  trusted_path+=("$dir")
  leaf=1
  while :; do
    if world_writable "$dir"; then
      if sticky "$dir" && [ -n "$leaf" ]; then die "$dir, on a PATH, is open to every user (sticky)" 1; fi
      if ! sticky "$dir"; then
        chmod o-w "$dir"
        echo "runner-sandbox: $dir was writable by every user; closed (o-w)" >&2
      fi
    fi
    [ "$dir" = / ] && break
    dir="$(dirname "$dir")" leaf=""
  done
done

# --- What the holder alone reads, and what everyone reads but nobody but root changes ---

install -d -m 0755 -o root -g root "$SANDBOX_ETC"
install -d -m 0700 -o "$SANDBOX_HOLDER_USER" -g "$SANDBOX_HOLDER_USER" "$SANDBOX_ETC/holder"
if [ -n "$secret" ]; then
  install -m 0600 -o "$SANDBOX_HOLDER_USER" -g "$SANDBOX_HOLDER_USER" /dev/null "$SANDBOX_ETC/holder/secret"
  printf '%s\n' "$secret" >"$SANDBOX_ETC/holder/secret"
fi
install -m 0644 -o root -g root /dev/null "$SANDBOX_ETC/known_hosts"
[ -z "$known" ] || printf '%s\n' "$known" >"$SANDBOX_ETC/known_hosts"
install -m 0644 -o root -g root /dev/null "$SANDBOX_ETC/env"
[ "${#envs[@]}" = 0 ] || printf '%s\n' "${envs[@]}" >"$SANDBOX_ETC/env"
install -m 0644 -o root -g root /dev/null "$SANDBOX_ETC/path"
[ "${#paths[@]}" = 0 ] || printf '%s\n' "${paths[@]}" >"$SANDBOX_ETC/path"

install -d -m 0755 -o root -g root "$SANDBOX_OPT"
for line in "${copies[@]}"; do
  install -d -m 0755 -o root -g root "$SANDBOX_OPT/$(dirname "$line")"
  cp -a "$line" "$SANDBOX_OPT/$line"
done
# -h and chmod's recursion leave a link's target alone: a link in a copied tree must not hand root's chown to it.
chown -R -h root:root "$SANDBOX_OPT"
chmod -R a+rX,go-w "$SANDBOX_OPT"

install -d -m 0755 -o root -g root "$LIB"
for f in common.sh step.sh probe.sh check.sh; do install -m 0755 -o root -g root "$HERE/$f" "$LIB/$f"; done
ln -sfn "$LIB/step.sh" "$SANDBOX_STEP_BIN"
[ -z "$holder" ] || install -m 0755 -o root -g root "$holder" "$SANDBOX_HOLDER_BIN"

install -d -m 0755 -o root -g root "$SANDBOX_VAR"
install -d -m 0755 -o "$runner" -g "$runner" "$SANDBOX_VAR/inputs"
install -d -m 0755 -o "$SANDBOX_STEP_USER" -g "$SANDBOX_STEP_USER" "$SANDBOX_VAR/evidence"

# Every folder the sandbox trusts, and each one above it, must be one only root or the runner can change: else the
# step could rename it away and put its own in its place.
runner_uid="$(id -u "$runner")" runner_gid="$(id -g "$runner")"
for path in "$LIB" "$SANDBOX_ETC" "$SANDBOX_OPT" "$SANDBOX_VAR" "$(dirname "$SANDBOX_STEP_BIN")" "${trusted_path[@]}"; do
  path="$(existing "$path")"
  while :; do
    read -r owner group mode <<<"$(stat -c '%u %g %a' "$path")"
    if [ "$owner" != 0 ] && [ "$owner" != "$runner_uid" ]; then die "$path is owned by uid $owner, which the step might be" 1; fi
    if (((8#$mode & 8#002) != 0)) && ! sticky "$path"; then die "$path is writable by every user" 1; fi
    if (((8#$mode & 8#020) != 0)) && [ "$group" != 0 ] && [ "$group" != "$runner_gid" ]; then die "$path is writable by group $group" 1; fi
    [ "$path" = / ] && break
    path="$(dirname "$path")"
  done
done

# --- sudoers: each hop resets the environment (env_reset is sudo's default, and these rules keep it) ---

rules="$runner ALL=($SANDBOX_STEP_USER) NOPASSWD: ALL"$'\n'
if [ -n "$holder" ]; then
  # With no arguments named, sudo lets the wrapper run with any; "" lets it run with none.
  command="$SANDBOX_HOLDER_BIN"
  [ "$holder_args" = any ] || command+=' ""'
  rules+="$runner ALL=($SANDBOX_HOLDER_USER) NOPASSWD: $command"$'\n'
  rules+="$SANDBOX_STEP_USER ALL=($SANDBOX_HOLDER_USER) NOPASSWD: $command"$'\n'
fi
# mroom-step kills the holder's processes after each step, as the holder.
rules+="$runner ALL=($SANDBOX_HOLDER_USER) NOPASSWD: /usr/bin/kill -KILL -1"$'\n'
tmp="$(mktemp)"
printf 'Defaults:%s env_reset\n%s' "$SANDBOX_STEP_USER" "$rules" >"$tmp"
visudo -cf "$tmp" >/dev/null || { rm -f "$tmp"; die "the sudoers rules do not parse" 1; }
install -m 0440 -o root -g root "$tmp" "$SANDBOX_SUDOERS"
rm -f "$tmp"

if [ -n "$secret" ]; then held="readable by $SANDBOX_HOLDER_USER only"; else held="not set"; fi
echo "runner-sandbox: ready (steps run as $SANDBOX_STEP_USER through mroom-step; the secret is $held)" >&2
