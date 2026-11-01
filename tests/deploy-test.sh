#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2016  # t_* run through test_case; a $ in single quotes is the fake's or the YAML's own
# Tests for the production deploy (design 10, patterns 8 to 10): templates/github/workflows/deploy-production.yml,
# its script templates/github/scripts/release-branch.sh and actions/deploy-verify. The script runs against a real git
# repository with a bare one as GitHub, so a tag moves the release branch forward, back for a rollback, or not at
# all, and a tag off the default branch is refused. deploy-verify runs against a fake host (curl answering from
# files, sleep recording), so it waits until the live commit matches the tag, three times in a row, and fails after
# its time limit. The workflow's shape (who holds the deploy key, what runs beside it) is checked by
# tests/ci/check.py, and it renders from both examples into YAML that parses. Offline.
set -euo pipefail
SUITE=deploy
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TPL="$ROOT/templates/github"
SCRIPT="$TPL/scripts/release-branch.sh"
VERIFY="$ROOT/actions/deploy-verify/verify.sh"
OLD=1111111111111111111111111111111111111111
NEW=2222222222222222222222222222222222222222
APP=https://api.shop.example.dev
WEB=https://shop.example.dev
PYTHONUSERBASE="$(python3 -m site --user-base 2>/dev/null || true)"
export PYTHONUSERBASE

has_yaml() { python3 -c 'import yaml' >/dev/null 2>&1; }
has_git() { command -v git >/dev/null 2>&1 && git init -q -b main "$TOP/.probe" >/dev/null 2>&1; }
has_bash4() { [ "${BASH_VERSINFO[0]}" -ge 4 ] && has_tomllib; }

# --- release-branch.sh, against a bare repository standing in for GitHub ---

g() { git -c user.name=Dev -c user.email=dev@example.invalid -c advice.detachedHead=false "$@"; }

# repo: $T/origin.git with main at two tagged commits (v1.0.0, then v1.1.0), a nightly tag on main, and a branch
# from v1.0.0 with a tag of its own (v9.0.0) that never merged. Sets C1, C2 and C3 to their commits.
repo() {
  g init -q --bare -b main "$T/origin.git"
  g init -q -b main "$T/dev"
  g -C "$T/dev" remote add origin "$T/origin.git"
  g -C "$T/dev" commit -q --allow-empty -m one && g -C "$T/dev" tag -a v1.0.0 -m v1.0.0
  g -C "$T/dev" commit -q --allow-empty -m two && g -C "$T/dev" tag v1.1.0 && g -C "$T/dev" tag nightly
  g -C "$T/dev" switch -q -c side v1.0.0 && g -C "$T/dev" commit -q --allow-empty -m side && g -C "$T/dev" tag v9.0.0
  g -C "$T/dev" push -q origin main side --tags
  C1="$(g -C "$T/dev" rev-parse 'v1.0.0^{commit}')" C2="$(g -C "$T/dev" rev-parse v1.1.0)" C3="$(g -C "$T/dev" rev-parse v9.0.0)"
}

# deploy <ref> [VAR=value...]: what the release job does for a run on <ref>: a fresh checkout of it, as actions/checkout
# with full history gives, then the script with the run's environment (a dispatch from a tag, unless the arguments
# say otherwise).
deploy() {
  local ref="$1"
  shift
  rm -rf "$T/run"
  g clone -q "$T/origin.git" "$T/run"
  g -C "$T/run" checkout -q "$ref"
  : >"$T/summary"
  run env EVENT=workflow_dispatch REF_TYPE=tag REF_NAME="$ref" DEFAULT_BRANCH=main \
    TAG_PATTERN='^v[0-9]+\.[0-9]+\.[0-9]+$' GITHUB_STEP_SUMMARY="$T/summary" "$@" \
    bash -c 'cd "$1" && exec bash "$2"' _ "$T/run" "$SCRIPT"
}

live() { g -C "$T/origin.git" rev-parse --verify --quiet refs/heads/release || echo none; }

# host_fetch: what the host's deploy script runs in its clone, $T/site, as the README gives it (production deploy,
# step 2): the branch by its full name into a ref of its own, then a reset to it.
host_fetch() {
  g -C "$T/site" fetch -q origin +refs/heads/release:refs/remotes/origin/release &&
    g -C "$T/site" reset -q --hard refs/remotes/origin/release
}

t_a_first_release_creates_the_branch_at_the_tag() {
  repo
  deploy v1.0.0 EVENT=release RELEASE_TAG=v1.0.0
  expect_rc 0
  expect_out $'tag=v1.0.0\ncommit='"$C1"$'\nprevious=none\ndirection=new'
  expect_true "release is not at v1.0.0's commit (an annotated tag)" [ "$(live)" = "$C1" ]
  expect_true "the job summary does not say where release points" grep -qF "points at v1.0.0 (\`$C1\`): new" "$T/summary"
}

t_a_newer_tag_moves_it_forward_and_a_rerun_leaves_it() {
  repo
  deploy v1.0.0
  deploy v1.1.0 EVENT=release RELEASE_TAG=v1.1.0
  expect_rc 0
  expect_out $'tag=v1.1.0\ncommit='"$C2"$'\nprevious='"$C1"$'\ndirection=forward'
  expect_true "release did not move to v1.1.0" [ "$(live)" = "$C2" ]
  deploy v1.1.0
  expect_rc 0
  expect_out_has "direction=same"
  expect_err_has "nothing to push"
  expect_true "a re-run moved release" [ "$(live)" = "$C2" ]
}

t_an_older_tag_rolls_it_back() {
  repo
  deploy v1.1.0
  deploy v1.0.0
  expect_rc 0
  expect_out $'tag=v1.0.0\ncommit='"$C1"$'\nprevious='"$C2"$'\ndirection=rollback'
  expect_err_has "::warning::rolling release back from $C2 to v1.0.0"
  expect_true "release did not roll back to v1.0.0" [ "$(live)" = "$C1" ]
}

t_a_tag_off_the_default_branch_is_refused() {
  repo
  deploy v1.0.0
  deploy v9.0.0
  expect_rc 1
  expect_err_has "v9.0.0 ($C3) is not on main"
  expect_out ""
  expect_true "a refused tag moved release" [ "$(live)" = "$C1" ]
}

t_only_a_release_tag_of_the_run_deploys() {
  repo
  # A run from a branch, as a dispatch from main would be.
  deploy main REF_TYPE=branch
  expect_rc 1; expect_err_has "runs from a release tag, not the branch main"
  deploy nightly
  expect_rc 1; expect_err_has "nightly is not a release tag"
  # A release whose tag is not the run's.
  deploy v1.0.0 EVENT=release RELEASE_TAG=v1.1.0
  expect_rc 1; expect_err_has "the release is for v1.1.0, but the run is for v1.0.0"
  # A checkout that is not the tag's commit.
  deploy v1.1.0 REF_NAME=v1.0.0
  expect_rc 1; expect_err_has "the checkout is not at v1.0.0's commit"
  deploy v1.0.0 REF_NAME=v7.7.7
  expect_rc 1; expect_err_has "no tag v7.7.7"
  deploy v1.0.0 DEFAULT_BRANCH=
  expect_rc 1; expect_err_has "DEFAULT_BRANCH is not set"
  expect_true "a refused run created release" [ "$(live)" = none ]
}

t_a_branch_someone_else_moved_is_left_for_a_person() {
  repo
  deploy v1.0.0
  g -C "$T/dev" push -q -f origin "$C3:refs/heads/release"
  deploy v1.1.0
  expect_rc 1
  expect_err_has "release is at $C3, which is not on main"
  expect_true "the deploy moved a branch someone else moved" [ "$(live)" = "$C3" ]
  # A commit after the tag, but never on main: moving release back to the tag would look like a rollback.
  g -C "$T/dev" switch -q --detach v1.1.0 && g -C "$T/dev" commit -q --allow-empty -m stray
  g -C "$T/dev" push -q -f origin HEAD:refs/heads/release
  local stray
  stray="$(g -C "$T/dev" rev-parse HEAD)"
  deploy v1.1.0
  expect_rc 1
  expect_err_has "release is at $stray, which is not on main"
  expect_true "the deploy moved a branch someone else moved" [ "$(live)" = "$stray" ]
}

# A tag named like the branch: git ranks refs/tags/<name> above refs/heads/<name>, so a host whose deploy script
# fetches the branch by its short name (git pull origin release) takes the tag instead. Anyone with Write can push a
# tag, so one at a commit no one released would go live with the next deploy.
t_a_tag_named_like_the_branch_is_left_for_a_person() {
  repo
  deploy v1.0.0
  g -C "$T/dev" switch -q --detach v1.0.0 && g -C "$T/dev" commit -q --allow-empty -m unreleased
  local unreleased
  unreleased="$(g -C "$T/dev" rev-parse HEAD)"
  # A tag whose name only ends in the branch's is no shadow.
  g -C "$T/dev" push -q origin HEAD:refs/tags/hotfix/release
  deploy v1.0.0
  expect_rc 0
  # An annotated tag release: what such a deploy script gets is the unreleased commit, not the branch at v1.0.0.
  g -C "$T/dev" tag -a -m unreleased release
  g -C "$T/dev" push -q origin refs/tags/release
  g -C "$T/dev" fetch -q origin release
  expect_true "a fetch of release by its short name took the branch over the tag" \
    [ "$(g -C "$T/dev" rev-parse 'FETCH_HEAD^{commit}')" = "$unreleased" ]
  deploy v1.1.0
  expect_rc 1
  expect_err_has "origin has the tag release, which a fetch of release by its short name takes over the branch"
  expect_out ""
  expect_true "the deploy moved release while a tag of its name was there" [ "$(live)" = "$C1" ]
  # A re-run of the deployed tag stops too: with a deploy hook, the host would deploy again.
  deploy v1.0.0
  expect_rc 1
  expect_err_has "origin has the tag release"
  # Once a person has removed it, the deploy goes on.
  g -C "$T/dev" push -q origin :refs/tags/release
  deploy v1.1.0
  expect_rc 0
  expect_true "release did not move to v1.1.0 once the tag was gone" [ "$(live)" = "$C2" ]
}

# The host's fetch as the README gives it takes the branch over a tag named release that came after the deploy's
# check, brings the release's tag for the version file's git describe, and moves the site back for a rollback.
t_the_hosts_fetch_takes_the_branch_and_its_tag() {
  # host_fetch runs the README's own commands.
  expect_true "the README's host fetch is not the one host_fetch runs" \
    grep -qxF '   git fetch origin +refs/heads/release:refs/remotes/origin/release &&' "$ROOT/README.md"
  expect_true "the README's host reset is not the one host_fetch runs" \
    grep -qxF '     git reset --hard refs/remotes/origin/release' "$ROOT/README.md"
  repo
  deploy v1.0.0
  g clone -q -b release "$T/origin.git" "$T/site"
  # A release tagged after the host's clone.
  g -C "$T/dev" switch -q main && g -C "$T/dev" commit -q --allow-empty -m three && g -C "$T/dev" tag v1.2.0
  g -C "$T/dev" push -q origin main refs/tags/v1.2.0
  local c4 unreleased
  c4="$(g -C "$T/dev" rev-parse HEAD)"
  deploy v1.2.0
  expect_rc 0
  g -C "$T/dev" switch -q --detach v1.0.0 && g -C "$T/dev" commit -q --allow-empty -m unreleased
  unreleased="$(g -C "$T/dev" rev-parse HEAD)"
  g -C "$T/dev" push -q origin HEAD:refs/tags/release
  host_fetch
  expect_true "the host's fetch did not take the branch" [ "$(g -C "$T/site" rev-parse HEAD)" = "$c4" ]
  expect_true "git describe does not name v1.2.0 after the host's fetch" \
    [ "$(g -C "$T/site" describe --tags --exact-match)" = v1.2.0 ]
  expect_true "the host's fetch brought the unreleased commit" \
    bash -c '! git -C "$1" cat-file -e "$2^{commit}" 2>/dev/null' _ "$T/site" "$unreleased"
  # A rollback, once a person has removed that tag.
  g -C "$T/dev" push -q origin :refs/tags/release
  deploy v1.1.0
  expect_rc 0
  host_fetch
  expect_true "the host's fetch did not move the site back" [ "$(g -C "$T/site" rev-parse HEAD)" = "$C2" ]
}

t_another_branch_name_can_be_used() {
  repo
  deploy v1.1.0 RELEASE_BRANCH=production
  expect_rc 0
  expect_true "the named branch was not created" [ "$(g -C "$T/origin.git" rev-parse production)" = "$C2" ]
  expect_true "release was created as well" [ "$(live)" = none ]
  # A name with a slash is refused: refs/<name>, outside heads and tags, would shadow it.
  deploy v1.1.0 RELEASE_BRANCH=deploy/live
  expect_rc 1
  expect_err_has "RELEASE_BRANCH is not one plain name"
  expect_true "a refused name was created" \
    bash -c '! git -C "$1" rev-parse --verify -q refs/heads/deploy/live' _ "$T/origin.git"
}

# --- deploy-verify, against a fake host ---

# host: a fake curl that answers from $T/web, one file per address (its query left out): each line is
# "<code> <body>", the first one used and dropped while more than one is left, so the last line answers from then on.
# An address with no file answers nothing (000). Each call's arguments go to $T/curl.log, one line each. sleep only
# records how long it was asked for. Called again in a test, it starts afresh.
host() {
  rm -rf "$T/web" "$T/curl.log" "$T/sleep.log"
  mkdir -p "$T/bin" "$T/web"
  cat >"$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
out="" format="" url=""
printf '%s\n' "$*" >>"$T/curl.log"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w) format="$2"; shift 2 ;;
    --max-time | --max-filesize | --proto | -H) shift 2 ;;
    http://* | https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
file="$T/web/$(printf '%s' "${url%%\?*}" | tr -c 'A-Za-z0-9.\n' _)"
[ -f "$file" ] || { [ -z "$format" ] || printf '000'; exit 7; }
line="$(head -n1 "$file")"
if [ "$(wc -l <"$file")" -gt 1 ]; then tail -n +2 "$file" >"$file.new" && mv "$file.new" "$file"; fi
printf '%s' "${line#* }" >"${out:-/dev/stdout}"
[ -z "$format" ] || printf '%s' "${line%% *}"
EOF
  printf '#!/bin/sh\necho "$1" >>"$T/sleep.log"\n' >"$T/bin/sleep"
  chmod +x "$T/bin/curl" "$T/bin/sleep"
  printf '[app]\nname = "shop"\n' >"$T/mroom.toml"
  export T PATH="$T/bin:$PATH" MROOM_NOW=1793102400 MROOM_CONFIG="$T/mroom.toml"
  unset GITHUB_OUTPUT
  : >"$T/summary"
}

# answers <url> <line...>: what the address answers, in order.
answers() {
  local url="$1"
  shift
  printf '%s\n' "$@" >"$T/web/$(printf '%s' "$url" | tr -c 'A-Za-z0-9.\n' _)"
}
# version <commit> [<release, or null>]: a version endpoint's answer line.
version() {
  local release="${2:-v1.2.3}"
  [ "$release" = null ] || release="\"$release\""
  printf '200 {"release": %s, "commit": "%s"}' "$release" "$1"
}

# verify [VAR=value...]: the action's script with the inputs the deploy passes, for v1.2.3 at $NEW.
verify() {
  run env DEPLOY_ORIGIN="$APP" DEPLOY_COMMIT="$NEW" DEPLOY_TAG=v1.2.3 DEPLOY_TIMEOUT=10m DEPLOY_INTERVAL=10s \
    GITHUB_STEP_SUMMARY="$T/summary" "$@" bash "$VERIFY"
}
polls() { grep -c "$1" "$T/curl.log" || true; }

t_it_waits_until_the_live_commit_matches_three_times() {
  host
  answers "$APP/version" "$(version "$OLD" v1.2.2)" "$(version "$OLD" v1.2.2)" "$(version "$NEW")"
  answers "$APP/up" "200 ok"
  verify
  expect_rc 0
  expect_out "seconds=40"
  expect_err_has "app: commit $OLD (v1.2.2)"
  expect_err_has "app: commit $NEW (v1.2.3)"
  expect_err_has "Live: v1.2.3 ($NEW), confirmed 3 times in a row after 40s"
  expect_err_lacks "::warning::"
  expect_true "it did not poll five times" [ "$(polls "$APP/version?mroom=")" = 5 ]
  expect_true "it did not sleep 10 seconds between polls" [ "$(tr '\n' ' ' <"$T/sleep.log")" = "10 10 10 10 " ]
  expect_true "the health path was asked before the release was live" [ "$(polls "$APP/up")" = 3 ]
  expect_true "two polls had the same query, which a cache could answer" \
    [ "$(grep -o 'mroom=[0-9-]*' "$T/curl.log" | sort -u | wc -l)" -eq 5 ]
  expect_true "it does not ask caches not to answer" grep -qF -- "-H Cache-Control: no-cache" "$T/curl.log"
  expect_true "it follows redirects" bash -c '! grep -qE -- "(^| )(-L|--location)( |$)" "$T/curl.log"'
  expect_true "the job summary does not say it is live" grep -qF "v1.2.3 (\`$NEW\`) is live on app, confirmed 3 times" "$T/summary"
}

t_an_old_answer_in_between_starts_the_count_again() {
  host
  answers "$APP/version" "$(version "$NEW")" "$(version "$NEW")" "$(version "$OLD" v1.2.2)" "$(version "$NEW")"
  answers "$APP/up" "200 ok"
  verify
  expect_rc 0
  expect_out "seconds=50"
}

t_a_failed_deploy_fails_after_the_time_limit() {
  host
  answers "$APP/version" "$(version "$OLD" v1.2.2)"
  answers "$APP/up" "200 ok"
  verify DEPLOY_TIMEOUT=1m
  expect_rc 1
  expect_out ""
  expect_err_has "::error::production did not report v1.2.3's commit $NEW 3 times in a row within 1m"
  expect_err_has "app last answered: commit $OLD (v1.2.2)"
  expect_err_has "A rollback deploys the previous tag"
  # It asks once more only while the next poll would still be within the limit.
  expect_true "it did not poll 7 times in a minute, 10 seconds apart" [ "$(polls "$APP/version")" = 7 ]
  expect_true "a health ping counted as the release" [ "$(polls "$APP/up")" = 0 ]
}

t_the_health_path_must_answer_too() {
  host
  answers "$APP/version" "$(version "$NEW")"
  answers "$APP/up" "503 down" "503 down" "200 ok"
  verify
  expect_rc 0
  expect_out "seconds=40"
  expect_err_has "app: the release, but /up answered HTTP 503"
  host
  answers "$APP/version" "$(version "$NEW")"
  answers "$APP/healthz" "200 ok"
  verify DEPLOY_HEALTH_PATH=/healthz
  expect_rc 0; expect_out "seconds=20"
  host
  answers "$APP/version" "$(version "$NEW")"
  verify DEPLOY_HEALTH_PATH=
  expect_rc 0; expect_out "seconds=20"
  expect_true "an empty health path was asked" [ "$(polls /up)" = 0 ]
}

t_a_separate_spa_must_report_the_commit_too() {
  host
  answers "$APP/version" "$(version "$NEW")"
  answers "$APP/up" "200 ok"
  answers "$WEB/version.json" "404 missing" "$(version "$OLD" v1.2.2)" "$(version "$OLD" v1.2.2)" "$(version "$NEW")"
  verify DEPLOY_FRONTEND_ORIGIN="$WEB"
  expect_rc 0
  expect_out "seconds=50"
  expect_err_has "frontend: HTTP 404"
  expect_err_has "frontend: commit $OLD (v1.2.2)"
  expect_true "the SPA's version.json had no fresh query" grep -qE "$WEB/version.json\?mroom=[0-9]+-[0-9]+" "$T/curl.log"
  expect_true "the summary does not name both" grep -qF "is live on app frontend" "$T/summary"
  # The app's own path stays app.version_path.
  printf '[app]\nname = "shop"\nversion_path = "/api/release"\n' >"$MROOM_CONFIG"
  answers "$APP/api/release" "$(version "$NEW")"
  answers "$WEB/version.json" "$(version "$NEW")"
  verify DEPLOY_FRONTEND_ORIGIN="$WEB"
  expect_rc 0; expect_out "seconds=20"
}

t_errors_and_odd_answers_are_not_yet() {
  host
  answers "$APP/version" "502 <html>bad gateway</html>" "200 not json" "301 " \
    "200 {\"release\": \"v1.2.3\", \"commit\": \"${NEW:0:12}\"}" "$(version "$NEW")"
  answers "$APP/up" "200 ok"
  verify
  expect_rc 0
  expect_out "seconds=60"
  expect_err_has "app: HTTP 502"
  expect_err_has "app: an answer that is not"
  expect_err_has "app: HTTP 301"
  # Nothing answering at all.
  host
  verify DEPLOY_TIMEOUT=20s
  expect_rc 1
  expect_err_has "app last answered: HTTP 000"
}

t_a_release_named_otherwise_is_a_warning() {
  host
  answers "$APP/version" "$(version "$NEW" release-v1.2.3)"
  answers "$APP/up" "200 ok"
  verify
  expect_rc 0
  expect_err_has "::warning::app runs v1.2.3's commit but names it release-v1.2.3"
  expect_true "the warning came more than once" [ "$(grep -c '::warning::' "$T/.err")" = 1 ]
  host
  answers "$APP/version" "$(version "$NEW" null)"
  answers "$APP/up" "200 ok"
  verify
  expect_rc 0
  expect_err_has "names no release"
}

t_bad_inputs_fail_before_any_poll() {
  host
  local bad
  for bad in DEPLOY_COMMIT=abc123 DEPLOY_COMMIT="${NEW:0:39}A" DEPLOY_ORIGIN="$APP/" DEPLOY_ORIGIN=api.shop.example.dev \
    DEPLOY_FRONTEND_ORIGIN="$WEB/app" DEPLOY_TIMEOUT=soon DEPLOY_INTERVAL=0 DEPLOY_HEALTH_PATH=up \
    DEPLOY_HEALTH_PATH=/../up "DEPLOY_TAG=v1 2"; do
    verify "$bad"
    expect_rc 2
  done
  expect_no_file "$T/curl.log"
}

# --- the release and deploy-verify together, as the Works of phase 4 asks ---

t_a_deploy_waits_until_the_host_runs_the_tag() {
  repo
  host
  deploy v1.0.0
  deploy v1.1.0 EVENT=release RELEASE_TAG=v1.1.0
  expect_rc 0
  local commit previous tag
  commit="$(sed -n 's/^commit=//p' <<<"$out")" previous="$(sed -n 's/^previous=//p' <<<"$out")" tag="$(sed -n 's/^tag=//p' <<<"$out")"
  expect_true "the release job did not report the tag's commit" [ "$commit" = "$C2" ]
  # The host still runs the previous release for three polls, then the branch it deploys.
  answers "$APP/version" "$(version "$previous" v1.0.0)" "$(version "$previous" v1.0.0)" "$(version "$previous" v1.0.0)" \
    "$(version "$(live)" v1.1.0)"
  answers "$APP/up" "200 ok"
  verify DEPLOY_COMMIT="$commit" DEPLOY_TAG="$tag"
  expect_rc 0
  expect_out "seconds=50"
  expect_err_has "Live: v1.1.0 ($C2)"
  # A host whose deploy failed keeps answering with the previous release, which a health ping alone would pass.
  host
  answers "$APP/version" "$(version "$previous" v1.0.0)"
  answers "$APP/up" "200 ok"
  verify DEPLOY_COMMIT="$commit" DEPLOY_TAG="$tag" DEPLOY_TIMEOUT=2m
  expect_rc 1
  expect_err_has "app last answered: commit $C1 (v1.0.0)"
}

# --- the workflow ---

shape() { run python3 "$ROOT/tests/ci/check.py" "$1" "${2:-$ROOT}"; }
t_only_a_published_release_or_a_person_starts_it() { shape deploy-triggers; expect_rc 0; }
t_only_the_production_job_holds_a_secret_and_runs_nothing_else() { shape deploy-secrets; expect_rc 0; }
t_one_deploy_at_a_time_moves_the_branch_then_the_hook() { shape deploy-release; expect_rc 0; }
t_verify_waits_for_the_pushed_commit_without_a_secret() { shape deploy-verify; expect_rc 0; }
t_placeholders_are_documented() { shape placeholders; expect_rc 0; }

# planted <check> <python edit of the template's text, as t> <what it should say>: the check catches the change.
planted() {
  rm -rf "$T/root"
  mkdir -p "$T/root/templates" "$T/root/actions"
  cp -R "$TPL" "$T/root/templates/github"
  cp "$ROOT/README.md" "$T/root/README.md"
  python3 -c 'import sys; p = sys.argv[1]; t = open(p).read(); exec(sys.argv[2]); open(p, "w").write(t)' \
    "$T/root/templates/github/workflows/deploy-production.yml" "$2"
  shape "$1" "$T/root"
  expect_rc 1
  expect_out_has "$3"
}

t_the_shape_checks_catch_planted_bugs() {
  planted deploy-triggers 't = t.replace("  workflow_dispatch:\n", "  workflow_dispatch:\n    inputs:\n      tag: {type: string}\n  push:\n", 1)' \
    "not only a published release"
  planted deploy-triggers 't = t.replace("  workflow_dispatch:\n", "  workflow_dispatch:\n    inputs:\n      tag: {type: string}\n", 1)' \
    "dispatch takes inputs"
  planted deploy-secrets 't = t.replace("          tag: ${{ needs.release.outputs.tag }}", "          tag: ${{ secrets.X }}")' \
    "deploy:verify reads a secret outside the production environment"
  planted deploy-secrets 't = t.replace("      - name: Point the release branch", "      - uses: some/action@v1\n      - name: Point the release branch")' \
    "deploy:release runs some/action beside the deploy key"
  planted deploy-secrets 't = t.replace("curl -sS --fail --max-time 30 -X POST -o /dev/null \"$DEPLOY_HOOK\"", "curl ${{ secrets.MROOM_DEPLOY_HOOK }}")' \
    "a secret is written into a script"
  planted deploy-secrets 't = t.replace("permissions:\n  contents: read", "permissions:\n  contents: write")' \
    "write permission"
  planted deploy-secrets 't = t.replace("          fetch-depth: 0\n", "")' "has no history"
  planted deploy-release 't = t.replace("cancel-in-progress: false", "cancel-in-progress: true")' "never cancels"
  planted deploy-release 't = t.replace("DEFAULT_BRANCH: <<default_branch>>", "DEFAULT_BRANCH: ${{ github.ref_name }}")' \
    "DEFAULT_BRANCH"
  planted deploy-verify 't = t.replace("          commit: ${{ needs.release.outputs.commit }}", "          commit: ${{ github.sha }}")' \
    "does not wait for the commit the release job pushed"
  planted deploy-verify 't = t.replace("    needs: release\n", "    needs: release\n    environment: production\n")' \
    "names an environment"
  planted placeholders 't = t.replace("<<fill:tag_pattern>>", "<<fill:tag_regex>>")' "<<fill:tag_regex>> is used"
}

# Only the production deploy is left out of the CI checks: another deploy-* workflow holding a secret is caught.
t_another_deploy_workflow_meets_the_ci_checks() {
  rm -rf "$T/root"
  mkdir -p "$T/root/templates"
  cp -R "$TPL" "$T/root/templates/github"
  cp "$TPL/workflows/deploy-production.yml" "$T/root/templates/github/workflows/deploy-staging.yml"
  shape no-secrets "$T/root"
  expect_rc 1
  expect_out_has "workflows/deploy-staging.yml contains 'secrets.'"
  rm "$T/root/templates/github/workflows/deploy-staging.yml"
  shape no-secrets "$T/root"
  expect_rc 0
}

t_the_template_renders_from_both_examples() {
  local example version
  version="v$(tr -d '[:space:]' <"$ROOT/VERSION")"
  for example in single-app two-folder; do
    run python3 "$ROOT/tests/ci/render.py" "$TPL/workflows/deploy-production.yml" "$ROOT/examples/$example/mroom.toml" \
      backend_origin=https://shop.example.dev frontend_origin= tag_pattern='^v[0-9]+\.[0-9]+\.[0-9]+$'
    expect_rc 0
    printf '%s\n' "$out" >"$T/$example.yml"
    run python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$T/$example.yml"
    expect_rc 0
    expect_true "deploy-verify is not pinned to this release" \
      grep -qx "        uses: milroyfraser/mroom/actions/deploy-verify@$version" "$T/$example.yml"
    expect_true "the default branch is not main" grep -qx "          DEFAULT_BRANCH: main" "$T/$example.yml"
    expect_true "the tag pattern did not survive YAML" python3 -c '
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
env = doc["jobs"]["release"]["steps"][1]["env"]
assert env["TAG_PATTERN"] == "^v[0-9]+\\.[0-9]+\\.[0-9]+$", env["TAG_PATTERN"]' "$T/$example.yml"
  done
  run python3 "$ROOT/tests/ci/render.py" "$TPL/workflows/deploy-production.yml" "$ROOT/examples/two-folder/mroom.toml"
  expect_rc 1
  expect_err_has "<<fill:backend_origin>>"
}

skip_unless has_git "git 2.28 or later is needed for the release branch tests"
test_case first t_a_first_release_creates_the_branch_at_the_tag
test_case forward t_a_newer_tag_moves_it_forward_and_a_rerun_leaves_it
test_case rollback t_an_older_tag_rolls_it_back
test_case off-main t_a_tag_off_the_default_branch_is_refused
test_case refused t_only_a_release_tag_of_the_run_deploys
test_case moved t_a_branch_someone_else_moved_is_left_for_a_person
test_case shadow t_a_tag_named_like_the_branch_is_left_for_a_person
test_case host-fetch t_the_hosts_fetch_takes_the_branch_and_its_tag
test_case branch t_another_branch_name_can_be_used
skip_unless has_yaml "python3 has no yaml module (PyYAML)"
test_case triggers t_only_a_published_release_or_a_person_starts_it
test_case secrets t_only_the_production_job_holds_a_secret_and_runs_nothing_else
test_case release-step t_one_deploy_at_a_time_moves_the_branch_then_the_hook
test_case verify-job t_verify_waits_for_the_pushed_commit_without_a_secret
test_case placeholders t_placeholders_are_documented
test_case planted t_the_shape_checks_catch_planted_bugs
test_case other-deploy t_another_deploy_workflow_meets_the_ci_checks
# deploy-verify reads app.version_path through the one reader, which needs python3 3.11+, and uses bash 4's arrays.
skip_unless has_bash4 "this host lacks bash 4 or python3 3.11 (tomllib), which deploy-verify needs"
test_case render t_the_template_renders_from_both_examples
test_case waits t_it_waits_until_the_live_commit_matches_three_times
test_case streak t_an_old_answer_in_between_starts_the_count_again
test_case timeout t_a_failed_deploy_fails_after_the_time_limit
test_case health t_the_health_path_must_answer_too
test_case spa t_a_separate_spa_must_report_the_commit_too
test_case odd t_errors_and_odd_answers_are_not_yet
test_case release-name t_a_release_named_otherwise_is_a_warning
test_case inputs t_bad_inputs_fail_before_any_poll
test_case works t_a_deploy_waits_until_the_host_runs_the_tag
finish
