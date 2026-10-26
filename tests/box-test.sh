#!/usr/bin/env bash
# shellcheck disable=SC2317  # the t_* functions run indirectly, through test_case
# Tests for `mroom config box`: box.env is parsed line by line, never sourced, and any line that is not
# an allowed KEY=value refuses the whole file.
set -euo pipefail
SUITE=box
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# box <text>: writes the default box.env, ~/.config/mroom/box.env.
box() { mkdir -p "$HOME/.config/mroom" && printf '%s\n' "$1" >"$HOME/.config/mroom/box.env"; }

t_reads_values() {
  box '# the box
MROOM_BOX_NAME=box-one

MROOM_FORGE_SERVER=12345
MROOM_REPO_URL=git@github.com:example/shop.git
MROOM_SITE_WEB="go.example.dev"
MROOM_SLACK_LOG_CHANNEL='"'"'#box log'"'"'
MROOM_ENV=devbox'
  run "$MROOM" config box MROOM_BOX_NAME; expect_rc 0; expect_out "box-one"; expect_err_empty
  run "$MROOM" config box MROOM_REPO_URL; expect_out "git@github.com:example/shop.git"
  run "$MROOM" config box MROOM_SITE_WEB; expect_out "go.example.dev"
  run "$MROOM" config box MROOM_SLACK_LOG_CHANNEL; expect_out "#box log"
  run "$MROOM" config box; expect_rc 0; expect_out_has "MROOM_FORGE_SERVER=12345"; expect_out_has "MROOM_ENV=devbox"
}

t_default_path_and_override() {
  run "$MROOM" config path --box; expect_out "$HOME/.config/mroom/box.env"
  printf 'MROOM_BOX_NAME=elsewhere\n' >"$T/other.env"
  export MROOM_BOX_ENV="$T/other.env"
  run "$MROOM" config path --box; expect_out "$T/other.env"
  run "$MROOM" config box MROOM_BOX_NAME; expect_out "elsewhere"
}

t_missing_file_or_key() {
  run "$MROOM" config box MROOM_BOX_NAME; expect_rc 1; expect_err_has "MROOM_BOX_NAME is not set in $HOME/.config/mroom/box.env"
  run "$MROOM" config box; expect_rc 0; expect_out ""
  box 'MROOM_ENV=local'
  run "$MROOM" config box MROOM_FORGE_ORG; expect_rc 1; expect_err_has "MROOM_FORGE_ORG is not set"
}

t_env_overrides() {
  box 'MROOM_BOX_NAME=from-file'
  export MROOM_BOX_NAME=from-env
  run "$MROOM" config box MROOM_BOX_NAME; expect_out "from-env"
  export MROOM_ENV=production
  run "$MROOM" config box MROOM_BOX_NAME; expect_rc 1; expect_err_has "environment: MROOM_ENV must be one of"
  expect_err_lacks "production"
  unset MROOM_ENV
  export MROOM_SITE_WEB="go.example.dev with spaces"
  run "$MROOM" config box MROOM_SITE_WEB; expect_rc 0; expect_out "go.example.dev with spaces"
}

t_env_overrides_must_be_plain() {
  local bad
  # shellcheck disable=SC2016  # literal shell, never run
  for bad in '$(touch x)' '`id`' 'a"b' 'back\slash' $'two\nlines' $'tab\there'; do
    MROOM_BOX_NAME="$bad" run "$MROOM" config box MROOM_BOX_NAME
    expect_rc 1; expect_err_has "environment: MROOM_BOX_NAME has a value that is not plain"
    expect_err_lacks "touch"; expect_err_lacks "id\`"; expect_out ""
  done
}

t_explicit_path_must_exist() {
  export MROOM_BOX_ENV="$T/missing.env"
  run "$MROOM" config box MROOM_BOX_NAME; expect_rc 1; expect_err_has "MROOM_BOX_ENV=$T/missing.env: no such file"
  run "$MROOM" config box; expect_rc 1
  run "$MROOM" config path --box; expect_rc 0; expect_out "$T/missing.env"
}

t_line_endings_and_whitespace() {
  mkdir -p "$HOME/.config/mroom"
  printf 'MROOM_BOX_NAME=box-one\r\nMROOM_ENV=devbox   \r\n  # an indented comment\r\n' >"$HOME/.config/mroom/box.env"
  run "$MROOM" config box MROOM_BOX_NAME; expect_rc 0; expect_out "box-one"
  run "$MROOM" config box MROOM_ENV; expect_out "devbox"
  box '  MROOM_BOX_NAME=box-one'
  run "$MROOM" config box; expect_rc 1; expect_err_has "line 1: starts with whitespace; a KEY=value line starts at the first column"
}

t_unknown_key_refused() {
  box 'MROOM_BOX_NAME=box-one
PATH=/tmp/evil'
  run "$MROOM" config box MROOM_BOX_NAME; expect_rc 1
  expect_err_has "box.env: line 2: PATH is not an allowed key"
  expect_out ""
}

t_not_assignments_refused() {
  box 'export MROOM_BOX_NAME=box-one
MROOM_ENV = devbox
source /etc/profile'
  run "$MROOM" config box; expect_rc 1
  expect_err_has "line 1: not a KEY=value line"
  expect_err_has "line 2: not a KEY=value line"
  expect_err_has "line 3: not a KEY=value line"
}

t_shell_never_runs() {
  # shellcheck disable=SC2016  # these are the literal lines a box.env might hold
  box 'MROOM_BOX_NAME=$(touch '"$T"'/ran)
MROOM_FORGE_ORG=`touch '"$T"'/ran`
MROOM_SITE_API="$(touch '"$T"'/ran)"
MROOM_SITE_WEB=a;touch '"$T"'/ran
MROOM_REPO_URL=two words'
  run "$MROOM" config box; expect_rc 1
  expect_err_has "line 1: MROOM_BOX_NAME has a value that is not plain"
  expect_err_has "line 2: MROOM_FORGE_ORG has a value that is not plain"
  expect_err_has "line 3: MROOM_SITE_API has a value that is not plain"
  expect_err_has "line 4: MROOM_SITE_WEB has a value that is not plain"
  expect_err_has "line 5: MROOM_REPO_URL has a value that is not plain"
  expect_err_lacks "touch"
  expect_no_file "$T/ran"
}

t_values_never_echoed() {
  box 'MROOM_ENV=s3cr3t-value'
  run "$MROOM" config box; expect_rc 1; expect_err_has "line 1: MROOM_ENV must be one of"; expect_err_lacks "s3cr3t"
}

t_duplicate_refused() {
  box 'MROOM_BOX_NAME=one
MROOM_BOX_NAME=two'
  run "$MROOM" config box MROOM_BOX_NAME; expect_rc 1; expect_err_has "line 2: MROOM_BOX_NAME is set twice"
}

t_unknown_key_asked() {
  run "$MROOM" config box HOME; expect_rc 2; expect_err_has "HOME is not a box.env key; allowed: MROOM_BOX_NAME"
  run "$MROOM" config box MROOM_ENV MROOM_BOX_NAME; expect_rc 2; expect_err_has "at most one KEY"
}

t_watch_mcp() {
  box "MROOM_WATCH_MCP='app=https://mcp.example.dev/mcp https://docs.example.dev/v1/mcp'"
  run "$MROOM" config box MROOM_WATCH_MCP; expect_rc 0; expect_out "app=https://mcp.example.dev/mcp https://docs.example.dev/v1/mcp"
  local bad
  for bad in 'app=https://mcp.example.dev/mcp?token=s3cr3t' 'https://user:s3cr3t@mcp.example.dev/mcp' \
    'app=ftp://mcp.example.dev' 'App=https://mcp.example.dev/mcp' 'app=https://mcp.example.dev/mcp#s3cr3t'; do
    box "MROOM_WATCH_MCP='$bad'"
    run "$MROOM" config box MROOM_WATCH_MCP; expect_rc 1
    expect_err_has "line 1: MROOM_WATCH_MCP must be space-separated name=https://host/path items"
    expect_err_lacks "s3cr3t"
  done
  box "MROOM_WATCH_MCP='a=https://one.test/mcp a=https://two.test/mcp'"
  run "$MROOM" config box MROOM_WATCH_MCP; expect_rc 1; expect_err_has "MROOM_WATCH_MCP must name each server once"
  box "MROOM_WATCH_MCP='https://api.test/mcp https://api.test/admin/mcp'"
  run "$MROOM" config box MROOM_WATCH_MCP; expect_rc 1; expect_err_has "give a bare URL a name= when two share a host"
  box "MROOM_WATCH_MCP='a=https://api.test/mcp b=https://api.test/admin/mcp k=https://h.test/s/k3y-1/mcp'"
  run "$MROOM" config box MROOM_WATCH_MCP; expect_rc 0
  box "MROOM_WATCH_MCP='a=https://api.test/m\"cp'"
  run "$MROOM" config box MROOM_WATCH_MCP; expect_rc 1
  box 'MROOM_ENV=local'
  export MROOM_WATCH_MCP='x=https://a.test/mcp?k=s3cr3t'
  run "$MROOM" config box MROOM_WATCH_MCP; expect_rc 1; expect_err_has "environment: MROOM_WATCH_MCP must be"
}

t_gate_names_are_plain_postgres_names() {
  box $'MROOM_APP_NAME=shop\nMROOM_QA_TEMPLATE=shop_qa_template'
  run "$MROOM" config box MROOM_APP_NAME; expect_rc 0; expect_out "shop"
  run "$MROOM" config box MROOM_QA_TEMPLATE; expect_rc 0; expect_out "shop_qa_template"
  local bad
  for bad in Shop 1shop shop-qa "'shop;drop'" a_name_that_is_longer_than_thirty_two; do
    box "MROOM_APP_NAME=$bad"
    run "$MROOM" config box MROOM_APP_NAME; expect_rc 1; expect_err_has "MROOM_APP_NAME must match [a-z][a-z0-9_]{0,31}"
  done
  box 'MROOM_QA_TEMPLATE=qa-template'
  run "$MROOM" config box MROOM_QA_TEMPLATE; expect_rc 1; expect_err_has "MROOM_QA_TEMPLATE must be a plain Postgres name"
  for bad in pg pg_shop; do
    box "MROOM_APP_NAME=$bad"
    run "$MROOM" config box MROOM_APP_NAME; expect_rc 1; expect_err_has "may not be pg or start with pg_"
  done
  box 'MROOM_APP_NAME=pgshop'
  run "$MROOM" config box MROOM_APP_NAME; expect_rc 0; expect_out pgshop
}

t_qa_site_settings() {
  box $'MROOM_QA_ZONE=qa.example.dev\nMROOM_QA_BACKEND_DIR=apps/backend\nMROOM_QA_PHP=php8.4\nMROOM_QA_PERSONA_DOMAIN=.test'
  run "$MROOM" config box MROOM_QA_ZONE; expect_rc 0; expect_out qa.example.dev
  run "$MROOM" config box MROOM_QA_BACKEND_DIR; expect_rc 0; expect_out apps/backend
  run "$MROOM" config box MROOM_QA_PHP; expect_rc 0; expect_out php8.4
  run "$MROOM" config box MROOM_QA_PERSONA_DOMAIN; expect_rc 0; expect_out .test
  box 'MROOM_QA_BACKEND_DIR=.'
  run "$MROOM" config box MROOM_QA_BACKEND_DIR; expect_rc 0; expect_out .
  local bad
  for bad in QA.example.dev qa..example.dev localhost -qa.example.dev qa.example.dev.; do
    box "MROOM_QA_ZONE=$bad"
    run "$MROOM" config box MROOM_QA_ZONE; expect_rc 1; expect_err_has "MROOM_QA_ZONE must be a lowercase DNS zone"
  done
  for bad in ../x x/../y /srv/app .hidden a//b a/ x/./y; do
    box "MROOM_QA_BACKEND_DIR=$bad"
    run "$MROOM" config box MROOM_QA_BACKEND_DIR; expect_rc 1; expect_err_has "MROOM_QA_BACKEND_DIR must be . or a folder"
  done
  for bad in /usr/bin/php php-cli python3 php8.4.1; do
    box "MROOM_QA_PHP=$bad"
    run "$MROOM" config box MROOM_QA_PHP; expect_rc 1; expect_err_has "MROOM_QA_PHP must be a PHP binary's name"
  done
  for bad in test example.test .Test . .test. .com .nl ..test .a..b .co.uk .com.au .github.io .mycompany.com; do
    box "MROOM_QA_PERSONA_DOMAIN=$bad"
    run "$MROOM" config box MROOM_QA_PERSONA_DOMAIN; expect_rc 1; expect_err_has "MROOM_QA_PERSONA_DOMAIN must be a domain suffix"
  done
  for good in .example .example.com .qa.example.com .qa.mycompany.com .personas.test; do
    box "MROOM_QA_PERSONA_DOMAIN=$good"
    run "$MROOM" config box MROOM_QA_PERSONA_DOMAIN; expect_rc 0; expect_out "$good"
  done
  for good in 1024 1025 2525 65535; do
    box "MROOM_QA_SMTP_PORT=$good"
    run "$MROOM" config box MROOM_QA_SMTP_PORT; expect_rc 0; expect_out "$good"
  done
  for bad in 25 1023 65536 01025 1025x -1; do
    box "MROOM_QA_SMTP_PORT=$bad"
    run "$MROOM" config box MROOM_QA_SMTP_PORT; expect_rc 1; expect_err_has "MROOM_QA_SMTP_PORT must be a port number"
  done
}

test_case reads-values t_reads_values
test_case default-path-and-override t_default_path_and_override
test_case missing-file-or-key t_missing_file_or_key
test_case env-overrides t_env_overrides
test_case env-overrides-must-be-plain t_env_overrides_must_be_plain
test_case explicit-path-must-exist t_explicit_path_must_exist
test_case line-endings-and-whitespace t_line_endings_and_whitespace
test_case unknown-key-refused t_unknown_key_refused
test_case not-assignments-refused t_not_assignments_refused
test_case shell-never-runs t_shell_never_runs
test_case values-never-echoed t_values_never_echoed
test_case duplicate-refused t_duplicate_refused
test_case unknown-key-asked t_unknown_key_asked
test_case watch-mcp t_watch_mcp
test_case gate-names t_gate_names_are_plain_postgres_names
test_case qa-site-settings t_qa_site_settings
finish
