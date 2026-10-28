#!/usr/bin/env bash
# shellcheck disable=SC2317  # the t_* functions run indirectly, through test_case
# Tests for the QA plan's path rules (actions/qa-plan/scope.sh): each area on its own, a mix, both layouts of an
# app, qa.visible_paths and qa.hidden_paths, a path in no area, an empty list and one GitHub cut short.
set -euo pipefail
SUITE=qa-scope
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
skip_unless has_tomllib "python3 has no tomllib (needs 3.11+)"

SCOPE="$ROOT/actions/qa-plan/scope.sh"
SINGLE='[app]
name = "shop"
backend_dir = "."
frontend_dir = "."'
TWO='[app]
name = "bookings"
backend_dir = "api"
frontend_dir = "web"'

# config <toml>: the app's mroom.toml for scope.sh.
config() { printf '%s\n' "$1" >"$T/mroom.toml"; export MROOM_CONFIG="$T/mroom.toml"; }
# scope <path...>: scope.sh's two lines for these paths, in $out.
scope() { run bash -c 'printf "%s\n" "$@" | "$0"' "$SCOPE" "$@"; }
# expect_scope <none|maybe> <path...>
expect_scope() {
  local want="$1"
  shift
  scope "$@"
  expect_rc 0
  case "$out" in "scope=$want"$'\n'*) ok ;; *) fail "expected scope=$want for: $*" ;; esac
}

t_what_no_user_can_see() {
  config "$TWO"
  expect_scope none README.md docs/qa.md web/README.md api/CLAUDE.md LICENSE
  expect_scope none .github/workflows/ci.yml .github/actions/x/action.yml
  expect_scope none .claude/skills/x/SKILL.md .mcp.json .cursor/rules
  expect_scope none api/tests/Feature/OrderTest.php api/phpunit.xml web/src/__tests__/cart.tsx \
    web/src/lib/money.test.ts web/src/ui/button.spec.tsx
  expect_scope none .mroom/hooks/qa-deploy mroom.toml .husky/pre-commit .editorconfig web/.gitignore \
    web/eslint.config.js api/pint.json api/phpstan.neon.dist
}

t_what_a_user_could_see() {
  config "$TWO"
  expect_scope maybe web/src/pages/cart.tsx
  expect_scope maybe web/package.json
  expect_scope maybe api/app/Orders/PlaceOrder.php
  expect_scope maybe api/database/migrations/2026_10_27_000000_add_x.php
  expect_scope maybe api/config/queue.php
  expect_scope maybe api/composer.lock
  # Markdown under resources is a view or a mail template, which reaches users.
  expect_scope maybe api/resources/views/mail/receipt.md
  expect_scope maybe scripts/new-thing.sh
  expect_scope maybe
}

t_one_visible_path_among_hidden_ones_is_enough() {
  config "$TWO"
  expect_scope maybe docs/a.md .github/workflows/x.yml api/tests/Pest.php web/src/main.tsx
  expect_scope maybe web/src/lib/money.test.ts web/src/lib/money.ts
}

t_a_single_app_is_all_app() {
  config "$SINGLE"
  expect_scope maybe app/Http/Controllers/CartController.php
  expect_scope maybe resources/js/app.ts
  expect_scope maybe resources/views/mail/receipt.md
  expect_scope none tests/Feature/CartTest.php phpunit.xml docs/x.md resources/js/cart.test.ts
  scope app/Models/Order.php tests/Unit/OrderTest.php
  expect_out $'scope=maybe\nreason=1 of 2 paths could reach the app: 1 app, 1 tests'
}

t_the_reason_names_the_areas_the_visible_ones_first() {
  config "$TWO"
  scope docs/a.md README.md .github/workflows/x.yml
  expect_out $'scope=none\nreason=only paths no user can see changed: 1 CI (.github), 2 docs'
  scope docs/a.md web/src/main.tsx api/routes/web.php docs/b.md
  expect_out $'scope=maybe\nreason=2 of 4 paths could reach the app: 1 backend, 1 frontend, 2 docs'
  scope
  expect_out $'scope=maybe\nreason=no changed paths could be read'
}

t_mroom_toml_names_more_paths() {
  config "$TWO"'

[qa]
zone = "qa.example.dev"
hidden_paths = ["api/app/*/Console/*", "api/routes/console.php"]
visible_paths = ["web/src/content/*", "docs/public/*"]'
  expect_scope none api/app/Orders/Console/PruneCommand.php api/routes/console.php
  # The visible rules come first, even over mroom's own rule for Markdown and docs.
  expect_scope maybe web/src/content/about.md
  expect_scope maybe docs/public/terms.md
  scope api/routes/console.php docs/public/terms.md
  expect_out $'scope=maybe\nreason=1 of 2 paths could reach the app: 1 qa.visible_paths, 1 qa.hidden_paths'
}

t_a_list_github_cut_short_is_a_maybe() {
  config "$TWO"
  local paths=() i
  for ((i = 0; i < 3000; i++)); do paths+=("docs/page-$i.md"); done
  scope "${paths[@]}"
  expect_out $'scope=maybe\nreason=3000 paths, the most GitHub lists, so some were not seen: 3000 docs'
}

t_a_broken_config_fails_instead_of_guessing() {
  config "$TWO"'

[qa]
hidden_paths = "api/tests/*"'
  scope docs/a.md
  expect_rc 1; expect_err_has "qa.hidden_paths must be a list of strings"
}

# listing <files JSON>: plan.sh's run for pull request 7, with GitHub's list of its files faked.
listing() {
  mkdir -p "$T/gh" "$T/bin"
  ln -sf "$ROOT/tests/fakes/gh" "$T/bin/gh"
  [ -z "$1" ] || printf '%s\n' "$1" >"$T/gh/files-7.json"
  run env PATH="$T/bin:$PATH" GH_FAKE="$T/gh" GITHUB_REPOSITORY=example/shop "$ROOT/actions/qa-plan/plan.sh" 7
}

t_a_renamed_file_counts_with_both_names() {
  config "$SINGLE"
  # A file moved from the app into the tests changes the app.
  listing '[{"filename": "tests/Unit/OrderTotals.php", "previous_filename": "app/Orders/OrderTotals.php", "status": "renamed"}]'
  expect_rc 0; expect_out $'scope=maybe\nreason=1 of 2 paths could reach the app: 1 app, 1 tests'
  listing '[{"filename": "docs/new.md", "previous_filename": "docs/old.md", "status": "renamed"}, {"filename": "README.md"}]'
  expect_out $'scope=none\nreason=only paths no user can see changed: 3 docs'
}

t_a_name_with_a_control_character_is_a_maybe() {
  config "$SINGLE"
  # GitHub lists a name with a newline as one string; read line by line it would be two names, one of them hidden.
  listing '[{"filename": "resources/js/a.test.ts\ndocs/b.php", "status": "added"}]'
  expect_rc 0; expect_out $'scope=maybe\nreason=1 of 1 paths could reach the app: 1 a name with a control character'
  listing '[{"filename": "docs/a\tb.md", "status": "added"}]'
  expect_out_has "scope=maybe"
}

t_a_listing_that_fails_is_a_maybe() {
  config "$SINGLE"
  listing ""
  expect_rc 0; expect_out $'scope=maybe\nreason=no changed paths could be read'
  expect_err_has "could not list the pull request's files"
  run env PATH="$T/bin:$PATH" GH_FAKE="$T/gh" GITHUB_REPOSITORY=example/shop "$ROOT/actions/qa-plan/plan.sh" 07
  expect_rc 2
}

test_case hidden-areas t_what_no_user_can_see
test_case visible-areas t_what_a_user_could_see
test_case one-visible-is-enough t_one_visible_path_among_hidden_ones_is_enough
test_case single-app t_a_single_app_is_all_app
test_case reason t_the_reason_names_the_areas_the_visible_ones_first
test_case config-paths t_mroom_toml_names_more_paths
test_case cut-short-list t_a_list_github_cut_short_is_a_maybe
test_case broken-config t_a_broken_config_fails_instead_of_guessing
test_case renamed-both-names t_a_renamed_file_counts_with_both_names
test_case control-character t_a_name_with_a_control_character_is_a_maybe
test_case listing-fails t_a_listing_that_fails_is_a_maybe
finish
