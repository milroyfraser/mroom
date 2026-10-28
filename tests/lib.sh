#!/usr/bin/env bash
# Shared helpers for the tests: sourced by each *-test.sh, never run on its own.
# Every test runs in its own temp HOME, offline; nothing outside $TOP is touched.
# shellcheck disable=SC2034  # variables here are read by the test files that source this one

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MROOM="$ROOT/bin/mroom"
TOP="$(mktemp -d)"
# A test may leave folders mode 555 (services_tree --locked).
trap 'chmod -R u+w "$TOP" 2>/dev/null; rm -rf "$TOP"' EXIT
ORIG_PATH="$PATH"
failures=0
passes=0

# setup <name>: a fresh world in $T with HOME at $T/home; clears every MROOM_* override.
setup() {
  T="$TOP/$1"
  mkdir -p "$T/home"
  local var
  for var in $(compgen -e | grep '^MROOM_' || true); do unset "$var"; done
  export HOME="$T/home" PATH="$ORIG_PATH"
  cd "$T" || exit 1
}

# run <command...>: runs it, keeping its exit code in $rc, stdout in $out and stderr in $err.
run() {
  rc=0
  "$@" >"$T/.out" 2>"$T/.err" || rc=$?
  out="$(cat "$T/.out")"
  err="$(cat "$T/.err")"
}

fail() {
  echo "  FAIL [$CURRENT] $*" >&2
  echo "    rc=$rc" >&2
  echo "    out: ${out//$'\n'/$'\n'         }" >&2
  echo "    err: ${err//$'\n'/$'\n'         }" >&2
  failures=$((failures + 1))
}

ok() { passes=$((passes + 1)); }

expect_rc() { if [ "$rc" = "$1" ]; then ok; else fail "expected exit $1"; fi; }
expect_out() { if [ "$out" = "$1" ]; then ok; else fail "expected stdout: $1"; fi; }
expect_out_has() { case "$out" in *"$1"*) ok ;; *) fail "stdout lacks: $1" ;; esac; }
expect_err_has() { case "$err" in *"$1"*) ok ;; *) fail "stderr lacks: $1" ;; esac; }
expect_err_lacks() { case "$err" in *"$1"*) fail "stderr has: $1" ;; *) ok ;; esac; }
expect_err_empty() { if [ -z "$err" ]; then ok; else fail "expected no stderr"; fi; }
expect_file() { if [ -e "$1" ] || [ -L "$1" ]; then ok; else fail "missing: $1"; fi; }
expect_no_file() { if [ -e "$1" ] || [ -L "$1" ]; then fail "should not exist: $1"; else ok; fi; }
# expect_true <what it means> <command...>: passes when the command succeeds.
expect_true() { local what="$1"; shift; if "$@"; then ok; else fail "$what"; fi; }

# test <name> <function>: runs one test function in a fresh world.
test_case() {
  CURRENT="$1"
  setup "$1"
  "$2"
}

# services_tree [--locked] [<service/folder>...]: the services' folders, as mroom's root recipe makes them
# (lib/root-setup), in $T/services, which MROOM_SERVICES_DIR then names; with no folder named, every part's.
# --locked makes the folders above them mode 555, as root's are to the box user.
services_tree() {
  local locked="" leaf leaves=()
  if [ "${1:-}" = --locked ]; then locked=1; shift; fi
  leaves=("$@")
  # shellcheck disable=SC2016  # expanded by the inner bash
  if [ "${#leaves[@]}" = 0 ]; then
    read -ra leaves <<<"$(bash -c '. "$1"; echo "${MAILPIT_TREE[*]} ${GARAGE_TREE[*]} ${REVERB_TREE[*]}"' _ "$ROOT/lib/root-setup")"
  fi
  export MROOM_SERVICES_DIR="$T/services"
  for leaf in "${leaves[@]}"; do mkdir -p "$T/services/$leaf"; chmod 700 "$T/services/$leaf"; done
  if [ -n "$locked" ]; then chmod 555 "$T/services" "$T/services"/*; fi
}

# has_tomllib: python3 can read TOML (3.11+). Outside CI the TOML tests skip without it.
has_tomllib() { python3 -c 'import tomllib' >/dev/null 2>&1; }

# has_box_tools: bash 5, flock and GNU date, which the box commands (job, watchdog) need. A laptop
# often lacks them; the box and CI have them.
has_box_tools() {
  [ "${BASH_VERSINFO[0]}" -ge 5 ] && command -v flock >/dev/null 2>&1 && date -u -d @0 >/dev/null 2>&1
}

# skip_unless <condition function> <why>: in CI a missing requirement is a failure, not a skip.
skip_unless() {
  if "$1"; then return 0; fi
  if [ -n "${CI:-}" ]; then
    echo "  FAIL [$SUITE] $2, and CI must run every test" >&2
    failures=$((failures + 1))
    finish
  fi
  echo "  skip [$SUITE] $2"
  exit 0
}

finish() {
  echo "$SUITE: $passes passed, $failures failed"
  [ "$failures" = 0 ] || exit 1
  exit 0
}
