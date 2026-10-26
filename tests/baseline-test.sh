#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2016  # t_* run through test_case; a $ in single quotes is for eval, later
# Tests for `mroom baseline`: a QA service's build is installed only when its archive and its binary match
# their SHA-256 pins, mroom's mail relay goes beside it, logins are made once, mode 600, from hashes openssl
# really gave, and the three systemd units are written and compared with the installed ones. Offline: curl is a fake that serves a test
# archive. tests/mail/gate-real-test.sh installs the real pinned Mailpit.
set -euo pipefail
SUITE=baseline
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
stop_all() {
  local f
  for f in "$TOP"/*/garage.pid; do if [ -s "$f" ]; then kill "$(cat "$f")" 2>/dev/null || true; fi; done
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

# world: a test build of "mailpit" and its archive, pins for them, a fake curl serving the archive, and a
# box.env naming a free SMTP port.
world() {
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
if [ "$socket" = "$HOME/.local/share/mroom-services/garage/run/admin.sock" ]; then exec "$REAL_CURL" "${args[@]}"; fi
case "$url" in
  https://example.test/mailpit.tgz) cp "$T/served/mailpit.tgz" "$out" ;;
  https://example.test/garage) cp "$T/served/garage" "$out" ;;
  http://localhost/livez)
    [ "$socket" = "$HOME/.local/share/mroom-services/mailpit/run/http.sock" ] && [ -e "$T/live" ] || exit 7 ;;
  *) echo "fake curl: no such URL $url" >&2; exit 22 ;;
esac
FAKE
  # systemctl: logs every call, and calls every unit inactive.
  printf '#!/bin/sh\necho "systemctl $*" >>"$T/systemctl.log"\n[ "$1" != is-active ] || { echo inactive; exit 3; }\n' >"$T/bin/systemctl"
  chmod +x "$T/bin/curl" "$T/bin/systemctl"
  export T PATH="$T/bin:$PATH" MROOM_PINS="$T/pins.txt" MROOM_SYSTEMD_DIR="$T/systemd" REAL_CURL
}

# root_script_of <output>: the script baseline printed for a person to run as root.
root_script_of() { sed -n '/^----- run as root -----$/,/^----- end -----$/p' <<<"$1" | sed '1d;$d'; }

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
services() { echo "$HOME/.local/share/mroom-services"; }
secrets() { echo "$HOME/.config/mroom/secrets"; }
downloads() { local n; n="$(grep -c 'example.test/mailpit.tgz' "$T/curl.log" 2>/dev/null)" || true; echo "${n:-0}"; }
mode() { stat -c %a "$1"; }
api_password() { sed -n 's/^MAILPIT_API_PASSWORD=//p' "$(secrets)/mailpit.env"; }
api_hash() { sed -n 's/^mroom-gate://p' "$(secrets)/mailpit-ui.passwd"; }

t_mailpit_is_installed_at_its_pin_with_its_relay_and_logins() {
  world
  run "$MROOM" baseline mailpit
  expect_rc 0
  expect_out_has "mailpit v9.9.9: installed, SHA-256 $(sha "$T/build/mailpit")"
  expect_out_has "mail relay: installed"
  run cat "$(services)/mailpit/current/mailpit"; expect_out "$(cat "$T/build/mailpit")"
  run readlink "$(services)/mailpit/current"; expect_out v9.9.9
  run mode "$(services)/mailpit/v9.9.9/mailpit"; expect_out 700
  expect_true "the relay is not this mroom's" cmp -s "$ROOT/lib/mail-relay" "$(services)/mail-relay/mail-relay"
  run mode "$(services)/mail-relay/mail-relay"; expect_out 700
  local file
  for file in mailpit-smtp.passwd mailpit-ui.passwd mailpit.env; do
    run mode "$(secrets)/$file"; expect_out 600
  done
  for file in "$(services)/mailpit/data" "$(services)/mailpit/run" "$(services)/mail-relay" "$(secrets)"; do
    run mode "$file"; expect_out 700
  done
  expect_true "the SMTP logins hold no placeholder login" grep -qE '^mroom-none:\$6\$' "$(secrets)/mailpit-smtp.passwd"
  # The API login's hash is of the password the gate keeps.
  local password
  password="$(api_password)"
  expect_true "the API password is not 48 hex characters" hex48 "$password"
  expect_true "the API login's hash is not of the gate's password" hash_of "$password" "$(api_hash)"
  expect_true "the download could be sent to a plain-http address" grep -q -- "--proto-redir =https" "$T/curl.log"
  local base script
  base="$(services)/mailpit"
  run "$MROOM" baseline mailpit
  expect_out_has "Mailpit does not answer yet."
  expect_out_has "Nothing listens on 127.0.0.1:$PORT yet."
  expect_true "the password reached the output" lacks "$out" "$password"
  # The units are installed by a person, as root, from a script in which every unit's text stands: root
  # reads no file the box user can write.
  script="$(root_script_of "$out")"
  expect_true "no script to run as root" [ -n "$script" ]
  expect_no_file "$(services)/units"
  expect_true "the root script reads or copies a file" lacks "$script" "install -o"
  expect_true "the root script reads a file of the box user's" lacks "$script" "<$HOME"
  local unit
  for unit in mroom-mail-relay.socket mroom-mail-relay.service mroom-mailpit.service; do
    expect_true "the root script does not write $unit" has "$script" "cat >$T/systemd/$unit <<'MROOM_UNIT'"
  done
  expect_true "the root script does not start the units" has "$script" "systemctl enable --now mroom-mail-relay.socket mroom-mail-relay.service mroom-mailpit.service"
  # The socket holds the port as root; the relay and Mailpit run as the box user, confined, and systemd
  # starts them again however often they stop.
  for line in "ListenStream=127.0.0.1:$PORT" \
    "ExecStart=$(command -v python3) -I $(services)/mail-relay/mail-relay 127.0.0.1 $PORT $base/run/smtp.sock" \
    "ExecStart=$base/current/mailpit --listen unix:$base/run/http.sock:0600 --smtp unix:$base/run/smtp.sock:0600 --database $base/data/mailpit.db --smtp-auth-file $(secrets)/mailpit-smtp.passwd --smtp-auth-allow-insecure --tags-username --tags-disable x-tags,plus-addresses --ui-auth-file $(secrets)/mailpit-ui.passwd --max 0 --max-age 7d" \
    "User=$(id -un)" "Group=$(id -gn)" "Restart=always" "StartLimitIntervalSec=0" "NoNewPrivileges=yes" \
    "WorkingDirectory=$base/data" "ProtectHome=tmpfs" "ProtectSystem=strict" "PrivateNetwork=yes" \
    "BindReadOnlyPaths=$base $(secrets)/mailpit-smtp.passwd $(secrets)/mailpit-ui.passwd" "BindPaths=$base/data $base/run" \
    "BindReadOnlyPaths=$(services)/mail-relay $base/run" "RestrictAddressFamilies=AF_UNIX"; do
    expect_true "the units lack: $line" grep -qxF -- "$line" <<<"$script"
  done
  expect_true "a unit runs something as root" \
    eval '! grep -qE "^Exec[A-Za-z]*=[+!@-]|^ExecStartPre=|^ExecStartPost=|^ExecStop=|^ExecReload=|^User=root" <<<"$script"'
  # MROOM_SYSTEMD_DIR, a setting for tests, moves where the script writes: baseline says so, loudly.
  expect_out_has "WARNING: MROOM_SYSTEMD_DIR is set, so this script writes to $T/systemd, not /etc/systemd/system"
  # Without box.env's port, the relay takes 1025.
  rm "$HOME/.config/mroom/box.env"
  run "$MROOM" baseline mailpit
  expect_out_has "ListenStream=127.0.0.1:1025"
}

t_installed_units_are_compared_with_what_this_mroom_writes() {
  world
  run "$MROOM" baseline mailpit; expect_rc 0
  # Running the printed script installs the three units and starts them.
  mkdir -p "$T/systemd"
  run bash -c "$(root_script_of "$out")"
  expect_rc 0
  run cat "$T/systemctl.log"
  expect_out_has "systemctl daemon-reload"
  expect_out_has "systemctl enable --now mroom-mail-relay.socket mroom-mail-relay.service mroom-mailpit.service"
  run stat -c %a "$T/systemd/mroom-mailpit.service"; expect_out 644
  run "$MROOM" baseline mailpit; expect_rc 0
  expect_out_has "systemd units: installed as this mroom writes them (mroom-mail-relay.socket inactive, mroom-mail-relay.service inactive, mroom-mailpit.service inactive)."
  expect_true "installed units asked to be installed again" lacks "$out" "run as root"
  # One that changed is written again, and its service restarted.
  printf '# a local change\n' >>"$T/systemd/mroom-mailpit.service"
  run "$MROOM" baseline mailpit; expect_rc 0
  expect_out_has "To be installed or updated: mroom-mailpit.service."
  local script
  script="$(root_script_of "$out")"
  expect_true "the changed unit is not written again" has "$script" "cat >$T/systemd/mroom-mailpit.service"
  expect_true "an unchanged unit is written again" lacks "$script" "cat >$T/systemd/mroom-mail-relay.socket"
  expect_true "the changed service is not restarted" has "$script" "systemctl restart mroom-mailpit.service"
  run bash -c "$script"; expect_rc 0
  # A new port: the socket is restarted, which frees the port for a moment, so every login is renewed.
  printf 'MROOM_QA_SMTP_PORT=%s\n' "$((PORT + 1))" >"$HOME/.config/mroom/box.env"
  run "$MROOM" baseline mailpit; expect_rc 0
  script="$(root_script_of "$out")"
  expect_true "the socket is not restarted on a new port" has "$script" "systemctl restart mroom-mail-relay.socket mroom-mail-relay.service"
  expect_true "a new port asks for no new logins" has "$script" "give each QA environment new mail logins"
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
  logins="$(secrets)/mailpit-smtp.passwd"
  before="$(cat "$logins")"
  chmod 000 "$logins"
  run "$MROOM" baseline mailpit
  chmod 600 "$logins"
  expect_rc 1; expect_err_has "cannot read ~/.config/mroom/secrets/mailpit-smtp.passwd"
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
  before="$(cat "$(secrets)/mailpit.env" "$(secrets)/mailpit-ui.passwd" "$(secrets)/mailpit-smtp.passwd")"
  : >"$T/live"
  run "$MROOM" baseline mailpit; expect_rc 0
  expect_out_has "mailpit v9.9.9: installed, and matches its pin"
  expect_out_has "mail relay: installed, and matches this mroom"
  expect_out_has "Mailpit answers."
  expect_true "a kept login asked for a restart" lacks "$out" "reads its API login"
  run downloads; expect_out 1
  run cat "$(secrets)/mailpit.env" "$(secrets)/mailpit-ui.passwd" "$(secrets)/mailpit-smtp.passwd"; expect_out "$before"
  # A relay that is not this mroom's is replaced; systemd's relay runs it from its next start.
  printf '# changed\n' >>"$(services)/mail-relay/mail-relay"
  run "$MROOM" baseline mailpit; expect_rc 0
  expect_out_has "mail relay: updated"
  expect_out_has "mail relay: runs the new one from its next start (mroom-mail-relay.service)"
  expect_true "the relay was not replaced" cmp -s "$ROOT/lib/mail-relay" "$(services)/mail-relay/mail-relay"
}

t_the_api_login_is_kept_or_rewritten_from_its_password() {
  world
  run "$MROOM" baseline mailpit; expect_rc 0
  local password
  password="$(api_password)"
  : >"$T/live"
  # Mailpit's copy of the hash gone: rewritten from the same password, and Mailpit must read it again.
  rm "$(secrets)/mailpit-ui.passwd"
  run "$MROOM" baseline mailpit; expect_rc 0
  expect_out_has "API login: its hash for Mailpit rewritten from ~/.config/mroom/secrets/mailpit.env"
  expect_out_has "Mailpit: runs its build and reads its API login from its next start (mroom-mailpit.service)"
  run api_password; expect_out "$password"
  expect_true "the rewritten hash is not of the password" hash_of "$password" "$(api_hash)"
  printf 'mroom-gate:$6$a$b\n' >"$(secrets)/mailpit-ui.passwd"
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
  mkdir -p "$(secrets)"
  printf 'shop_qa_12:$6$a$b\nmroom-none:\n' >"$(secrets)/mailpit-smtp.passwd"
  chmod 600 "$(secrets)/mailpit-smtp.passwd"
  run "$MROOM" baseline mailpit; expect_rc 0
  expect_out_has "SMTP logins: the placeholder login restored"
  run grep -c '^mroom-none:' "$(secrets)/mailpit-smtp.passwd"; expect_out 1
  expect_true "the placeholder login is not a SHA-512 crypt hash" \
    grep -qE '^mroom-none:\$6\$[A-Za-z0-9./]+\$[A-Za-z0-9./]+$' "$(secrets)/mailpit-smtp.passwd"
  expect_true "an environment's login was lost" grep -qxF 'shop_qa_12:$6$a$b' "$(secrets)/mailpit-smtp.passwd"
}

t_a_hash_openssl_did_not_give_is_never_written() {
  world
  printf '#!/bin/sh\ncat >/dev/null\necho not-a-hash\n' >"$T/bin/openssl"
  chmod +x "$T/bin/openssl"
  run "$MROOM" baseline mailpit
  expect_rc 1; expect_err_has "openssl gave no SHA-512 crypt hash; nothing changed"
  expect_no_file "$(secrets)/mailpit-smtp.passwd"
  expect_no_file "$(secrets)/mailpit-ui.passwd"
  expect_no_file "$(secrets)/mailpit.env"
  run bash -c 'compgen -G "$1/.baseline.*" || true' _ "$(secrets)"; expect_out ""
}

t_a_build_that_does_not_match_its_pin_is_not_installed() {
  world
  pins "$(printf '0%.0s' $(seq 64))" "$(sha "$T/build/mailpit")"
  run "$MROOM" baseline mailpit
  expect_rc 1; expect_err_has "the download's SHA-256 is $(sha "$T/served/mailpit.tgz"), not the pinned"
  expect_err_has "nothing installed"
  expect_no_file "$(services)/mailpit/v9.9.9/mailpit"
  pins "$(sha "$T/served/mailpit.tgz")" "$(printf 'f%.0s' $(seq 64))"
  run "$MROOM" baseline mailpit
  expect_rc 1; expect_err_has "the binary's SHA-256 is $(sha "$T/build/mailpit"), not the pinned"
  expect_no_file "$(services)/mailpit/v9.9.9/mailpit"
  tar -czf "$T/served/mailpit.tgz" -C "$T/build" README.md
  pins "$(sha "$T/served/mailpit.tgz")" "$(sha "$T/build/mailpit")"
  run "$MROOM" baseline mailpit
  expect_rc 1; expect_err_has "the archive holds no mailpit binary"
  expect_no_file "$(services)/mailpit/v9.9.9/mailpit"
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
  local run="$HOME/.local/share/mroom-services/garage/run"
  python3 -I "$ROOT/tests/fakes/garage.py" "$run/admin.sock" "$run/s3.sock" "$HOME/.config/mroom/secrets/garage-admin-token" \
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
  local base secrets script
  base="$(services)/garage" secrets="$(secrets)"
  run cat "$base/current/garage"; expect_out "$(cat "$T/served/garage")"
  run mode "$base/v8.8.8/garage"; expect_out 700
  for file in "$base" "$base/meta" "$base/data" "$base/run"; do run mode "$file"; expect_out 700; done
  for file in garage-rpc-secret garage-admin-token garage-metrics-token; do run mode "$secrets/$file"; expect_out 600; done
  run cat "$secrets/garage-rpc-secret"; expect_true "the RPC secret is not 32 bytes of hex" eval '[[ "$out" =~ ^[0-9a-f]{64}$ ]]'
  run mode "$base/garage.toml"; expect_out 600
  # Its config names its secrets' files, never a secret, and Unix sockets for every endpoint but RPC.
  for line in "metadata_dir = \"$base/meta\"" "data_dir = \"$base/data\"" "replication_factor = 1" \
    'rpc_bind_addr = "127.0.0.1:3901"' "rpc_secret_file = \"$secrets/garage-rpc-secret\"" \
    "api_bind_addr = \"$base/run/s3.sock\"" "bind_addr = \"$base/run/web.sock\"" 'root_domain = ".web.mroom.invalid"' \
    "api_bind_addr = \"$base/run/admin.sock\"" "admin_token_file = \"$secrets/garage-admin-token\""; do
    expect_true "the config lacks: $line" grep -qxF -- "$line" "$base/garage.toml"
  done
  expect_true "a secret is in the config" eval '! grep -qF "$(cat "$secrets/garage-admin-token")" "$base/garage.toml"'
  run "$MROOM" baseline garage
  script="$(root_script_of "$out")"
  expect_true "the root script does not write the unit" has "$script" "cat >$T/systemd/mroom-garage.service <<'MROOM_UNIT'"
  for line in "ExecStart=$base/current/garage -c $base/garage.toml server" "User=$(id -un)" "Restart=always" \
    "StartLimitIntervalSec=0" "PrivateNetwork=yes" "ProtectHome=tmpfs" "ProtectSystem=strict" \
    "BindPaths=$base/meta $base/data $base/run" \
    "BindReadOnlyPaths=$base $secrets/garage-rpc-secret $secrets/garage-admin-token $secrets/garage-metrics-token"; do
    expect_true "the unit lacks: $line" grep -qxF -- "$line" <<<"$script"
  done
  expect_true "the unit runs something as root" \
    eval '! grep -qE "^Exec[A-Za-z]*=[+!@-]|^ExecStartPre=|^ExecStartPost=|^ExecStop=|^ExecReload=|^User=root" <<<"$script"'
  expect_out_has "Garage does not answer yet: install its unit, then run mroom baseline garage again"
  # The two hosts' nginx configs, on Garage's sockets.
  expect_out_has "s3.qa.example.dev, the S3 API"
  expect_out_has "proxy_pass http://unix:$base/run/s3.sock;"
  expect_out_has "files.qa.example.dev, public files"
  expect_out_has 'proxy_set_header Host $bucket.web.mroom.invalid;'
  # nginx reads a bare { as a block: a regex with a count in it must be quoted.
  expect_out_has 'location ~ "^/([a-z0-9][a-z0-9-]{1,61}[a-z0-9])(/.*)$" {'
  expect_out_has "proxy_pass http://unix:$base/run/web.sock;"
}

t_garage_keeps_its_secrets_and_sets_its_layout_once() {
  world
  run "$MROOM" baseline garage; expect_rc 0
  expect_out_has "Set MROOM_QA_ZONE in box.env, and run this again for the nginx configs"
  local before
  before="$(cat "$(secrets)"/garage-*)"
  garage_up
  run "$MROOM" baseline garage; expect_rc 0
  expect_out_has "garage v8.8.8: installed, and matches its pin"
  expect_out_has "Garage answers; its layout now holds this node."
  expect_true "a kept config was written again" lacks "$out" "Garage config:"
  run cat "$(secrets)"/garage-*; expect_out "$before"
  run bash -c 'printf "Authorization: Bearer %s\n" "$(cat "$1")" | "$2" -q -s --unix-socket "$3" --header @- http://localhost/test/state' _ \
    "$(secrets)/garage-admin-token" "$REAL_CURL" "$(services)/garage/run/admin.sock"
  run jq -c '.layout | {version, zones: [.roles[].zone]}' <<<"$out"; expect_out '{"version":1,"zones":["box"]}'
  run "$MROOM" baseline garage; expect_rc 0
  expect_out_has "Garage answers; its layout holds one node."
  kill "$(cat "$T/garage.pid")" 2>/dev/null || true
}

t_usage_and_unknown_parts() {
  world
  run "$MROOM" baseline; expect_rc 0; expect_out_has "mroom baseline mailpit"
  run "$MROOM" baseline reverb; expect_rc 1; expect_err_has "unknown part 'reverb'"
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
test_case usage t_usage_and_unknown_parts
finish
