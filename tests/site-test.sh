#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2016  # t_* run through test_case; a $ in single quotes is for eval, later
# Tests for the gate's site operations (code-put, dist-put, env-sha, signin-code, user-clean) and
# lib/site-op, which does their work as the site's user. Offline: a fake sudo checks the gate's arguments,
# then runs the real site-op as the test's own user with HOME at a fake site home. Hostile tarballs are
# made with Python's tarfile, since tar will not write most of them. tests/site/gate-real-test.sh runs the
# same gate with real users and sudo in CI.
set -euo pipefail
SUITE=site
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
skip_unless has_box_tools "this host lacks bash 5, flock or GNU date, which box commands need"

COMMIT=abc1234def5678abc1234def5678abc1234def56
SITE="api-12.qa.example.test"
WEB="go-12.qa.example.test"

# world: box.env, a root-like copy of site-op, the site user's home with a live tree, and fakes for sudo,
# id and logger.
world() {
  mkdir -p "$HOME/.config/mroom" "$T/bin" "$T/libexec"
  printf 'MROOM_APP_NAME=shop\nMROOM_QA_ZONE=qa.example.test\nMROOM_QA_BACKEND_DIR=backend\n' >"$HOME/.config/mroom/box.env"
  cp "$ROOT/lib/site-op" "$T/libexec/site-op"
  chmod 555 "$T/libexec/site-op"
  export MROOM_GATE_SITE_OP="$T/libexec/site-op" MROOM_GATE_SITE_OP_OWNER
  MROOM_GATE_SITE_OP_OWNER="$(id -u)"
  printf 'shop_qa_12 shop_qa_12 isolated\nshop_qa_13 shop_qa_13 isolated\nshop_qa_14 shop_qa_14\n' >"$T/users"
  live_tree
  cat >"$T/bin/sudo" <<'FAKE'
#!/usr/bin/env bash
# Insists on `sudo -n -u <user> -- <site-op> ...`, then runs site-op as the test's own user with HOME at
# that user's home under $T/homes, and no SUDO_UID, so site-op takes that HOME.
printf '%s\n' "$*" >>"$T/sudo.log"
if [ "$1" != -n ] || [ "$2" != -u ] || [ "$4" != -- ]; then echo "fake sudo: unexpected arguments: $*" >&2; exit 1; fi
user="$3"
shift 4
exec env -u SUDO_UID -u SUDO_USER HOME="$T/homes/$user" "$@"
FAKE
  cat >"$T/bin/id" <<'FAKE'
#!/usr/bin/env bash
# id for the fake users in $T/users ("<name> <groups...>"); anything else asks the real id.
user="${!#}"
if [ "$#" -ge 2 ] && line="$(grep -m1 "^$user " "$T/users" 2>/dev/null)"; then
  case "$1" in
    -u) echo 2000 ;;
    -nG) echo "${line#* }" ;;
  esac
  exit 0
fi
exec /usr/bin/id "$@"
FAKE
  printf '#!/bin/sh\necho "$*" >>"$T/syslog"\n' >"$T/bin/logger"
  chmod +x "$T/bin/sudo" "$T/bin/id" "$T/bin/logger"
  export T PATH="$T/bin:$PATH"
}

# live_tree: the site as qa-up leaves it before a put: Forge's .env, an upload in storage, an old file.
live_tree() {
  local s="$T/homes/shop_qa_12/$SITE"
  mkdir -p "$s/backend/storage/app" "$T/homes/shop_qa_12/$WEB"
  printf 'APP_KEY=base64:live\n\n' >"$s/backend/.env"
  printf 'uploaded\n' >"$s/backend/storage/app/photo.jpg"
  printf 'old\n' >"$s/old-file"
  printf 'old\n' >"$T/homes/shop_qa_12/$WEB/old.html"
}

# repo_tarball [<folder name>]: GitHub's tarball of the PR's tree: one folder named after the commit.
repo_tarball() {
  local name="${1:-example-shop-${COMMIT:0:7}}" top
  top="$T/src/$name"
  rm -rf "$T/src"
  mkdir -p "$top/backend/public" "$top/backend/storage/app" "$top/backend/bootstrap/cache" "$top/.mroom/hooks"
  printf '<?php echo "ok";\n' >"$top/backend/public/index.php"
  printf '#!/usr/bin/env php\n<?php\n' >"$top/backend/artisan"
  printf 'COMMITTED=1\n' >"$top/backend/.env"
  : >"$top/backend/storage/app/.gitignore"
  printf 'readme\n' >"$top/README.md"
  printf '#!/bin/sh\necho "log line"\necho 123456\n' >"$top/.mroom/hooks/qa-signin"
  chmod +x "$top/.mroom/hooks/qa-signin"
  tar -czf "$T/code.tgz" -C "$T/src" "$name"
}

# craft <out> <entry>...: a tarball tar would not write. Each entry is type:name[:target]: file, dir,
# symlink, hardlink, fifo or setuid (a file with mode 4755).
craft() {
  python3 - "$@" <<'PY'
import io, sys, tarfile
out, entries = sys.argv[1], sys.argv[2:]
with tarfile.open(out, "w:gz") as tf:
    for entry in entries:
        kind, name, *rest = entry.split(":")
        info = tarfile.TarInfo(name)
        data = None
        if kind in ("file", "setuid"):
            data = b"x\n"
            info.size, info.mode = len(data), 0o4755 if kind == "setuid" else 0o644
        elif kind == "dir":
            info.type, info.mode = tarfile.DIRTYPE, 0o755
        elif kind == "symlink":
            info.type, info.linkname = tarfile.SYMTYPE, rest[0]
        elif kind == "hardlink":
            info.type, info.linkname = tarfile.LNKTYPE, rest[0]
        elif kind == "fifo":
            info.type = tarfile.FIFOTYPE
        tf.addfile(info, io.BytesIO(data) if data else None)
PY
}

gate() { run env SSH_ORIGINAL_COMMAND="$2" "$MROOM" gate "$1"; }
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
lacks() { ! has "$@"; }
site() { echo "$T/homes/shop_qa_12/$SITE"; }
no_leftovers() { ! compgen -G "$(site)/.mroom-*" >/dev/null && ! compgen -G "$T/homes/shop_qa_12/$WEB/.mroom-*" >/dev/null; }
unchanged() { [ -f "$(site)/old-file" ] && [ "$(cat "$(site)/backend/.env")" = "APP_KEY=base64:live" ]; }
gate_log_text() { cat "$HOME/.local/state/mroom/gate.log" 2>/dev/null || true; }
put() { gate provision "code-put 12 $COMMIT" <"${1:-$T/code.tgz}"; }

t_code_put_replaces_the_tree_and_keeps_env_and_storage() {
  world; repo_tarball
  put
  expect_rc 0; expect_out "$SITE: 5 entries unpacked, 1 .env skipped"
  expect_file "$(site)/backend/public/index.php"
  expect_file "$(site)/README.md"
  expect_no_file "$(site)/old-file"
  run cat "$(site)/backend/.env"; expect_out "APP_KEY=base64:live"
  run cat "$(site)/backend/storage/app/photo.jpg"; expect_out "uploaded"
  run cat "$(site)/backend/version.json"; expect_out "{\"release\": null, \"commit\": \"$COMMIT\"}"
  run cat "$HOME/.local/state/mroom/qa/shop_qa_12.commit"; expect_out "$COMMIT"
  run tail -n 1 "$T/sudo.log"; expect_out "-n -u shop_qa_12 -- $T/libexec/site-op unpack code $SITE backend $COMMIT"
  expect_true "a scratch folder stayed" no_leftovers
  expect_true "the put is not logged" has "$(gate_log_text)" "code-put 12: $COMMIT into $SITE"
}

t_a_second_put_replaces_the_first() {
  world; repo_tarball; put; expect_rc 0
  rm "$T/src/example-shop-${COMMIT:0:7}/README.md"
  tar -czf "$T/code.tgz" -C "$T/src" "example-shop-${COMMIT:0:7}"
  put; expect_rc 0
  expect_no_file "$(site)/README.md"
  run cat "$(site)/backend/.env"; expect_out "APP_KEY=base64:live"
}

t_env_sha_reports_the_env_hash_and_the_recorded_commit() {
  world
  gate provision "env-sha 12"
  expect_rc 0; expect_out "env=$(printf '%s' 'APP_KEY=base64:live' | sha256sum | cut -d' ' -f1)"$'\ncommit=none'
  repo_tarball; put
  gate provision "env-sha 12"; expect_rc 0; expect_out_has "commit=$COMMIT"
  rm "$(site)/backend/.env"
  gate provision "env-sha 12"; expect_rc 0; expect_out_has "env=missing"
  ln -s /etc/hostname "$(site)/backend/.env"
  gate provision "env-sha 12"; expect_rc 0; expect_out_has "env=missing"
}

t_a_tarball_of_another_commit_or_shape_changes_nothing() {
  world
  repo_tarball "example-shop-0000000"
  put; expect_rc 1; expect_err_has "the tarball's folder example-shop-0000000 is not of commit abc1234def56"
  local top="example-shop-${COMMIT:0:7}" bad
  craft "$T/two.tgz" "file:$top/backend/a" "file:other/b"
  put "$T/two.tgz"; expect_rc 1; expect_err_has "the tarball must hold one folder"
  craft "$T/nobackend.tgz" "file:$top/README.md"
  put "$T/nobackend.tgz"; expect_rc 1; expect_err_has "the tarball has no backend/ folder"
  craft "$T/empty.tgz"
  put "$T/empty.tgz"; expect_rc 1
  for bad in "file:$top/../evil" "file:$top/backend/../../evil" "symlink:$top/backend/evil:/etc/passwd" \
    "symlink:$top/backend/out:../../../outside" "symlink:$top/backend/storage:../elsewhere" \
    "symlink:$top/backend:elsewhere" "hardlink:$top/backend/h:/etc/passwd" "fifo:$top/backend/pipe" \
    "file:$top/.mroom-new-x/backend/.env"; do
    craft "$T/bad.tgz" "dir:$top" "file:$top/backend/artisan" "$bad"
    put "$T/bad.tgz"; expect_rc 1
    expect_true "a refused tarball ($bad) changed the site" unchanged
    expect_true "a refused tarball ($bad) left a scratch folder" no_leftovers
  done
  expect_true "nothing was recorded" eval '[ ! -e "$HOME/.local/state/mroom/qa/shop_qa_12.commit" ]'
}

t_size_limits_refuse_before_unpacking() {
  world; repo_tarball
  MROOM_SITE_OP_MAX_TARBALL=100 put; expect_rc 1; expect_err_has "the tarball is larger than 100 bytes"
  MROOM_SITE_OP_MAX_MEMBERS=3 put; expect_rc 1; expect_err_has "the tarball holds more than 3 entries"
  MROOM_SITE_OP_MAX_UNPACKED=5 put; expect_rc 1; expect_err_has "the tarball unpacks to more than 5 bytes"
  expect_true "a refused tarball changed the site" unchanged
  gate provision "code-put 12 $COMMIT" </dev/null; expect_rc 1; expect_err_has "no tarball came on stdin"
}

t_unpacked_files_lose_setuid_and_dirs_stay_removable() {
  world
  local top="example-shop-${COMMIT:0:7}"
  craft "$T/modes.tgz" "dir:$top" "file:$top/backend/artisan" "setuid:$top/backend/tool"
  put "$T/modes.tgz"; expect_rc 0
  run stat -c %a "$(site)/backend/tool"; expect_out 755
}

t_an_interrupted_put_is_recovered() {
  world; repo_tarball
  # A put that died mid-swap: its new tree holds the live .env, and the live tree has none.
  mkdir -p "$(site)/.mroom-new-dead/backend" "$(site)/.mroom-old-dead/x"
  mv "$(site)/backend/.env" "$(site)/.mroom-new-dead/backend/.env"
  put; expect_rc 0
  run cat "$(site)/backend/.env"; expect_out "APP_KEY=base64:live"
  expect_true "a scratch folder stayed" no_leftovers
}

t_dist_put_replaces_the_web_folder() {
  world
  mkdir -p "$T/dist/assets"
  printf '<html></html>\n' >"$T/dist/index.html"
  printf 'x\n' >"$T/dist/assets/app.js"
  printf 'SECRET=1\n' >"$T/dist/.env"
  tar -czf "$T/dist.tgz" -C "$T/dist" .
  gate provision "dist-put 12" <"$T/dist.tgz"
  expect_rc 0; expect_out "$WEB: 2 entries unpacked, 1 .env skipped"
  expect_file "$T/homes/shop_qa_12/$WEB/index.html"
  expect_file "$T/homes/shop_qa_12/$WEB/assets/app.js"
  expect_no_file "$T/homes/shop_qa_12/$WEB/old.html"
  expect_no_file "$T/homes/shop_qa_12/$WEB/.env"
  run tail -n 1 "$T/sudo.log"; expect_out "-n -u shop_qa_12 -- $T/libexec/site-op unpack dist $WEB"
}

t_signin_code_comes_from_the_app_for_persona_addresses_only() {
  world
  gate provision "signin-code 12 ada@example.test"
  expect_rc 1; expect_err_has "the tree has neither .mroom/hooks/qa-signin nor artisan"
  repo_tarball; put
  gate provision "signin-code 12 ada@example.test"; expect_rc 0; expect_out 123456
  gate provision "signin-code 12 someone@customer.example"
  expect_rc 1; expect_err_has "not a persona address ending in .test"
  expect_true "a refused address reached the log" lacks "$(gate_log_text)" "customer.example"
  printf '#!/bin/sh\necho "not a code!"\n' >"$(site)/.mroom/hooks/qa-signin"
  gate provision "signin-code 12 ada@example.test"; expect_rc 1; expect_err_has "the app gave no code (exit 0)"
  printf 'MROOM_QA_PERSONA_DOMAIN=.personas.example\n' >>"$HOME/.config/mroom/box.env"
  gate provision "signin-code 12 ada@example.test"; expect_rc 1; expect_err_has "ending in .personas.example"
}

t_user_clean_runs_only_as_a_qa_sites_user() {
  world
  mkdir -p "$HOME/.local/state/mroom/qa"
  echo "$COMMIT" >"$HOME/.local/state/mroom/qa/shop_qa_12.commit"
  # site-op runs as the test's own user here, which is no QA site's: it refuses before stopping anything.
  gate provision "user-clean 12"; expect_rc 1; expect_err_has "is not a QA site's isolated user"
  gate provision "user-clean 99"; expect_rc 0; expect_out "no user shop_qa_99, so nothing to clean"
  echo "$COMMIT" >"$HOME/.local/state/mroom/qa/shop_qa_99.commit"
  gate provision "user-clean 99"; expect_rc 0
  expect_no_file "$HOME/.local/state/mroom/qa/shop_qa_99.commit"
}

t_the_gate_checks_the_site_user_and_the_installed_helper() {
  world; repo_tarball
  gate provision "code-put 14 $COMMIT"; expect_rc 1; expect_err_has "shop_qa_14 is not one of Forge's isolated users"
  gate provision "code-put 99 $COMMIT"; expect_rc 1; expect_err_has "there is no user shop_qa_99"
  gate provision "code-put 12 abc1234"; expect_rc 1; expect_err_has "is not a full commit SHA"
  chmod 755 "$T/libexec/site-op"
  put; expect_rc 1; expect_err_has "must belong to root, and $(id -un) must not be able to change it"
  chmod 644 "$T/libexec/site-op"; echo "# changed" >>"$T/libexec/site-op"; chmod 444 "$T/libexec/site-op"
  put; expect_rc 1; expect_err_has "is not this release's site-op; install it again"
  rm -f "$T/libexec/site-op"
  put; expect_rc 1; expect_err_has "site-op is not installed"
  printf 'MROOM_APP_NAME=shop\n' >"$HOME/.config/mroom/box.env"
  put; expect_rc 1; expect_err_has "MROOM_QA_ZONE is not set in box.env"
  printf 'MROOM_APP_NAME=a_long_application_name_of_25\nMROOM_QA_ZONE=qa.example.test\n' >"$HOME/.config/mroom/box.env"
  gate provision "env-sha 123456"; expect_rc 1; expect_err_has "is longer than a user name may be (32)"
  expect_true "site-op ran" eval '[ ! -s "$T/sudo.log" ]'
  expect_true "the site changed" unchanged
}

t_one_site_request_at_a_time_per_environment() {
  world; repo_tarball
  export MROOM_GATE_LOCK_WAIT=0
  mkdir -p "$HOME/.local/state/mroom"
  exec 8>"$HOME/.local/state/mroom/gate-site-shop_qa_12.lock"
  flock 8
  put; expect_rc 1; expect_err_has "another request for site-shop_qa_12 is still running"
  exec 8>&-
  put; expect_rc 0
}

test_case code-put t_code_put_replaces_the_tree_and_keeps_env_and_storage
test_case second-put t_a_second_put_replaces_the_first
test_case env-sha t_env_sha_reports_the_env_hash_and_the_recorded_commit
test_case hostile-tarballs t_a_tarball_of_another_commit_or_shape_changes_nothing
test_case size-limits t_size_limits_refuse_before_unpacking
test_case modes t_unpacked_files_lose_setuid_and_dirs_stay_removable
test_case interrupted-put t_an_interrupted_put_is_recovered
test_case dist-put t_dist_put_replaces_the_web_folder
test_case signin-code t_signin_code_comes_from_the_app_for_persona_addresses_only
test_case user-clean t_user_clean_runs_only_as_a_qa_sites_user
test_case gate-checks t_the_gate_checks_the_site_user_and_the_installed_helper
test_case one-request-per-environment t_one_site_request_at_a_time_per_environment
finish
