#!/usr/bin/env bash
# shellcheck disable=SC2317  # the t_* function runs indirectly, through test_case
# The gate against a real Postgres (16 or later), set up as the README's "QA gate" section says: what a
# fake psql cannot show. pg_hba.conf lets the gate in and keeps each environment's role to its own
# database; the template's objects change hands; a PR cannot keep its database from being dropped; a role
# taken out of its group is put back. CI only: it needs sudo and a Postgres it may reconfigure (the
# runner's own), so tests/run.sh does not pick it up.
set -euo pipefail
SUITE=gate-real
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

su_psql() { sudo -u postgres psql -X -q -A -t -v ON_ERROR_STOP=1 "$@"; }
# as <role> <password> <database> <sql>: the SQL as that role over TCP, as an app would connect.
as() { PGPASSWORD="$2" psql -X -q -A -t -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "$1" -d "$3" -c "$4"; }
can() { as "$@" >/dev/null 2>&1; }
gate() { run env SSH_ORIGINAL_COMMAND="$1" "$MROOM" gate provision; }
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

# set_up: the README's steps, with passwords from variables instead of \password.
set_up() {
  GATE_PW="gate-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
  OBJECTS_PW="objects-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
  su_psql -v gate_pw="$GATE_PW" -v objects_pw="$OBJECTS_PW" <<'SQL'
CREATE ROLE shop_qa_gate LOGIN CREATEDB CREATEROLE PASSWORD :'gate_pw';
CREATE ROLE shop_qa_objects NOLOGIN;
GRANT shop_qa_objects TO shop_qa_gate;
CREATE ROLE shop_qa_envs NOLOGIN;
GRANT shop_qa_envs TO shop_qa_gate WITH ADMIN OPTION;
CREATE DATABASE shop_qa_template OWNER shop_qa_gate;
GRANT CONNECT ON DATABASE shop_qa_template TO shop_qa_objects;
CREATE DATABASE shop_dev;
REVOKE CONNECT ON DATABASE shop_dev FROM PUBLIC;
\c shop_qa_template
GRANT CREATE ON SCHEMA public TO shop_qa_objects;
\c postgres
ALTER ROLE shop_qa_objects LOGIN PASSWORD :'objects_pw';
SQL
  # The app's migrations and seeders, as the objects role.
  as shop_qa_objects "$OBJECTS_PW" shop_qa_template \
    "CREATE TABLE users (id serial PRIMARY KEY, email text); INSERT INTO users (email) VALUES ('ada@example.test');"
  su_psql <<'SQL'
ALTER ROLE shop_qa_objects NOLOGIN PASSWORD NULL;
REVOKE CONNECT ON DATABASE shop_qa_template FROM PUBLIC, shop_qa_objects;
SQL
  mkdir -p "$HOME/.config/mroom/secrets"
  printf 'MROOM_APP_NAME=shop\nMROOM_QA_TEMPLATE=shop_qa_template\n' >"$HOME/.config/mroom/box.env"
  printf '[mroom-gate]\nhost=127.0.0.1\nport=5432\ndbname=postgres\nuser=shop_qa_gate\npassword=%s\n' "$GATE_PW" \
    >"$HOME/.config/mroom/secrets/pg_service.conf"
  chmod 600 "$HOME/.config/mroom/secrets/pg_service.conf"
}

t_the_gate_on_a_real_postgres() {
  start_postgres
  set_up

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

  gate "db-create 13"; expect_rc 0
  pw13="$(password_of "$out")"
  expect_true "env 13 cannot use its database" can shop_qa_13 "$pw13" shop_qa_13 "SELECT 1"
  expect_true "env 12 reached env 13's database" cannot shop_qa_12 "$pw12" shop_qa_13 "SELECT 1"

  # A second request: a new password, the old one refused, the data kept.
  old="$pw12"
  gate "db-create 12"; expect_rc 0; expect_out_has "database shop_qa_12: exists"
  pw12="$(password_of "$out")"
  expect_true "the old password still works" cannot shop_qa_12 "$old" shop_qa_12 "SELECT 1"
  run as shop_qa_12 "$pw12" shop_qa_12 "SELECT count(*) FROM notes"; expect_rc 0; expect_out 0

  # A role taken out of its group is put back, so pg_hba.conf keeps it in its database again.
  su_psql -c "REVOKE shop_qa_envs FROM shop_qa_13 GRANTED BY shop_qa_gate"
  gate "db-create 13"; expect_rc 0
  pw13="$(password_of "$out")"
  expect_true "env 13 outside its group reached postgres" cannot shop_qa_13 "$pw13" postgres "SELECT 1"

  # A PR marks its own database a template; the gate still drops it, and its role.
  run as shop_qa_12 "$pw12" shop_qa_12 "ALTER DATABASE shop_qa_12 IS_TEMPLATE true"; expect_rc 0
  gate "db-drop 12"; expect_rc 0; expect_out "database shop_qa_12: dropped"
  run su_psql -c "SELECT count(*) FROM pg_database WHERE datname = 'shop_qa_12'"; expect_out 0
  run su_psql -c "SELECT count(*) FROM pg_roles WHERE rolname = 'shop_qa_12'"; expect_out 0

  # An objects role that owns a database would hand it over: refused before anything is made.
  su_psql -c "CREATE DATABASE shop_trap OWNER shop_qa_objects"
  gate "db-create 14"; expect_rc 1; expect_err_has "shop_qa_objects owns a database or tablespace"
  run su_psql -c "SELECT count(*) FROM pg_roles WHERE rolname = 'shop_qa_14'"; expect_out 0
  run su_psql -c "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = 'shop_trap'"; expect_out shop_qa_objects
}

test_case real-postgres t_the_gate_on_a_real_postgres
finish
