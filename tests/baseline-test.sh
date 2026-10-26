#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2016  # t_* run through test_case; a $ in single quotes is for eval, later
# Tests for `mroom baseline`: a QA service's build is installed only when its archive and its binary match
# their SHA-256 pins, mroom's mail relay goes beside it, logins are made once, mode 600, from hashes openssl
# really gave, and the two Forge daemons to create are printed. Offline: curl is a fake that serves a test
# archive. tests/mail/gate-real-test.sh installs the real pinned Mailpit.
set -euo pipefail
SUITE=baseline
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
skip_unless has_box_tools "this host lacks bash 5, flock or GNU date, which box commands need"

platform() {
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) echo linux-amd64 ;;
    *) echo linux-arm64 ;;
  esac
}
sha() { sha256sum "$1" | cut -d' ' -f1; }

# world: a test build of "mailpit" and its archive, pins for them, a fake curl serving the archive, and a
# box.env naming a free SMTP port.
world() {
  mkdir -p "$T/bin" "$T/build" "$T/served" "$HOME/.config/mroom"
  printf '#!/bin/sh\necho mailpit\n' >"$T/build/mailpit"
  chmod 755 "$T/build/mailpit"
  printf 'readme\n' >"$T/build/README.md"
  tar -czf "$T/served/mailpit.tgz" -C "$T/build" mailpit README.md
  pins "$(sha "$T/served/mailpit.tgz")" "$(sha "$T/build/mailpit")"
  PORT=$((20000 + RANDOM % 30000))
  while (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; do PORT=$((PORT + 1)); done
  printf 'MROOM_QA_SMTP_PORT=%s\n' "$PORT" >"$HOME/.config/mroom/box.env"
  cat >"$T/bin/curl" <<'FAKE'
#!/usr/bin/env bash
# Logs each call; serves https://example.test/mailpit.tgz into --output, and Mailpit's /livez on its Unix
# socket only when $T/live exists.
printf '%s\n' "$*" >>"$T/curl.log"
out="" socket="" url="${!#}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) out="$2"; shift 2 ;;
    --unix-socket) socket="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "$url" in
  https://example.test/mailpit.tgz) cp "$T/served/mailpit.tgz" "$out" ;;
  http://localhost/livez)
    [ "$socket" = "$HOME/.local/share/mroom-services/mailpit/run/http.sock" ] && [ -e "$T/live" ] || exit 7 ;;
  *) echo "fake curl: no such URL $url" >&2; exit 22 ;;
esac
FAKE
  chmod +x "$T/bin/curl"
  export T PATH="$T/bin:$PATH" MROOM_PINS="$T/pins.txt"
}

# pins <archive sha> <binary sha> [<platform>] [<url>]
pins() {
  printf '# test pins\nmailpit v9.9.9 %s %s %s %s\n' "${3:-$(platform)}" "$1" "$2" "${4:-https://example.test/mailpit.tgz}" >"$T/pins.txt"
}

# hash_of <password> <hash>: whether the SHA-512 crypt hash is of the password.
hash_of() { [ "$(printf '%s' "$1" | openssl passwd -6 -salt "$(cut -d'$' -f3 <<<"$2")" -stdin)" = "$2" ]; }
hex48() { [[ "$1" =~ ^[0-9a-f]{48}$ ]]; }
lacks() { case "$1" in *"$2"*) return 1 ;; esac; return 0; }
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
  run "$MROOM" baseline mailpit
  local base
  base="$(services)/mailpit"
  expect_out_has "-I $(services)/mail-relay/mail-relay 127.0.0.1 $PORT $base/run/smtp.sock"
  expect_out_has "$base/current/mailpit --listen unix:$base/run/http.sock:0600 --smtp unix:$base/run/smtp.sock:0600 --database $base/data/mailpit.db"
  expect_out_has "--smtp-auth-file $(secrets)/mailpit-smtp.passwd --smtp-auth-allow-insecure --tags-username --tags-disable x-tags,plus-addresses"
  expect_out_has "Directory: $base/data"
  expect_out_has "Start Seconds 1"
  expect_out_has "Mailpit does not answer yet."
  expect_out_has "Nothing listens on 127.0.0.1:$PORT yet."
  expect_true "the password reached the output" lacks "$out" "$password"
  # Without box.env's port, the relay takes 1025.
  rm "$HOME/.config/mroom/box.env"
  run "$MROOM" baseline mailpit
  expect_out_has "mail-relay 127.0.0.1 1025 $base/run/smtp.sock"
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
  expect_true "a kept login asked for a restart" lacks "$out" "restart its daemon"
  run downloads; expect_out 1
  run cat "$(secrets)/mailpit.env" "$(secrets)/mailpit-ui.passwd" "$(secrets)/mailpit-smtp.passwd"; expect_out "$before"
  # A relay that is not this mroom's is replaced, and its daemon needs a restart to run the new one.
  printf '# changed\n' >>"$(services)/mail-relay/mail-relay"
  run "$MROOM" baseline mailpit; expect_rc 0
  expect_out_has "mail relay: updated; restart its daemon in Forge to run this one"
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
  expect_out_has "Mailpit reads its API login only when it starts: restart its daemon in Forge."
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
  local platform count=0 line
  while read -r line; do
    case "$line" in "" | \#*) continue ;; esac
    count=$((count + 1))
    expect_true "a pin is malformed: $line" \
      eval '[[ "$line" =~ ^[a-z]+\ +v[0-9.]+\ +linux-(amd64|arm64)\ +[0-9a-f]{64}\ +[0-9a-f]{64}\ +https://github\.com/[A-Za-z0-9._/-]+$ ]]'
  done <"$ROOT/lib/core/pins.txt"
  expect_true "the pins file pins nothing" [ "$count" -ge 2 ]
  for platform in linux-amd64 linux-arm64; do
    expect_true "no mailpit pin for $platform" grep -qE "^mailpit +v[0-9.]+ +$platform " "$ROOT/lib/core/pins.txt"
  done
}

t_usage_and_unknown_parts() {
  world
  run "$MROOM" baseline; expect_rc 0; expect_out_has "mroom baseline mailpit"
  run "$MROOM" baseline garage; expect_rc 1; expect_err_has "unknown part 'garage'"
  run "$MROOM" baseline mailpit extra; expect_rc 1; expect_err_has "usage: mroom baseline mailpit"
}

test_case mailpit-installed t_mailpit_is_installed_at_its_pin_with_its_relay_and_logins
test_case second-run t_a_second_run_keeps_the_build_the_relay_and_the_logins
test_case api-login t_the_api_login_is_kept_or_rewritten_from_its_password
test_case placeholder t_the_placeholder_login_is_put_back_and_kept_whole
test_case bad-hash t_a_hash_openssl_did_not_give_is_never_written
test_case pin-mismatch t_a_build_that_does_not_match_its_pin_is_not_installed
test_case bad-pins t_a_missing_or_malformed_pin_is_refused
test_case committed-pins t_the_committed_pins_are_well_formed
test_case usage t_usage_and_unknown_parts
finish
