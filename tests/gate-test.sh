#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2016  # t_* run through test_case; a $ in single quotes is meant literally
# (expected SQL, or a command the gate must refuse).
# Tests for `mroom gate` (lib/gate) and lib/core/scram.py: the forced command refuses anything but plain
# words a role may run, builds every name from box.env, and db-create / db-drop send Postgres the right
# SQL, never the password. Offline: psql is a fake that logs the SQL it gets on stdin.
set -euo pipefail
SUITE=gate
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
skip_unless has_box_tools "this host lacks bash 5, flock or GNU date, which box commands need"

# world: box.env, the gate's libpq service file (mode 600), and fakes for psql, sleep and logger.
world() {
  mkdir -p "$HOME/.config/mroom/secrets" "$T/bin" "$T/pg"
  printf 'MROOM_APP_NAME=shop\nMROOM_QA_TEMPLATE=shop_qa_template\n' >"$HOME/.config/mroom/box.env"
  printf '[mroom-gate]\nhost=127.0.0.1\nuser=shop_qa_gate\npassword=not-a-real-one\n' >"$HOME/.config/mroom/secrets/pg_service.conf"
  chmod 600 "$HOME/.config/mroom/secrets/pg_service.conf"
  cat >"$T/bin/psql" <<'FAKE'
#!/usr/bin/env bash
# Logs "db=<database> service=<PGSERVICE> <sql on one line>" to $T/psql.log and answers from $T/pg/*:
# version (t or f), role-exists, db-exists, busy (how many CREATE DATABASE calls fail as busy first).
db=""
while [ "$#" -gt 0 ]; do case "$1" in -d) db="$2"; shift 2 ;; *) shift ;; esac; done
sql="$(cat)"
printf 'db=%s service=%s %s\n' "$db" "${PGSERVICE:-}" "$(tr '\n' ' ' <<<"$sql")" >>"$T/psql.log"
case "$sql" in
  *server_version_num*) cat "$T/pg/version" 2>/dev/null || echo t ;;
  *"FROM pg_roles"*) if [ -f "$T/pg/role-exists" ]; then echo 1; fi ;;
  *"FROM pg_database"*) if [ -f "$T/pg/db-exists" ]; then echo 1; fi ;;
  *"CREATE DATABASE"*)
    n="$(cat "$T/pg/busy" 2>/dev/null || echo 0)"
    if [ "$n" -gt 0 ]; then
      echo $((n - 1)) >"$T/pg/busy"
      echo 'ERROR:  source database "shop_qa_template" is being accessed by other users' >&2
      exit 1
    fi ;;
esac
exit 0
FAKE
  cat >"$T/bin/sleep" <<'FAKE'
#!/bin/sh
echo "$1" >>"$T/sleep.log"
FAKE
  cat >"$T/bin/logger" <<'FAKE'
#!/bin/sh
echo "$*" >>"$T/syslog"
FAKE
  chmod +x "$T/bin/psql" "$T/bin/sleep" "$T/bin/logger"
  export T PATH="$T/bin:$PATH"
}

# gate <role> <ssh command>: the gate as sshd runs it.
gate() { run env SSH_ORIGINAL_COMMAND="$2" "$MROOM" gate "$1"; }
sql() { cat "$T/psql.log" 2>/dev/null || true; }
no_psql_calls() { [ ! -s "$T/psql.log" ]; }
lacks() { case "$1" in *"$2"*) return 1 ;; esac; }
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
password_of() { sed -n 's/^DB_PASSWORD=//p' <<<"$1"; }

t_it_runs_only_as_a_forced_command_with_a_role() {
  world
  run "$MROOM" gate; expect_rc 2; expect_err_has "run it as an SSH forced command: mroom gate provision"
  gate shell "db-create 1"; expect_rc 2
}

t_anything_but_plain_words_is_refused() {
  world
  local c
  for c in "" "db-create 1; rm -rf ~" 'db-create $(id)' "db-create 1 && true" "db-create  1" "db-create 1 " \
    "db-create	1" 'db-create "1"' "db-create 1|cat" "db-create *"; do
    gate provision "$c"; expect_rc 1; expect_err_has "mroom gate: refused:"
  done
  expect_true "psql ran for a refused request" no_psql_calls
}

t_only_the_roles_operations_with_their_arguments_run() {
  world
  gate provision "shell"; expect_rc 1; expect_err_has "provision may not run 'shell'"
  gate provision "db-create"; expect_rc 1; expect_err_has "db-create takes 1 argument(s), got 0"
  gate provision "db-create 1 2"; expect_rc 1; expect_err_has "db-create takes 1 argument(s), got 2"
  local n
  for n in 0 01 -1 abc 1x 1234567890 shop_qa_1 ../1; do
    gate provision "db-create $n"; expect_rc 1; expect_err_has "is not an environment number"
  done
  expect_true "psql ran for a refused request" no_psql_calls
}

t_db_create_makes_a_role_and_a_database_of_their_own() {
  world
  gate provision "db-create 12"
  expect_rc 0; expect_out_has "database shop_qa_12: created"
  expect_out_has $'DB_DATABASE=shop_qa_12\nDB_USERNAME=shop_qa_12\nDB_PASSWORD='
  local pw log
  pw="$(password_of "$out")"
  expect_true "the password is not 48 hex characters: $pw" eval '[[ "$pw" =~ ^[0-9a-f]{48}$ ]]'
  log="$(sql)"
  expect_true "the role is not created in its group with a SCRAM verifier" has "$log" \
    'CREATE ROLE "shop_qa_12" LOGIN NOINHERIT CONNECTION LIMIT 30 IN ROLE "shop_qa_envs" PASSWORD '"'"'SCRAM-SHA-256$4096:'
  expect_true "an existing role's statement was sent" lacks "$log" 'ALTER ROLE'
  expect_true "the gate is not made a member" has "$log" 'GRANT "shop_qa_12" TO CURRENT_USER;'
  expect_true "the clone is wrong" has "$log" 'CREATE DATABASE "shop_qa_12" TEMPLATE "shop_qa_template" OWNER "shop_qa_12";'
  expect_true "the objects are not handed over in the new database" has "$log" \
    'db=shop_qa_12 service=mroom-gate REASSIGN OWNED BY "shop_qa_objects" TO "shop_qa_12"; REVOKE CONNECT, TEMPORARY ON DATABASE "shop_qa_12" FROM PUBLIC;'
  expect_true "the password reached Postgres" lacks "$log" "$pw"
  expect_true "the password reached the gate log" lacks "$(cat "$HOME/.local/state/mroom/gate.log")" "$pw"
  expect_true "the password reached syslog" lacks "$(cat "$T/syslog")" "$pw"
}

t_db_create_on_an_existing_database_gives_a_new_password_and_keeps_the_data() {
  world; : >"$T/pg/db-exists"; : >"$T/pg/role-exists"
  gate provision "db-create 12"
  expect_rc 0; expect_out_has "database shop_qa_12: exists"; expect_out_has "DB_PASSWORD="
  local log
  log="$(sql)"
  expect_true "the database was created again" lacks "$log" "CREATE DATABASE"
  expect_true "the role was created again" lacks "$log" "CREATE ROLE"
  expect_true "the role's password is not replaced" has "$log" 'ALTER ROLE "shop_qa_12" LOGIN PASSWORD '"'"'SCRAM-SHA-256$4096:'
  expect_true "PUBLIC keeps CONNECT" has "$log" 'REVOKE CONNECT, TEMPORARY ON DATABASE "shop_qa_12" FROM PUBLIC;'
}

t_a_busy_template_is_tried_again() {
  world; echo 2 >"$T/pg/busy"
  export MROOM_GATE_RETRY_SLEEP=5
  gate provision "db-create 3"
  expect_rc 0; expect_out_has "database shop_qa_3: created"
  expect_err_has "template shop_qa_template is busy, trying again (1)"
  expect_err_has "template shop_qa_template is busy, trying again (2)"
  run cat "$T/sleep.log"; expect_out $'5\n5'
}

t_a_template_that_stays_busy_fails() {
  world; echo 9 >"$T/pg/busy"
  gate provision "db-create 3"
  expect_rc 1; expect_err_has "shop_qa_template stayed busy; try again later"
}

t_postgres_older_than_15_is_refused() {
  world; echo f >"$T/pg/version"
  gate provision "db-create 3"
  expect_rc 1; expect_err_has "Postgres must be 15 or later (D18)"
  expect_true "it went on past the version check" lacks "$(sql)" "CREATE"
}

t_db_drop_removes_the_database_and_its_role() {
  world
  gate provision "db-drop 12"
  expect_rc 0; expect_out "database shop_qa_12: dropped"
  run tail -n 1 "$T/psql.log"
  expect_out 'db=postgres service=mroom-gate DROP DATABASE IF EXISTS "shop_qa_12" WITH (FORCE); DROP ROLE IF EXISTS "shop_qa_12"; '
}

t_box_env_and_the_service_file_must_be_in_place() {
  world
  printf 'MROOM_QA_TEMPLATE=shop_qa_template\n' >"$HOME/.config/mroom/box.env"
  gate provision "db-create 1"; expect_rc 1; expect_err_has "MROOM_APP_NAME is not set in box.env"
  printf 'MROOM_APP_NAME=shop\n' >"$HOME/.config/mroom/box.env"
  gate provision "db-create 1"; expect_rc 1; expect_err_has "MROOM_QA_TEMPLATE is not set in box.env"
  printf 'MROOM_APP_NAME=shop\nMROOM_QA_TEMPLATE=shop_qa_template\n' >"$HOME/.config/mroom/box.env"
  chmod 644 "$HOME/.config/mroom/secrets/pg_service.conf"
  gate provision "db-create 1"; expect_rc 1; expect_err_has "pg_service.conf must be yours and mode 600"
  rm "$HOME/.config/mroom/secrets/pg_service.conf"
  gate provision "db-create 1"; expect_rc 1; expect_err_has "pg_service.conf is missing"
  printf 'MROOM_APP_NAME="Shop; DROP"\n' >"$HOME/.config/mroom/box.env"
  gate provision "db-create 1"; expect_rc 1; expect_err_has "MROOM_APP_NAME must match"
  expect_true "psql ran" no_psql_calls
}

t_one_request_at_a_time_per_environment() {
  world
  export MROOM_GATE_LOCK_WAIT=0
  mkdir -p "$HOME/.local/state/mroom"
  exec 8>"$HOME/.local/state/mroom/gate-shop_qa_12.lock"
  flock 8
  gate provision "db-create 12"; expect_rc 1; expect_err_has "another request for shop_qa_12 is still running"
  gate provision "db-create 13"; expect_rc 0
  exec 8>&-
}

t_requests_and_refusals_are_logged() {
  world
  gate provision "db-drop 4"; expect_rc 0
  gate provision "db-create 1; id"; expect_rc 1
  run cat "$HOME/.local/state/mroom/gate.log"
  expect_out_has "provision request: db-drop 4"; expect_out_has "provision db-drop 4: shop_qa_4 dropped"
  expect_out_has "provision refused: characters outside the allowed set"
  run cat "$T/syslog"; expect_out_has "provision refused: characters outside the allowed set"
}

t_the_password_verifier_matches_rfc_7677() {
  local v
  v="$(printf '%s' pencil | MROOM_SCRAM_SALT='W22ZaJ0SNY7soEsUEjb6gQ==' python3 "$ROOT/lib/core/scram.py")"
  # RFC 7677's exchange for user "user", password "pencil": the verifier must reproduce both its client
  # proof and its server signature, which is what Postgres checks at sign-in.
  run env VERIFIER="$v" python3 - <<'PY'
import base64, hashlib, hmac, os
_, rest = os.environ["VERIFIER"].split("$", 1)
_, keys = rest.split("$")
stored, server = (base64.b64decode(k) for k in keys.split(":"))
auth = ("n=user,r=rOprNGfwEbeRWgbNEkqO,"
        "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096,"
        "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0").encode()
signature = base64.b64encode(hmac.new(server, auth, hashlib.sha256).digest()).decode()
proof = base64.b64decode("dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=")
client_key = bytes(a ^ b for a, b in zip(proof, hmac.new(stored, auth, hashlib.sha256).digest()))
print(signature == "6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=", hashlib.sha256(client_key).digest() == stored)
PY
  expect_rc 0; expect_out "True True"
  run bash -c "printf 'two\nlines' | python3 '$ROOT/lib/core/scram.py'"
  expect_rc 2; expect_err_has "exactly one password on stdin"
}

test_case forced-command-only t_it_runs_only_as_a_forced_command_with_a_role
test_case plain-words-only t_anything_but_plain_words_is_refused
test_case role-operations-and-arguments t_only_the_roles_operations_with_their_arguments_run
test_case db-create-own-role-and-database t_db_create_makes_a_role_and_a_database_of_their_own
test_case db-create-existing t_db_create_on_an_existing_database_gives_a_new_password_and_keeps_the_data
test_case busy-template-retried t_a_busy_template_is_tried_again
test_case busy-template-fails t_a_template_that_stays_busy_fails
test_case postgres-15-or-later t_postgres_older_than_15_is_refused
test_case db-drop t_db_drop_removes_the_database_and_its_role
test_case box-env-and-service-file t_box_env_and_the_service_file_must_be_in_place
test_case one-request-per-environment t_one_request_at_a_time_per_environment
test_case logged t_requests_and_refusals_are_logged
test_case scram-rfc-7677 t_the_password_verifier_matches_rfc_7677
finish
