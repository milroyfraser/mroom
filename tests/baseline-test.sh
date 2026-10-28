#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2016  # t_* run through test_case; a $ in single quotes is for eval, later
# Tests for `mroom baseline`: a QA service's build is installed only when its archive and its binary match
# their SHA-256 pins, mroom's mail relay goes beside it, logins are made once, mode 600, from hashes openssl
# really gave, and the three systemd units are written and compared with the installed ones. The services live
# in folders the root recipe makes, and a box whose services lived in the home moves their data there once.
# Offline: curl is a fake that serves a test archive. tests/mail/gate-real-test.sh installs the real pinned
# Mailpit.
set -euo pipefail
SUITE=baseline
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
stop_all() {
  local f
  for f in "$TOP"/*/garage.pid "$TOP"/*/old.pid; do if [ -s "$f" ]; then kill "$(cat "$f")" 2>/dev/null || true; fi; done
  chmod -R u+w "$TOP" 2>/dev/null
  rm -rf "$TOP"
}
trap stop_all EXIT
skip_unless has_box_tools "this host lacks bash 5, flock or GNU date, which box commands need"

platform() {
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) echo linux-amd64 ;;
    *) echo linux-arm64 ;;
  esac
}
sha() { sha256sum "$1" | cut -d' ' -f1; }
REAL_CURL="$(command -v curl)"
# shellcheck disable=SC2034  # read by the tests
read -ra MAILPIT_TREE <<<"$(bash -c '. "$1"; echo "${MAILPIT_TREE[*]}"' _ "$ROOT/lib/root-setup")"

# world [--no-tree]: a test build of "mailpit" and its archive, pins for them, a fake curl serving the archive,
# a box.env naming a free SMTP port, and the services' folders as the root recipe makes them (not with
# --no-tree).
world() {
  if [ "${1:-}" != --no-tree ]; then services_tree --locked; fi
  mkdir -p "$T/bin" "$T/build" "$T/served" "$HOME/.config/mroom"
  printf '#!/bin/sh\necho mailpit\n' >"$T/build/mailpit"
  chmod 755 "$T/build/mailpit"
  printf 'readme\n' >"$T/build/README.md"
  tar -czf "$T/served/mailpit.tgz" -C "$T/build" mailpit README.md
  # Garage ships as a bare binary.
  printf '#!/bin/sh\necho garage\n' >"$T/served/garage"
  GARAGE_SHA="$(sha "$T/served/garage")"
  pins "$(sha "$T/served/mailpit.tgz")" "$(sha "$T/build/mailpit")"
  PORT=$((20000 + RANDOM % 30000))
  while (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; do PORT=$((PORT + 1)); done
  printf 'MROOM_QA_SMTP_PORT=%s\n' "$PORT" >"$HOME/.config/mroom/box.env"
  cat >"$T/bin/curl" <<'FAKE'
#!/usr/bin/env bash
# Logs each call; serves https://example.test/mailpit.tgz and https://example.test/garage into --output, and
# Mailpit's /livez on its Unix socket only when $T/live exists. Calls to Garage's admin socket go to the real
# curl, and so to tests/fakes/garage.py when a test runs it.
printf '%s\n' "$*" >>"$T/curl.log"
args=("$@") out="" socket="" url="${!#}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) out="$2"; shift 2 ;;
    --unix-socket) socket="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [ "$socket" = "$T/services/garage/run/admin.sock" ]; then exec "$REAL_CURL" "${args[@]}"; fi
case "$url" in
  https://example.test/mailpit.tgz) cp "$T/served/mailpit.tgz" "$out" ;;
  https://example.test/garage) cp "$T/served/garage" "$out" ;;
  http://localhost/livez)
    [ "$socket" = "$T/services/mailpit/run/http.sock" ] && [ -e "$T/live" ] || exit 7 ;;
  *) echo "fake curl: no such URL $url" >&2; exit 22 ;;
esac
FAKE
  # systemctl: logs every call, and calls every unit inactive.
  printf '#!/bin/sh\necho "systemctl $*" >>"$T/systemctl.log"\n[ "$1" != is-active ] || { echo inactive; exit 3; }\n' >"$T/bin/systemctl"
  chmod +x "$T/bin/curl" "$T/bin/systemctl"
  export T PATH="$T/bin:$PATH" MROOM_PINS="$T/pins.txt" MROOM_SYSTEMD_DIR="$T/systemd" REAL_CURL
}

# root_install <part...>: what mroom's root recipe does, here into the test's own folders (lib/root-setup),
# whose folders above the services' are the box user's only in a test: mode 555 again afterwards.
root_install() {
  mkdir -p "$T/systemd" "$T/libexec" "$T/sudoers"
  chmod u+w "$T/services" "$T/services"/* 2>/dev/null || true
  run env MROOM_ROOT_SETUP_TEST=1 MROOM_LIBEXEC_DIR="$T/libexec" MROOM_SUDOERS_DIR="$T/sudoers" MROOM_ROOT_STATE_DIR="$T/state" \
    MROOM_SERVICES_DIR="$T/services" "$ROOT/lib/root-setup" --user "$(id -un)" --smtp-port "${PORT:-1025}" "$@"
  chmod 555 "$T/services" "$T/services"/*
}

# pins <archive sha> <binary sha> [<platform>] [<url>]
pins() {
  printf '# test pins\nmailpit v9.9.9 %s %s %s %s\ngarage v8.8.8 %s %s %s https://example.test/garage\n' \
    "${3:-$(platform)}" "$1" "$2" "${4:-https://example.test/mailpit.tgz}" "$(platform)" "$GARAGE_SHA" "$GARAGE_SHA" >"$T/pins.txt"
}

# hash_of <password> <hash>: whether the SHA-512 crypt hash is of the password.
hash_of() { [ "$(printf '%s' "$1" | openssl passwd -6 -salt "$(cut -d'$' -f3 <<<"$2")" -stdin)" = "$2" ]; }
hex48() { [[ "$1" =~ ^[0-9a-f]{48}$ ]]; }
lacks() { case "$1" in *"$2"*) return 1 ;; esac; return 0; }
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
services() { echo "$T/services"; }
secrets() { echo "$HOME/.config/mroom/secrets"; }
etc() { echo "$T/services/$1/etc"; }
old() { echo "$HOME/.local/share/mroom-services"; }
downloads() { local n; n="$(grep -c 'example.test/mailpit.tgz' "$T/curl.log" 2>/dev/null)" || true; echo "${n:-0}"; }
mode() { stat -c %a "$1"; }
api_password() { sed -n 's/^MAILPIT_API_PASSWORD=//p' "$(secrets)/mailpit.env"; }
api_hash() { sed -n 's/^mroom-gate://p' "$(etc mailpit)/mailpit-ui.passwd"; }

t_mailpit_is_installed_at_its_pin_with_its_relay_and_logins() {
  world
  run "$MROOM" baseline mailpit
  expect_rc 0
  expect_out_has "mailpit v9.9.9: installed, SHA-256 $(sha "$T/build/mailpit")"
  expect_out_has "mail relay: installed"
  run cat "$(services)/mailpit/builds/current/mailpit"; expect_out "$(cat "$T/build/mailpit")"
  run readlink "$(services)/mailpit/builds/current"; expect_out v9.9.9
  run mode "$(services)/mailpit/builds/v9.9.9/mailpit"; expect_out 700
  expect_true "the relay is not this mroom's" cmp -s "$ROOT/lib/mail-relay" "$(services)/mail-relay/bin/mail-relay"
  run mode "$(services)/mail-relay/bin/mail-relay"; expect_out 700
  local file
  for file in "$(etc mailpit)/mailpit-smtp.passwd" "$(etc mailpit)/mailpit-ui.passwd" "$(secrets)/mailpit.env"; do
    run mode "$file"; expect_out 600
  done
  for file in "$(services)/mailpit/builds" "$(services)/mailpit/data" "$(services)/mailpit/etc" "$(services)/mailpit/run" \
    "$(services)/mail-relay/bin" "$(secrets)"; do
    run mode "$file"; expect_out 700
  done
  # Nothing of Mailpit's is left in the home, where its unit could not bind it.
  expect_no_file "$(secrets)/mailpit-smtp.passwd"; expect_no_file "$(secrets)/mailpit-ui.passwd"; expect_no_file "$(old)"
  expect_true "the SMTP logins hold no placeholder login" grep -qE '^mroom-none:\$6\$' "$(etc mailpit)/mailpit-smtp.passwd"
  # The API login's hash is of the password the gate keeps.
  local password
  password="$(api_password)"
  expect_true "the API password is not 48 hex characters" hex48 "$password"
  expect_true "the API login's hash is not of the gate's password" hash_of "$password" "$(api_hash)"
  expect_true "the download could be sent to a plain-http address" grep -q -- "--proto-redir =https" "$T/curl.log"
  run "$MROOM" baseline mailpit
  expect_out_has "Mailpit does not answer yet."
  expect_out_has "Nothing listens on 127.0.0.1:$PORT yet."
  expect_true "the password reached the output" lacks "$out" "$password"
  # Root installs the units with mroom's root recipe, from a release (lib/root-setup): baseline only says
  # which are missing or out of date, and prints nothing to run as root.
  expect_out_has "To be installed or updated: mroom-mail-relay.socket mroom-mail-relay.service mroom-mailpit.service."
  expect_out_has "Root installs them with mroom's root recipe (README, \"The root recipe\"): mailpit in its parts, smtp_port=$PORT."
  expect_out_has "Take its v and sum from the README of the latest release on GitHub, never from this box"
  expect_out_has "This box runs mroom v$(cat "$ROOT/VERSION"): upgrade it to that release first."
  expect_out_has "This mroom was installed from a checkout, not a release"
  expect_true "baseline printed a unit to run as root" lacks "$out" "ExecStart="
  expect_true "baseline printed a script to run as root" lacks "$out" "systemctl "
  expect_no_file "$(services)/units"
  # MROOM_SYSTEMD_DIR, a setting for tests, moves where baseline looks: it says so, loudly.
  expect_out_has "WARNING: MROOM_SYSTEMD_DIR is set, so this compares the units in $T/systemd, not /etc/systemd/system"
  expect_out_has "WARNING: MROOM_SERVICES_DIR is set, so the services live in $T/services, not /var/lib/mroom/services"
  # Without box.env's port, the relay takes 1025.
  rm "$HOME/.config/mroom/box.env"
  run "$MROOM" baseline mailpit
  expect_out_has "mailpit in its parts, smtp_port=1025."
}

t_installed_units_are_compared_with_what_this_mroom_writes() {
  world
  run "$MROOM" baseline mailpit; expect_rc 0
  # What the root recipe installs is what baseline expects.
  root_install mailpit; expect_rc 0
  run "$MROOM" baseline mailpit; expect_rc 0
  expect_out_has "systemd units: installed as this mroom writes them (mroom-mail-relay.socket inactive, mroom-mail-relay.service inactive, mroom-mailpit.service inactive)."
  expect_true "installed units asked to be installed again" lacks "$out" "To be installed"
  # A unit that changed is named.
  printf '# a local change\n' >>"$T/systemd/mroom-mailpit.service"
  run "$MROOM" baseline mailpit; expect_rc 0
  expect_out_has "To be installed or updated: mroom-mailpit.service."
  root_install mailpit; expect_rc 0
  # A new port: the socket and the relay, which both name it.
  printf 'MROOM_QA_SMTP_PORT=%s\n' "$((PORT + 1))" >"$HOME/.config/mroom/box.env"
  run "$MROOM" baseline mailpit; expect_rc 0
  expect_out_has "To be installed or updated: mroom-mail-relay.socket mroom-mail-relay.service."
  expect_out_has "mailpit in its parts, smtp_port=$((PORT + 1))."
  printf 'MROOM_QA_SMTP_PORT=%s\n' "$PORT" >"$HOME/.config/mroom/box.env"
  # Something that is not systemd on the port: say so before the units are installed.
  python3 -I -c 'import socket, sys, time
s = socket.create_server(("127.0.0.1", int(sys.argv[1]))); time.sleep(30)' "$PORT" &
  local listener=$!
  for _ in $(seq 1 50); do (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && break; sleep 0.1; done
  run "$MROOM" baseline mailpit; expect_rc 0
  expect_out_has "Something else listens on 127.0.0.1:$PORT (user $(id -u)): stop it before installing the units"
  kill "$listener" 2>/dev/null || true
}

t_a_login_file_it_cannot_read_or_a_busy_gate_stops_it() {
  world
  run "$MROOM" baseline mailpit; expect_rc 0
  local logins before
  logins="$(etc mailpit)/mailpit-smtp.passwd"
  before="$(cat "$logins")"
  chmod 000 "$logins"
  run "$MROOM" baseline mailpit
  chmod 600 "$logins"
  expect_rc 1; expect_err_has "cannot read $(etc mailpit)/mailpit-smtp.passwd"
  run cat "$logins"; expect_out "$before"
  # The gate holds Mailpit's lock while it changes a login: baseline waits for it, then gives up.
  mkdir -p "$HOME/.local/state/mroom"
  flock "$HOME/.local/state/mroom/gate-mailpit.lock" sleep 20 &
  local holder=$!
  sleep 0.3
  MROOM_GATE_LOCK_WAIT=1 run "$MROOM" baseline mailpit
  expect_rc 1; expect_err_has "the gate is still changing Mailpit's logins"
  kill "$holder" 2>/dev/null || true
}

t_a_second_run_keeps_the_build_the_relay_and_the_logins() {
  world
  run "$MROOM" baseline mailpit; expect_rc 0
  local before
  before="$(cat "$(secrets)/mailpit.env" "$(etc mailpit)/mailpit-ui.passwd" "$(etc mailpit)/mailpit-smtp.passwd")"
  : >"$T/live"
  run "$MROOM" baseline mailpit; expect_rc 0
  expect_out_has "mailpit v9.9.9: installed, and matches its pin"
  expect_out_has "mail relay: installed, and matches this mroom"
  expect_out_has "Mailpit answers."
  expect_true "a kept login asked for a restart" lacks "$out" "reads its API login"
  run downloads; expect_out 1
  run cat "$(secrets)/mailpit.env" "$(etc mailpit)/mailpit-ui.passwd" "$(etc mailpit)/mailpit-smtp.passwd"; expect_out "$before"
  expect_true "a second run said it moved something" lacks "$out" "moved"
  # A relay that is not this mroom's is replaced; systemd's relay runs it from its next start.
  printf '# changed\n' >>"$(services)/mail-relay/bin/mail-relay"
  run "$MROOM" baseline mailpit; expect_rc 0
  expect_out_has "mail relay: updated"
  expect_out_has "mail relay: runs the new one from its next start (mroom-mail-relay.service)"
  expect_true "the relay was not replaced" cmp -s "$ROOT/lib/mail-relay" "$(services)/mail-relay/bin/mail-relay"
}

t_the_api_login_is_kept_or_rewritten_from_its_password() {
  world
  run "$MROOM" baseline mailpit; expect_rc 0
  local password
  password="$(api_password)"
  : >"$T/live"
  # Mailpit's copy of the hash gone: rewritten from the same password, and Mailpit must read it again.
  rm "$(etc mailpit)/mailpit-ui.passwd"
  run "$MROOM" baseline mailpit; expect_rc 0
  expect_out_has "API login: its hash for Mailpit rewritten from ~/.config/mroom/secrets/mailpit.env"
  expect_out_has "Mailpit: runs its build and reads its API login from its next start (mroom-mailpit.service)"
  run api_password; expect_out "$password"
  expect_true "the rewritten hash is not of the password" hash_of "$password" "$(api_hash)"
  printf 'mroom-gate:$6$a$b\n' >"$(etc mailpit)/mailpit-ui.passwd"
  run "$MROOM" baseline mailpit; expect_rc 0; expect_out_has "API login: its hash for Mailpit rewritten"
  expect_true "the rewritten hash is not of the password" hash_of "$password" "$(api_hash)"
  # The gate's copy gone: a new password, since a hash cannot give the old one back.
  rm "$(secrets)/mailpit.env"
  run "$MROOM" baseline mailpit; expect_rc 0
  expect_out_has "API login: ~/.config/mroom/secrets/mailpit.env made"
  expect_true "the password stayed after its file went" [ "$(api_password)" != "$password" ]
  expect_true "the new hash is not of the new password" hash_of "$(api_password)" "$(api_hash)"
}

t_the_placeholder_login_is_put_back_and_kept_whole() {
  world
  printf 'shop_qa_12:$6$a$b\nmroom-none:\n' >"$(etc mailpit)/mailpit-smtp.passwd"
  chmod 600 "$(etc mailpit)/mailpit-smtp.passwd"
  run "$MROOM" baseline mailpit; expect_rc 0
  expect_out_has "SMTP logins: the placeholder login restored"
  run grep -c '^mroom-none:' "$(etc mailpit)/mailpit-smtp.passwd"; expect_out 1
  expect_true "the placeholder login is not a SHA-512 crypt hash" \
    grep -qE '^mroom-none:\$6\$[A-Za-z0-9./]+\$[A-Za-z0-9./]+$' "$(etc mailpit)/mailpit-smtp.passwd"
  expect_true "an environment's login was lost" grep -qxF 'shop_qa_12:$6$a$b' "$(etc mailpit)/mailpit-smtp.passwd"
}

t_a_hash_openssl_did_not_give_is_never_written() {
  world
  printf '#!/bin/sh\ncat >/dev/null\necho not-a-hash\n' >"$T/bin/openssl"
  chmod +x "$T/bin/openssl"
  run "$MROOM" baseline mailpit
  expect_rc 1; expect_err_has "openssl gave no SHA-512 crypt hash; nothing changed"
  expect_no_file "$(etc mailpit)/mailpit-smtp.passwd"
  expect_no_file "$(etc mailpit)/mailpit-ui.passwd"
  expect_no_file "$(secrets)/mailpit.env"
  run bash -c 'compgen -G "$1/.baseline.*" || compgen -G "$2/.baseline.*" || true' _ "$(secrets)" "$(etc mailpit)"; expect_out ""
}

t_a_build_that_does_not_match_its_pin_is_not_installed() {
  world
  pins "$(printf '0%.0s' $(seq 64))" "$(sha "$T/build/mailpit")"
  run "$MROOM" baseline mailpit
  expect_rc 1; expect_err_has "the download's SHA-256 is $(sha "$T/served/mailpit.tgz"), not the pinned"
  expect_err_has "nothing installed"
  expect_no_file "$(services)/mailpit/builds/v9.9.9/mailpit"
  pins "$(sha "$T/served/mailpit.tgz")" "$(printf 'f%.0s' $(seq 64))"
  run "$MROOM" baseline mailpit
  expect_rc 1; expect_err_has "the binary's SHA-256 is $(sha "$T/build/mailpit"), not the pinned"
  expect_no_file "$(services)/mailpit/builds/v9.9.9/mailpit"
  tar -czf "$T/served/mailpit.tgz" -C "$T/build" README.md
  pins "$(sha "$T/served/mailpit.tgz")" "$(sha "$T/build/mailpit")"
  run "$MROOM" baseline mailpit
  expect_rc 1; expect_err_has "the archive holds no mailpit binary"
  expect_no_file "$(services)/mailpit/builds/v9.9.9/mailpit"
  expect_no_file "$(secrets)/mailpit.env"
}

t_a_missing_or_malformed_pin_is_refused() {
  world
  pins "$(sha "$T/served/mailpit.tgz")" "$(sha "$T/build/mailpit")" linux-mips
  run "$MROOM" baseline mailpit; expect_rc 1; expect_err_has "pins no mailpit build for $(platform)"
  pins "$(sha "$T/served/mailpit.tgz")" "$(sha "$T/build/mailpit")" "$(platform)" http://example.test/mailpit.tgz
  run "$MROOM" baseline mailpit; expect_rc 1; expect_err_has "the mailpit pin's URL is not a plain https URL"
  pins short "$(sha "$T/build/mailpit")"
  run "$MROOM" baseline mailpit; expect_rc 1; expect_err_has "is malformed"
  run downloads; expect_out 0
}

t_the_committed_pins_are_well_formed() {
  local platform count=0 line name archive binary url service
  while read -r line; do
    case "$line" in "" | \#*) continue ;; esac
    count=$((count + 1))
    expect_true "a pin is malformed: $line" \
      eval '[[ "$line" =~ ^[a-z]+\ +v[0-9.]+\ +linux-(amd64|arm64)\ +[0-9a-f]{64}\ +[0-9a-f]{64}\ +https://(github\.com|garagehq\.deuxfleurs\.fr)/[A-Za-z0-9._/-]+$ ]]'
    # A bare binary (its URL ends in its name) is its own archive: its two hashes are one.
    read -r name _ _ archive binary url <<<"$line"
    if [ "${url##*/}" = "$name" ]; then
      expect_true "the bare $name binary has two hashes: $line" [ "$archive" = "$binary" ]
    fi
  done <"$ROOT/lib/core/pins.txt"
  expect_true "the pins file pins nothing" [ "$count" -ge 4 ]
  for service in mailpit garage; do
    for platform in linux-amd64 linux-arm64; do
      expect_true "no $service pin for $platform" grep -qE "^$service +v[0-9.]+ +$platform " "$ROOT/lib/core/pins.txt"
    done
  done
}

# garage_up: tests/fakes/garage.py on Garage's sockets, playing its admin API.
garage_up() {
  local run="$T/services/garage/run"
  python3 -I "$ROOT/tests/fakes/garage.py" "$run/admin.sock" "$run/s3.sock" "$T/services/garage/etc/garage-admin-token" \
    "$T/garage.log" >"$T/garage.out" 2>&1 &
  echo $! >"$T/garage.pid"
  for _ in $(seq 1 50); do grep -q up "$T/garage.out" 2>/dev/null && return 0; sleep 0.1; done
  cat "$T/garage.out" >&2
  return 1
}

t_garage_is_installed_with_its_config_secrets_and_unit() {
  world
  printf 'MROOM_QA_ZONE=qa.example.dev\n' >>"$HOME/.config/mroom/box.env"
  run "$MROOM" baseline garage
  expect_rc 0
  expect_out_has "garage v8.8.8: installed, SHA-256 $GARAGE_SHA"
  local base secrets
  base="$(services)/garage" secrets="$(etc garage)"
  run cat "$base/builds/current/garage"; expect_out "$(cat "$T/served/garage")"
  run mode "$base/builds/v8.8.8/garage"; expect_out 700
  for file in "$base/builds" "$base/etc" "$base/meta" "$base/data" "$base/run"; do run mode "$file"; expect_out 700; done
  for file in garage-rpc-secret garage-admin-token garage-metrics-token; do run mode "$secrets/$file"; expect_out 600; done
  run cat "$secrets/garage-rpc-secret"; expect_true "the RPC secret is not 32 bytes of hex" eval '[[ "$out" =~ ^[0-9a-f]{64}$ ]]'
  run mode "$secrets/garage.toml"; expect_out 600
  # Its config names its secrets' files, never a secret, and Unix sockets for every endpoint but RPC.
  for line in "metadata_dir = \"$base/meta\"" "data_dir = \"$base/data\"" "replication_factor = 1" "metadata_fsync = true" \
    'rpc_bind_addr = "127.0.0.1:3901"' "rpc_secret_file = \"$secrets/garage-rpc-secret\"" \
    "api_bind_addr = \"$base/run/s3.sock\"" "bind_addr = \"$base/run/web.sock\"" 'root_domain = ".web.mroom.invalid"' \
    "api_bind_addr = \"$base/run/admin.sock\"" "admin_token_file = \"$secrets/garage-admin-token\""; do
    expect_true "the config lacks: $line" grep -qxF -- "$line" "$secrets/garage.toml"
  done
  expect_true "a secret is in the config" eval '! grep -qF "$(cat "$secrets/garage-admin-token")" "$secrets/garage.toml"'
  run "$MROOM" baseline garage
  expect_out_has "To be installed or updated: mroom-garage.service."
  expect_out_has "Root installs them with mroom's root recipe (README, \"The root recipe\"): garage in its parts."
  root_install garage; expect_rc 0
  run "$MROOM" baseline garage
  expect_out_has "systemd units: installed as this mroom writes them (mroom-garage.service inactive)."
  expect_out_has "Garage does not answer yet: install its unit (the root recipe), then run mroom baseline garage again"
  # The two hosts' nginx configs, on Garage's sockets.
  expect_out_has "s3.qa.example.dev, the S3 API"
  expect_out_has "proxy_pass http://unix:$base/run/s3.sock;"
  expect_out_has "files.qa.example.dev, public files"
  expect_out_has 'proxy_set_header Host $bucket.web.mroom.invalid;'
  # Bodies stream to Garage (HTTP/1.1), so nginx stores no unsigned upload; nothing else catches a path; the
  # Host a client signed reaches Garage as it sent it; and a website redirect keeps the bucket in the path.
  local lines
  lines="$(awk '{ sub(/^ +/, ""); print }' <<<"$out")"
  expect_true "the configs lack a ^~ / block each" eval '[ "$(grep -c -xF "location ^~ / {" <<<"$lines")" = 2 ]'
  expect_true "a config lets nginx keep a copy of an answer" \
    eval '[ "$(grep -c -xF "proxy_max_temp_file_size 0;" <<<"$lines")" = 2 ]'
  for line in "client_max_body_size 5g;" "proxy_http_version 1.1;" "proxy_request_buffering off;" \
    'proxy_set_header Host $http_host;' "client_max_body_size 1k;" 'proxy_redirect ~^/(.*)$ /$bucket/$1;' \
    "absolute_redirect off;"; do
    expect_true "the nginx configs lack: $line" grep -qxF -- "$line" <<<"$lines"
  done
  # nginx reads a bare { as a block: a regex with a count in it must be quoted.
  expect_out_has 'location ~ "^/([a-z0-9][a-z0-9-]{1,61}[a-z0-9])(/.*)$" {'
  expect_out_has "proxy_pass http://unix:$base/run/web.sock;"
}

t_garage_keeps_its_secrets_and_sets_its_layout_once() {
  world
  run "$MROOM" baseline garage; expect_rc 0
  expect_out_has "Set MROOM_QA_ZONE in box.env, and run this again for the nginx configs"
  local before
  before="$(cat "$(etc garage)"/garage-*)"
  garage_up
  run "$MROOM" baseline garage; expect_rc 0
  expect_out_has "garage v8.8.8: installed, and matches its pin"
  expect_out_has "Garage answers; its layout now holds this node."
  expect_true "a kept config was written again" lacks "$out" "Garage config:"
  run cat "$(etc garage)"/garage-*; expect_out "$before"
  run bash -c 'printf "Authorization: Bearer %s\n" "$(cat "$1")" | "$2" -q -s --unix-socket "$3" --header @- http://localhost/test/state' _ \
    "$(etc garage)/garage-admin-token" "$REAL_CURL" "$(services)/garage/run/admin.sock"
  run jq -c '.layout | {version, zones: [.roles[].zone]}' <<<"$out"; expect_out '{"version":1,"zones":["box"]}'
  run "$MROOM" baseline garage; expect_rc 0
  expect_out_has "Garage answers; its layout holds one node."
  kill "$(cat "$T/garage.pid")" 2>/dev/null || true
}

# Until the root recipe has made a part's folders, baseline installs nothing, and says how to run it; a folder
# that is not as the recipe makes it stops it.
t_the_folders_must_be_as_the_root_recipe_makes_them() {
  world --no-tree
  run "$MROOM" baseline mailpit
  expect_rc 1
  expect_out_has "The folders of mailpit are not in place yet: root makes them in /var/lib/mroom/services, with its systemd units."
  expect_out_has "Root installs them with mroom's root recipe (README, \"The root recipe\"): mailpit in its parts, smtp_port=$PORT."
  run downloads; expect_out 0
  expect_no_file "$(secrets)/mailpit.env"
  services_tree "${MAILPIT_TREE[@]}"
  # A folder that is a link, or one in a folder the box user can change: not as root makes them.
  rmdir "$(services)/mailpit/data"
  mkdir "$T/elsewhere"
  ln -s "$T/elsewhere" "$(services)/mailpit/data"
  chmod 555 "$(services)" "$(services)/mailpit" "$(services)/mail-relay"
  run "$MROOM" baseline mailpit
  expect_rc 1; expect_err_has "$(services)/mailpit/data is not as mroom's root recipe makes it: a folder of $(id -un)'s own, in a folder only root can change; nothing changed"
  chmod 755 "$(services)/mailpit"
  rm "$(services)/mailpit/data"; mkdir -m 700 "$(services)/mailpit/data"
  run "$MROOM" baseline mailpit
  expect_rc 1; expect_err_has "$(services)/mailpit/builds is not as mroom's root recipe makes it"
  chmod 555 "$(services)/mailpit"; chmod 755 "$(services)"
  run "$MROOM" baseline mailpit
  expect_rc 1; expect_err_has "is not as mroom's root recipe makes it"
  chmod 555 "$(services)"
  run "$MROOM" baseline mailpit; expect_rc 0
  run downloads; expect_out 1
}

# old_world: a box whose services lived in the home, as before: Mailpit's mail and logins, Garage's metadata,
# data and secrets, the Reverb host's apps, and old builds.
old_world() {
  local old
  old="$(old)"
  mkdir -p "$old/mailpit/v1.0.0" "$old/mailpit/data" "$old/mailpit/run" "$old/mail-relay" "$old/garage/meta/db" \
    "$old/garage/data/ab" "$old/garage/run" "$old/reverb/apps" "$(secrets)"
  printf 'mail\n' >"$old/mailpit/data/mailpit.db"
  printf 'wal\n' >"$old/mailpit/data/mailpit.db-wal"
  printf 'old\n' >"$old/mailpit/v1.0.0/mailpit"
  ln -s v1.0.0 "$old/mailpit/current"
  printf 'node key\n' >"$old/garage/meta/node_key"
  printf 'layout\n' >"$old/garage/meta/db/db.sqlite"
  printf 'block\n' >"$old/garage/data/ab/block"
  printf '{"apps": [{"app_id": "shop-qa-7"}]}\n' >"$old/reverb/apps/apps.json"
  printf 'mroom-none:$6$a$b\nshop_qa_7:$6$c$d\n' >"$(secrets)/mailpit-smtp.passwd"
  printf 'mroom-gate:$6$e$f\n' >"$(secrets)/mailpit-ui.passwd"
  printf 'MAILPIT_API_USER=mroom-gate\nMAILPIT_API_PASSWORD=%s\n' 0123456789abcdef0123456789abcdef0123456789abcdef >"$(secrets)/mailpit.env"
  openssl rand -hex 32 >"$(secrets)/garage-rpc-secret"
  printf 'admin-token\n' >"$(secrets)/garage-admin-token"
  printf 'metrics-token\n' >"$(secrets)/garage-metrics-token"
  chmod 600 "$(secrets)"/*
}

# A box upgraded from the home: once root has installed this release's units, which stopped the services
# that ran from there, each part's data moves into its folders before its build, with nothing lost, and a
# second run moves nothing.
t_a_box_whose_services_lived_in_the_home_moves_their_data() {
  world
  old_world
  local old logins
  old="$(old)" logins="$(cat "$(secrets)/mailpit-smtp.passwd")"
  # Before the recipe has installed this release's units, nothing moves.
  run "$MROOM" baseline mailpit
  expect_rc 1
  # shellcheck disable=SC2088  # the message names the home as ~, as it prints it
  expect_err_has "~/.local/share/mroom-services/mailpit holds mailpit's data, which moves to $(services) once root has installed this release's units; run the root recipe (mailpit in its parts), then this again; nothing changed"
  expect_file "$old/mailpit/data/mailpit.db"; expect_file "$(secrets)/mailpit-smtp.passwd"
  run downloads; expect_out 0
  root_install mailpit garage; expect_rc 0
  # A process that still runs from the old folder: nothing moves.
  bash -c 'sleep 30; :' "$old/mailpit/current/mailpit" &
  echo $! >"$T/old.pid"
  run "$MROOM" baseline mailpit
  expect_rc 1; expect_err_has "a process still runs from ~/.local/share/mroom-services/mailpit, so mailpit's data cannot move yet"
  expect_file "$old/mailpit/data/mailpit.db"
  kill "$(cat "$T/old.pid")"; wait "$(cat "$T/old.pid")" 2>/dev/null || true; rm "$T/old.pid"
  # Then it moves: mail, logins and all.
  run "$MROOM" baseline mailpit
  expect_rc 0
  expect_out_has "Mailpit: its data moved from ~/.local/share/mroom-services/mailpit to $(services)"
  expect_out_has "Mailpit: what is left in ~/.local/share/mroom-services/mailpit (old builds, sockets) is not used any more: remove it"
  run cat "$(services)/mailpit/data/mailpit.db" "$(services)/mailpit/data/mailpit.db-wal"; expect_out $'mail\nwal'
  run cat "$(etc mailpit)/mailpit-smtp.passwd"; expect_out "$logins"
  expect_no_file "$(secrets)/mailpit-smtp.passwd"; expect_no_file "$(secrets)/mailpit-ui.passwd"
  expect_no_file "$old/mailpit/data"
  # The gate's API login stays where only the gate reads it, and Mailpit's hash of it is made again.
  expect_file "$(secrets)/mailpit.env"
  expect_true "the API login's hash is not of the gate's password" hash_of "$(api_password)" "$(api_hash)"
  # A second run moves nothing, and changes nothing.
  local before
  before="$(find "$(services)" "$old" "$(secrets)" -printf '%p %y %m\n' | sort; cat "$(etc mailpit)"/*)"
  run "$MROOM" baseline mailpit; expect_rc 0
  expect_true "a second run moved something" lacks "$out" "moved"
  run bash -c 'find "$1" "$2" "$3" -printf "%p %y %m\n" | sort; cat "$4"/*' _ "$(services)" "$old" "$(secrets)" "$(etc mailpit)"
  expect_out "$before"

  # Garage: its metadata, data and secrets, so its node, its layout, its buckets and their keys stay.
  local rpc
  rpc="$(cat "$(secrets)/garage-rpc-secret")"
  run "$MROOM" baseline garage
  expect_rc 0
  expect_out_has "Garage: its data moved from ~/.local/share/mroom-services/garage to $(services)"
  expect_true "Garage made a secret it had" lacks "$out" "token: made"
  run cat "$(services)/garage/meta/node_key" "$(services)/garage/meta/db/db.sqlite" "$(services)/garage/data/ab/block"
  expect_out $'node key\nlayout\nblock'
  run cat "$(etc garage)/garage-rpc-secret" "$(etc garage)/garage-admin-token" "$(etc garage)/garage-metrics-token"
  expect_out "$rpc"$'\nadmin-token\nmetrics-token'
  expect_no_file "$(secrets)/garage-admin-token"
  expect_true "Garage's config names the old metadata" eval '! grep -q mroom-services "$(etc garage)/garage.toml"'
  run "$MROOM" baseline garage; expect_rc 0
  expect_true "a second run moved something" lacks "$out" "moved"
}

# A file of the same name in both places, one not a copy of the other: neither is taken over the other.
t_a_file_in_both_places_stops_the_move() {
  world
  old_world
  root_install mailpit; expect_rc 0
  printf 'new mail\n' >"$(services)/mailpit/data/mailpit.db"
  run "$MROOM" baseline mailpit
  expect_rc 1
  expect_err_has "both ~/.local/share/mroom-services/mailpit/data/mailpit.db and $(services)/mailpit/data/mailpit.db exist: keep the one that holds the service's data, remove the other, then run this again; nothing changed"
  run cat "$(services)/mailpit/data/mailpit.db"; expect_out "new mail"
  # Nothing of the part moved: not the old database's other files, nor its logins.
  expect_file "$(old)/mailpit/data/mailpit.db"; expect_file "$(old)/mailpit/data/mailpit.db-wal"
  expect_no_file "$(services)/mailpit/data/mailpit.db-wal"
  expect_file "$(secrets)/mailpit-smtp.passwd"; expect_no_file "$(etc mailpit)/mailpit-smtp.passwd"
  expect_no_file "$(services)/mailpit/builds/v9.9.9"
  # The same file in both, as a move that stopped halfway leaves it: the old copy goes.
  cp "$(secrets)/mailpit-ui.passwd" "$(etc mailpit)/mailpit-ui.passwd"
  rm "$(services)/mailpit/data/mailpit.db"
  # A move an earlier run left halfway, under its hidden name: nothing changes until a person looks.
  mkdir "$(services)/mailpit/data/.mailpit.db-wal.moving"
  run "$MROOM" baseline mailpit
  expect_rc 1; expect_err_has "$(services)/mailpit/data/.mailpit.db-wal.moving is what an earlier move left halfway, and"
  expect_file "$(old)/mailpit/data/mailpit.db"
  rmdir "$(services)/mailpit/data/.mailpit.db-wal.moving"
  run "$MROOM" baseline mailpit
  expect_rc 0
  expect_no_file "$(secrets)/mailpit-ui.passwd"
  run cat "$(services)/mailpit/data/mailpit.db" "$(services)/mailpit/data/mailpit.db-wal"; expect_out $'mail\nwal'
  run bash -c 'compgen -G "$1/.*.moving" || true' _ "$(services)/mailpit/data"; expect_out ""
  # A move cut short after the old copy went: the hidden one is whole, and is finished before any build
  # could start on an empty folder, even with nothing left in the old folder.
  mv "$(services)/mailpit/data/mailpit.db" "$(services)/mailpit/data/.mailpit.db.moving"
  run "$MROOM" baseline mailpit
  expect_rc 0; expect_out_has "Mailpit: its data moved"
  run cat "$(services)/mailpit/data/mailpit.db"; expect_out mail
  expect_no_file "$(services)/mailpit/data/.mailpit.db.moving"
}

t_usage_and_unknown_parts() {
  world
  run "$MROOM" baseline; expect_rc 0; expect_out_has "mroom baseline mailpit"; expect_out_has "mroom baseline reverb"
  run "$MROOM" baseline redis; expect_rc 1; expect_err_has "unknown part 'redis'"
  run "$MROOM" baseline mailpit extra; expect_rc 1; expect_err_has "usage: mroom baseline mailpit"
}

test_case mailpit-installed t_mailpit_is_installed_at_its_pin_with_its_relay_and_logins
test_case second-run t_a_second_run_keeps_the_build_the_relay_and_the_logins
test_case units t_installed_units_are_compared_with_what_this_mroom_writes
test_case unreadable t_a_login_file_it_cannot_read_or_a_busy_gate_stops_it
test_case api-login t_the_api_login_is_kept_or_rewritten_from_its_password
test_case placeholder t_the_placeholder_login_is_put_back_and_kept_whole
test_case bad-hash t_a_hash_openssl_did_not_give_is_never_written
test_case pin-mismatch t_a_build_that_does_not_match_its_pin_is_not_installed
test_case bad-pins t_a_missing_or_malformed_pin_is_refused
test_case committed-pins t_the_committed_pins_are_well_formed
test_case garage t_garage_is_installed_with_its_config_secrets_and_unit
test_case garage-layout t_garage_keeps_its_secrets_and_sets_its_layout_once
test_case folders t_the_folders_must_be_as_the_root_recipe_makes_them
test_case upgrade t_a_box_whose_services_lived_in_the_home_moves_their_data
test_case both-places t_a_file_in_both_places_stops_the_move
test_case usage t_usage_and_unknown_parts
finish
