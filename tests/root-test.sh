#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2016  # t_* run through test_case; a $ in single quotes is for eval, later
# Tests for lib/root-setup, what mroom installs as root (design D21), and for the README's root recipe, which
# downloads it from a release tag, checks its SHA-256 and runs it. Offline: MROOM_ROOT_SETUP_TEST points it at
# folders of the test's own, and stand-ins play systemctl, visudo and curl. CI runs it as root for real in the
# mail, files and site jobs (tests/mail/, tests/files/, tests/site/).
set -euo pipefail
SUITE=root
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
skip_unless has_box_tools "this host lacks bash 5, flock or GNU date, which box commands need"

USER_NAME="$(id -un)"
GROUP_NAME="$(id -gn)"
sha() { sha256sum "$1" | cut -d' ' -f1; }

world() {
  mkdir -p "$T/bin" "$T/systemd" "$T/libexec" "$T/sudoers" "$T/served" "$T/home" "$T/state"
  # systemctl: logs each call, and fails a restart while $T/systemctl-fails-restart exists.
  printf '#!/bin/sh\necho "systemctl $*" >>"$T/systemctl.log"\n[ "$1" != restart ] || [ ! -e "$T/systemctl-fails-restart" ]\n' \
    >"$T/bin/systemctl"
  # visudo: logs what it checks, and refuses while $T/visudo-refuses exists.
  printf '#!/bin/sh\necho "visudo $*" >>"$T/visudo.log"\n[ ! -e "$T/visudo-refuses" ]\n' >"$T/bin/visudo"
  cat >"$T/bin/curl" <<'FAKE'
#!/usr/bin/env bash
# Logs each call, and serves https://raw.githubusercontent.com/milroyfraser/mroom/<path> from $T/served/<path>.
printf '%s\n' "$*" >>"$T/curl.log"
out="" url="${!#}"
while [ "$#" -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac; done
path="${url#https://raw.githubusercontent.com/milroyfraser/mroom/}"
[ "$path" != "$url" ] && [ -f "$T/served/$path" ] || { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
cp "$T/served/$path" "$out"
FAKE
  chmod +x "$T/bin/systemctl" "$T/bin/visudo" "$T/bin/curl"
  export T PATH="$T/bin:$PATH" MROOM_ROOT_SETUP_TEST=1 MROOM_SYSTEMD_DIR="$T/systemd" MROOM_LIBEXEC_DIR="$T/libexec" \
    MROOM_SUDOERS_DIR="$T/sudoers" MROOM_ROOT_STATE_DIR="$T/state"
}

rs() { run "$ROOT/lib/root-setup" --user "$USER_NAME" --home "$T/home" "$@"; }
mode() { stat -c %a "$1"; }
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
lacks() { ! has "$@"; }
log_of() { cat "$T/$1.log" 2>/dev/null || true; }

t_the_mailpit_units() {
  world
  rs --smtp-port 2525 mailpit
  expect_rc 0
  expect_out_has "WARNING: MROOM_ROOT_SETUP_TEST is set, so this writes to $T/systemd"
  expect_out_has "systemd units written: mroom-mail-relay.socket mroom-mail-relay.service mroom-mailpit.service"
  local unit services="$T/home/.local/share/mroom-services" secrets="$T/home/.config/mroom/secrets" base line all
  base="$services/mailpit"
  for unit in mroom-mail-relay.socket mroom-mail-relay.service mroom-mailpit.service; do
    run mode "$T/systemd/$unit"; expect_out 644
  done
  all="$(cat "$T"/systemd/mroom-*)"
  # The socket holds the port as root; the relay and Mailpit run as the box user, confined, and systemd
  # starts them again however often they stop.
  for line in "ListenStream=127.0.0.1:2525" \
    "ExecStart=/usr/bin/python3 -I $services/mail-relay/mail-relay 127.0.0.1 2525 $base/run/smtp.sock" \
    "ExecStart=$base/current/mailpit --listen unix:$base/run/http.sock:0600 --smtp unix:$base/run/smtp.sock:0600 --database $base/data/mailpit.db --smtp-auth-file $secrets/mailpit-smtp.passwd --smtp-auth-allow-insecure --tags-username --tags-disable x-tags,plus-addresses --ui-auth-file $secrets/mailpit-ui.passwd --max 0 --max-age 7d" \
    "User=$USER_NAME" "Group=$GROUP_NAME" "Restart=always" "StartLimitIntervalSec=0" "NoNewPrivileges=yes" \
    "WorkingDirectory=$base/data" "ProtectHome=tmpfs" "ProtectSystem=strict" "PrivateNetwork=yes" \
    "BindReadOnlyPaths=$base $secrets/mailpit-smtp.passwd $secrets/mailpit-ui.passwd" "BindPaths=$base/data $base/run" \
    "BindReadOnlyPaths=$services/mail-relay $base/run" "RestrictAddressFamilies=AF_UNIX"; do
    expect_true "the units lack: $line" grep -qxF -- "$line" <<<"$all"
  done
  run log_of systemctl
  expect_out $'systemctl daemon-reload\nsystemctl enable --now mroom-mail-relay.socket mroom-mail-relay.service mroom-mailpit.service'
  # Again: nothing written, nothing restarted.
  rm "$T/systemctl.log"
  rs --smtp-port 2525 mailpit; expect_rc 0
  expect_out_has "systemd units: mroom-mail-relay.socket mroom-mail-relay.service mroom-mailpit.service already as this release writes them"
  run log_of systemctl
  expect_out $'systemctl daemon-reload\nsystemctl enable --now mroom-mail-relay.socket mroom-mail-relay.service mroom-mailpit.service'
  # A unit that changed is written again, and its service restarted.
  printf '# a local change\n' >>"$T/systemd/mroom-mailpit.service"
  rm "$T/systemctl.log"
  rs --smtp-port 2525 mailpit; expect_rc 0
  expect_out_has "systemd units written: mroom-mailpit.service"
  run log_of systemctl; expect_out_has "systemctl restart mroom-mailpit.service"
  expect_true "the local change stayed" lacks "$(cat "$T/systemd/mroom-mailpit.service")" "a local change"
  # A new port: the socket is restarted, which frees the port for a moment, so every login is renewed.
  rm "$T/systemctl.log"
  rs --smtp-port 2526 mailpit; expect_rc 0
  expect_out_has "systemd units written: mroom-mail-relay.socket mroom-mail-relay.service"
  expect_out_has "the SMTP port changed, and was free for a moment: give each QA environment new mail logins (mail-user-add)"
  run log_of systemctl
  expect_out_has "systemctl restart mroom-mail-relay.service"
  expect_out_has "systemctl restart mroom-mail-relay.socket mroom-mail-relay.service"
  # No port given: 1025.
  rm -r "$T/systemd"; mkdir "$T/systemd"
  rs mailpit; expect_rc 0
  expect_true "the port is not 1025 when none is given" grep -qxF "ListenStream=127.0.0.1:1025" "$T/systemd/mroom-mail-relay.socket"
  expect_true "a unit was left half written" eval '[ -z "$(find "$T/systemd" -name ".*")" ]'
}

t_the_garage_unit() {
  world
  rs garage
  expect_rc 0; expect_out_has "systemd units written: mroom-garage.service"
  local base="$T/home/.local/share/mroom-services/garage" secrets="$T/home/.config/mroom/secrets" line
  run mode "$T/systemd/mroom-garage.service"; expect_out 644
  for line in "ExecStart=$base/current/garage -c $base/garage.toml server" "User=$USER_NAME" "Group=$GROUP_NAME" \
    "Restart=always" "StartLimitIntervalSec=0" "PrivateNetwork=yes" "ProtectHome=tmpfs" "ProtectSystem=strict" \
    "BindPaths=$base/meta $base/data $base/run" \
    "BindReadOnlyPaths=$base $secrets/garage-rpc-secret $secrets/garage-admin-token $secrets/garage-metrics-token"; do
    expect_true "the unit lacks: $line" grep -qxF -- "$line" "$T/systemd/mroom-garage.service"
  done
  run log_of systemctl; expect_out $'systemctl daemon-reload\nsystemctl enable --now mroom-garage.service'
  expect_no_file "$T/systemd/mroom-mailpit.service"
}

t_the_reverb_unit() {
  world
  rs reverb
  expect_rc 0; expect_out_has "systemd units written: mroom-reverb.service"
  local base="$T/home/.local/share/mroom-services/reverb" line
  run mode "$T/systemd/mroom-reverb.service"; expect_out 644
  for line in "ExecStart=/usr/bin/php -d pcre.jit=0 -d opcache.jit=disable $base/current/artisan reverb-host:start" "User=$USER_NAME" \
    "Group=$GROUP_NAME" "Restart=always" "StartLimitIntervalSec=0" "PrivateNetwork=yes" "RestrictAddressFamilies=AF_UNIX" \
    "MemoryDenyWriteExecute=yes" "ProtectHome=tmpfs" "ProtectSystem=strict" "UMask=0077" \
    "BindReadOnlyPaths=$base" "BindPaths=$base/run" \
    "Environment=REVERB_HOST_SOCKET=$base/run/reverb.sock REVERB_HOST_APPS=$base/apps/apps.json"; do
    expect_true "the unit lacks: $line" grep -qxF -- "$line" "$T/systemd/mroom-reverb.service"
  done
  # The apps file is never bound on its own: that would keep the file the host found at start.
  expect_true "the unit binds the apps file itself" eval '! grep -q "apps.json" <(grep -E "^Bind" "$T/systemd/mroom-reverb.service")'
  run log_of systemctl; expect_out $'systemctl daemon-reload\nsystemctl enable --now mroom-reverb.service'
  expect_no_file "$T/systemd/mroom-garage.service"
}

# Every line of every unit is one this test allows: a unit could otherwise give the box user root, through
# lines such as AmbientCapabilities=, SupplementaryGroups=, LoadCredential=, StandardOutput=file: or
# RuntimeDirectory=, which a checklist of what to refuse would always miss some of.
t_every_unit_line_is_one_mroom_allows() {
  world
  rs mailpit garage reverb; expect_rc 0
  run python3 -I - "$USER_NAME" "$GROUP_NAME" "$T/home" "$T"/systemd/mroom-* <<'PY'
import re, sys
user, group, home, *files = sys.argv[1:]
allowed = {
    "Unit": {"Description", "Requires", "After", "StartLimitIntervalSec"},
    "Socket": {"ListenStream", "Accept"},
    "Service": {"User", "Group", "ExecStart", "Environment", "WorkingDirectory", "Restart", "RestartSec", "UMask", "LimitNOFILE",
                "NoNewPrivileges", "ProtectSystem", "ProtectHome", "BindReadOnlyPaths", "BindPaths", "PrivateTmp",
                "PrivateDevices", "PrivateNetwork", "RestrictAddressFamilies", "SystemCallFilter",
                "SystemCallArchitectures", "CapabilityBoundingSet", "LockPersonality", "MemoryDenyWriteExecute",
                "RestrictNamespaces", "RestrictRealtime", "RestrictSUIDSGID", "ProtectKernelTunables",
                "ProtectKernelModules", "ProtectControlGroups"},
    "Install": {"WantedBy"},
}
envs = {"APP_ENV", "APP_DEBUG", "LOG_CHANNEL", "LOG_LEVEL", "CACHE_STORE", "QUEUE_CONNECTION", "REVERB_HOST_SOCKET",
        "REVERB_HOST_APPS"}
must = {"User": user, "Group": group, "NoNewPrivileges": "yes", "CapabilityBoundingSet": "", "ProtectSystem": "strict",
        "ProtectHome": "tmpfs", "RestrictSUIDSGID": "yes"}
bad = []
for path in files:
    section, seen = None, {}
    for n, line in enumerate(open(path).read().splitlines(), 1):
        if not line or line.startswith("#"):
            continue
        if re.fullmatch(r"\[(\w+)\]", line):
            section = line[1:-1]
            if section not in allowed:
                bad.append(f"{path}:{n}: section {line}")
            continue
        key, eq, value = line.partition("=")
        if not eq or section not in allowed or key not in allowed[section]:
            bad.append(f"{path}:{n}: {line}")
            continue
        seen[key] = value
        if key == "ExecStart" and not (re.match(r"/usr/bin/python3 -I " + re.escape(home) + "/", value)
                                       or re.match(r"/usr/bin/php -d pcre\.jit=0 -d opcache\.jit=disable " + re.escape(home) + "/", value)
                                       or value.startswith(home + "/")):
            bad.append(f"{path}:{n}: runs something outside the box user's home: {line}")
        # Only these settings, with plain values: no LD_PRELOAD, PATH or the like.
        if key == "Environment":
            for word in value.split(" "):
                name, _, setting = word.partition("=")
                if name not in envs or not re.fullmatch(r"[A-Za-z0-9_./-]+", setting):
                    bad.append(f"{path}:{n}: sets {word}")
        if key == "ListenStream" and not re.fullmatch(r"127\.0\.0\.1:\d{4,5}", value):
            bad.append(f"{path}:{n}: listens beyond 127.0.0.1: {line}")
        if key == "WantedBy" and value not in ("sockets.target", "multi-user.target"):
            bad.append(f"{path}:{n}: {line}")
    if path.endswith(".service"):
        for key, value in must.items():
            if seen.get(key) != value:
                bad.append(f"{path}: {key}= is {seen.get(key)!r}, not {value!r}")
print("\n".join(bad) or "all allowed")
PY
  expect_out "all allowed"
}

t_site_op_and_its_sudoers_line() {
  world
  rs site-op
  expect_rc 0
  expect_out_has "site-op: installed from the checkout beside this file, with the sudoers line that lets $USER_NAME run it as an isolated user"
  expect_true "the installed site-op is not this release's" cmp -s "$ROOT/lib/site-op" "$T/libexec/site-op"
  run mode "$T/libexec/site-op"; expect_out 755
  run cat "$T/sudoers/mroom-gate"; expect_out "$USER_NAME ALL=(%isolated) NOPASSWD: $T/libexec/site-op"
  run mode "$T/sudoers/mroom-gate"; expect_out 440
  # Checked under a name sudo skips, and only then put in place.
  run log_of visudo; expect_out "visudo -cf $T/sudoers/.mroom-gate.new"
  expect_no_file "$T/sudoers/.mroom-gate.new"
  expect_no_file "$T/libexec/.site-op.new"
  # The SHA-256 it checks site-op against is this release's site-op's.
  run sed -n 's/^SITE_OP_SHA256="\(.*\)"$/\1/p' "$ROOT/lib/root-setup"
  expect_out "$(sha "$ROOT/lib/site-op")"

  # From a release: downloaded over https alone, and checked.
  rm -r "$T/libexec" "$T/sudoers"; mkdir "$T/libexec" "$T/sudoers"
  mkdir -p "$T/served/refs/tags/v9.9.9/lib"
  cp "$ROOT/lib/site-op" "$T/served/refs/tags/v9.9.9/lib/site-op"
  rs --release v9.9.9 site-op
  expect_rc 0; expect_out_has "site-op: installed from v9.9.9"
  run log_of curl
  expect_out_has "--proto =https --proto-redir =https"
  expect_out_has "https://raw.githubusercontent.com/milroyfraser/mroom/refs/tags/v9.9.9/lib/site-op"
  expect_true "the downloaded site-op is not installed" cmp -s "$ROOT/lib/site-op" "$T/libexec/site-op"
  # One that is not the release's is refused, and nothing changes.
  rm -r "$T/libexec" "$T/sudoers"; mkdir "$T/libexec" "$T/sudoers"
  printf '\necho planted\n' >>"$T/served/refs/tags/v9.9.9/lib/site-op"
  rs --release v9.9.9 site-op
  expect_rc 1; expect_err_has "that site-op is not this release's: its SHA-256 differs; nothing changed"
  expect_no_file "$T/libexec/site-op"; expect_no_file "$T/sudoers/mroom-gate"
  rs --release v9.9.8 site-op
  expect_rc 1; expect_err_has "could not download site-op of v9.9.8"
  # A sudoers line visudo refuses is never put in place.
  touch "$T/visudo-refuses"
  rs site-op
  expect_rc 1; expect_err_has "visudo refused the sudoers line; site-op is installed, the line is not"
  expect_no_file "$T/sudoers/mroom-gate"; expect_no_file "$T/sudoers/.mroom-gate.new"
  # On a box with no visudo, it says the line goes in unchecked.
  rm "$T/bin/visudo" "$T/visudo-refuses"
  run env PATH="$T/bin:/usr/bin:/bin" "$ROOT/lib/root-setup" --user "$USER_NAME" --home "$T/home" site-op
  expect_rc 0; expect_out_has "site-op: this box has no visudo, so the sudoers line goes in unchecked, as this file writes it"
  expect_file "$T/sudoers/mroom-gate"
}

t_a_run_that_stops_halfway_is_finished_by_the_next() {
  world
  rs --smtp-port 2525 mailpit; expect_rc 0
  # A new port, and the restarts fail: the units are written, and their restarts left pending.
  touch "$T/systemctl-fails-restart"
  rs --smtp-port 2526 mailpit
  expect_rc 1
  expect_out_has "systemd units written: mroom-mail-relay.socket mroom-mail-relay.service"
  expect_file "$T/state/pending/mroom-mail-relay.service"; expect_file "$T/state/pending/port-moved"
  # The next run finds the files written, and does the restarts still owed.
  rm "$T/systemctl-fails-restart" "$T/systemctl.log"
  rs --smtp-port 2526 mailpit
  expect_rc 0
  expect_out_has "systemd units: mroom-mail-relay.socket mroom-mail-relay.service mroom-mailpit.service already as this release writes them"
  expect_out_has "restarted to run their new text: mroom-mail-relay.service"
  expect_out_has "the SMTP port changed, and was free for a moment: give each QA environment new mail logins (mail-user-add)"
  run log_of systemctl
  expect_out_has "systemctl restart mroom-mail-relay.service"
  expect_out_has "systemctl restart mroom-mail-relay.socket mroom-mail-relay.service"
  expect_no_file "$T/state/pending/mroom-mail-relay.service"; expect_no_file "$T/state/pending/port-moved"
  # And the one after has nothing left to do.
  rm "$T/systemctl.log"
  rs --smtp-port 2526 mailpit; expect_rc 0
  run log_of systemctl
  expect_out $'systemctl daemon-reload\nsystemctl enable --now mroom-mail-relay.socket mroom-mail-relay.service mroom-mailpit.service'
}

t_what_root_setup_refuses() {
  world
  local args
  while IFS='|' read -r args message; do
    # shellcheck disable=SC2086  # each case is words
    run "$ROOT/lib/root-setup" $args
    expect_rc 1; expect_err_has "$message"
  done <<EOF
--user $USER_NAME|name the parts to install: site-op, mailpit, garage or reverb
--user $USER_NAME nginx|unknown argument 'nginx'
--user|--user needs a value
--user Bad mailpit|--user needs the box user's name
--user nosuchuser9 mailpit|there is no user nosuchuser9
--user root mailpit|the box user cannot be root
--user $USER_NAME --smtp-port 80 mailpit|--smtp-port takes a port from 1024 to 65535
--user $USER_NAME --smtp-port 70000 mailpit|--smtp-port takes a port from 1024 to 65535
--user $USER_NAME --smtp-port 25x mailpit|--smtp-port takes a port from 1024 to 65535
--user $USER_NAME --release main site-op|--release takes a tag, such as v0.4.0
--user $USER_NAME --release v1.2 site-op|--release takes a tag, such as v0.4.0
--user $USER_NAME --home home mailpit|is not a plain path
--user $USER_NAME --home /home/../root mailpit|is not a plain path
EOF
  run env -u MROOM_ROOT_SETUP_TEST "$ROOT/lib/root-setup" --user "$USER_NAME" mailpit
  expect_rc 1; expect_err_has "run this as root, through mroom's root recipe (README, \"The root recipe\")"
  # As root, the test setting is refused: its folders come from the environment.
  printf '#!/bin/sh
if [ "$1" = -u ]; then echo 0; else exec /usr/bin/id "$@"; fi
' >"$T/bin/id"
  chmod +x "$T/bin/id"
  rs mailpit
  expect_rc 1; expect_err_has "MROOM_ROOT_SETUP_TEST is a setting for tests: never set it as root"
  expect_no_file "$T/systemd/mroom-mailpit.service"
}

# recipe: the README's root recipe, as written there.
recipe() { awk '/^<!-- root-recipe/ { f = 1; next } f && /^```bash$/ { g = 1; next } g && /^```$/ { exit } g' "$ROOT/README.md"; }

t_the_readme_recipe() {
  world
  local text v sum file where expected
  text="$(recipe)"
  v="$(sed -n 's/^v=//p' <<<"$text")" sum="$(sed -n 's/^sum=//p' <<<"$text")"
  expect_true "the recipe names no release tag: $v" eval '[[ "$v" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]'
  # Its sum is of lib/root-setup at its tag once the tag exists, and until then (a release PR sets v and sum
  # together) of this checkout's.
  local served="$T/served/refs/tags/$v/lib"
  mkdir -p "$served"
  if git -C "$ROOT" rev-parse -q --verify "refs/tags/$v" >/dev/null 2>&1; then
    where="the tag $v"
    for file in root-setup site-op; do
      git -C "$ROOT" show "$v:lib/$file" >"$served/$file"
      # The recipe installs what this checkout holds: a change since that release moves v and sum to the next.
      expect_true "lib/$file changed since $v: set the README's root recipe to the next release's v, and sum to this lib/root-setup's" \
        cmp -s "$served/$file" "$ROOT/lib/$file"
    done
  else
    where="this checkout"
    cp "$ROOT/lib/root-setup" "$ROOT/lib/site-op" "$served/"
  fi
  expected="$(sha "$served/root-setup")"
  expect_true "the README's root recipe has sum $sum, but lib/root-setup at $where is $expected" [ "$sum" = "$expected" ]
  # Run, for this test's user, it installs every part from the release.
  text="$(awk -v u="$USER_NAME" '$0 == "user=forge" { $0 = "user=" u } { print }' <<<"$text")"
  run bash -c "$text"
  expect_rc 0
  expect_out_has "site-op: installed from $v"
  expect_out_has "systemd units written: mroom-mail-relay.socket mroom-mail-relay.service mroom-mailpit.service"
  expect_out_has "systemd units written: mroom-garage.service"
  expect_out_has "systemd units written: mroom-reverb.service"
  run log_of curl; expect_out_has "https://raw.githubusercontent.com/milroyfraser/mroom/refs/tags/$v/lib/root-setup"
  # A file that is not the one its sum names never runs.
  rm -r "$T/systemd" "$T/libexec" "$T/sudoers"; mkdir "$T/systemd" "$T/libexec" "$T/sudoers"
  printf '\necho planted\n' >>"$served/root-setup"
  run bash -c "$text"
  expect_true "a file its sum does not name ran" [ "$rc" != 0 ]
  expect_true "a file its sum does not name ran" lacks "$out" "planted"
  expect_no_file "$T/systemd/mroom-mailpit.service"; expect_no_file "$T/libexec/site-op"
  # Nor does anything but a release tag.
  run bash -c "$(awk '/^v=/ { $0 = "v=main" } { print }' <<<"$text")"
  expect_rc 1; expect_err_has "v must be a release tag, such as v0.4.0"
}

test_case mailpit t_the_mailpit_units
test_case garage t_the_garage_unit
test_case reverb t_the_reverb_unit
test_case allowed-lines t_every_unit_line_is_one_mroom_allows
test_case site-op t_site_op_and_its_sudoers_line
test_case halfway t_a_run_that_stops_halfway_is_finished_by_the_next
test_case refusals t_what_root_setup_refuses
test_case readme-recipe t_the_readme_recipe
finish
