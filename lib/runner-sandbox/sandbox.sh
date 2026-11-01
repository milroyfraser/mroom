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
#   MROOM_SANDBOX_KNOWN_HOSTS  pinned SSH host key lines for the holder's wrapper; root-owned, so not even the holder
#                              can change which host it trusts
#   MROOM_SANDBOX_COPY         paths below the current folder, one per line, copied root-owned and read-only into
#                              /opt/mroom-sandbox at the same relative path (a harness and the packages it loads)
#   MROOM_SANDBOX_PATH         absolute folders, one per line, put first on the step's PATH (node's, for example)
#   MROOM_SANDBOX_ENV          NAME=value lines the step gets; never a credential (common.sh refuses those names)
#   MROOM_SANDBOX_EPHEMERAL    1 on a self-hosted runner that is thrown away after the job; refused otherwise
#
# What it builds:
#   mroom-step      runs the untrusted code (mroom-step, step.sh): env -i, no sudo but mroom-holder as the holder,
#                   and the runner's home closed (0700), so it reads no workspace, credential or runner process.
#   mroom-holder    the only user that can read the secret ($ETC/holder/secret, 0600), through
#                   /usr/local/bin/mroom-holder, a root-owned copy of MROOM_SANDBOX_HOLDER.
#   /opt/mroom-sandbox             the copies, root-owned
#   /var/lib/mroom-sandbox/inputs  written by the runner (mroom-step --input), read-only to the step
#   /var/lib/mroom-sandbox/evidence  written by the step, read by the runner afterwards
# The runner may run anything as mroom-step and only the wrapper as mroom-holder; mroom-step only the wrapper.
# sudo resets the environment on each hop. It refuses to run twice: a sandbox is set up once, on a fresh runner.
# Exits 2 for a bad input, 1 when it cannot set up.
set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
HERE="$(dirname "$SELF")"
# shellcheck source=lib/runner-sandbox/common.sh
. "$HERE/common.sh"
LIB=/usr/local/lib/mroom-sandbox

die() { echo "runner-sandbox: $*" >&2; exit "${2:-2}"; }

secret="${MROOM_SANDBOX_SECRET:-}" holder="${MROOM_SANDBOX_HOLDER:-}" known="${MROOM_SANDBOX_KNOWN_HOSTS:-}"
copies=() paths=() envs=() line="" why=""
here="$(pwd -P)"

# --- Inputs, all checked before anything changes ---

if [ -n "$secret" ] && [ -z "$holder" ]; then die "MROOM_SANDBOX_SECRET needs MROOM_SANDBOX_HOLDER, the wrapper that uses it"; fi
if [ -n "$holder" ]; then
  [ -f "$holder" ] && [ ! -L "$holder" ] || die "MROOM_SANDBOX_HOLDER is not a regular file: $holder"
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
[ -n "$runner" ] && [ "$runner" != root ] || die "run through sudo from the runner's user, which SUDO_USER names" 1
if [ "${RUNNER_ENVIRONMENT:-}" = self-hosted ] && [ "${MROOM_SANDBOX_EPHEMERAL:-}" != 1 ]; then
  die "a self-hosted runner keeps the sandbox's users, secret and sudoers after the job; set MROOM_SANDBOX_EPHEMERAL=1 only on one thrown away after it" 1
fi
[ ! -e "$SANDBOX_SUDOERS" ] || die "already set up on this runner ($SANDBOX_SUDOERS exists); a sandbox is set up once" 1
[ ! -e "$SANDBOX_OPT" ] || die "$SANDBOX_OPT exists already" 1
command -v visudo >/dev/null || die "visudo is missing" 1

# --- Users, and the runner's home closed ---

for user in "$SANDBOX_STEP_USER" "$SANDBOX_HOLDER_USER"; do
  id "$user" >/dev/null 2>&1 || useradd --create-home --shell /usr/sbin/nologin "$user"
done
home="$(getent passwd "$runner" | cut -d: -f6)"
[ -d "$home" ] || die "no home for $runner" 1
# The runner's home holds the workspace (and git's credentials in it), temp files and tool state.
chmod 0700 "$home"

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

# --- sudoers: each hop resets the environment (env_reset is sudo's default, and these rules keep it) ---

rules="$runner ALL=($SANDBOX_STEP_USER) NOPASSWD: ALL"$'\n'
if [ -n "$holder" ]; then
  rules+="$runner ALL=($SANDBOX_HOLDER_USER) NOPASSWD: $SANDBOX_HOLDER_BIN"$'\n'
  rules+="$SANDBOX_STEP_USER ALL=($SANDBOX_HOLDER_USER) NOPASSWD: $SANDBOX_HOLDER_BIN"$'\n'
fi
tmp="$(mktemp)"
printf 'Defaults:%s env_reset\n%s' "$SANDBOX_STEP_USER" "$rules" >"$tmp"
visudo -cf "$tmp" >/dev/null || { rm -f "$tmp"; die "the sudoers rules do not parse" 1; }
install -m 0440 -o root -g root "$tmp" "$SANDBOX_SUDOERS"
rm -f "$tmp"

if [ -n "$secret" ]; then held="readable by $SANDBOX_HOLDER_USER only"; else held="not set"; fi
echo "runner-sandbox: ready (steps run as $SANDBOX_STEP_USER through mroom-step; the secret is $held)" >&2
