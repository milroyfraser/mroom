#!/usr/bin/env bash
# bwrap-probe.sh — whether Claude Code's own sandbox can sit on top of the runner sandbox (design 8.5). For mroom's CI
# on a throwaway runner (tests/sandbox/real-test.sh), and on each Claude Code bump.
#
#   bwrap-probe.sh setup               as a user with sudo: install bubblewrap, and let it make namespaces
#   bwrap-probe.sh check <hop>...      as the runner's user, after sandbox.sh: <hop> is a command that crosses
#                                      the sandbox's sudo hop, such as `mroom-step -- true`
#
# Why it exists: Claude Code's subprocess env scrub (CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1) needs bubblewrap, and with it
# runs every Bash command inside `bwrap --unshare-user …`. Inside that user namespace only the caller's own uid is
# mapped, so root's files show as owned by the overflow uid (65534) and sudo refuses to start ("/etc/sudo.conf is
# owned by uid 65534", as GitHub's runner shows); and bwrap sets no_new_privs, so a setuid sudo could not change user
# even then. The runner sandbox reaches its users through exactly such a hop (mroom-step, mroom-holder).
# So on a sandboxed runner the scrub stays off, and the sandbox, not bwrap, keeps the step from the job's secrets.
# `check` shows it on a real runner: bubblewrap works for the runner's user, and the hop is refused inside it. If the
# hop ever works there, it warns, and the scrub could be switched on.
#
# Prints `ok …` and `warning …` lines (a warning also as ::warning::); exits 1 when bubblewrap itself does not work,
# 2 for a bad call.
set -uo pipefail

warn() { echo "::warning::bwrap-probe: $*"; echo "warning $*"; }
first() { grep -m1 . <<<"$1" | cut -c1-160; }

# bwrap_setup: install bubblewrap and, when Ubuntu's AppArmor userns restriction stops it making namespaces, load a
# profile that allows them for /usr/bin/bwrap alone (narrower than turning the restriction off for every program).
bwrap_setup() {
  local err restrict
  sudo apt-get update -qq >/dev/null 2>&1 || true
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends bubblewrap >/dev/null \
    || { echo "fail apt-get install bubblewrap"; return 1; }
  restrict="$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || echo n/a)"
  echo "bubblewrap: $(bwrap --version); kernel.apparmor_restrict_unprivileged_userns=$restrict"
  if err="$(bwrap --unshare-all --ro-bind / / --dev /dev --proc /proc true 2>&1)"; then
    echo "ok bubblewrap makes namespaces as $(id -un) without an AppArmor profile"
    return 0
  fi
  echo "bubblewrap: blocked as $(id -un) ($(first "$err")); loading an AppArmor profile for /usr/bin/bwrap that allows userns"
  sudo tee /etc/apparmor.d/bwrap >/dev/null <<'EOF'
abi <abi/4.0>,
include <tunables/global>

profile bwrap /usr/bin/bwrap flags=(unconfined) {
  userns,

  include if exists <local/bwrap>
}
EOF
  sudo apparmor_parser -r /etc/apparmor.d/bwrap || { echo "fail load the bwrap AppArmor profile"; return 1; }
  echo "ok bubblewrap allowed to make namespaces by its own AppArmor profile"
}

# bwrap_check <hop>...: the hop counts as refused inside bwrap only when the same call succeeds outside it and sudo
# itself says no inside; anything else (it fails outside too, or bwrap could not run it) is inconclusive and warns.
bwrap_check() {
  local out rc=0
  if ! out="$(bwrap --unshare-all --ro-bind / / --dev /dev --proc /proc true 2>&1)"; then
    echo "fail bwrap --unshare-all as $(id -un): $(first "$out")"
    return 1
  fi
  echo "ok bwrap --unshare-all works as $(id -un)"
  out="$("$@" 2>&1)" || rc=$?
  if ((rc != 0)); then
    warn "inconclusive: the sudo hop fails outside bwrap too (exit $rc: $(first "$out"))"
    return 0
  fi
  echo "ok the sudo hop works outside bwrap"
  # The flags Claude Code's sandbox runtime passes (2.1.302): the filesystem left writable, so only the namespaces
  # and no_new_privs differ from the call above.
  rc=0
  out="$(bwrap --new-session --die-with-parent --unshare-user --unshare-pid --unshare-ipc --unshare-uts \
    --bind / / --dev /dev --proc /proc -- "$@" 2>&1)" || rc=$?
  if ((rc == 0)); then
    warn "the sudo hop works inside bwrap, so CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 may now be possible on a sandboxed runner"
  elif grep -q '^sudo\(-rs\)\?: ' <<<"$out"; then
    echo "ok the sudo hop inside bwrap, as Claude Code's env scrub would run it, is refused by sudo (exit $rc: $(grep -m1 '^sudo' <<<"$out" | cut -c1-160)), so the scrub stays off"
  else
    warn "inconclusive: bwrap did not get as far as sudo (exit $rc: $(first "$out"))"
  fi
}

case "${1:-}" in
  setup) [ "$#" = 1 ] || { echo "usage: bwrap-probe.sh setup" >&2; exit 2; }; bwrap_setup ;;
  check) [ "$#" -ge 2 ] || { echo "usage: bwrap-probe.sh check <hop command>..." >&2; exit 2; }; shift; bwrap_check "$@" ;;
  *) echo "usage: bwrap-probe.sh setup | check <hop command>..." >&2; exit 2 ;;
esac
