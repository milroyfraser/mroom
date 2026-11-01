#!/usr/bin/env bash
# shellcheck disable=SC2317  # the t_* function runs indirectly, through test_case
# The gate against a real Postgres (16 or later), set up as the README's "QA gate" section says: what a
# fake psql cannot show. template-load builds the template from a pg_dump archive as the objects role and swaps
# it in; pg_hba.conf lets the gate in and keeps each environment's role to its own database; the template's
# objects change hands; db-read reads, as the environment's read-only role, what the template held and what the
# PR made later, and that role can change nothing and reach no other database; a PR cannot keep its database
# from being dropped; a role taken out of its group is put back; a second request keeps the password and --rotate
# replaces it. CI only: it
# needs sudo and a Postgres it may reconfigure (the runner's own), so tests/run.sh does not pick it up.
set -euo pipefail
SUITE=gate-real
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

su_psql() { sudo -u postgres psql -X -q -A -t -v ON_ERROR_STOP=1 "$@"; }
# as <role> <password> <database> <sql>: the SQL as that role over TCP, as an app would connect.
as() { PGPASSWORD="$2" psql -X -q -A -t -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "$1" -d "$3" -c "$4"; }
can() { as "$@" >/dev/null 2>&1; }
gate() { run env SSH_ORIGINAL_COMMAND="$1" "$MROOM" gate provision; }
browser() { run env SSH_ORIGINAL_COMMAND="$1" "$MROOM" gate browser; }
# load <database>: the database as pg_dump -Fc writes it, through template-load.
load() {
  # shellcheck disable=SC2024  # the archive is the runner's own file; postgres only writes to stdout
  sudo -u postgres pg_dump -Fc "$1" >"$T/seed.dump"
  run env SSH_ORIGINAL_COMMAND=template-load "$MROOM" gate template <"$T/seed.dump"
}
read_password_of() { sed -n 's/^DB_READ_PASSWORD=//p' "$HOME/.local/state/mroom/qa/shop_qa_$1.secrets"; }
password_of() { sed -n 's/^DB_PASSWORD=//p' <<<"$1"; }
cannot() { ! can "$@"; }

start_postgres() {
  if ! command -v pg_lsclusters >/dev/null 2>&1; then
    sudo apt-get update -qq && sudo apt-get install -y -qq postgresql >/dev/null
  fi
  read -r PG_VERSION PG_CLUSTER _ < <(pg_lsclusters -h | head -n1)
  sudo pg_ctlcluster "$PG_VERSION" "$PG_CLUSTER" start || true
  local hba="/etc/postgresql/$PG_VERSION/$PG_CLUSTER/pg_hba.conf"
  { cat "$ROOT/tests/pg/pg_hba.conf"; sudo cat "$hba"; } | sudo tee "$hba.mroom" >/dev/null
  sudo mv "$hba.mroom" "$hba"
  sudo pg_ctlcluster "$PG_VERSION" "$PG_CLUSTER" reload
  for _ in $(seq 1 30); do su_psql -c 'SELECT 1' >/dev/null 2>&1 && return 0; sleep 1; done
  echo "Postgres did not start" >&2
  exit 1
}

# set_up: the README's steps, with a password from a variable instead of \password, and the app's migrations and
# seeders standing in as a database the superuser fills.
set_up() {
  GATE_PW="gate-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
  su_psql -v gate_pw="$GATE_PW" <<'SQL'
CREATE ROLE shop_qa_gate LOGIN CREATEDB CREATEROLE PASSWORD :'gate_pw';
CREATE ROLE shop_qa_objects NOLOGIN;
GRANT shop_qa_objects TO shop_qa_gate WITH ADMIN OPTION;
CREATE ROLE shop_qa_envs NOLOGIN;
GRANT shop_qa_envs TO shop_qa_gate WITH ADMIN OPTION;
CREATE ROLE shop_qa_readers NOLOGIN;
GRANT shop_qa_readers TO shop_qa_gate WITH ADMIN OPTION;
CREATE DATABASE shop_dev;
REVOKE CONNECT ON DATABASE shop_dev FROM PUBLIC;
CREATE DATABASE shop_seed;
\c shop_seed
CREATE TABLE users (id serial PRIMARY KEY, email text, password text);
INSERT INTO users (email, password) VALUES ('ada@example.test', 'not-a-hash');
SQL
  mkdir -p "$HOME/.config/mroom/secrets"
  printf 'MROOM_APP_NAME=shop\nMROOM_QA_TEMPLATE=shop_qa_template\nMROOM_QA_DB_READ="users.id users.email notes.body"\n' \
    >"$HOME/.config/mroom/box.env"
  printf '[mroom-gate]\nhost=127.0.0.1\nport=5432\ndbname=postgres\nuser=shop_qa_gate\npassword=%s\n' "$GATE_PW" \
    >"$HOME/.config/mroom/secrets/pg_service.conf"
  chmod 600 "$HOME/.config/mroom/secrets/pg_service.conf"
}

t_the_gate_on_a_real_postgres() {
  start_postgres
  set_up

  # mroom doctor reads the same Postgres as the gate: its groups are there, and no template is loaded yet.
  run "$MROOM" doctor; expect_rc 1
  expect_out_has "ok    postgres: Postgres "
  expect_out_has "ok    postgres: the gate holds shop_qa_objects with ADMIN OPTION"
  expect_out_has "ok    postgres: the gate holds shop_qa_envs with ADMIN OPTION"
  expect_out_has "ok    postgres: the gate holds shop_qa_readers with ADMIN OPTION"
  expect_out_has "fail  template: the QA template shop_qa_template is not loaded"
  expect_out_has "warn  postgres: any role may connect to shop_seed"
  case "$out" in *"$GATE_PW"*) fail "doctor printed the gate's password" ;; *) ok ;; esac

  # The template, from the seeded database's archive; the objects role owns it and has no login left.
  load shop_seed; expect_rc 0; expect_out_has "template shop_qa_template: loaded from"
  run su_psql -c "SELECT rolcanlogin FROM pg_roles WHERE rolname = 'shop_qa_objects'"; expect_out f
  run su_psql -c "SELECT count(*) FROM pg_database WHERE datname LIKE 'shop_qa_template_%'"; expect_out 0
  run su_psql -c "SELECT has_database_privilege('public', 'shop_qa_template', 'CONNECT')"; expect_out f

  gate "db-create 12"; expect_rc 0; expect_out_has "database shop_qa_12: created"
  local pw12 pw13 old
  pw12="$(password_of "$out")"
  run as shop_qa_12 "$pw12" shop_qa_12 "SELECT count(*) FROM users"; expect_rc 0; expect_out 1
  run as shop_qa_12 "$pw12" shop_qa_12 "SELECT tableowner FROM pg_tables WHERE tablename = 'users'"
  expect_out shop_qa_12
  run as shop_qa_12 "$pw12" shop_qa_12 "CREATE TABLE notes (body text)"; expect_rc 0
  expect_true "env 12 reached postgres" cannot shop_qa_12 "$pw12" postgres "SELECT 1"
  expect_true "env 12 reached the template" cannot shop_qa_12 "$pw12" shop_qa_template "SELECT 1"
  expect_true "env 12 reached the dev database" cannot shop_qa_12 "$pw12" shop_dev "SELECT 1"
  run su_psql -d shop_qa_template -c "SELECT tableowner FROM pg_tables WHERE tablename = 'users'"
  expect_out shop_qa_objects

  # db-read: what the template held, and a table the PR made since, through the read-only role alone.
  browser "db-read 12 users id email email=ada@example.test"; expect_rc 0; expect_out '[{"id":1,"email":"ada@example.test"}]'
  browser "db-read 12 users id email=nobody@example.test"; expect_rc 0; expect_out '[]'
  run as shop_qa_12 "$pw12" shop_qa_12 "INSERT INTO notes VALUES ('first')"; expect_rc 0
  browser "db-read 12 notes body desc:body limit:1"; expect_rc 0; expect_out '[{"body":"first"}]'
  browser "db-read 12 users password"; expect_rc 1; expect_err_has "users.password is not in MROOM_QA_DB_READ"
  local rpw12
  rpw12="$(read_password_of 12)"
  expect_true "the read-only role cannot read" can shop_qa_12_read "$rpw12" shop_qa_12 "SELECT count(*) FROM notes"
  expect_true "the read-only role wrote" cannot shop_qa_12_read "$rpw12" shop_qa_12 "BEGIN READ WRITE; INSERT INTO notes VALUES ('x'); COMMIT"
  expect_true "the read-only role deleted" cannot shop_qa_12_read "$rpw12" shop_qa_12 "BEGIN READ WRITE; DELETE FROM notes; COMMIT"
  expect_true "the read-only role made a table" cannot shop_qa_12_read "$rpw12" shop_qa_12 "BEGIN READ WRITE; CREATE TABLE x (a int); COMMIT"
  expect_true "the read-only role reached postgres" cannot shop_qa_12_read "$rpw12" postgres "SELECT 1"
  expect_true "the read-only role reached the template" cannot shop_qa_12_read "$rpw12" shop_qa_template "SELECT 1"
  expect_true "the read-only role reached the dev database" cannot shop_qa_12_read "$rpw12" shop_dev "SELECT 1"
  run su_psql -c "SELECT count(*) FROM pg_auth_members WHERE member = 'shop_qa_12_read'::regrole AND roleid = 'shop_qa_12'::regrole"
  expect_out 0

  gate "db-create 13"; expect_rc 0
  pw13="$(password_of "$out")"
  run "$MROOM" doctor
  expect_out_has "ok    template: the QA template shop_qa_template is loaded"
  expect_out_has "ok    postgres: PUBLIC may connect to neither the template nor any environment's database"
  case "$out" in *"fail  postgres"*) fail "doctor failed a Postgres check" ;; *) ok ;; esac
  expect_true "env 13 cannot use its database" can shop_qa_13 "$pw13" shop_qa_13 "SELECT 1"
  expect_true "env 12 reached env 13's database" cannot shop_qa_12 "$pw12" shop_qa_13 "SELECT 1"
  expect_true "env 12's read-only role reached env 13's database" cannot shop_qa_12_read "$rpw12" shop_qa_13 "SELECT 1"

  # A new template while environments run: the next clone has it, and the running ones keep their own.
  su_psql -d shop_seed -c "INSERT INTO users (email) VALUES ('bob@example.test')"
  load shop_seed; expect_rc 0
  gate "db-create 15"; expect_rc 0
  run as shop_qa_15 "$(password_of "$out")" shop_qa_15 "SELECT count(*) FROM users"; expect_out 2
  run as shop_qa_12 "$pw12" shop_qa_12 "SELECT count(*) FROM users"; expect_out 1
  run su_psql -c "SELECT rolcanlogin FROM pg_roles WHERE rolname = 'shop_qa_objects'"; expect_out f

  # A second request: the same password, which still signs in, and the data kept.
  gate "db-create 12"; expect_rc 0; expect_out_has "database shop_qa_12: exists"
  expect_true "a second request changed the password" [ "$(password_of "$out")" = "$pw12" ]
  expect_true "the kept password no longer signs in" can shop_qa_12 "$pw12" shop_qa_12 "SELECT 1"
  # --rotate: a new password, the old one refused, the data kept.
  old="$pw12"
  gate "db-create 12 --rotate"; expect_rc 0; expect_out_has "database shop_qa_12: exists"
  pw12="$(password_of "$out")"
  expect_true "the old password still works" cannot shop_qa_12 "$old" shop_qa_12 "SELECT 1"
  run as shop_qa_12 "$pw12" shop_qa_12 "SELECT count(*) FROM notes"; expect_rc 0; expect_out 1

  # A role taken out of its group is put back, so pg_hba.conf keeps it in its database again.
  su_psql -c "REVOKE shop_qa_envs FROM shop_qa_13 GRANTED BY shop_qa_gate"
  gate "db-create 13"; expect_rc 0
  pw13="$(password_of "$out")"
  expect_true "env 13 outside its group reached postgres" cannot shop_qa_13 "$pw13" postgres "SELECT 1"

  # A PR marks its own database a template; the gate still drops it, and its role.
  run as shop_qa_12 "$pw12" shop_qa_12 "ALTER DATABASE shop_qa_12 IS_TEMPLATE true"; expect_rc 0
  gate "db-drop 12"; expect_rc 0; expect_out "database shop_qa_12: dropped"
  run su_psql -c "SELECT count(*) FROM pg_database WHERE datname = 'shop_qa_12'"; expect_out 0
  run su_psql -c "SELECT count(*) FROM pg_roles WHERE rolname IN ('shop_qa_12', 'shop_qa_12_read')"; expect_out 0

  # An objects role that owns a database would hand it over: refused before anything is made.
  su_psql -c "CREATE DATABASE shop_trap OWNER shop_qa_objects"
  gate "db-create 14"; expect_rc 1; expect_err_has "shop_qa_objects owns a database or tablespace"
  run su_psql -c "SELECT count(*) FROM pg_roles WHERE rolname = 'shop_qa_14'"; expect_out 0
  run su_psql -c "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = 'shop_trap'"; expect_out shop_qa_objects
}

test_case real-postgres t_the_gate_on_a_real_postgres
finish
