#!/usr/bin/env bash
# shellcheck disable=SC2317  # the t_* functions run indirectly, through test_case
# Tests for the QA plan's frontend build (actions/qa-plan/build.sh): what it builds where for each layout of an app,
# and that the build gets the environment's public values and nothing else: env:<KEY> for a value qa-up writes
# into the .env, empty for any other, a plain value as it is; the Reverb app's, from the pull request's number, only
# when the environment broadcasts with Reverb. Offline: npm and pnpm are fakes that say how they ran.
set -euo pipefail
SUITE=qa-build
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/qa-world.sh
source "$(dirname "${BASH_SOURCE[0]}")/qa-world.sh"
skip_unless has_box_tools "this host lacks bash 5, flock or GNU date, which the QA actions need"
skip_unless has_tomllib "python3 has no tomllib (needs 3.11+)"
has_jq() { command -v jq >/dev/null 2>&1; }
skip_unless has_jq "this host has no jq"

BUILD="$ROOT/actions/qa-plan/build.sh"

# app <toml>: the pull request's checkout in $T/app, with that mroom.toml, and fakes for npm and pnpm. The fake's
# build writes index.html into the folder app.build.frontend_dist names, and the build's environment into
# $T/build.env.
app() {
  mkdir -p "$T/app" "$T/bin"
  printf '[app]\nname = "shop"\n%s\n\n[qa]\nzone = "qa.example.dev"\n' "$1" >"$T/app/mroom.toml"
  local tool
  for tool in npm pnpm; do
    cat >"$T/bin/$tool" <<FAKE
#!/usr/bin/env bash
echo "$tool \$* (in \${PWD#\$T/app})" >>"\$T/tools.log"
if [ "\$*" = "run build" ]; then
  env | grep -E '^(VITE_|APP_URL)' | sort >"\$T/build.env" || true
  mkdir -p "\${OUT:-dist}" && echo '<html></html>' >"\${OUT:-dist}/index.html"
fi
FAKE
    chmod +x "$T/bin/$tool"
  done
  export T PATH="$T/bin:$PATH"
}

t_what_each_layout_builds() {
  app $'backend_dir = "api"\nfrontend_dir = "web"\n\n[app.build]\nfrontend = "npm run build"'
  run "$BUILD" settings 7 "$T/app"; expect_rc 0; expect_out $'dir=web\nnode_file=\ndist=web/dist'
  mkdir -p "$T/app/web" && echo 22 >"$T/app/web/.nvmrc"
  run "$BUILD" settings 7 "$T/app"; expect_out $'dir=web\nnode_file=web/.nvmrc\ndist=web/dist'
  # Vite inside the Laravel app builds in the backend's folder, into public/build.
  app $'backend_dir = "."\nfrontend_dir = "."\n\n[app.build]\nfrontend = "npm run build"'
  echo 22 >"$T/app/.node-version"
  run "$BUILD" settings 7 "$T/app"; expect_out $'dir=.\nnode_file=.node-version\ndist=./public/build'
  app $'backend_dir = "."\nfrontend_dir = "."\n\n[app.build]\nfrontend = "npm run build"\nfrontend_dist = "public/assets"'
  run "$BUILD" settings 7 "$T/app"; expect_out $'dir=.\nnode_file=.node-version\ndist=./public/assets'
  # No frontend, or no build command: nothing to build.
  app $'frontend_dir = ""\n\n[app.build]\nfrontend = "npm run build"'
  run "$BUILD" settings 7 "$T/app"; expect_out $'dir=\nnode_file=\ndist='
  app 'frontend_dir = "web"'
  run "$BUILD" settings 7 "$T/app"; expect_out $'dir=web\nnode_file=\ndist='
  run "$BUILD" run 7 "$T/app"; expect_rc 0; expect_out_has "nothing to build"
  expect_no_file "$T/tools.log"
}

t_the_build_gets_public_values_only() {
  app $'backend_dir = "api"\nfrontend_dir = "web"\n\n[app.build]\nfrontend = "npm run build"
frontend_env = { VITE_API = "env:APP_URL", VITE_CLIENT = "env:CLIENT_URL", VITE_XSRF = "env:XSRF_COOKIE_NAME", VITE_COOKIES = "env:SESSION_DOMAIN", VITE_PAYMENTS = "env:PAYMENTS_SECRET", VITE_MODE = "qa" }'
  mkdir -p "$T/app/web"
  # Even when the runner has the key in its own environment, the build never gets it.
  run env PAYMENTS_SECRET=leaked-from-the-runner "$BUILD" run 7 "$T/app"
  expect_rc 0; expect_out_has "VITE_PAYMENTS reads PAYMENTS_SECRET, which is not one of a QA environment's public values"
  expect_out_has "built web/dist"
  run cat "$T/build.env"
  # The cookies are for the environment's own two hosts.
  expect_out "VITE_API=https://$(api_host 7)"$'\n'"VITE_CLIENT=https://$(web_host 7)"$'\n'"VITE_COOKIES=.$(web_host 7)"$'\nVITE_MODE=qa\nVITE_PAYMENTS=\n'"VITE_XSRF=$(site_user 7)_csrf"
  run cat "$T/tools.log"; expect_out $'npm ci (in /web)\nnpm run build (in /web)'
}

t_the_reverb_settings_come_from_the_pull_request() {
  local echo='frontend_env = { VITE_REVERB_APP_KEY = "env:REVERB_APP_KEY", VITE_REVERB_HOST = "env:REVERB_HOST", VITE_REVERB_PORT = "env:REVERB_PORT", VITE_REVERB_SCHEME = "env:REVERB_SCHEME", VITE_REVERB_SECRET = "env:REVERB_APP_SECRET" }'
  # Broadcasting with Reverb, the default: the app's key from the pull request, as the gate makes it, and the
  # box's Reverb host. Its secret is never one of them.
  app $'frontend_dir = "web"\n\n[app.build]\nfrontend = "npm run build"\n'"$echo"
  mkdir -p "$T/app/web"
  run "$BUILD" run 7 "$T/app"
  expect_rc 0; expect_out_has "VITE_REVERB_SECRET reads REVERB_APP_SECRET, which is not one of a QA environment's public values"
  run cat "$T/build.env"
  expect_out "VITE_REVERB_APP_KEY=$(reverb_app 7)"$'\nVITE_REVERB_HOST=ws.qa.example.dev\nVITE_REVERB_PORT=443\nVITE_REVERB_SCHEME=https\nVITE_REVERB_SECRET='
  # To the log: none of them, and the build is told why each is empty.
  rm -f "$T/build.env"
  printf '\n[qa.parity]\nbroadcast = "log"\n' >>"$T/app/mroom.toml"
  run "$BUILD" run 7 "$T/app"
  expect_rc 0; expect_out_has "VITE_REVERB_APP_KEY reads REVERB_APP_KEY, which is not one of a QA environment's public values"
  run cat "$T/build.env"
  expect_out $'VITE_REVERB_APP_KEY=\nVITE_REVERB_HOST=\nVITE_REVERB_PORT=\nVITE_REVERB_SCHEME=\nVITE_REVERB_SECRET='
  # A setting mroom.toml does not allow fails the build.
  printf '%s\n' "$(sed 's/broadcast = "log"/broadcast = "pusher"/' "$T/app/mroom.toml")" >"$T/app/mroom.toml"
  run "$BUILD" run 7 "$T/app"
  expect_rc 1; expect_err_has "mroom.toml could not say how the environment broadcasts (qa.parity.broadcast)"
}

t_vite_inside_laravel_gets_the_api_host_for_both() {
  app $'[app.build]\nfrontend = "npm run build"\nfrontend_env = { VITE_CLIENT = "env:CLIENT_URL", VITE_COOKIES = "env:SESSION_DOMAIN" }'
  run env OUT=public/build "$BUILD" run 12 "$T/app"
  expect_rc 0; expect_out_has "built ./public/build"
  # The cookies stay on the one host.
  run cat "$T/build.env"; expect_out "VITE_CLIENT=https://$(api_host 12)"$'\nVITE_COOKIES=null'
}

t_pnpm_installs_from_the_lockfile() {
  app $'frontend_dir = "web"\npackage_manager = "pnpm"\n\n[app.build]\nfrontend = "pnpm run build"'
  mkdir -p "$T/app/web"
  run "$BUILD" run 7 "$T/app"
  expect_rc 0
  run cat "$T/tools.log"; expect_out $'pnpm install --frozen-lockfile (in /web)\npnpm run build (in /web)'
}

t_a_build_that_writes_nothing_fails() {
  app $'frontend_dir = "web"\n\n[app.build]\nfrontend = "true"'
  mkdir -p "$T/app/web"
  run "$BUILD" run 7 "$T/app"
  expect_rc 1; expect_err_has "the build wrote nothing to web/dist (app.build.frontend_dist)"
}

t_a_bad_name_or_number_is_refused() {
  app $'frontend_dir = "web"\n\n[app.build]\nfrontend = "npm run build"\nfrontend_env = { "A-B" = "x" }'
  mkdir -p "$T/app/web"
  run "$BUILD" run 7 "$T/app"; expect_rc 1; expect_err_has "app.build.frontend_env has a name that is not one: A-B"
  run "$BUILD" run 07 "$T/app"; expect_rc 2
  run "$BUILD" build 7 "$T/app"; expect_rc 2
  run "$BUILD" settings 7 "$T/nowhere"; expect_rc 2
}

test_case layouts t_what_each_layout_builds
test_case public-values-only t_the_build_gets_public_values_only
test_case reverb-from-the-pr t_the_reverb_settings_come_from_the_pull_request
test_case vite-inside-laravel t_vite_inside_laravel_gets_the_api_host_for_both
test_case pnpm t_pnpm_installs_from_the_lockfile
test_case writes-nothing t_a_build_that_writes_nothing_fails
test_case refused t_a_bad_name_or_number_is_refused
finish
