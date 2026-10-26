#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2016  # t_* run through test_case; a $ in single quotes is for eval, later
# The gate's site operations with real users and sudo, set up as the README says: what the fake sudo cannot
# show. A box user holding nothing but the one sudoers line plays forge; Forge-style isolated users own the
# sites, and site-op is a root-owned copy. site-op unpacks as the site user and keeps .env and storage; a
# hostile tarball changes nothing; signin-code runs the app's artisan; user-clean stops one site user's
# processes and removes its files in /tmp and /dev/shm, leaving another's alone; and the sudoers line gives
# the box user nothing else. CI only: it adds users and a sudoers file, so tests/run.sh does not pick it up.
set -euo pipefail
SUITE=site-real
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

BOX_USER=mroombox
ZONE=qa.example.test
COMMIT=abc1234def5678abc1234def5678abc1234def56
trap 'sudo pkill -KILL -u shop_qa_13 >/dev/null 2>&1 || true; sudo rm -f /etc/sudoers.d/mroom-gate; rm -rf "$TOP"' EXIT

as_box() { sudo -u "$BOX_USER" -H "$@"; }
gate() { run sudo -u "$BOX_USER" -H env SSH_ORIGINAL_COMMAND="$1" /opt/mroom/bin/mroom gate provision; }
site() { echo "/home/shop_qa_$1/api-$1.$ZONE"; }

# set_up: users, mroom where any user can read it (as an installed release is), site-op owned by root,
# the sudoers line, box.env, and two sites as Forge leaves them.
set_up() {
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
  printf '%s ALL=(%%isolated) NOPASSWD: /usr/local/libexec/mroom/site-op\n' "$BOX_USER" | sudo tee /etc/sudoers.d/mroom-gate >/dev/null
  sudo chmod 440 /etc/sudoers.d/mroom-gate
  sudo visudo -cf /etc/sudoers.d/mroom-gate >/dev/null
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
import io, sys, tarfile
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
  local out12

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

  # user-clean: two environments' processes and files; only environment 12's go.
  local n
  for n in 12 13; do
    sudo -u "shop_qa_$n" setsid sleep 600 >/dev/null 2>&1 &
    sudo -u "shop_qa_$n" sh -c "echo x >/tmp/qa$n-file; mkdir -p /tmp/qa$n-dir/sub; echo y >/tmp/qa$n-dir/sub/f; echo z >/dev/shm/qa$n-shm"
  done
  for _ in $(seq 1 20); do
    if pgrep -u shop_qa_12 -x sleep >/dev/null && pgrep -u shop_qa_13 -x sleep >/dev/null; then break; fi
    sleep 0.25
  done
  gate "user-clean 12"; expect_rc 0; expect_out_has "shop_qa_12: "
  out12="$out"
  expect_true "a process of environment 12 still runs: $out12" eval '! pgrep -u shop_qa_12 >/dev/null'
  expect_true "environment 12's files stayed: $out12" eval '! sudo test -e /tmp/qa12-file && ! sudo test -e /tmp/qa12-dir && ! sudo test -e /dev/shm/qa12-shm'
  expect_true "environment 13's process was stopped" pgrep -u shop_qa_13 -x sleep
  expect_true "environment 13's files went" sudo test -f /tmp/qa13-file
  expect_true "environment 12's site files went with the clean" sudo test -f "$(site 12)/backend/.env"
  expect_true "the recorded commit stayed" eval '! sudo test -e "/home/$BOX_USER/.local/state/mroom/qa/shop_qa_12.commit"'

  gate "user-clean 14"; expect_rc 1; expect_err_has "shop_qa_14 is not one of Forge's isolated users"

  # The sudoers line runs site-op as an isolated user and nothing else, never as root.
  expect_true "the box user ran a shell as a site user" eval '! as_box sudo -n -u shop_qa_12 /bin/sh -c id >/dev/null 2>&1'
  expect_true "the box user ran site-op as root" eval '! as_box sudo -n -u root /usr/local/libexec/mroom/site-op clean >/dev/null 2>&1'
  expect_true "the box user ran site-op as a user outside the isolated group" \
    eval '! as_box sudo -n -u shop_qa_14 /usr/local/libexec/mroom/site-op clean >/dev/null 2>&1'
}

test_case real-site-users t_the_site_operations_with_real_users_and_sudo
finish
