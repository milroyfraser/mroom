#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2016  # t_* run through test_case; a $ in single quotes is for eval, later
# Tests for the gate's site operations (code-put, dist-put, env-put, env-sha, signin-code, probe-link, user-clean) and
# lib/site-op, which does their work as the site's user. Offline: a fake sudo checks the gate's arguments,
# then runs the real site-op as the test's own user, with HOME at a fake site home and MROOM_SITE_OP_USER
# naming the site user it plays. Hostile tarballs are made with Python's tarfile, since tar will not write
# most of them. tests/site/gate-real-test.sh runs the same gate with real users, sudo and PHP-FPM in CI.
set -euo pipefail
SUITE=site
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# The tests leave read-only folders (the site-op copy's), which rm -rf cannot empty.
trap 'chmod -R u+w "$TOP" 2>/dev/null; rm -rf "$TOP"' EXIT
skip_unless has_box_tools "this host lacks bash 5, flock or GNU date, which box commands need"

COMMIT=abc1234def5678abc1234def5678abc1234def56
SITE="api.12.qa.example.test"
WEB="12.qa.example.test"

# world: box.env, a root-like copy of site-op in a folder the box user cannot change, the site user's home
# with a live tree, and fakes for sudo, id and logger.
world() {
  mkdir -p "$HOME/.config/mroom" "$T/bin" "$T/libexec"
  printf 'MROOM_APP_NAME=shop\nMROOM_QA_ZONE=qa.example.test\nMROOM_QA_BACKEND_DIR=backend\n' >"$HOME/.config/mroom/box.env"
  cp "$ROOT/lib/site-op" "$T/libexec/site-op"
  chmod 555 "$T/libexec/site-op" "$T/libexec"
  export MROOM_GATE_SITE_OP="$T/libexec/site-op" MROOM_GATE_SITE_OP_OWNER
  MROOM_GATE_SITE_OP_OWNER="$(id -u)"
  printf 'shop_qa_12 shop_qa_12 isolated\nshop_qa_13 shop_qa_13 isolated\nshop_qa_14 shop_qa_14\n' >"$T/users"
  live_tree
  cat >"$T/bin/sudo" <<'FAKE'
#!/usr/bin/env bash
# Insists on `sudo -n -u <user> -- <site-op> ...`, then runs site-op as the test's own user with HOME at
# that user's home under $T/homes, playing that user, and no SUDO_UID, so site-op takes that HOME.
printf '%s\n' "$*" >>"$T/sudo.log"
if [ "$1" != -n ] || [ "$2" != -u ] || [ "$4" != -- ]; then echo "fake sudo: unexpected arguments: $*" >&2; exit 1; fi
user="$3"
shift 4
exec env -u SUDO_UID -u SUDO_USER HOME="$T/homes/$user" MROOM_SITE_OP_USER="$user" "$@"
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

# live_tree: the site as qa-up leaves it before a put: its .env, an upload in storage, an old file.
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
# symlink, hardlink, fifo, setuid (a file with mode 4755) or pax (a file with a 2 MiB pax record).
craft() {
  python3 - "$@" <<'PY'
import io, sys, tarfile
out, entries = sys.argv[1], sys.argv[2:]
with tarfile.open(out, "w:gz", format=tarfile.PAX_FORMAT) as tf:
    for entry in entries:
        kind, name, *rest = entry.split(":")
        info = tarfile.TarInfo(name)
        data = None
        if kind in ("file", "setuid", "pax"):
            data = b"x\n"
            info.size, info.mode = len(data), 0o4755 if kind == "setuid" else 0o644
            if kind == "pax":
                info.pax_headers = {"comment": "x" * (2 << 20)}
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
# site_op <user> <args...>: site-op run directly, playing that site user, as a box user could run it.
site_op() { local user="$1"; shift; run env HOME="$T/homes/$user" MROOM_SITE_OP_USER="$user" "$ROOT/lib/site-op" "$@"; }
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
lacks() { ! has "$@"; }
site() { echo "$T/homes/shop_qa_12/$SITE"; }
no_leftovers() { ! compgen -G "$(site)/.mroom-*" >/dev/null && ! compgen -G "$T/homes/shop_qa_12/$WEB/.mroom-*" >/dev/null; }
unchanged() {
  [ -f "$(site)/old-file" ] && [ "$(cat "$(site)/backend/.env")" = "APP_KEY=base64:live" ] \
    && [ "$(cat "$(site)/backend/storage/app/photo.jpg")" = uploaded ]
}
gate_log_text() { cat "$HOME/.local/state/mroom/gate.log" 2>/dev/null || true; }
# snapshot: the live tree's every path, type and mode, and the kept items' content.
snapshot() {
  (cd "$(site)" && find . -path './.mroom-*' -prune -o -printf '%p %y %m\n' | sort
    cat backend/.env backend/storage/app/photo.jpg 2>/dev/null) || true
}
tree_is() { [ "$(snapshot)" = "$1" ]; }
# park <backend>: a scratch tree a put killed mid-swap left, its marker naming that backend folder.
park() { mkdir -p "$(site)/.mroom-new-dead/backend"; printf 'code %s\n' "$1" >"$(site)/.mroom-new-dead/.mroom-put"; }
put() { gate provision "code-put 12 $COMMIT" <"${1:-$T/code.tgz}"; }
recorded() { cat "$HOME/.local/state/mroom/qa/shop_qa_12.commit" 2>/dev/null || echo none; }

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
  run recorded; expect_out "$COMMIT"
  run tail -n 1 "$T/sudo.log"; expect_out "-n -u shop_qa_12 -- $T/libexec/site-op unpack code $SITE backend $COMMIT"
  expect_true "a scratch folder stayed" no_leftovers
  expect_true "the put is not logged" has "$(gate_log_text)" "code-put 12: $COMMIT into $SITE"
}

# The version file is the gate's, never the tree's: a PR's own version.json, naming another commit or a link to a
# file it should not read, is replaced, and env-sha reports what the gate recorded, whatever the site writes later.
t_the_version_file_is_the_gates() {
  world; repo_tarball
  local top="$T/src/example-shop-${COMMIT:0:7}" other=ffffffffffffffffffffffffffffffffffffffff
  printf '{"release": "v9.9.9", "commit": "%s"}\n' "$other" >"$top/backend/version.json"
  tar -czf "$T/code.tgz" -C "$T/src" "example-shop-${COMMIT:0:7}"
  put; expect_rc 0
  run cat "$(site)/backend/version.json"; expect_out "{\"release\": null, \"commit\": \"$COMMIT\"}"
  # A link inside the tree, which the data filter lets through (one to an absolute path refuses the tarball).
  rm "$top/backend/version.json"; ln -s ../README.md "$top/backend/version.json"
  tar -czf "$T/code.tgz" -C "$T/src" "example-shop-${COMMIT:0:7}"
  put; expect_rc 0
  expect_true "the version file is a link" eval '[ ! -L "$(site)/backend/version.json" ]'
  run cat "$(site)/README.md"; expect_out readme
  run cat "$(site)/backend/version.json"; expect_out "{\"release\": null, \"commit\": \"$COMMIT\"}"
  # The site's code may write the file later: env-sha does not read it.
  printf '{"release": null, "commit": "%s"}\n' "$other" >"$(site)/backend/version.json"
  gate provision "env-sha 12"; expect_rc 0; expect_out_has "commit=$COMMIT"
}

t_a_second_put_replaces_the_first() {
  world; repo_tarball; put; expect_rc 0
  rm "$T/src/example-shop-${COMMIT:0:7}/README.md"
  tar -czf "$T/code.tgz" -C "$T/src" "example-shop-${COMMIT:0:7}"
  put; expect_rc 0
  expect_no_file "$(site)/README.md"
  run cat "$(site)/backend/.env"; expect_out "APP_KEY=base64:live"
}

t_a_failed_step_puts_everything_back() {
  world; repo_tarball
  local before n=1
  before="$(snapshot)"
  # Each step of a put in turn: the kept items into the new tree, then each entry exchanged, placed or
  # retired. Every failure leaves the tree exactly as it was; the first step that is not there succeeds.
  while MROOM_SITE_OP_FAIL_STEP="$n" put; [ "$rc" != 0 ] && [ "$n" -le 20 ]; do
    expect_err_has "No space left on device (a test's)"
    expect_true "a put failing at step $n changed the site" tree_is "$before"
    expect_true "a put failing at step $n left a scratch folder" no_leftovers
    expect_true "a put failing at step $n kept a recorded commit" eval '[ "$(recorded)" = none ]'
    n=$((n + 1))
  done
  expect_true "a put took only $((n - 1)) steps" [ "$n" -gt 5 ]
  expect_rc 0
  expect_file "$(site)/README.md"
  expect_no_file "$(site)/old-file"
}

t_a_put_survives_the_sites_own_writes() {
  world; repo_tarball
  # Laravel's logger runs mkdir -p storage/logs at any moment, here as fast as it can, through every put.
  : >"$T/writing"
  (while [ -e "$T/writing" ]; do mkdir -p "$T/homes/shop_qa_12/$SITE/backend/storage/logs" 2>/dev/null; done) &
  local writer=$! i failed=0
  for i in $(seq 1 25); do
    put
    if [ "$rc" != 0 ]; then failed=$((failed + 1)); echo "    put $i: $err" >&2; fi
    if [ "$(cat "$(site)/backend/storage/app/photo.jpg" 2>/dev/null)" != uploaded ]; then failed=$((failed + 1)); fi
  done
  rm -f "$T/writing"
  wait "$writer" 2>/dev/null || true
  expect_true "$failed puts failed or lost the upload while the site wrote" [ "$failed" = 0 ]
  run cat "$(site)/backend/.env"; expect_out "APP_KEY=base64:live"
}

t_an_interrupted_put_is_recovered() {
  world; repo_tarball
  # A put that died mid-swap: its new tree holds the live .env, and the live tree has none.
  park backend
  mkdir -p "$(site)/.mroom-old-dead/x"
  mv "$(site)/backend/.env" "$(site)/.mroom-new-dead/backend/.env"
  put; expect_rc 0
  run cat "$(site)/backend/.env"; expect_out "APP_KEY=base64:live"
  expect_true "a scratch folder stayed" no_leftovers
}

t_a_kept_item_the_site_made_again_is_set_aside_not_deleted() {
  world; repo_tarball
  # A put died with storage parked in its new tree; since then the app wrote a log into a fresh storage.
  park backend
  mv "$(site)/backend/storage" "$(site)/.mroom-new-dead/backend/storage"
  mkdir -p "$(site)/backend/storage/logs"
  printf 'log\n' >"$(site)/backend/storage/logs/laravel.log"
  put; expect_rc 0
  expect_out_has "backend/storage from an interrupted put are live again; the copies the site made meanwhile stay in .mroom-kept-"
  expect_out_has "1 set-aside copies (.mroom-kept-*) wait for a person"
  run cat "$(site)/backend/storage/app/photo.jpg"; expect_out uploaded
  expect_true "the site's own log was deleted" compgen -G "$(site)/.mroom-kept-*/backend/storage/logs/laravel.log"
}

t_a_scratch_tree_of_unknown_origin_or_another_backend_is_kept() {
  world; repo_tarball
  mkdir -p "$(site)/.mroom-new-old/backend/storage/app"
  printf 'precious\n' >"$(site)/.mroom-new-old/backend/storage/app/doc.pdf"
  put; expect_rc 0
  expect_out_has "a scratch tree of an unknown put stays in .mroom-kept-"
  expect_true "the unknown scratch tree was deleted" compgen -G "$(site)/.mroom-kept-*/backend/storage/app/doc.pdf"
  park app
  printf 'other\n' >"$(site)/.mroom-new-dead/backend/marker"
  put; expect_rc 0
  expect_out_has "a put for the backend folder app was interrupted; its scratch tree stays in .mroom-kept-"
  expect_out_has "2 set-aside copies (.mroom-kept-*) wait for a person"
}

t_a_backend_without_its_search_bit_keeps_env_and_storage() {
  world; repo_tarball
  chmod 600 "$(site)/backend"
  put; expect_rc 0
  run cat "$(site)/backend/.env"; expect_out "APP_KEY=base64:live"
  run cat "$(site)/backend/storage/app/photo.jpg"; expect_out uploaded
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
  rm "$(site)/backend/.env"; mkfifo "$(site)/backend/.env"
  gate provision "env-sha 12"; expect_rc 0; expect_out_has "env=missing"
  rm "$(site)/backend/.env"; truncate -s 2M "$(site)/backend/.env"
  gate provision "env-sha 12"; expect_rc 1; expect_err_has "the .env is larger than 1048576 bytes"
}

t_env_put_writes_the_env_as_the_site_user_without_following_a_link() {
  world
  printf 'secret\n' >"$T/target"
  rm "$(site)/backend/.env"; ln -s "$T/target" "$(site)/backend/.env"
  # Input from files, not pipes: a pipe would run gate, and so run, in a subshell.
  printf 'APP_KEY=base64:new\nDB_PASSWORD=pw\n' >"$T/new.env"
  gate provision "env-put 12" <"$T/new.env"
  expect_rc 0; expect_out "env=$(printf '%s' $'APP_KEY=base64:new\nDB_PASSWORD=pw' | sha256sum | cut -d' ' -f1)"
  expect_true "the .env is still a link" eval '[ ! -L "$(site)/backend/.env" ]'
  run cat "$T/target"; expect_out secret
  run stat -c %a "$(site)/backend/.env"; expect_out 600
  gate provision "env-sha 12"; expect_out_has "env=$(printf '%s' $'APP_KEY=base64:new\nDB_PASSWORD=pw' | sha256sum | cut -d' ' -f1)"
  expect_true "the .env reached the log" lacks "$(gate_log_text)" "DB_PASSWORD"
  head -c 70000 /dev/zero | tr '\0' a >"$T/big.env"
  gate provision "env-put 12" <"$T/big.env"; expect_rc 1; expect_err_has "the .env is larger than 65536 bytes"
  gate provision "env-put 12" </dev/null; expect_rc 1; expect_err_has "no .env came on stdin"
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
    "symlink:$top/backend:elsewhere" "hardlink:$top/backend/h:/etc/passwd" "hardlink:$top/backend/h:$top/backend/.env" \
    "hardlink:$top/backend/h:$top/backend/later" "fifo:$top/backend/pipe" "file:$top/.mroom-new-x/backend/.env" \
    "pax:$top/backend/big"; do
    craft "$T/bad.tgz" "dir:$top" "file:$top/backend/artisan" "file:$top/backend/.env" "$bad" "file:$top/backend/later"
    put "$T/bad.tgz"; expect_rc 1
    expect_true "a refused tarball ($bad) changed the site" unchanged
    expect_true "a refused tarball ($bad) left a scratch folder" no_leftovers
  done
  expect_true "nothing was recorded" eval '[ "$(recorded)" = none ]'
}

t_a_cut_off_or_padded_upload_is_refused() {
  world; repo_tarball
  head -c "$(($(stat -c %s "$T/code.tgz") - 20))" "$T/code.tgz" >"$T/cut.tgz"
  put "$T/cut.tgz"; expect_rc 1
  expect_true "a cut-off upload changed the site" unchanged
  tar -cf "$T/padded.tar" -C "$T/src" "example-shop-${COMMIT:0:7}"
  head -c 2097152 /dev/zero >>"$T/padded.tar"
  gzip -c "$T/padded.tar" >"$T/padded.tgz"
  put "$T/padded.tgz"; expect_rc 1; expect_err_has "the tarball has data after its end"
  expect_true "a refused upload left a scratch folder or itself" no_leftovers
}

t_size_limits_refuse_before_unpacking() {
  world; repo_tarball
  MROOM_SITE_OP_MAX_TARBALL=100 put; expect_rc 1; expect_err_has "the tarball is larger than 100 bytes"
  expect_true "a refused upload stayed" no_leftovers
  MROOM_SITE_OP_MAX_MEMBERS=3 put; expect_rc 1; expect_err_has "the tarball holds more than 3 entries"
  MROOM_SITE_OP_MAX_UNPACKED=5 put; expect_rc 1; expect_err_has "the tarball unpacks to more than 5 bytes"
  expect_true "a refused tarball changed the site" unchanged
  gate provision "code-put 12 $COMMIT" </dev/null; expect_rc 1; expect_err_has "no tarball came on stdin"
  expect_true "an empty upload stayed" no_leftovers
}

t_a_sparse_entry_is_refused() {
  world
  local top="$T/src/example-shop-${COMMIT:0:7}"
  mkdir -p "$top/backend"
  printf '#!/usr/bin/env php\n' >"$top/backend/artisan"
  truncate -s 1M "$top/backend/hole"
  tar --sparse --format=gnu -czf "$T/sparse.tgz" -C "$T/src" "example-shop-${COMMIT:0:7}"
  put "$T/sparse.tgz"; expect_rc 1; expect_err_has "the tarball has a sparse entry"
  expect_true "a refused tarball changed the site" unchanged
}

t_unpacked_files_lose_setuid_and_dirs_stay_removable() {
  world
  local top="example-shop-${COMMIT:0:7}"
  craft "$T/modes.tgz" "dir:$top" "file:$top/backend/artisan" "setuid:$top/backend/tool"
  put "$T/modes.tgz"; expect_rc 0
  run stat -c %a "$(site)/backend/tool"; expect_out 755
}

t_site_op_works_only_on_its_own_environments_sites() {
  world; repo_tarball
  site_op shop_qa_12 unpack dist "$SITE" <"$T/code.tgz"; expect_rc 1; expect_err_has "is not this environment's 12.<zone> site"
  site_op shop_qa_12 unpack code "$WEB" backend "$COMMIT" <"$T/code.tgz"; expect_rc 1; expect_err_has "is not this environment's api.12.<zone> site"
  site_op shop_qa_12 env-sha api.13.qa.example.test backend; expect_rc 1; expect_err_has "is not this environment's api.12.<zone> site"
  site_op shop_qa_12 env-sha api.123.qa.example.test backend; expect_rc 1; expect_err_has "is not this environment's api.12.<zone> site"
  site_op shop_qa_12 unpack dist 123.qa.example.test <"$T/code.tgz"; expect_rc 1; expect_err_has "is not this environment's 12.<zone> site"
  # The names of before mroom 0.5.0 are no environment's sites now.
  site_op shop_qa_12 env-sha api-12.qa.example.test backend; expect_rc 1; expect_err_has "is not this environment's api.12.<zone> site"
  site_op shop_qa_12 unpack dist go-12.qa.example.test <"$T/code.tgz"; expect_rc 1; expect_err_has "is not this environment's 12.<zone> site"
  site_op forge env-sha "$SITE" backend; expect_rc 1; expect_err_has "forge is not a QA site's isolated user"
  expect_true "a refused call changed the site" unchanged
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
  gate provision "signin-code someone@customer.example 12"; expect_rc 1
  expect_true "a refused address reached the log" lacks "$(gate_log_text)" "customer.example"
  printf '#!/bin/sh\necho "not a code!"\n' >"$(site)/.mroom/hooks/qa-signin"
  gate provision "signin-code 12 ada@example.test"; expect_rc 1; expect_err_has "the app gave no code (exit 0)"
  printf 'MROOM_QA_PERSONA_DOMAIN=.personas.example\n' >>"$HOME/.config/mroom/box.env"
  gate provision "signin-code 12 ada@example.test"; expect_rc 1; expect_err_has "ending in .personas.example"
}

t_signin_code_does_not_wait_on_what_the_app_leaves_running() {
  world; repo_tarball; put
  # The hook prints its code and leaves a child holding its output open.
  printf '#!/bin/sh\n(sleep 31.7) &\necho 654321\n' >"$(site)/.mroom/hooks/qa-signin"
  local start=$SECONDS
  gate provision "signin-code 12 ada@example.test"
  expect_rc 0; expect_out 654321
  expect_true "signin-code waited on the child" [ $((SECONDS - start)) -lt 10 ]
  sleep 0.5
  expect_true "the child kept running" eval '! pgrep -f "sleep 31.7" >/dev/null'
}

t_probe_link_puts_a_link_to_site_op_at_each_web_root() {
  world
  local api="$T/homes/shop_qa_12/$SITE/backend/public" web="$T/homes/shop_qa_12/$WEB"
  # Before any code: the api site's web root is made, and the link goes in it, to the installed site-op.
  gate provision "probe-link 12 api"
  expect_rc 0
  expect_out "sha256=$(sha256sum "$T/libexec/site-op" | cut -d' ' -f1)"$'\n'"target=$T/libexec/site-op"
  run readlink "$api/mroom-symlink-probe"; expect_out "$T/libexec/site-op"
  gate provision "probe-link 12 web"
  expect_rc 0
  run readlink "$web/mroom-symlink-probe"; expect_out "$T/libexec/site-op"
  # Again: the same link, replaced, and nothing else left beside it.
  gate provision "probe-link 12 api"; expect_rc 0
  run bash -c 'ls -A "$1" | sort' _ "$api"; expect_out "mroom-symlink-probe"
  # The next put replaces the tree, and the link goes with it.
  repo_tarball
  put
  expect_rc 0
  expect_no_file "$api/mroom-symlink-probe"
  # A web root reached through a link, which the PR's code could have left, is refused.
  rm -rf "$api"
  ln -s /tmp "$api"
  gate provision "probe-link 12 api"; expect_rc 1; expect_err_has "goes through a link"
  gate provision "probe-link 12 both"; expect_rc 1; expect_err_has "its second argument is api or web"
  gate provision "probe-link 12"; expect_rc 1
  # Only a QA site's own user puts it, in its own site.
  site_op shop_qa_12 probe-link api.13.qa.example.test backend; expect_rc 1; expect_err_has "is not this environment's api.12.<zone> site"
  site_op forge probe-link "$WEB"; expect_rc 1; expect_err_has "forge is not a QA site's isolated user"
  # What site-op says is passed on only as a file's SHA-256 and path: a release whose site-op says anything else.
  mkdir -p "$T/release"
  cp -R "$ROOT/bin" "$ROOT/lib" "$T/release/"
  sed -i 's/^    print(f"{digest} {target}")$/    print("linked it")/' "$T/release/lib/site-op"
  grep -q '^    print("linked it")$' "$T/release/lib/site-op" || fail "the other site-op was not written"
  chmod u+w "$T/libexec" "$T/libexec/site-op"
  cp "$T/release/lib/site-op" "$T/libexec/site-op"
  chmod 555 "$T/libexec/site-op" "$T/libexec"
  run env SSH_ORIGINAL_COMMAND="probe-link 12 web" "$T/release/bin/mroom" gate provision
  expect_rc 1; expect_err_has "site-op named no file and SHA-256"
}

t_user_clean_runs_only_as_a_qa_sites_user() {
  world
  mkdir -p "$HOME/.local/state/mroom/qa"
  echo "$COMMIT" >"$HOME/.local/state/mroom/qa/shop_qa_12.commit"
  # site-op's clean looks at the user it really runs as, here the test's own: it refuses before stopping
  # anything, whatever MROOM_SITE_OP_USER says.
  gate provision "user-clean 12"; expect_rc 1; expect_err_has "is not a QA site's isolated user"
  gate provision "user-clean 99"; expect_rc 0; expect_out "no user shop_qa_99, so nothing to clean"
  echo "$COMMIT" >"$HOME/.local/state/mroom/qa/shop_qa_99.commit"
  printf 'DB_PASSWORD=%048d\nAPP_KEY=base64:kept\n' 0 >"$HOME/.local/state/mroom/qa/shop_qa_99.secrets"
  gate provision "user-clean 99"; expect_rc 0
  expect_no_file "$HOME/.local/state/mroom/qa/shop_qa_99.commit"
  # The app key goes with the site user; the database's password goes with the database.
  run cat "$HOME/.local/state/mroom/qa/shop_qa_99.secrets"; expect_out "DB_PASSWORD=$(printf '%048d' 0)"
}

t_the_gate_checks_the_site_user_and_the_installed_helper() {
  world; repo_tarball
  gate provision "code-put 14 $COMMIT"; expect_rc 1; expect_err_has "shop_qa_14 is not one of Forge's isolated users"
  gate provision "code-put 99 $COMMIT"; expect_rc 1; expect_err_has "there is no user shop_qa_99"
  gate provision "code-put 12 abc1234"; expect_rc 1; expect_err_has "is not a full commit SHA"
  chmod 755 "$T/libexec"
  put; expect_rc 1; expect_err_has "$T/libexec must belong to root, and $(id -un) must not be able to change it"
  chmod 555 "$T/libexec"; chmod 755 "$T/libexec/site-op"
  put; expect_rc 1; expect_err_has "site-op must belong to root, and $(id -un) must not be able to change it"
  chmod 644 "$T/libexec/site-op"; echo "# changed" >>"$T/libexec/site-op"; chmod 444 "$T/libexec/site-op"
  put; expect_rc 1; expect_err_has "is not this release's site-op; install it again"
  chmod 755 "$T/libexec"; rm -f "$T/libexec/site-op"; ln -s "$ROOT/lib/site-op" "$T/libexec/site-op"; chmod 555 "$T/libexec"
  put; expect_rc 1; expect_err_has "site-op is not installed, or is a link"
  chmod 755 "$T/libexec"; rm -f "$T/libexec/site-op"
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
  gate provision "signin-code 12 ada@example.test"; expect_rc 1; expect_err_has "another request for site-shop_qa_12"
  exec 8>&-
  put; expect_rc 0
}

test_case code-put t_code_put_replaces_the_tree_and_keeps_env_and_storage
test_case version-file t_the_version_file_is_the_gates
test_case second-put t_a_second_put_replaces_the_first
test_case failed-step t_a_failed_step_puts_everything_back
test_case concurrent-writes t_a_put_survives_the_sites_own_writes
test_case interrupted-put t_an_interrupted_put_is_recovered
test_case kept-item-set-aside t_a_kept_item_the_site_made_again_is_set_aside_not_deleted
test_case unknown-scratch-tree t_a_scratch_tree_of_unknown_origin_or_another_backend_is_kept
test_case no-search-bit t_a_backend_without_its_search_bit_keeps_env_and_storage
test_case env-sha t_env_sha_reports_the_env_hash_and_the_recorded_commit
test_case env-put t_env_put_writes_the_env_as_the_site_user_without_following_a_link
test_case hostile-tarballs t_a_tarball_of_another_commit_or_shape_changes_nothing
test_case cut-or-padded t_a_cut_off_or_padded_upload_is_refused
test_case size-limits t_size_limits_refuse_before_unpacking
test_case sparse t_a_sparse_entry_is_refused
test_case modes t_unpacked_files_lose_setuid_and_dirs_stay_removable
test_case own-sites-only t_site_op_works_only_on_its_own_environments_sites
test_case dist-put t_dist_put_replaces_the_web_folder
test_case signin-code t_signin_code_comes_from_the_app_for_persona_addresses_only
test_case signin-code-children t_signin_code_does_not_wait_on_what_the_app_leaves_running
test_case probe-link t_probe_link_puts_a_link_to_site_op_at_each_web_root
test_case user-clean t_user_clean_runs_only_as_a_qa_sites_user
test_case gate-checks t_the_gate_checks_the_site_user_and_the_installed_helper
test_case one-request-per-environment t_one_site_request_at_a_time_per_environment
finish
