#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2016  # t_* run through test_case; a $ in single quotes is meant literally
# Tests for `mroom doctor` (lib/doctor): the box checks and, with --app, an app's mroom.toml, its workflow pins and
# the app contract against the box. Each check says ok, warn or fail with a fix, a fail exits 1, and no secret is
# ever printed. Offline: psql, redis-cli and curl are fakes; the box's /proc, sshd_config, services and site-op are
# folders of the test's own.
set -euo pipefail
SUITE=doctor
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
skip_unless has_box_tools "this host lacks bash 5, flock or GNU date, which box commands need"
skip_unless has_tomllib "python3 cannot read TOML (3.11 or later needed)"

TAG="v$(cat "$ROOT/VERSION")"
PG_PASSWORD="pg-secret-$RANDOM$RANDOM"
REDIS_PASSWORD="redis-secret-$RANDOM$RANDOM"

lacks() { case "$1" in *"$2"*) return 1 ;; *) return 0 ;; esac; }
expect_out_lacks() { case "$out" in *"$1"*) fail "stdout has: $1" ;; *) ok ;; esac; }

# caller <workflow> [<ref>] [<secret...>]: the app's workflow that calls one of mroom's, as the README shows it.
caller() {
  local name="$1" ref="${2:-$TAG}" secret
  shift 2 || shift $#
  {
    printf 'name: %s\non: workflow_dispatch\njobs:\n  qa:\n    uses: milroyfraser/mroom/.github/workflows/%s.yml@%s\n' "$name" "$name" "$ref"
    if [ "$#" -gt 0 ]; then
      printf '    secrets:\n'
      for secret in "$@"; do printf '      %s: ${{ secrets.%s }}\n' "$secret" "$secret"; done
    fi
  } >"$T/app/.github/workflows/$name.yml"
}

# world: a box set up as the README says, and an app (one Laravel app with Vite inside it) whose mroom.toml it
# meets. Every check passes in it.
world() {
  export T  # the fakes answer from files under it
  # A test may call it again for a fresh app and box: what the last one left goes first.
  if [ -d "$T/libexec" ]; then chmod u+w "$T/libexec"; fi
  if [ -d "$T/services" ]; then chmod -R u+w "$T/services"; fi
  rm -rf "$T/app" "$T/pg" "$T/redis" "$T/live" "$T/libexec" "$T/services" "$T/ssh" "$HOME/.config/mroom" "$HOME/.ssh"
  mkdir -p "$HOME/.config/mroom/secrets" "$HOME/.ssh" "$T/bin" "$T/pg" "$T/redis" "$T/live" "$T/proc/sys/fs" \
    "$T/ssh/sshd_config.d" "$T/libexec"
  printf 'MROOM_APP_NAME=shop\nMROOM_QA_TEMPLATE=shop_qa_template\nMROOM_QA_ZONE=qa.example.test\n' >"$HOME/.config/mroom/box.env"
  printf '[mroom-gate]\nhost=127.0.0.1\nport=5432\ndbname=postgres\nuser=shop_qa_gate\npassword=%s\n' "$PG_PASSWORD" \
    >"$HOME/.config/mroom/secrets/pg_service.conf"
  printf 'REDIS_GATE_USER=mroom-gate\nREDIS_GATE_PASSWORD=%s\n' "$REDIS_PASSWORD" >"$HOME/.config/mroom/secrets/redis-gate.env"
  printf 'MAILPIT_API_USER=mroom-gate\nMAILPIT_API_PASSWORD=mail-secret\n' >"$HOME/.config/mroom/secrets/mailpit.env"
  chmod 600 "$HOME/.config/mroom/secrets/"*
  {
    printf 'restrict,command="%s gate provision" ssh-ed25519 AAAAC3provision mroom-qa-up\n' "$MROOM"
    printf 'restrict,command="%s gate template" ssh-ed25519 AAAAC3template mroom-qa-template\n' "$MROOM"
    printf 'restrict,command="%s gate browser" ssh-ed25519 AAAAC3browser mroom-qa-browser\n' "$MROOM"
    printf 'ssh-ed25519 AAAAC3person a-person\n'
  } >"$HOME/.ssh/authorized_keys"

  # site-op as root's recipe installs it: the release's own, in a folder the box user cannot change.
  cp "$ROOT/lib/site-op" "$T/libexec/site-op"
  chmod 555 "$T/libexec/site-op" "$T/libexec"
  export MROOM_GATE_SITE_OP="$T/libexec/site-op" MROOM_GATE_SITE_OP_OWNER
  MROOM_GATE_SITE_OP_OWNER="$(id -u)"

  # The QA services, set up by mroom baseline, each answering.
  services_tree mailpit/run mailpit/etc garage/run garage/etc reverb/run reverb/apps
  printf 'token\n' >"$T/services/garage/etc/garage-admin-token"
  printf '{"apps": []}\n' >"$T/services/reverb/apps/apps.json"
  chmod 600 "$T/services/garage/etc/garage-admin-token" "$T/services/reverb/apps/apps.json"
  touch "$T/live/mailpit" "$T/live/garage" "$T/live/reverb"

  export MROOM_PROC="$T/proc" MROOM_SSHD_CONFIG="$T/ssh/sshd_config"
  printf 'MemTotal:       16384000 kB\nMemFree:         2000000 kB\nMemAvailable:    9000000 kB\nSwapFree:        1000000 kB\n' \
    >"$T/proc/meminfo"
  echo 1 >"$T/proc/sys/fs/protected_hardlinks"
  printf 'Include %s/sshd_config.d/*.conf\n#AllowAgentForwarding yes\nDenyGroups isolated\nAllowAgentForwarding no\n' "$T/ssh" \
    >"$T/ssh/sshd_config"

  cat >"$T/bin/psql" <<'FAKE'
#!/usr/bin/env bash
# Logs its arguments and service to $T/psql.log, and answers each of doctor's queries, by its tag, from $T/pg/*.
printf 'args=%s service=%s file=%s password=%s\n' "$*" "${PGSERVICE:-}" "${PGSERVICEFILE:-}" "${PGPASSWORD:+set}" >>"$T/psql.log"
sql="$(cat)"
if [ -f "$T/pg/down" ]; then echo 'psql: error: connection to server at "127.0.0.1", port 5432 failed: Connection refused' >&2; exit 2; fi
case "$sql" in
  *doctor:version*) cat "$T/pg/version" 2>/dev/null || echo 160004 ;;
  *"doctor:role "*)
    role="$(sed -n 's/.*doctor:role \([a-z0-9_]*\).*/\1/p' <<<"$sql")"
    cat "$T/pg/role-$role" 2>/dev/null || echo "1 1" ;;
  *doctor:objects-owns*) cat "$T/pg/objects-owns" 2>/dev/null || echo 0 ;;
  *doctor:template*) cat "$T/pg/template" 2>/dev/null || echo shop_qa_template ;;
  *doctor:public-connect*) cat "$T/pg/public-connect" 2>/dev/null || true ;;
  *) echo "fake psql: no answer for: $sql" >&2; exit 3 ;;
esac
FAKE
  cat >"$T/bin/redis-cli" <<'FAKE'
#!/usr/bin/env bash
# Logs its arguments and whether REDISCLI_AUTH was set to $T/redis.log, and answers from $T/redis/*.
printf 'args=%s auth=%s\n' "$*" "${REDISCLI_AUTH:+set}" >>"$T/redis.log"
[ ! -f "$T/redis/down" ] || { echo "Could not connect to Redis at 127.0.0.1:6379: Connection refused" >&2; exit 1; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h | -p | --user) shift 2 ;;
    -e | --no-auth-warning) shift ;;
    *) break ;;
  esac
done
case "$*" in
  "INFO server") printf '# Server\r\nredis_version:%s\r\n' "$(cat "$T/redis/version" 2>/dev/null || echo 7.2.4)" ;;
  "CONFIG GET aclfile") printf 'aclfile\n%s\n' "$(cat "$T/redis/aclfile" 2>/dev/null || echo /etc/redis/users.acl)" ;;
  "ACL LIST") cat "$T/redis/acl-list" 2>/dev/null || printf 'user default off sanitize-payload &* -@all\nuser mroom-gate on #abc ~* &* +@all\n' ;;
  *) echo "ERR unknown" >&2; exit 1 ;;
esac
FAKE
  cat >"$T/bin/curl" <<'FAKE'
#!/usr/bin/env bash
# A service answers 200 when $T/live/<service> exists; the service is the folder its socket's run/ is in.
socket=""
while [ "$#" -gt 0 ]; do
  case "$1" in --unix-socket) socket="$2"; shift 2 ;; *) shift ;; esac
done
service="$(basename "$(dirname "$(dirname "$socket")")")"
if [ -n "$socket" ] && [ -f "$T/live/$service" ]; then printf 200; else printf 000; fi
FAKE
  chmod +x "$T/bin/psql" "$T/bin/redis-cli" "$T/bin/curl"
  export PATH="$T/bin:$PATH"

  # The app.
  mkdir -p "$T/app/.github/workflows" "$T/app/app/Http/Middleware" "$T/app/bootstrap" "$T/app/routes"
  cat >"$T/app/mroom.toml" <<'TOML'
[app]
name = "shop"
backend_dir = "."
frontend_dir = "."
php = "8.4"

[app.build]
after_deploy = ["config:cache", "route:cache"]

[app.build.frontend_env]
VITE_REVERB_APP_KEY = "env:REVERB_APP_KEY"
VITE_REVERB_HOST = "env:REVERB_HOST"
VITE_REVERB_PORT = "env:REVERB_PORT"
VITE_REVERB_SCHEME = "env:REVERB_SCHEME"

[qa]
zone = "qa.example.test"
TOML
  caller qa-plan
  caller qa-up "$TAG" MROOM_FORGE_TOKEN MROOM_QA_SSH_KEY MROOM_QA_ENV_TEMPLATE
  caller qa-down "$TAG" MROOM_FORGE_TOKEN MROOM_QA_SSH_KEY
  caller qa-reap "$TAG" MROOM_FORGE_TOKEN
  printf '#!/usr/bin/env php\n<?php\n' >"$T/app/artisan"
  printf "<?php\nclass VerifyCsrfToken { protected function cookieName() { return env('XSRF_COOKIE_NAME', 'XSRF-TOKEN'); } }\n" \
    >"$T/app/app/Http/Middleware/VerifyCsrfToken.php"
  printf "<?php\nreturn Application::configure()->withRouting(web: __DIR__.'/../routes/web.php', health: '/up')->create();\n" \
    >"$T/app/bootstrap/app.php"
  printf "<?php\nRoute::get('/version', VersionController::class);\n" >"$T/app/routes/web.php"
  printf "<?php\nSchedule::command('queue:prune-batches')->daily();\n" >"$T/app/routes/console.php"
}

doctor_app() { run "$MROOM" doctor --app "$T/app"; }

t_a_box_and_app_as_mroom_needs_them_pass() {
  world
  doctor_app
  expect_rc 0
  expect_out_has "ok    config: $T/app/mroom.toml is valid"
  expect_out_has "ok    workflow qa-up: .github/workflows/qa-up.yml calls it at @$TAG, the box's release"
  expect_out_has "ok    workflow qa-reap: .github/workflows/qa-reap.yml calls it at @$TAG"
  expect_out_has "ok    parity: QA runs production's services"
  expect_out_has "ok    sockets: app.build.frontend_env gives the frontend its Reverb app"
  expect_out_has "ok    isolation: the backend reads every setting that keeps environments apart"
  expect_out_has "ok    names: box.env's MROOM_APP_NAME is mroom.toml's app.name (shop)"
  expect_out_has "ok    gate-keys: a key is forced to mroom gate provision"
  expect_out_has "ok    postgres: the gate holds shop_qa_readers with ADMIN OPTION"
  expect_out_has "ok    template: the QA template shop_qa_template is loaded"
  expect_out_has "ok    redis: Redis's default user is off"
  expect_out_has "ok    site-op: $T/libexec/site-op is root's and this release's"
  expect_out_has "ok    reverb: it is set up and answers"
  expect_out_has "ok    memory: the box's 16000 MB, less its reserve of 4096 MB, holds qa.max_envs (5)"
  expect_out_has "ok    sshd: DenyGroups isolated"
  expect_out_has ", 0 warn, 0 fail"
  expect_err_empty
  # No secret is printed, and none travels on a command line.
  expect_out_lacks "$PG_PASSWORD"
  expect_out_lacks "$REDIS_PASSWORD"
  expect_out_lacks "mail-secret"
  expect_true "a password reached psql's command line" lacks "$(cat "$T/psql.log")" "$PG_PASSWORD"
  expect_true "psql did not use the gate's service" grep -q "service=mroom-gate file=$HOME/.config/mroom/secrets/pg_service.conf password= *$" "$T/psql.log"
  expect_true "a password reached redis-cli's command line" lacks "$(cat "$T/redis.log")" "$REDIS_PASSWORD"
  expect_true "redis-cli got no REDISCLI_AUTH" grep -q "auth=set" "$T/redis.log"
}

t_without_app_it_checks_the_box_alone() {
  world
  cd "$T/home"
  run "$MROOM" doctor
  expect_rc 0
  expect_out_lacks "== app"
  expect_out_has "== box"
  expect_out_has "ok    names: MROOM_APP_NAME is shop"
  expect_out_has "ok    garage: it is set up and answers"
  # A service the box has not set up is left out when no app asks for it.
  chmod -R u+w "$T/services"
  rm -rf "$T/services/garage"
  run "$MROOM" doctor
  expect_rc 0
  expect_out_lacks "garage:"
  # A box with no QA gate is told so, and its kernel and sshd are still checked.
  printf 'MROOM_BOX_NAME=one\n' >"$HOME/.config/mroom/box.env"
  run "$MROOM" doctor
  expect_rc 0
  expect_out_has "warn  names: MROOM_APP_NAME is not set in box.env, so this box has no QA gate"
  expect_out_has "ok    kernel: fs.protected_hardlinks is 1"
  expect_out_lacks "gate-keys:"
}

t_usage_and_a_missing_app() {
  world
  run "$MROOM" doctor --frobnicate; expect_rc 2; expect_err_has "unknown argument '--frobnicate'"
  run "$MROOM" doctor --help; expect_rc 0; expect_out_has "mroom doctor --app [<dir>]"
  run "$MROOM" doctor --app "$T/home"; expect_rc 1; expect_err_has "$T/home has no mroom.toml"
  # --app with no folder finds mroom.toml by walking up from here.
  cd "$T/app/routes"
  run "$MROOM" doctor --app; expect_rc 0; expect_out_has "ok    config: $T/app/mroom.toml is valid"
}

t_an_invalid_mroom_toml_fails_and_stops_the_app_checks() {
  world
  sed -i 's/^name = "shop"/name = "Shop!"/' "$T/app/mroom.toml"
  doctor_app
  expect_rc 1
  expect_out_has "fail  config: $T/app/mroom.toml is not valid: "
  expect_out_has "fix: mroom config validate lists every error"
  expect_out_lacks "workflow qa-up"
  # An unknown key only warns.
  world
  printf '\n[persona]\nnmae = "x"\n' >>"$T/app/mroom.toml"
  doctor_app
  expect_rc 0
  expect_out_has "warn  config: "
  expect_out_has "unknown key \"persona.nmae\""
}

t_qa_off_skips_the_qa_checks() {
  world
  sed -i '/^\[qa\]/,$d' "$T/app/mroom.toml"
  doctor_app
  expect_rc 0
  expect_out_has "warn  qa: qa.zone is not set, so the app has no QA environments"
  expect_out_lacks "workflow qa-up"
  expect_out_lacks "gate-keys:"
  expect_out_has "ok    kernel:"
}

t_workflows_must_be_called_and_pinned_to_the_box_release() {
  world
  rm "$T/app/.github/workflows/qa-reap.yml"
  caller qa-plan v99.0.0
  caller qa-down main MROOM_FORGE_TOKEN MROOM_QA_SSH_KEY
  caller qa-up v0.0.1 MROOM_FORGE_TOKEN MROOM_QA_SSH_KEY MROOM_QA_ENV_TEMPLATE
  doctor_app
  expect_rc 1
  expect_out_has "fail  workflow qa-reap: no workflow in .github/workflows calls milroyfraser/mroom/.github/workflows/qa-reap.yml"
  expect_out_has "fail  workflow qa-plan: .github/workflows/qa-plan.yml calls it at @v99.0.0, and the box runs mroom $TAG"
  expect_out_has "fix: upgrade the box to v99.0.0 first"
  expect_out_has "fail  workflow qa-down: .github/workflows/qa-down.yml calls it at @main"
  expect_out_has "fix: pin it to the release tag the box runs, @$TAG, never a branch or a commit"
  expect_out_has "fail  workflow qa-up: .github/workflows/qa-up.yml calls it at @v0.0.1"
  expect_out_has "fix: pin it to @$TAG, the release the box runs"
}

t_a_caller_must_pass_the_secrets_its_workflow_takes() {
  world
  caller qa-up "$TAG" MROOM_FORGE_TOKEN
  doctor_app
  expect_rc 1
  expect_out_has "fail  workflow qa-up: .github/workflows/qa-up.yml does not pass the secrets qa-up takes: MROOM_QA_SSH_KEY, MROOM_QA_ENV_TEMPLATE"
}

t_every_other_use_of_mroom_is_pinned_too() {
  world
  printf 'jobs:\n  t:\n    steps:\n      - uses: milroyfraser/mroom/actions/regression-label@v0.1.0\n      - uses: "milroyfraser/mroom/actions/qa-plan@%s"\n' "$TAG" \
    >"$T/app/.github/workflows/ci.yaml"
  doctor_app
  expect_rc 1
  expect_out_has "fail  pins: .github/workflows/ci.yaml uses milroyfraser/mroom/actions/regression-label at @v0.1.0"
  expect_out_has "ok    pins: .github/workflows/ci.yaml uses actions/qa-plan at @$TAG"
}

t_box_env_must_name_what_mroom_toml_names() {
  world
  printf 'MROOM_APP_NAME=store\nMROOM_QA_ZONE=qa.other.test\nMROOM_QA_PHP=php8.3\nMROOM_QA_PERSONA_DOMAIN=.example\n' \
    >"$HOME/.config/mroom/box.env"
  printf '[persona]\nname = "Agent"\n' >>"$T/app/mroom.toml"
  sed -i 's/^zone = .*/&\ntemplate_database = "qa_template"/' "$T/app/mroom.toml"
  doctor_app
  expect_rc 1
  expect_out_has "fail  names: box.env's MROOM_APP_NAME is store, and mroom.toml's app.name is shop"
  expect_out_has "fix: set MROOM_APP_NAME=shop in box.env, or app.name in mroom.toml, so the two agree"
  expect_out_has "fail  names: box.env's MROOM_QA_ZONE is qa.other.test, and mroom.toml's qa.zone is qa.example.test"
  expect_out_has "fail  names: box.env's MROOM_QA_PERSONA_DOMAIN is .example, and mroom.toml's qa.persona_domain is .test"
  expect_out_has "warn  names: box.env's MROOM_QA_PHP is php8.3, and mroom.toml's app.php is 8.4"
  expect_out_has "warn  names: mroom.toml's qa.template_database is qa_template, and the gate clones box.env's MROOM_QA_TEMPLATE (not set)"
  expect_out_has "fail  names: MROOM_QA_TEMPLATE is not set in box.env"
  # A broken box.env stops the box checks at once, naming the line, never its value.
  printf 'MROOM_APP_NAME=shop\nMROOM_SECRET=hunter2\n' >"$HOME/.config/mroom/box.env"
  doctor_app
  expect_rc 1
  expect_out_has "fail  box.env: "
  expect_out_has "MROOM_SECRET is not an allowed key"
  expect_out_lacks "hunter2"
  expect_out_lacks "gate-keys:"
}

t_the_gate_allowlist_must_be_the_app_allowlist() {
  world
  sed -i 's/^zone = .*/&\ndb_read_allowlist = ["users.id", "users.email", "posts.title"]/' "$T/app/mroom.toml"
  printf 'MROOM_QA_DB_READ="users.id users.password"\n' >>"$HOME/.config/mroom/box.env"
  doctor_app
  expect_rc 1
  expect_out_has "fail  db-read: box.env's MROOM_QA_DB_READ is not mroom.toml's qa.db_read_allowlist: only in mroom.toml: posts.title users.email; only in box.env: users.password"
  expect_out_has 'fix: set MROOM_QA_DB_READ="posts.title users.email users.id" in box.env'
  # The same entries in another order agree.
  sed -i 's/^MROOM_QA_DB_READ=.*/MROOM_QA_DB_READ="users.email posts.title users.id"/' "$HOME/.config/mroom/box.env"
  doctor_app
  expect_rc 0
  expect_out_has "ok    db-read: box.env's MROOM_QA_DB_READ is mroom.toml's qa.db_read_allowlist"
  # No allowlist in mroom.toml but one on the box: a warn.
  sed -i '/^db_read_allowlist/d' "$T/app/mroom.toml"
  doctor_app
  expect_rc 0
  expect_out_has "warn  db-read: box.env's MROOM_QA_DB_READ lets db-read read posts.title users.email users.id, and mroom.toml has no qa.db_read_allowlist"
}

t_the_gate_keys_are_restricted_and_forced_to_a_role() {
  world
  rm "$HOME/.ssh/authorized_keys"
  doctor_app
  expect_rc 1
  expect_out_has "fail  gate-keys: no key in ~/.ssh/authorized_keys is forced to mroom gate provision"
  expect_out_has "warn  gate-keys: no key is forced to mroom gate template"
  {
    printf 'command="%s gate provision" ssh-ed25519 AAAAC3a qa-up\n' "$MROOM"
    printf 'restrict,command="%s/nowhere/mroom gate template" ssh-ed25519 AAAAC3b qa-template\n' "$T"
    printf 'restrict,command="%s gate shell" ssh-ed25519 AAAAC3c odd\n' "$MROOM"
    printf '# restrict,command="mroom gate browser" a comment\n'
  } >"$HOME/.ssh/authorized_keys"
  sed -i 's/^zone = .*/&\ndb_read_allowlist = []/' "$T/app/mroom.toml"
  doctor_app
  expect_rc 1
  expect_out_has "fail  gate-keys: the provision key in ~/.ssh/authorized_keys is not restrict-ed"
  expect_out_has "fail  gate-keys: the template key is forced to $T/nowhere/mroom, which is not an mroom that runs"
  expect_out_has "fail  gate-keys: a key in ~/.ssh/authorized_keys is forced to \"$MROOM gate shell\""
  expect_out_has "warn  gate-keys: no key is forced to mroom gate browser"
  expect_out_lacks "AAAAC3"
}

t_the_gate_secret_files_are_private_and_complete() {
  world
  chmod 644 "$HOME/.config/mroom/secrets/pg_service.conf"
  printf 'REDIS_GATE_USER=mroom-gate\n' >"$HOME/.config/mroom/secrets/redis-gate.env"
  doctor_app
  expect_rc 1
  expect_out_has "fail  secrets: ~/.config/mroom/secrets/pg_service.conf must be yours and mode 600"
  expect_out_has "fail  secrets: ~/.config/mroom/secrets/redis-gate.env sets no REDIS_GATE_PASSWORD"
  expect_out_lacks "postgres:"
  expect_out_lacks "redis:"
  expect_out_lacks "$PG_PASSWORD"
  rm "$HOME/.config/mroom/secrets/pg_service.conf"
  printf '[other]\nuser=x\npassword=%s\n' "$PG_PASSWORD" >"$HOME/.config/mroom/secrets/pg_service.conf"
  chmod 600 "$HOME/.config/mroom/secrets/pg_service.conf"
  doctor_app
  expect_out_has "fail  secrets: ~/.config/mroom/secrets/pg_service.conf has no [mroom-gate] service"
  expect_out_lacks "$PG_PASSWORD"
}

t_postgres_is_checked_as_the_gate_sees_it() {
  world
  echo 150008 >"$T/pg/version"
  doctor_app
  expect_rc 1
  expect_out_has "fail  postgres: Postgres is older than 16"
  rm "$T/pg/version"
  echo "0 0" >"$T/pg/role-shop_qa_readers"
  echo "1 0" >"$T/pg/role-shop_qa_envs"
  echo 1 >"$T/pg/objects-owns"
  printf 'shop_qa_template_next\n' >"$T/pg/template"
  printf 'forge\nshop_qa_12\nshop_qa_template\n' >"$T/pg/public-connect"
  doctor_app
  expect_rc 1
  expect_out_has "ok    postgres: Postgres 16 answers the gate's role"
  expect_out_has "fail  postgres: the role shop_qa_readers does not exist"
  expect_out_has "fail  postgres: the gate's role does not hold shop_qa_envs WITH ADMIN OPTION"
  expect_out_has "ok    postgres: the gate holds shop_qa_objects with ADMIN OPTION"
  expect_out_has "fail  postgres: shop_qa_objects owns a database or a tablespace"
  expect_out_has "fail  template: the QA template shop_qa_template is not loaded"
  expect_out_has "warn  template: a template load was cut short: shop_qa_template_next is left"
  expect_out_has "fail  postgres: any role may connect to shop_qa_12 shop_qa_template"
  expect_out_has "warn  postgres: any role may connect to forge"
  touch "$T/pg/down"
  doctor_app
  expect_rc 1
  expect_out_has "fail  postgres: cannot reach Postgres as the gate's role: psql: error: connection to server"
  expect_out_lacks "template:"
}

t_redis_is_checked_as_the_gate_sees_it() {
  world
  printf 'user default on nopass ~* &* +@all\nuser mroom-gate on #abc ~* &* +@all\n' >"$T/redis/acl-list"
  : >"$T/redis/aclfile"
  doctor_app
  expect_rc 1
  expect_out_has "fail  redis: Redis has no aclfile"
  expect_out_has "fail  redis: Redis's default user is on"
  echo 6.2.14 >"$T/redis/version"
  doctor_app
  expect_out_has "fail  redis: Redis is older than 7"
  touch "$T/redis/down"
  doctor_app
  expect_out_has "fail  redis: cannot reach Redis as the gate's user"
  expect_out_lacks "$REDIS_PASSWORD"
}

t_site_op_is_root_owned_and_this_release() {
  world
  chmod u+w "$T/libexec"
  rm -f "$T/libexec/site-op"
  doctor_app
  expect_rc 1
  expect_out_has "fail  site-op: $T/libexec/site-op is not installed, or is a link"
  printf '#!/bin/sh\n' >"$T/libexec/site-op"
  chmod 555 "$T/libexec/site-op" "$T/libexec"
  doctor_app
  expect_out_has "fail  site-op: $T/libexec/site-op is not this release's site-op"
  chmod u+w "$T/libexec"
  doctor_app
  expect_out_has "fail  site-op: $T/libexec must belong to root"
}

t_the_services_the_app_needs_are_set_up_and_answer() {
  world
  rm "$T/live/reverb"
  doctor_app
  expect_rc 1
  expect_out_has "fail  reverb: it does not answer on $T/services/reverb/run/reverb.sock"
  chmod -R u+w "$T/services"
  rm -rf "$T/services/reverb" "$T/services/garage"
  doctor_app
  expect_out_has "fail  reverb: $T/services/reverb does not exist, and mroom.toml's [qa.parity] needs reverb"
  expect_out_has "fix: run mroom's root recipe with reverb in its parts, then mroom baseline reverb"
  # A swap needs no service, and is listed as a known gap.
  printf '\n[qa.parity]\nbroadcast = "log"\nfiles = "local"\n' >>"$T/app/mroom.toml"
  doctor_app
  expect_rc 0
  expect_out_lacks "reverb:"
  expect_out_lacks "garage:"
  expect_out_has "warn  parity: a swap, a known gap from production: files = \"local\""
  expect_out_has "warn  parity: a swap, a known gap from production: broadcast = \"log\""
  expect_out_lacks "sockets:"
  # A login file that is not private fails its service.
  chmod 644 "$HOME/.config/mroom/secrets/mailpit.env"
  doctor_app
  expect_rc 1
  expect_out_has "fail  mailpit: ~/.config/mroom/secrets/mailpit.env is missing, or not yours and mode 600"
}

t_the_memory_holds_the_slots() {
  world
  sed -i 's/^MemTotal:.*/MemTotal:        8000000 kB/' "$T/proc/meminfo"
  doctor_app
  expect_rc 0
  expect_out_has "warn  memory: the box's 7812 MB, less its reserve of 4096 MB, holds 3 QA environments of 1024 MB, fewer than qa.max_envs (5)"
  printf 'MROOM_QA_RESERVE_MB=2048\n' >>"$HOME/.config/mroom/box.env"
  sed -i 's/^zone = .*/&\nmax_envs = 4\nenv_memory_mb = 1400/' "$T/app/mroom.toml"
  doctor_app
  expect_out_has "ok    memory: the box's 7812 MB, less its reserve of 2048 MB, holds qa.max_envs (4) QA environments"
  sed -i 's/^MemTotal:.*/MemTotal:        4000000 kB/' "$T/proc/meminfo"
  sed -i 's/^MROOM_QA_RESERVE_MB=.*/MROOM_QA_RESERVE_MB=4096/' "$HOME/.config/mroom/box.env"
  doctor_app
  expect_rc 1
  expect_out_has "fail  memory: the box's 3906 MB, less its reserve of 4096 MB, holds no QA environment of 1400 MB"
}

t_the_kernel_and_sshd_keep_site_users_in_place() {
  world
  echo 0 >"$T/proc/sys/fs/protected_hardlinks"
  printf 'PermitRootLogin no\n' >"$T/ssh/sshd_config"
  doctor_app
  expect_rc 1
  expect_out_has "fail  kernel: fs.protected_hardlinks is not 1"
  expect_out_has "fail  sshd: sshd_config has no DenyGroups isolated"
  expect_out_has "fail  sshd: sshd forwards SSH agents"
  # The included files count, and come first; a Match block's settings do not.
  printf 'DenyGroups isolated\nAllowAgentForwarding no\n' >"$T/ssh/sshd_config.d/50-mroom.conf"
  printf 'AllowAgentForwarding yes\n' >>"$T/ssh/sshd_config"
  echo 1 >"$T/proc/sys/fs/protected_hardlinks"
  doctor_app
  expect_rc 0
  expect_out_has "ok    sshd: AllowAgentForwarding no"
  rm "$T/ssh/sshd_config.d/50-mroom.conf"
  printf 'Match User someone\n  DenyGroups isolated\n' >"$T/ssh/sshd_config"
  doctor_app
  expect_out_has "fail  sshd: sshd_config has no DenyGroups isolated"
}

t_the_app_contract_it_can_see() {
  world
  mkdir -p "$T/app/config" "$T/app/.mroom/hooks" "$T/app/app/Console"
  printf "<?php\nreturn ['cookie' => 'shop_session', 'domain' => env('SESSION_DOMAIN')];\n" >"$T/app/config/session.php"
  printf "<?php\nreturn ['prefix' => env('CACHE_PREFIX', 'shop_cache_')];\n" >"$T/app/config/cache.php"
  rm "$T/app/app/Http/Middleware/VerifyCsrfToken.php"
  sed -i 's/^after_deploy = .*/after_deploy = ["config:cache", "optimize:clear"]/' "$T/app/mroom.toml"
  printf '#!/bin/sh\nphp artisan migrate --force\nphp artisan cache:clear\n' >"$T/app/.mroom/hooks/qa-deploy"
  printf "<?php\nSchedule::command('cache:prune-stale-tags')->hourly();\n" >"$T/app/routes/console.php"
  printf "<?php\nreturn Application::configure()->create();\n" >"$T/app/bootstrap/app.php"
  : >"$T/app/routes/web.php"
  doctor_app
  expect_rc 1
  expect_out_has "fail  isolation: qa-up sets SESSION_COOKIE for each environment, and config/session.php, which the app has published, never reads it"
  expect_out_has "fail  isolation: qa-up sets XSRF_COOKIE_NAME for each environment, and nothing in the backend reads it"
  expect_out_lacks "CACHE_PREFIX for each"
  expect_out_lacks "SESSION_DOMAIN for each"
  expect_out_has "fail  redis-commands: app.build.after_deploy runs optimize:clear"
  expect_out_has "fail  redis-commands: .mroom/hooks/qa-deploy:3 runs cache:clear"
  expect_out_has "fail  redis-commands: routes/console.php:2 runs cache:prune-stale-tags"
  expect_out_has "warn  health: no /up route found"
  expect_out_has "warn  health: no /version route found in routes/ (app.version_path)"
  # Horizon in composer.json: its config, once published, must read HORIZON_PREFIX.
  world
  mkdir -p "$T/app/config"
  printf '{"require": {"laravel/horizon": "^5.0"}}\n' >"$T/app/composer.json"
  printf "<?php\nreturn ['prefix' => 'shop_horizon:'];\n" >"$T/app/config/horizon.php"
  doctor_app
  expect_rc 1
  expect_out_has "fail  isolation: qa-up sets HORIZON_PREFIX for each environment, and config/horizon.php"
  # A backend folder with no artisan is not the Laravel app.
  world
  rm "$T/app/artisan"
  doctor_app
  expect_out_has "fail  isolation: . has no artisan, so it is not the Laravel app"
}

t_a_frontend_of_its_own_reads_its_hosts_and_sockets() {
  world
  mkdir -p "$T/app/web"
  sed -i 's/^frontend_dir = .*/frontend_dir = "web"/; /^VITE_REVERB_HOST/d' "$T/app/mroom.toml"
  printf "<?php\nreturn ['client' => env('CLIENT_URL')];\n" >"$T/app/app/client.php"
  doctor_app
  expect_rc 1
  expect_out_has "warn  sockets: app.build.frontend_env does not map VITE_REVERB_HOST"
  expect_out_has "fail  isolation: qa-up sets CORS_ALLOWED_ORIGINS for each environment, and nothing in the backend reads it"
  expect_out_lacks "CLIENT_URL for each"
  expect_out_lacks "SANCTUM_STATEFUL_DOMAINS for each"
}

test_case healthy t_a_box_and_app_as_mroom_needs_them_pass
test_case box-only t_without_app_it_checks_the_box_alone
test_case usage t_usage_and_a_missing_app
test_case invalid-config t_an_invalid_mroom_toml_fails_and_stops_the_app_checks
test_case qa-off t_qa_off_skips_the_qa_checks
test_case workflow-pins t_workflows_must_be_called_and_pinned_to_the_box_release
test_case workflow-secrets t_a_caller_must_pass_the_secrets_its_workflow_takes
test_case other-pins t_every_other_use_of_mroom_is_pinned_too
test_case names t_box_env_must_name_what_mroom_toml_names
test_case db-read t_the_gate_allowlist_must_be_the_app_allowlist
test_case gate-keys t_the_gate_keys_are_restricted_and_forced_to_a_role
test_case secrets t_the_gate_secret_files_are_private_and_complete
test_case postgres t_postgres_is_checked_as_the_gate_sees_it
test_case redis t_redis_is_checked_as_the_gate_sees_it
test_case site-op t_site_op_is_root_owned_and_this_release
test_case services t_the_services_the_app_needs_are_set_up_and_answer
test_case memory t_the_memory_holds_the_slots
test_case kernel-sshd t_the_kernel_and_sshd_keep_site_users_in_place
test_case contract t_the_app_contract_it_can_see
test_case frontend t_a_frontend_of_its_own_reads_its_hosts_and_sockets
finish
