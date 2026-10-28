#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2016  # t_* run through test_case; a $ in single quotes is nginx's own
# Tests for actions/qa-up/nginx-conf, read on its own: a domain's server block counts only when it includes the
# site's site.conf right inside the server block and sets no disable_symlinks of its own; a site's fragment counts
# only with disable_symlinks if_not_owner at its top level, alone; guard puts it there once. Comments, quotes and
# blocks are read as nginx reads them. tests/qa-up-test.sh runs it through up.sh against Forge's own configs.
set -euo pipefail
SUITE=qa-nginx-conf
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONF="$ROOT/actions/qa-up/nginx-conf"
# conf <mode> <config> [--spa]: nginx-conf on that config.
conf() { run bash -c 'printf "%s" "$2" | python3 -I "$1" "${@:3}"' _ "$CONF" "$2" "$1" "${@:3}"; }
# domain <inside the server block> [<outside it>]: a domain's server block as Forge writes one.
domain() {
  printf '# FORGE CONFIG (DO NOT REMOVE!)\ninclude forge-conf/101/before/*;\n%s\nserver {\n    listen 443 ssl;\n    server_name api.7.qa.example.dev;\n    root /home/shop_qa_7/api.7.qa.example.dev/public;\n%s\n}\n' "${2:-}" "$1"
}
SITE_CONF='    include forge-conf/101/site.conf;'

t_the_server_block_must_include_the_site_config_itself() {
  conf includes "$(domain "$SITE_CONF")"; expect_rc 0
  # Inside a location, or an if, it is not the server's own.
  conf includes "$(domain $'    location / {\n        include forge-conf/101/site.conf;\n    }')"
  expect_rc 1; expect_err_has "does not include the site's site.conf"
  conf includes "$(domain $'    if ($host) {\n        include forge-conf/101/site.conf;\n    }')"
  expect_rc 1
  # Outside any server block, or with no server block at all.
  conf includes "$(domain '' 'include forge-conf/101/site.conf;')"; expect_rc 1
  conf includes 'include forge-conf/101/site.conf;'; expect_rc 1
  # In a server block inside another block, which is not the domain's own.
  conf includes $'http {\n    server {\n        include forge-conf/101/site.conf;\n    }\n}'; expect_rc 1
  # Every server block at the top includes it: one that does not would serve the site without the guard.
  conf includes "$(domain "$SITE_CONF")"$'\nserver {\n    listen 8080;\n    root /home/shop_qa_7/api.7.qa.example.dev/public;\n}'
  expect_rc 1; expect_err_has "does not include the site's site.conf"
  conf includes "$(domain "$SITE_CONF")"$'\nserver {\n    listen 8080;\n'"$SITE_CONF"$'\n}'; expect_rc 0
  # Another file, a comment, or a file that only ends like it.
  conf includes "$(domain '    include forge-conf/101/server/*;')"; expect_rc 1
  conf includes "$(domain '    # include forge-conf/101/site.conf;')"; expect_rc 1
  conf includes "$(domain '    include forge-conf/101/my-site.conf;')"; expect_rc 1
  conf includes "$(domain '    include forge-conf/101/site.conf.bak;')"; expect_rc 1
}

t_the_server_block_sets_no_disable_symlinks_of_its_own() {
  conf includes "$(domain "$SITE_CONF"$'\n    disable_symlinks off;')"
  expect_rc 1; expect_err_has "sets disable_symlinks of its own"
  # Not even the same one: two of them clash.
  conf includes "$(domain "$SITE_CONF"$'\n    disable_symlinks if_not_owner;')"; expect_rc 1
  conf includes "$(domain "$SITE_CONF"$'\n    location /x {\n        disable_symlinks off;\n    }')"; expect_rc 1
  # One in a comment does not count.
  conf includes "$(domain "$SITE_CONF"$'\n    # disable_symlinks off;')"; expect_rc 0
  # A server block that does not parse never counts.
  conf includes "$(domain "$SITE_CONF"$'\n    }')"; expect_rc 1; expect_err_has "does not parse"
}

t_the_fragment_needs_the_guard_at_its_top_alone() {
  conf check $'disable_symlinks if_not_owner;\nlocation / {\n    try_files $uri $uri/ /index.php?$query_string;\n}'
  expect_rc 0
  conf check $'location / {\n    disable_symlinks if_not_owner;\n}'
  expect_rc 1; expect_err_has "no disable_symlinks if_not_owner at the top of the site's config, alone"
  conf check $'# disable_symlinks if_not_owner;\nlocation / {}'; expect_rc 1
  conf check $'disable_symlinks if_not_owner;\ndisable_symlinks if_not_owner;'; expect_rc 1
  conf check $'disable_symlinks if_not_owner;\nlocation /x {\n    disable_symlinks off;\n}'; expect_rc 1
  conf check 'disable_symlinks if_not_owner from=$document_root;'; expect_rc 1
  conf check 'disable_symlinks on;'; expect_rc 1
  # A quoted word is one word, as nginx reads it.
  conf check '"disable_symlinks if_not_owner";'; expect_rc 1
}

t_the_single_page_fallback_is_checked_and_put_in() {
  conf check $'disable_symlinks if_not_owner;\nlocation / {\n    try_files $uri $uri/ =404;\n}' --spa
  expect_rc 1; expect_err_has "no try_files that sends a path the site does not have to /index.html"
  conf guard $'location / {\n    try_files $uri $uri/ =404;\n}' --spa
  expect_rc 0; expect_out_has 'try_files $uri $uri/ /index.html;'
  expect_out_has $'\ndisable_symlinks if_not_owner;\n'
  local guarded="$out"
  conf check "$guarded" --spa; expect_rc 0
  # Guarding a guarded config changes nothing.
  conf guard "$guarded" --spa; expect_rc 0; expect_out "$guarded"
  # The fallback counts only in location /.
  conf check $'disable_symlinks if_not_owner;\nlocation /app {\n    try_files $uri $uri/ /index.html;\n}' --spa; expect_rc 1
}

t_usage() {
  conf nothing ''; expect_rc 2
  conf check '' --other; expect_rc 2
}

test_case include-in-server t_the_server_block_must_include_the_site_config_itself
test_case no-own-disable-symlinks t_the_server_block_sets_no_disable_symlinks_of_its_own
test_case guard-at-top t_the_fragment_needs_the_guard_at_its_top_alone
test_case spa-fallback t_the_single_page_fallback_is_checked_and_put_in
test_case usage t_usage
finish
