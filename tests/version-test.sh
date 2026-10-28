#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2016  # t_* run through test_case; a $ in single quotes is for the shell lib() starts
# Tests for lib/core/version.sh, how deploy-verify, /release and browser QA ask what an app runs: the address from
# app.version_path, its default and an override, with a query no cache has seen; the answer read strictly; and a QA
# environment's commit, which comes from the gate's record (env-sha), never from the environment's own code.
# Offline: the gate is tests/fakes/ssh.
set -euo pipefail
SUITE=version
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/qa-world.sh
source "$(dirname "${BASH_SOURCE[0]}")/qa-world.sh"
skip_unless has_box_tools "this host lacks bash 5, flock or GNU date, which the QA actions need"
skip_unless has_tomllib "python3 has no tomllib (needs 3.11+)"

SHA=0123456789abcdef0123456789abcdef01234567
# Sourced here only so shellcheck reads it with the tests; each test runs it in a shell of its own (lib).
# shellcheck source=lib/core/version.sh
. "$ROOT/lib/core/version.sh"

# lib <shell code>: runs it with util.sh, forge.sh, qa.sh and version.sh sourced, as an action script would.
lib() {
  run env MROOM_ROOT="$ROOT" bash -c ". '$ROOT/lib/core/util.sh'; . '$ROOT/lib/core/forge.sh'; . '$ROOT/lib/core/qa.sh'
    . '$ROOT/lib/core/version.sh'; $1"
}
parse() { lib "printf '%s' '$1' | version_parse"; }

t_the_address_follows_app_version_path() {
  qa_world
  lib 'version_url https://shop.example.dev'
  expect_rc 0
  if [[ "$out" =~ ^https://shop\.example\.dev/version\?mroom=${NOW}-[0-9]+$ ]]; then ok; else fail "not the default path with a fresh query"; fi
  first="$out"
  lib 'version_url https://shop.example.dev'
  if [ "$out" != "$first" ]; then ok; else fail "two asks had the same query, which a cache could answer"; fi
  printf '[app]\nname = "shop"\nversion_path = "/api/release"\n' >"$MROOM_CONFIG"
  lib 'version_url http://127.0.0.1:8080'
  expect_rc 0; expect_out_has "http://127.0.0.1:8080/api/release?mroom=$NOW-"
  # Not an origin: a path, a query, a user, another scheme.
  local bad
  for bad in https://shop.example.dev/ https://shop.example.dev/x 'https://shop.example.dev?x=1' \
    https://user@shop.example.dev ftp://shop.example.dev shop.example.dev 'https://Shop.example.dev'; do
    lib "version_url '$bad'"; expect_rc 2; expect_err_has "is not an origin"
  done
  # A path that breaks the rule is refused by the one reader.
  printf '[app]\nname = "shop"\nversion_path = "/v?x=1"\n' >"$MROOM_CONFIG"
  lib 'version_url https://shop.example.dev'; expect_rc 1; expect_err_has "app.version_path must be a path"
}

t_the_answer_is_read_strictly() {
  qa_world
  parse "{\"release\": \"v1.2.3\", \"commit\": \"$SHA\"}"; expect_rc 0; expect_out $'release=v1.2.3\ncommit='"$SHA"
  parse "{\"release\": null, \"commit\": \"$SHA\"}"; expect_rc 0; expect_out $'release=none\ncommit='"$SHA"
  parse "{\"commit\": \"$SHA\"}"; expect_rc 0; expect_out $'release=none\ncommit='"$SHA"
  local bad
  for bad in "" "not json" "[]" "{}" "{\"release\": \"v1\"}" "{\"release\": \"v1\", \"commit\": \"${SHA:0:12}\"}" \
    "{\"release\": \"v1\", \"commit\": \"${SHA^^}\"}" "{\"release\": \"v1\", \"commit\": \"$SHA\\n\"}" \
    "{\"release\": \"v1 2\", \"commit\": \"$SHA\"}" "{\"release\": \"v1\\nrelease=v9\", \"commit\": \"$SHA\"}" \
    "{\"release\": 3, \"commit\": \"$SHA\"}" "{\"release\": \"v1\", \"commit\": 7}" "<html>502</html>"; do
    parse "$bad"; expect_rc 1; expect_out ""
  done
}

t_a_qa_environment_reports_the_gates_commit() {
  qa_world
  lib 'qa_gate_init && qa_version 7'; expect_rc 1; expect_out ""
  printf '%s\n' "$SHA" >"$GATE/commit-7"
  lib 'qa_gate_init && qa_version 7'; expect_rc 0; expect_out $'release=none\ncommit='"$SHA"
  run cat "$GATE/gate.log"; expect_out $'env-sha 7\nenv-sha 7'
  # A gate that cannot answer, or answers with no commit, says nothing ran.
  echo 1 >"$GATE/env-sha.rc"
  lib 'qa_gate_init && qa_version 7'; expect_rc 1; expect_out ""
  rm "$GATE/env-sha.rc"; printf 'env=missing\ncommit=none\n' >"$GATE/env-sha.out"
  lib 'qa_gate_init && qa_version 7'; expect_rc 1
}

test_case address t_the_address_follows_app_version_path
test_case answer t_the_answer_is_read_strictly
test_case qa-commit t_a_qa_environment_reports_the_gates_commit
finish
