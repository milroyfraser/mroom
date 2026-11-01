#!/usr/bin/env bash
# shellcheck disable=SC2317  # the t_* functions run indirectly, through test_case
# Tests for `mroom config get|validate|path|keys` against mroom.toml files. Needs python3 >= 3.11.
set -euo pipefail
SUITE=config
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
skip_unless has_tomllib "python3 has no tomllib (needs 3.11+)"

# toml <text>: writes $T/mroom.toml.
toml() { printf '%s\n' "$1" >"$T/mroom.toml"; }

t_examples_read() {
  cd "$ROOT/examples/single-app"
  run "$MROOM" config get app.name; expect_rc 0; expect_out "shop"; expect_err_empty
  cd "$ROOT/examples/two-folder"
  run "$MROOM" config get app.name; expect_rc 0; expect_out "bookings"
  run "$MROOM" config get app.frontend_dir; expect_out "web"
}

t_examples_validate() {
  local ex
  for ex in single-app two-folder; do
    cd "$ROOT/examples/$ex"
    run "$MROOM" config validate; expect_rc 0; expect_out_has "mroom.toml: ok"; expect_err_empty
  done
}

t_walk_up() {
  mkdir -p "$T/repo/api/app/Deep"
  cp "$ROOT/examples/two-folder/mroom.toml" "$T/repo/"
  cd "$T/repo/api/app/Deep"
  run "$MROOM" config get app.name; expect_rc 0; expect_out "bookings"
  run "$MROOM" config path; expect_out "$(cd "$T/repo" && pwd -P)/mroom.toml"
}

t_mroom_config_env() {
  toml '[app]
name = "local"'
  export MROOM_CONFIG="$ROOT/examples/single-app/mroom.toml"
  run "$MROOM" config get app.name; expect_out "shop"
  run "$MROOM" config path; expect_out "$ROOT/examples/single-app/mroom.toml"
  export MROOM_CONFIG="$T/nope.toml"
  run "$MROOM" config get app.name; expect_rc 1; expect_err_has "MROOM_CONFIG=$T/nope.toml: no such file"
}

t_not_found() {
  mkdir -p "$T/empty" && cd "$T/empty"
  run "$MROOM" config get app.name; expect_rc 1; expect_err_has "no mroom.toml in"
}

t_value_shapes() {
  cd "$ROOT/examples/two-folder"
  run "$MROOM" config get app.build.daemons; expect_out $'horizon\nreverb'
  run "$MROOM" config get app.build.daemons --json; expect_out '["horizon", "reverb"]'
  run "$MROOM" config get qa.max_envs; expect_out "5"
  run "$MROOM" config get app.build.frontend_env
  expect_out $'VITE_REVERB_APP_KEY=env:REVERB_APP_KEY\nVITE_REVERB_HOST=env:REVERB_HOST\nVITE_REVERB_PORT=env:REVERB_PORT\nVITE_REVERB_SCHEME=env:REVERB_SCHEME'
  run "$MROOM" config get app.name --json; expect_out '"bookings"'
  run "$MROOM" config get app.build; expect_rc 2; expect_err_has "app.build is a table; use --json"
  run "$MROOM" config get app.build --json; expect_rc 0; expect_out_has '"daemons": ["horizon", "reverb"]'
  run "$MROOM" config get app.version_path; expect_out "/version"
  run "$MROOM" config get qa.parity.mail; expect_out "catcher"
  run "$MROOM" config get qa.parity --json; expect_out_has '"database": "seeded"'
  cd "$ROOT/examples/single-app"
  run "$MROOM" config get qa.db_read_allowlist; expect_rc 0; expect_out ""
}

t_unset_and_default() {
  toml '[app]
name = "shop"'
  run "$MROOM" config get app.php; expect_rc 1; expect_err_has "app.php is not set in $T/mroom.toml"
  run "$MROOM" config get app.php --default 8.3; expect_rc 0; expect_out "8.3"
  run "$MROOM" config get app.php --default; expect_rc 2; expect_err_has "--default needs a value"
}

t_unknown_key_asked() {
  cd "$ROOT/examples/single-app"
  run "$MROOM" config get app.nmae; expect_rc 2; expect_err_has "app.nmae is not a mroom.toml key; did you mean app.name?"
  run "$MROOM" config get; expect_rc 2; expect_err_has "get needs a key"
}

t_missing_required() {
  toml '[app]
php = "8.4"'
  run "$MROOM" config validate; expect_rc 1
  expect_err_has "app.name is required, for example:"
  expect_err_has '  [app]'
  expect_err_has '  name = "shop"'
  run "$MROOM" config get app.php; expect_rc 1; expect_err_has "app.name is required"
  toml ''
  run "$MROOM" config validate; expect_rc 1; expect_err_has "app.name is required"
}

t_unknown_key_warns() {
  toml '[app]
name = "shop"
nmae = "x"

[extra]
thing = 1'
  run "$MROOM" config validate; expect_rc 0; expect_out_has "ok"
  expect_err_has "warning: $T/mroom.toml: unknown key app.nmae (ignored); did you mean app.name?"
  expect_err_has "unknown key extra.thing (ignored)"
  # get stays quiet about unknown keys: a script reading many keys must not repeat the warning each time.
  run "$MROOM" config get app.name; expect_rc 0; expect_out "shop"; expect_err_empty
}

t_get_errors_scoped_to_key() {
  toml '[app]
name = "shop"

[qa]
max_envs = "five"'
  run "$MROOM" config get app.name; expect_rc 0; expect_out "shop"; expect_err_empty
  run "$MROOM" config get qa.max_envs; expect_rc 1; expect_err_has "qa.max_envs must be a whole number"
  run "$MROOM" config get qa --json; expect_rc 1; expect_err_has "qa.max_envs must be a whole number"
  run "$MROOM" config validate; expect_rc 1; expect_err_has "qa.max_envs must be a whole number"
  toml 'app = "shop"'
  run "$MROOM" config get app.name; expect_rc 1; expect_err_has "app must be a table"
}

t_default_takes_the_key_type() {
  toml '[app]
name = "shop"'
  run "$MROOM" config get qa.ttl_days --default 3 --json; expect_rc 0; expect_out "3"
  run "$MROOM" config get qa.ttl_days --default 3; expect_out "3"
  run "$MROOM" config get qa.ttl_days --default three; expect_rc 2; expect_err_has "--default for qa.ttl_days must be a whole number"
  run "$MROOM" config get qa.ttl_days --default 0; expect_rc 2; expect_err_has "--default: qa.ttl_days must be a whole number of at least 1"
  run "$MROOM" config get pr.required_checks --default '["test", "lint"]'; expect_rc 0; expect_out $'test\nlint'
  run "$MROOM" config get pr.required_checks --default '["test"]' --json; expect_out '["test"]'
  run "$MROOM" config get pr.required_checks --default test; expect_rc 2; expect_err_has "must be JSON, for example []"
  run "$MROOM" config get app.package_manager --default yarn; expect_rc 2; expect_err_has "must be one of npm, pnpm"
  run "$MROOM" config get app.version_path --default /version; expect_rc 0; expect_out "/version"
  run "$MROOM" config get qa.parity.database --default seeded; expect_rc 0; expect_out "seeded"
  run "$MROOM" config get qa.parity.files --default s3; expect_rc 2; expect_err_has "must be one of same, local"
  run "$MROOM" config get app.php --default 8.4 --json; expect_out '"8.4"'
  run "$MROOM" config get app.build --default x --json; expect_rc 2; expect_err_has "--default does not apply to a table"
  # a value that is set wins over --default, and a bad --default is refused even then
  run "$MROOM" config get app.name --default other; expect_out "shop"
  run "$MROOM" config get qa.ttl_days --default x; expect_rc 2
}

# A key mroom has decided a default for gives it when the file leaves it out, whatever a reader's --default says,
# so every reader agrees; a value in the file wins.
t_mroom_defaults() {
  toml '[app]
name = "shop"'
  run "$MROOM" config get app.version_path; expect_rc 0; expect_out "/version"; expect_err_empty
  run "$MROOM" config get app.version_path --json; expect_out '"/version"'
  run "$MROOM" config get qa.max_envs; expect_rc 0; expect_out "5"
  run "$MROOM" config get qa.env_memory_mb; expect_rc 0; expect_out "1024"
  run "$MROOM" config get qa.env_memory_mb --json; expect_out "1024"
  run "$MROOM" config get app.version_path --default /other; expect_rc 0; expect_out "/version"
  run "$MROOM" config get qa.max_envs --default 3; expect_rc 0; expect_out "5"
  # A bad --default is still refused.
  run "$MROOM" config get qa.max_envs --default 0; expect_rc 2; expect_err_has "--default: qa.max_envs must be a whole number of at least 1"
  toml '[app]
name = "shop"
version_path = "/api/release.json"

[qa]
max_envs = 8
env_memory_mb = 1536'
  run "$MROOM" config get app.version_path; expect_out "/api/release.json"
  run "$MROOM" config get app.version_path --default /version; expect_out "/api/release.json"
  run "$MROOM" config get qa.max_envs; expect_out "8"
  run "$MROOM" config get qa.env_memory_mb; expect_out "1536"
  run "$MROOM" config validate; expect_rc 0
  run "$MROOM" config keys
  expect_out_has "the release and commit the app runs (default /version)"
  expect_out_has "(default 1024)"
}

t_version_path_rule() {
  local good bad
  for good in /version /v /api/version /api/version/ /.well-known/release /a_b/c-d~e.json; do
    toml "[app]
name = \"shop\"
version_path = \"$good\""
    run "$MROOM" config get app.version_path; expect_rc 0; expect_out "$good"
  done
  for bad in version / // /version?x=1 /version#top /a//b /a/../b /a/./b /. "/a b" /v%41 https://x.example/version \
    "/$(printf 'a%.0s' {1..200})"; do
    toml "[app]
name = \"shop\"
version_path = \"$bad\""
    run "$MROOM" config get app.version_path; expect_rc 1; expect_err_has "app.version_path must be a path such as /version"
    run "$MROOM" config validate; expect_rc 1
  done
  toml '[app]
name = "shop"
version_path = 3'
  run "$MROOM" config get app.version_path; expect_rc 1; expect_err_has "app.version_path must be a string"
  toml '[app]
name = "shop"

[qa]
env_memory_mb = 0'
  run "$MROOM" config get qa.env_memory_mb; expect_rc 1; expect_err_has "qa.env_memory_mb must be a whole number of at least 1"
}

t_type_errors() {
  toml '[app]
name = "shop"
package_manager = "yarn"
php = 8.4

[app.build]
daemons = "horizon"
frontend_env = { A = 1 }

[qa]
max_envs = "five"
ttl_days = 0

[qa.parity]
mail = "smtp"'
  run "$MROOM" config validate; expect_rc 1
  expect_err_has 'app.package_manager must be one of npm, pnpm (got "yarn")'
  expect_err_has "app.php must be a string"
  expect_err_has "app.build.daemons must be a list of strings"
  expect_err_has "app.build.frontend_env must be a table of strings"
  expect_err_has "qa.max_envs must be a whole number of at least 1"
  expect_err_has "qa.ttl_days must be a whole number of at least 1"
  expect_err_has 'qa.parity.mail must be one of catcher, log (got "smtp")'
}

t_rules() {
  toml '[app]
name = "My Shop"

[tests]
database_pattern = "{app}_testing"

[issues]
url = "https://tracker.example.dev/issues"
id_pattern = "(SHOP"'
  run "$MROOM" config validate; expect_rc 1
  expect_err_has 'app.name must match [a-z][a-z0-9_]*'
  expect_err_has "tests.database_pattern must contain {slug}"
  expect_err_has "issues.url must contain {id}"
  expect_err_has "issues.id_pattern is not a valid regular expression"
}

t_qa_rules() {
  toml '[app]
name = "shop"
backend_dir = "../api"
frontend_dir = "web/./x"

[app.build]
frontend_dist = "."

[qa]
zone = "QA.example.dev"
hidden_paths = "tests/*"'
  run "$MROOM" config validate; expect_rc 1
  expect_err_has 'app.backend_dir must be . or a folder inside the repository, with no . or .. part (got "../api")'
  expect_err_has 'app.frontend_dir must be . or a folder inside the repository'
  expect_err_has 'app.build.frontend_dist must be a folder inside the frontend'
  expect_err_has 'qa.zone must be a lowercase DNS zone, such as qa.example.dev (got "QA.example.dev")'
  expect_err_has "qa.hidden_paths must be a list of strings"
  toml '[app]
name = "shop"
backend_dir = "api"
frontend_dir = ""

[app.build]
frontend_dist = "public/build"

[qa]
zone = "qa.example.dev"
visible_paths = ["web/src/content/*"]'
  run "$MROOM" config validate; expect_rc 0
  run "$MROOM" config get app.frontend_dir; expect_out ""
  run "$MROOM" config get qa.visible_paths; expect_out "web/src/content/*"
  run "$MROOM" config get app.frontend_dir --default .; expect_out ""
  run "$MROOM" config get app.build.frontend_dist --default ..; expect_rc 2
  toml '[app]
name = "shop"

[qa]
disks = { files = "AWS_", "Media-Disk" = "MEDIA_", logs = "aws" }
public_disks = ["public_files"]'
  run "$MROOM" config validate; expect_rc 1
  expect_err_has 'qa.disks has a disk name that is not [a-z][a-z0-9]{0,15}: "Media-Disk"'
  expect_err_has 'qa.public_disks has a disk name that is not [a-z][a-z0-9]{0,15}: "public_files"'
  toml '[app]
name = "shop"

[qa]
disks = { logs = "aws" }'
  run "$MROOM" config validate; expect_rc 1; expect_err_has 'qa.disks.logs must be the prefix of env names, such as AWS_ (got "aws")'
  toml '[app]
name = "shop"

[qa]
disks = { files = "AWS_", media = "MEDIA_" }
public_disks = ["media"]'
  run "$MROOM" config validate; expect_rc 0
  run "$MROOM" config get qa.disks; expect_out $'files=AWS_\nmedia=MEDIA_'
}

t_shape_errors() {
  toml 'app = "shop"'
  run "$MROOM" config validate; expect_rc 1; expect_err_has "app must be a table ([app])"
  toml '[app.name]
x = 1'
  run "$MROOM" config validate; expect_rc 1; expect_err_has "app.name must be a string"
}

t_bad_toml() {
  toml '[app
name = "shop"'
  run "$MROOM" config validate; expect_rc 1; expect_err_has "$T/mroom.toml: not valid TOML"
}

t_keys_and_help() {
  run "$MROOM" config keys; expect_rc 0
  expect_out_has "app.name"; expect_out_has "required"; expect_out_has "qa.db_read_allowlist"
  expect_out_has "qa.parity.database       seeded|snapshot"
  run "$MROOM" config; expect_rc 2; expect_out_has "mroom config get <dotted.key>"
  run "$MROOM" config help; expect_rc 0
  run "$MROOM" config frob; expect_rc 2; expect_err_has "unknown command frob"
}

test_case examples-read t_examples_read
test_case examples-validate t_examples_validate
test_case walk-up t_walk_up
test_case mroom-config-env t_mroom_config_env
test_case not-found t_not_found
test_case value-shapes t_value_shapes
test_case unset-and-default t_unset_and_default
test_case unknown-key-asked t_unknown_key_asked
test_case missing-required t_missing_required
test_case unknown-key-warns t_unknown_key_warns
test_case get-errors-scoped-to-key t_get_errors_scoped_to_key
test_case default-takes-the-key-type t_default_takes_the_key_type
test_case mroom-defaults t_mroom_defaults
test_case version-path-rule t_version_path_rule
test_case type-errors t_type_errors
test_case rules t_rules
test_case qa-rules t_qa_rules
test_case shape-errors t_shape_errors
test_case bad-toml t_bad_toml
test_case keys-and-help t_keys_and_help
finish
