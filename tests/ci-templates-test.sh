#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2016  # t_* run through test_case; a $ in single quotes is the YAML's own
# Tests for the CI templates in templates/github (design section 10), which no offline test can run on
# GitHub: caches are saved only on the default branch and only restored in pull requests; the apt and
# vendor keys and their fallbacks; the catch-all shard; the fixed aggregate checks; the measuring mode;
# no secret or write permission near a pull request's code; every placeholder documented. The shape
# checks are in tests/files/ci-check.py; this file also runs the changed-areas script and the measuring
# report, and renders every template from both example configs into YAML that parses.
set -euo pipefail
SUITE=ci-templates
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TPL="$ROOT/templates/github"
CHECK="$ROOT/tests/files/ci-check.py"
RENDER="$ROOT/tests/files/ci-render.py"

has_yaml() { python3 -c 'import yaml' >/dev/null 2>&1; }

# shape <check>: one check of ci-check.py passes.
shape() { run python3 "$CHECK" "$1" "$ROOT"; expect_rc 0; }

t_caches_are_never_saved_by_a_post_step() { shape no-save-on-post; }
t_caches_are_saved_only_on_the_default_branch() { shape save-on-default-branch; }
t_setup_node_saves_no_cache_of_its_own() { shape no-setup-node-cache; }
t_restore_and_save_use_the_same_paths_and_keys() { shape keys-match; }
t_vendor_is_keyed_on_the_lock_with_a_fallback() { shape vendor; }
t_apt_packages_are_keyed_on_the_lock_and_the_week_and_cleaned_before_a_save() { shape apt; }
t_the_last_backend_shard_catches_every_other_suite() { shape catch-all; }
t_each_sharded_job_has_one_fixed_aggregate_check() { shape aggregate; }
t_the_backend_has_a_measuring_mode() { shape measure; }
t_no_secret_or_write_permission_reaches_pull_request_code() { shape no-secrets; }
t_required_checks_always_report() { shape required-checks-report; }
t_job_names_match_ci_first_push_defaults() { shape first-push-names; }
t_the_e2e_build_is_reused_and_saved_on_the_default_branch() { shape e2e-build; }
t_every_placeholder_is_documented() { shape placeholders; }

t_every_template_file_is_there() {
  local file
  for file in workflows/ci-backend.yml workflows/ci-frontend.yml workflows/ci-e2e.yml workflows/ci-cache-warm.yml \
    workflows/ci-e2e-build-warm.yml actions/changed-areas/action.yml actions/setup-frontend/action.yml \
    actions/e2e-frontend-build/action.yml scripts/vitest-file-times.mjs; do
    expect_file "$TPL/$file"
  done
}

# areas <event> <backend dir> <frontend dir> <changed file...>: runs the changed-areas script with a fake git that
# lists those files, leaving its outputs in $out as one line.
areas() {
  local event="$1" back="$2" front="$3"
  shift 3
  mkdir -p "$T/bin"
  printf '%s\n' "$@" >"$T/files"
  cat >"$T/bin/git" <<EOF
#!/usr/bin/env bash
case "\$1" in fetch) exit 0 ;; diff) cat "$T/files" ;; *) exit 1 ;; esac
EOF
  chmod +x "$T/bin/git"
  python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))["runs"]["steps"][0]["run"])' \
    "$TPL/actions/changed-areas/action.yml" >"$T/areas.sh"
  : >"$T/output"
  run env PATH="$T/bin:$PATH" EVENT="$event" BACKEND_DIR="$back" FRONTEND_DIR="$front" GITHUB_OUTPUT="$T/output" \
    GITHUB_SHA=0 bash "$T/areas.sh"
  out="$(tr '\n' ' ' <"$T/output")"
}

t_changed_areas_by_folder() {
  areas pull_request api web web/src/main.ts
  expect_out "backend=false frontend=true e2e=true "
  areas pull_request api web api/app/Models/User.php
  expect_out "backend=true frontend=false e2e=true "
  areas pull_request api web docs/notes.txt README.md
  expect_out "backend=false frontend=false e2e=false "
  # A folder named like the backend's start is not the backend.
  areas pull_request api web apiary/x.php
  expect_out "backend=false frontend=false e2e=false "
  # A dot in a folder's name is a dot, not any character.
  areas pull_request my.app web myXapp/x.php
  expect_out "backend=false frontend=false e2e=false "
}

t_changed_areas_for_ci_files() {
  areas pull_request api web .github/workflows/ci-cache-warm.yml
  expect_out "backend=true frontend=false e2e=true "
  areas pull_request api web .github/actions/setup-frontend/action.yml
  expect_out "backend=true frontend=true e2e=true "
  areas pull_request api web .github/scripts/vitest-file-times.mjs
  expect_out "backend=false frontend=true e2e=false "
  areas pull_request api web .github/workflows/ci-e2e-build-warm.yml
  expect_out "backend=false frontend=false e2e=true "
}

t_changed_areas_for_one_folder_and_none() {
  # "." is the whole repository.
  areas pull_request . . README.md
  expect_out "backend=true frontend=true e2e=true "
  # No frontend: nothing is the frontend.
  areas pull_request . "" README.md
  expect_out "backend=true frontend=false e2e=true "
}

t_changed_areas_outside_a_pull_request_is_everything() {
  areas push api web README.md
  expect_out "backend=true frontend=true e2e=true "
}

t_the_measuring_report_suggests_a_split_with_rest_last() {
  local dir="$T/times" i
  python3 -c '
import sys, yaml
run = yaml.safe_load(open(sys.argv[1]))["jobs"]["measure-report"]["steps"][1]["run"]
print(run.split("<<'"'"'PY'"'"'\n", 1)[1].split("\nPY\n", 1)[0])' "$TPL/workflows/ci-backend.yml" >"$T/report.py"
  i=0
  for pair in Orders:150 Billing:140 Users:60 Mail:40 Search:30; do
    i=$((i + 1))
    mkdir -p "$dir/suite-time-$i"
    printf '{"suite": "%s", "seconds": %s}\n' "${pair%%:*}" "${pair##*:}" >"$dir/suite-time-$i/suite-time.json"
  done
  run python3 "$T/report.py" 3 "$dir"
  expect_rc 0
  expect_out_has "| Orders | 150 |"
  expect_out_has "| Orders | 150 | Orders |"
  expect_out_has "| Billing | 140 | Billing |"
  expect_out_has "| rest | 130 | Users, Mail, Search |"
}

# render_all <example>: renders every template from examples/<example>/mroom.toml into $T/<example>.
render_all() {
  local file rel
  for file in "$TPL"/workflows/*.yml "$TPL"/actions/*/action.yml; do
    rel="${file#"$TPL"/}"
    mkdir -p "$T/$1/$(dirname "$rel")"
    run python3 "$RENDER" "$file" "$ROOT/examples/$1/mroom.toml" node_version=22 backend_static_checks="vendor/bin/pint --test" \
      slowest_suite=Orders e2e_suite=Browser measured_times="Orders 150 s" frontend_lint="npm run lint" frontend_src=src \
      e2e_build="npx vite build --sourcemap false" e2e_command="php artisan test --testsuite=Browser"
    expect_rc 0
    printf '%s\n' "$out" >"$T/$1/$rel"
    run python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$T/$1/$rel"
    expect_rc 0
  done
}

t_the_single_app_example_renders() {
  render_all single-app
  local backend="$T/single-app/workflows/ci-backend.yml"
  expect_true "a folder of . left a ./ in a path" grep -qx '          path: vendor' "$backend"
  expect_true "the CI database is not from tests.database_pattern" grep -qx '  DB_DATABASE: shop_ci_testing' "$backend"
  expect_true "npm's lockfile is not in the store key" grep -qF "hashFiles('package-lock.json'" \
    "$T/single-app/actions/setup-frontend/action.yml"
  expect_true "Vite inside Laravel does not build into public/build" grep -qx '        path: public/build' \
    "$T/single-app/actions/e2e-frontend-build/action.yml"
  expect_true "a single app starts a frontend server of its own" grep -qF "'.' != '.'" "$T/single-app/workflows/ci-e2e.yml"
}

t_the_two_folder_example_renders() {
  render_all two-folder
  local backend="$T/two-folder/workflows/ci-backend.yml"
  expect_true "the backend folder is not in the vendor path" grep -qx '          path: api/vendor' "$backend"
  expect_true "the test command is not tests.command" grep -qxF '          php artisan test --compact --parallel "${options[@]}"' "$backend"
  expect_true "the pnpm install is not frozen" grep -qF 'pnpm install --frozen-lockfile' "$T/two-folder/workflows/ci-e2e.yml"
  expect_true "the default branch is not main" grep -qF "github.ref == 'refs/heads/main'" "$T/two-folder/workflows/ci-cache-warm.yml"
}

t_an_unfilled_placeholder_fails_the_render() {
  run python3 "$RENDER" "$TPL/workflows/ci-frontend.yml" "$ROOT/examples/two-folder/mroom.toml"
  expect_rc 1
  expect_err_has "unfilled: <<fill:frontend_lint>>"
}

skip_unless has_yaml "python3 has no yaml module (PyYAML)"
test_case files t_every_template_file_is_there
test_case save-on-post t_caches_are_never_saved_by_a_post_step
test_case save-default t_caches_are_saved_only_on_the_default_branch
test_case setup-node t_setup_node_saves_no_cache_of_its_own
test_case keys t_restore_and_save_use_the_same_paths_and_keys
test_case vendor t_vendor_is_keyed_on_the_lock_with_a_fallback
test_case apt t_apt_packages_are_keyed_on_the_lock_and_the_week_and_cleaned_before_a_save
test_case catch-all t_the_last_backend_shard_catches_every_other_suite
test_case aggregate t_each_sharded_job_has_one_fixed_aggregate_check
test_case measure t_the_backend_has_a_measuring_mode
test_case secrets t_no_secret_or_write_permission_reaches_pull_request_code
test_case report t_required_checks_always_report
test_case first-push t_job_names_match_ci_first_push_defaults
test_case e2e-build t_the_e2e_build_is_reused_and_saved_on_the_default_branch
test_case placeholders t_every_placeholder_is_documented
test_case areas-folder t_changed_areas_by_folder
test_case areas-ci t_changed_areas_for_ci_files
test_case areas-one t_changed_areas_for_one_folder_and_none
test_case areas-push t_changed_areas_outside_a_pull_request_is_everything
test_case measure-report t_the_measuring_report_suggests_a_split_with_rest_last
# Rendering reads mroom.toml through bin/mroom, which needs python3 3.11+.
skip_unless has_tomllib "python3 has no tomllib (3.11+)"
test_case single-app t_the_single_app_example_renders
test_case two-folder t_the_two_folder_example_renders
test_case unfilled t_an_unfilled_placeholder_fails_the_render
finish
