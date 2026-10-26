#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2016  # t_* run through test_case; a $ in single quotes is for eval, later
# The gate's site operations with real users, sudo and PHP-FPM, set up as the README says: what the fake
# sudo cannot show. A box user holding nothing but the one sudoers line plays forge; Forge-style isolated
# users own the sites, and site-op is a root-owned copy. site-op unpacks as the site user and keeps .env and
# storage; env-put replaces a planted link; a hostile tarball changes nothing; signin-code runs the app's
# artisan; user-clean leaves a real PHP-FPM pool's workers (their master replaces them) but stops everything
# else and removes the user's files, and reports what keeps coming back; and the sudoers line gives the box
# user nothing more. It runs as a user with sudo (CI's runner) or as root in a container with sudo-rs.
# CI only: it adds users and a sudoers file, so tests/run.sh does not pick it up.
set -euo pipefail
SUITE=site-real
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

BOX_USER=mroombox
ZONE=qa.example.test
COMMIT=abc1234def5678abc1234def5678abc1234def56
FPM=""
WRITING="/tmp/mroom-writing-$$"
cleanup() {
  rm -f "$TOP/respawn" "$WRITING"
  if [ -n "$FPM" ] && [ -f "$TOP/fpm.pid" ]; then sudo kill "$(cat "$TOP/fpm.pid")" 2>/dev/null || true; fi
  sudo pkill -KILL -u shop_qa_12 >/dev/null 2>&1 || true
  sudo pkill -KILL -u shop_qa_13 >/dev/null 2>&1 || true
  sudo rm -f /etc/sudoers.d/mroom-gate
  rm -rf "$TOP"
}
trap cleanup EXIT

as_box() { sudo -u "$BOX_USER" "$@"; }
gate() { run sudo -u "$BOX_USER" env SSH_ORIGINAL_COMMAND="$1" /opt/mroom/bin/mroom gate provision; }
site() { echo "/home/shop_qa_$1/api-$1.$ZONE"; }
pool_workers() { pgrep -c -u shop_qa_12 -f 'pool shop_qa_12' || true; }

# set_up: users, mroom where any user can read it (as an installed release is), site-op owned by root,
# the sudoers line, box.env, and two sites as Forge leaves them.
set_up() {
  sudo --version | head -n 1
  sudo groupadd -f isolated
  sudo useradd -m -s /bin/bash "$BOX_USER"
  local n
  for n in 12 13; do
    sudo useradd -m -s /bin/bash -G isolated "shop_qa_$n"
    sudo chmod 750 "/home/shop_qa_$n"
  done
  sudo useradd -m -s /bin/bash shop_qa_14
  sudo rm -rf /opt/mroom
  sudo cp -r "$ROOT" /opt/mroom
  sudo chmod -R a+rX /opt/mroom
  sudo install -d -o root -g root -m 755 /usr/local/libexec/mroom
  sudo install -o root -g root -m 755 /opt/mroom/lib/site-op /usr/local/libexec/mroom/site-op
  printf '%s ALL=(%%isolated) NOPASSWD: /usr/local/libexec/mroom/site-op\n' "$BOX_USER" >"$T/sudoers"
  if command -v visudo >/dev/null; then sudo visudo -cf "$T/sudoers" >/dev/null; fi
  sudo install -o root -g root -m 440 "$T/sudoers" /etc/sudoers.d/mroom-gate
  as_box mkdir -p "/home/$BOX_USER/.config/mroom"
  printf 'MROOM_APP_NAME=shop\nMROOM_QA_ZONE=%s\nMROOM_QA_BACKEND_DIR=backend\nMROOM_QA_PHP=php\n' "$ZONE" \
    | as_box tee "/home/$BOX_USER/.config/mroom/box.env" >/dev/null
  for n in 12 13; do
    sudo -u "shop_qa_$n" mkdir -p "$(site "$n")/backend/storage/app" "/home/shop_qa_$n/go-$n.$ZONE"
    printf 'APP_KEY=base64:live%s\n' "$n" | sudo -u "shop_qa_$n" tee "$(site "$n")/backend/.env" >/dev/null
    printf 'uploaded\n' | sudo -u "shop_qa_$n" tee "$(site "$n")/backend/storage/app/photo.jpg" >/dev/null
    printf 'old\n' | sudo -u "shop_qa_$n" tee "$(site "$n")/old-file" >/dev/null
  done
}

# start_fpm: a real PHP-FPM pool running as shop_qa_12, as Forge gives an isolated site: a root master
# that replaces any worker that dies.
start_fpm() {
  local f
  for f in /usr/sbin/php-fpm*; do
    if [ -x "$f" ]; then FPM="$f"; break; fi
  done
  [ -n "$FPM" ] || { echo "no php-fpm found" >&2; exit 1; }
  cat >"$T/fpm.conf" <<EOF
[global]
pid = $TOP/fpm.pid
error_log = $T/fpm.log
daemonize = yes
[shop_qa_12]
user = shop_qa_12
group = shop_qa_12
listen = $T/fpm-12.sock
pm = static
pm.max_children = 2
EOF
  sudo "$FPM" -y "$T/fpm.conf"
  for _ in $(seq 1 40); do
    if [ "$(pool_workers)" = 2 ]; then return 0; fi
    sleep 0.25
  done
  echo "PHP-FPM started no workers" >&2
  exit 1
}

# repo_tarball: GitHub's tarball of the PR's tree, with an artisan that answers mroom:signin-code.
repo_tarball() {
  local top="$T/src/example-shop-${COMMIT:0:7}"
  mkdir -p "$top/backend/public" "$top/backend/storage/app"
  printf '<?php echo "ok";\n' >"$top/backend/public/index.php"
  cat >"$top/backend/artisan" <<'PHP'
<?php
// A stand-in for Laravel's artisan: `mroom:signin-code <email>` prints a line, then the code.
if (($argv[1] ?? '') === 'mroom:signin-code' && str_ends_with($argv[2] ?? '', '.test')) {
    echo "Signing in {$argv[2]}\n654321\n";
    exit(0);
}
exit(1);
PHP
  printf 'COMMITTED=1\n' >"$top/backend/.env"
  printf 'readme\n' >"$top/README.md"
  tar -czf "$T/code.tgz" -C "$T/src" "example-shop-${COMMIT:0:7}"
  python3 - "$T/hostile.tgz" "example-shop-${COMMIT:0:7}" <<'PY'
import sys, tarfile
out, top = sys.argv[1], sys.argv[2]
with tarfile.open(out, "w:gz") as tf:
    for name in (top, f"{top}/backend"):
        info = tarfile.TarInfo(name)
        info.type, info.mode = tarfile.DIRTYPE, 0o755
        tf.addfile(info)
    link = tarfile.TarInfo(f"{top}/backend/secret")
    link.type, link.linkname = tarfile.SYMTYPE, "/home/mroombox/.config/mroom/box.env"
    tf.addfile(link)
PY
}

t_the_site_operations_with_real_users_and_sudo() {
  set_up
  repo_tarball
  local box_env n

  gate "code-put 12 $COMMIT" <"$T/code.tgz"
  expect_rc 0; expect_out "api-12.$ZONE: 3 entries unpacked, 1 .env skipped"
  run sudo stat -c %U "$(site 12)/backend/public/index.php"; expect_out shop_qa_12
  run sudo cat "$(site 12)/backend/.env"; expect_out "APP_KEY=base64:live12"
  run sudo cat "$(site 12)/backend/storage/app/photo.jpg"; expect_out uploaded
  run sudo cat "$(site 12)/backend/version.json"; expect_out "{\"release\": null, \"commit\": \"$COMMIT\"}"
  expect_true "the old tree stayed" eval '! sudo test -e "$(site 12)/old-file"'
  expect_true "the box user read the site's files itself" eval '! as_box cat "$(site 12)/backend/.env" >/dev/null 2>&1'

  gate "env-sha 12"; expect_rc 0
  expect_out "env=$(printf '%s' 'APP_KEY=base64:live12' | sha256sum | cut -d' ' -f1)"$'\n'"commit=$COMMIT"

  # The PR's code plants a link at .env; env-put replaces it and never writes through it.
  box_env="$(sudo cat "/home/$BOX_USER/.config/mroom/box.env")"
  sudo -u shop_qa_12 ln -sfn "/home/$BOX_USER/.config/mroom/box.env" "$(site 12)/backend/.env"
  printf 'APP_KEY=base64:put12\n' >"$T/put.env"
  gate "env-put 12" <"$T/put.env"
  expect_rc 0; expect_out "env=$(printf '%s' 'APP_KEY=base64:put12' | sha256sum | cut -d' ' -f1)"
  run sudo stat -c '%U %a %F' "$(site 12)/backend/.env"; expect_out "shop_qa_12 600 regular file"
  run sudo cat "/home/$BOX_USER/.config/mroom/box.env"; expect_out "$box_env"

  # The site's own code writing all the while (Laravel's logger runs mkdir -p storage/logs): every put still
  # succeeds and keeps the upload live, since each entry is exchanged in one step.
  : >"$WRITING"
  sudo -u shop_qa_12 bash -c "while [ -e '$WRITING' ]; do mkdir -p '$(site 12)/backend/storage/logs' 2>/dev/null; done" &
  local i failed=0
  for i in $(seq 1 10); do
    gate "code-put 12 $COMMIT" <"$T/code.tgz"
    if [ "$rc" != 0 ]; then failed=$((failed + 1)); echo "    put $i: $err" >&2; fi
    if [ "$(sudo cat "$(site 12)/backend/storage/app/photo.jpg" 2>/dev/null)" != uploaded ]; then failed=$((failed + 1)); fi
  done
  rm -f "$WRITING"
  expect_true "$failed puts failed or lost the upload while the site wrote" [ "$failed" = 0 ]

  gate "code-put 12 $COMMIT" <"$T/hostile.tgz"
  expect_rc 1; expect_err_has "refused"
  expect_true "a refused tarball changed the site" sudo test -f "$(site 12)/README.md"

  gate "signin-code 12 ada@example.test"; expect_rc 0; expect_out 654321

  mkdir -p "$T/dist/assets"
  printf '<html></html>\n' >"$T/dist/index.html"
  printf 'x\n' >"$T/dist/assets/app.js"
  tar -czf "$T/dist.tgz" -C "$T/dist" .
  gate "dist-put 12" <"$T/dist.tgz"; expect_rc 0
  run sudo stat -c %U "/home/shop_qa_12/go-12.$ZONE/assets/app.js"; expect_out shop_qa_12

  # user-clean: environment 12 has a PHP-FPM pool, a stray process and files outside its home; environment
  # 13 has a process and a file too. The pool's workers stay, everything else of 12's goes, 13 is untouched.
  start_fpm
  for n in 12 13; do
    sudo -u "shop_qa_$n" setsid sleep 600 >/dev/null 2>&1 &
    sudo -u "shop_qa_$n" sh -c "echo x >/tmp/qa$n-file; mkdir -p /tmp/qa$n-dir/sub; echo y >/tmp/qa$n-dir/sub/f; echo z >/dev/shm/qa$n-shm"
  done
  for _ in $(seq 1 20); do
    if pgrep -u shop_qa_12 -x sleep >/dev/null && pgrep -u shop_qa_13 -x sleep >/dev/null; then break; fi
    sleep 0.25
  done
  gate "user-clean 12"; expect_rc 0
  expect_out_has "2 PHP-FPM pool workers stopped once"
  expect_out_has "fresh ones left, which stop when the site goes"
  expect_true "environment 12's stray process still runs" eval '! pgrep -u shop_qa_12 -x sleep >/dev/null'
  for _ in $(seq 1 20); do
    if [ "$(pool_workers)" = 2 ]; then break; fi
    sleep 0.25
  done
  expect_true "the pool's master did not replace its workers" [ "$(pool_workers)" = 2 ]
  expect_true "environment 12's files stayed" eval '! sudo test -e /tmp/qa12-file && ! sudo test -e /tmp/qa12-dir && ! sudo test -e /dev/shm/qa12-shm'
  expect_true "environment 13's process was stopped" pgrep -u shop_qa_13 -x sleep
  expect_true "environment 13's files went" sudo test -f /tmp/qa13-file
  expect_true "environment 12's site files went with the clean" sudo test -f "$(site 12)/backend/.env"
  expect_true "the recorded commit stayed" eval '! sudo test -e "/home/$BOX_USER/.local/state/mroom/qa/shop_qa_12.commit"'

  # Something outside the pool that keeps restarting a process is reported, and the files still go.
  : >"$TOP/respawn"
  sudo bash -c "while [ -e '$TOP/respawn' ]; do sudo -u shop_qa_12 sleep 7.3; done" >/dev/null 2>&1 &
  sudo -u shop_qa_12 sh -c 'echo again >/tmp/qa12-again'
  for _ in $(seq 1 20); do
    if pgrep -u shop_qa_12 -f 'sleep 7.3' >/dev/null; then break; fi
    sleep 0.25
  done
  gate "user-clean 12"; expect_rc 1; expect_err_has "other processes kept coming back"
  expect_true "the files did not go while a process kept coming back" eval '! sudo test -e /tmp/qa12-again'
  rm -f "$TOP/respawn"

  gate "user-clean 14"; expect_rc 1; expect_err_has "shop_qa_14 is not one of Forge's isolated users"

  # The sudoers line runs site-op as an isolated user and nothing else, never as root.
  expect_true "the box user ran a shell as a site user" eval '! as_box sudo -n -u shop_qa_12 /bin/sh -c id >/dev/null 2>&1'
  expect_true "the box user ran site-op as root" eval '! as_box sudo -n -u root /usr/local/libexec/mroom/site-op clean >/dev/null 2>&1'
  expect_true "the box user ran site-op as a user outside the isolated group" \
    eval '! as_box sudo -n -u shop_qa_14 /usr/local/libexec/mroom/site-op clean >/dev/null 2>&1'
}

test_case real-site-users t_the_site_operations_with_real_users_and_sudo
finish
