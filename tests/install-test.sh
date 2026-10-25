#!/usr/bin/env bash
# shellcheck disable=SC2317  # the t_* functions run indirectly, through test_case
# Tests for install.sh: into a temp HOME, from the checkout and from a release tarball served from a
# file:// URL (no network), idempotent, refusing a foreign mroom, the host checks, and --uninstall.
# Needs a host install.sh accepts (Linux, bash 5, python3 3.11+, jq, git); outside CI it skips otherwise.
set -euo pipefail
SUITE=install
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALL="$ROOT/install.sh"
V="$(tr -d '[:space:]' <"$ROOT/VERSION")"

host_ok() {
  [ "$(uname -s)" = Linux ] && [ "$(bash -c 'echo "${BASH_VERSINFO[0]}"')" -ge 5 ] && has_tomllib \
    && command -v jq >/dev/null && command -v git >/dev/null
}
skip_unless host_ok "this host is not one install.sh accepts"

# release <tag> [<VERSION inside>]: a GitHub-style archive at $T/releases/<tag>.tar.gz, made from HEAD.
release() {
  local tag="$1" inside="${2:-}" dir="$T/build/mroom-${1#v}"
  mkdir -p "$T/releases" "$dir"
  git -C "$ROOT" archive HEAD | tar -x -C "$dir"
  [ -z "$inside" ] || echo "$inside" >"$dir/VERSION"
  tar -czf "$T/releases/$tag.tar.gz" -C "$T/build" "mroom-${1#v}"
  export MROOM_RELEASE_BASE="file://$T/releases"
}

t_installs_from_checkout() {
  run "$INSTALL"; expect_rc 0; expect_out_has "installed mroom $V from checkout $ROOT"
  expect_file "$HOME/.local/share/mroom/$V/bin/mroom"
  expect_file "$HOME/.local/share/mroom/$V/lib/core/config.py"
  expect_file "$HOME/.local/share/mroom/$V/LICENSE"
  if [ "$(readlink "$HOME/.local/bin/mroom")" = "$HOME/.local/share/mroom/$V/bin/mroom" ]; then ok; else fail "link"; fi
  expect_out_has "is not on PATH"
  run "$HOME/.local/bin/mroom" version; expect_rc 0; expect_out "$V"
  run "$HOME/.local/bin/mroom" version --source; expect_out_has "checkout $ROOT at "
  cd "$ROOT/examples/single-app"
  run "$HOME/.local/bin/mroom" config get app.name; expect_rc 0; expect_out "shop"
}

t_idempotent() {
  run "$INSTALL"; expect_rc 0
  touch "$HOME/.local/share/mroom/$V/stale-file"
  run "$INSTALL"; expect_rc 0
  expect_no_file "$HOME/.local/share/mroom/$V/stale-file"
  if [ "$(find "$HOME/.local/share/mroom" -mindepth 1 -maxdepth 1 | wc -l)" = 1 ]; then ok; else fail "one version dir"; fi
  run "$HOME/.local/bin/mroom" version; expect_out "$V"
}

t_prefix_and_path_note() {
  export PATH="$T/opt/bin:$PATH"
  run "$INSTALL" --prefix "$T/opt"; expect_rc 0
  expect_file "$T/opt/bin/mroom"; expect_no_file "$HOME/.local/bin/mroom"
  case "$out" in *"not on PATH"*) fail "PATH note shown though it is on PATH" ;; *) ok ;; esac
  run mroom version; expect_out "$V"
}

t_relative_prefix() {
  mkdir -p "$T/work" && cd "$T/work"
  run "$INSTALL" --prefix rel; expect_rc 0
  if [ "$(readlink "$T/work/rel/bin/mroom")" = "$T/work/rel/share/mroom/$V/bin/mroom" ]; then ok; else fail "link is not absolute"; fi
  cd "$T"
  run "$T/work/rel/bin/mroom" version; expect_rc 0; expect_out "$V"
}

t_same_install_spelled_differently() {
  run "$INSTALL" --prefix "$T/opt"; expect_rc 0
  run "$INSTALL" --prefix "$T//opt/"; expect_rc 0
  if [ "$(readlink "$T/opt/bin/mroom")" = "$T/opt/share/mroom/$V/bin/mroom" ]; then ok; else fail "slashes not normalised"; fi
  ln -s "$T/opt" "$T/alias"
  run "$INSTALL" --prefix "$T/alias"; expect_rc 0; expect_err_lacks "is not an mroom install"
  run "$INSTALL" --prefix "$T/alias" --uninstall; expect_rc 0; expect_out_has "removed $T/alias/bin/mroom"
  expect_no_file "$T/opt/bin/mroom"; expect_no_file "$T/opt/share/mroom"
}

# a mv on PATH that refuses to move a staged install into place, as a full disk or a race would.
failing_mv() {
  mkdir -p "$T/mvbin"
  # shellcheck disable=SC2016  # the stub script is written literally
  printf '#!/bin/sh\ncase "$1" in *.stage.*) echo "mv: refused" >&2; exit 1 ;; esac\nexec %s "$@"\n' \
    "$(command -v mv)" >"$T/mvbin/mv"
  chmod +x "$T/mvbin/mv"
  echo "$T/mvbin"
}

t_failed_reinstall_keeps_old() {
  local mvbin
  run "$INSTALL"; expect_rc 0
  echo marker >"$HOME/.local/share/mroom/$V/marker"
  mvbin="$(failing_mv)"
  run env PATH="$mvbin:$PATH" "$INSTALL"; expect_rc 1
  expect_err_has "could not move the new $V into place; the previous install is unchanged"
  expect_file "$HOME/.local/share/mroom/$V/marker"
  run "$HOME/.local/bin/mroom" version; expect_rc 0; expect_out "$V"
  if [ -z "$(find "$HOME/.local/share/mroom" -mindepth 1 -maxdepth 1 -name '.*')" ]; then ok; else fail "left .old or .stage"; fi
  run "$INSTALL"; expect_rc 0
  expect_no_file "$HOME/.local/share/mroom/$V/marker"
  if [ -z "$(find "$HOME/.local/share/mroom" -mindepth 1 -maxdepth 1 -name '.*')" ]; then ok; else fail "left .old or .stage"; fi
}

t_installs_release() {
  release "v$V"
  run "$INSTALL" --version "v$V"; expect_rc 0; expect_out_has "installed mroom $V from release v$V"
  run "$HOME/.local/bin/mroom" version --source; expect_out "release v$V of milroyfraser/mroom"
  cd "$ROOT/examples/two-folder"
  run "$HOME/.local/bin/mroom" config get app.name; expect_out "bookings"
}

t_release_mismatch_and_bad_tag() {
  release v9.9.9 "$V"
  run "$INSTALL" --version v9.9.9; expect_rc 1; expect_err_has "release v9.9.9 carries VERSION $V"
  expect_no_file "$HOME/.local/bin/mroom"
  run "$INSTALL" --version 1.0; expect_rc 1; expect_err_has "--version takes a tag like v0.1.0"
  run "$INSTALL" --version v8.8.8; expect_rc 1; expect_err_has "could not download file://$T/releases/v8.8.8.tar.gz"
  run "$INSTALL" --version; expect_rc 1; expect_err_has "--version needs a tag"
}

t_refuses_foreign_link() {
  mkdir -p "$HOME/.local/bin"
  ln -s /somewhere/else/mroom "$HOME/.local/bin/mroom"
  run "$INSTALL"; expect_rc 1; expect_err_has "is not an mroom install (/somewhere/else/mroom); move it or rerun with --force"
  run "$INSTALL" --force; expect_rc 0
  run "$HOME/.local/bin/mroom" version; expect_out "$V"
}

# a PATH holding only what install.sh needs before its checks, minus the tools a test leaves out.
fake_path() {
  local tool
  mkdir -p "$T/fakebin"
  for tool in bash python3 git jq dirname uname; do
    case " $* " in *" $tool "*) continue ;; esac
    ln -sf "$(command -v "$tool")" "$T/fakebin/$tool"
  done
  echo "$T/fakebin"
}

t_host_checks() {
  local fake bash_bin
  bash_bin="$(command -v bash)"
  fake="$(fake_path jq git)"
  run env PATH="$fake" "$bash_bin" "$INSTALL"; expect_rc 1
  expect_err_has "this host is missing what mroom needs:"; expect_err_has "  - jq"; expect_err_has "  - git"
  expect_err_lacks "  - python3"
  run env MROOM_UNAME=Darwin "$INSTALL"; expect_rc 1; expect_err_has "  - Linux (this is Darwin"
  # shellcheck disable=SC2016  # the stub script is written literally
  printf '#!/bin/sh\ncase "$2" in *platform*) echo 3.10.12 ;; *) exit 1 ;; esac\n' >"$T/py" && chmod +x "$T/py"
  fake="$(fake_path python3)" && ln -sf "$T/py" "$fake/python3"
  run env PATH="$fake" "$bash_bin" "$INSTALL"; expect_rc 1; expect_err_has "  - python3 >= 3.11 (the python3 on PATH is 3.10.12)"
}

t_links_forge_api_beside_mroom() {
  run "$INSTALL"; expect_rc 0; expect_out_has "$HOME/.local/bin/forge-api -> $HOME/.local/share/mroom/$V/bin/forge-api"
  if [ "$(readlink "$HOME/.local/bin/forge-api")" = "$HOME/.local/share/mroom/$V/bin/forge-api" ]; then ok; else fail "forge-api link"; fi
  run "$HOME/.local/bin/forge-api" --help; expect_rc 0; expect_out_has "forge-api GET sites"
}

t_leaves_a_foreign_forge_api_alone() {
  mkdir -p "$HOME/.local/bin" && ln -s /somewhere/else/forge-api "$HOME/.local/bin/forge-api"
  run "$INSTALL"; expect_rc 0
  expect_out_has "left $HOME/.local/bin/forge-api alone: it is not mroom's"
  if [ "$(readlink "$HOME/.local/bin/forge-api")" = /somewhere/else/forge-api ]; then ok; else fail "foreign link replaced"; fi
  run "$INSTALL" --uninstall; expect_rc 0
  if [ "$(readlink "$HOME/.local/bin/forge-api")" = /somewhere/else/forge-api ]; then ok; else fail "foreign link removed"; fi
  expect_no_file "$HOME/.local/share/mroom"
  run "$INSTALL" --force; expect_rc 0
  if [ "$(readlink "$HOME/.local/bin/forge-api")" = "$HOME/.local/share/mroom/$V/bin/forge-api" ]; then ok; else fail "--force did not replace it"; fi
}

t_uninstall() {
  run "$INSTALL"; expect_rc 0
  mkdir -p "$HOME/.config/mroom" && echo "MROOM_ENV=local" >"$HOME/.config/mroom/box.env"
  run "$INSTALL" --uninstall; expect_rc 0; expect_out_has "removed $HOME/.local/bin/mroom"
  expect_out_has "removed $HOME/.local/bin/forge-api"; expect_no_file "$HOME/.local/bin/forge-api"
  expect_no_file "$HOME/.local/bin/mroom"; expect_no_file "$HOME/.local/share/mroom"
  expect_file "$HOME/.config/mroom/box.env"
  run "$INSTALL" --uninstall; expect_rc 0
  ln -s /somewhere/else/mroom "$HOME/.local/bin/mroom"
  run "$INSTALL" --uninstall; expect_rc 0; expect_out_has "left $HOME/.local/bin/mroom alone"
  expect_file "$HOME/.local/bin/mroom"
}

t_uninstall_keeps_share_behind_foreign_link() {
  run "$INSTALL"; expect_rc 0
  rm "$HOME/.local/bin/mroom" && ln -s /somewhere/else/mroom "$HOME/.local/bin/mroom"
  run "$INSTALL" --uninstall; expect_rc 0
  expect_out_has "left $HOME/.local/bin/mroom alone: it is not an mroom install"
  expect_out_has "left $HOME/.local/share/mroom alone too"
  expect_file "$HOME/.local/share/mroom/$V/bin/mroom"; expect_file "$HOME/.local/bin/mroom"
}

test_case installs-from-checkout t_installs_from_checkout
test_case idempotent t_idempotent
test_case prefix-and-path-note t_prefix_and_path_note
test_case relative-prefix t_relative_prefix
test_case same-install-spelled-differently t_same_install_spelled_differently
test_case failed-reinstall-keeps-old t_failed_reinstall_keeps_old
test_case uninstall-keeps-share-behind-foreign-link t_uninstall_keeps_share_behind_foreign_link
test_case installs-release t_installs_release
test_case release-mismatch-and-bad-tag t_release_mismatch_and_bad_tag
test_case refuses-foreign-link t_refuses_foreign_link
test_case host-checks t_host_checks
test_case links-forge-api t_links_forge_api_beside_mroom
test_case leaves-foreign-forge-api t_leaves_a_foreign_forge_api_alone
test_case uninstall t_uninstall
finish
