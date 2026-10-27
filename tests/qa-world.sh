#!/usr/bin/env bash
# The world the QA action tests share (tests/qa-*-test.sh): sourced after tests/lib.sh, never run on its own.
# Fakes for Forge (tests/fakes/forge.py, as curl), GitHub (tests/fakes/gh) and the box's gate (tests/fakes/ssh)
# come first on PATH, sleep only records how long it was asked for, and the environment is what a runner gives
# the actions. Nothing leaves $T.
# shellcheck disable=SC2034  # variables here are read by the test files that source this one

QA_KEY=$'-----BEGIN OPENSSH PRIVATE KEY-----\nnot-a-real-key\n-----END OPENSSH PRIVATE KEY-----'
NOW=1793102400 # 2026-10-27 12:00 UTC

# qa_world: the fakes, an app named shop with the zone qa.example.dev, and an empty Forge. Called again in a test, it
# starts that world afresh.
qa_world() {
  rm -rf "$T/gate" "$T/gh" "$T/forge.log" "$T/order.log" "$T/github-output" "$T"/up-codes*
  mkdir -p "$T/bin" "$T/gate" "$T/gh" "$T/tmp"
  # shellcheck disable=SC2016  # the fakes' own $1, $@ and $T
  printf '#!/bin/sh\nexec python3 -I "%s" "$@"\n' "$ROOT/tests/fakes/forge.py" >"$T/bin/curl"
  # shellcheck disable=SC2016
  printf '#!/bin/sh\necho "$1" >>"$T/sleep.log"\n' >"$T/bin/sleep"
  chmod +x "$T/bin/curl" "$T/bin/sleep"
  ln -sfn "$ROOT/tests/fakes/gh" "$T/bin/gh"
  ln -sfn "$ROOT/tests/fakes/ssh" "$T/bin/ssh"
  echo '{"sites": [], "processes": []}' >"$T/forge.json"
  printf '[app]\nname = "shop"\n\n[qa]\nzone = "qa.example.dev"\n' >"$T/mroom.toml"
  echo '[]' >"$T/gh/prs.json"
  export T PATH="$T/bin:$PATH" TMPDIR="$T/tmp" MROOM_NOW="$NOW"
  export FORGE_STATE="$T/forge.json" FORGE_LOG="$T/forge.log" ORDER_LOG="$T/order.log" GATE="$T/gate"
  export GATE_KEY="$QA_KEY" GH_FAKE="$T/gh"
  export MROOM_CONFIG="$T/mroom.toml" MROOM_FORGE_ORG=acme MROOM_FORGE_SERVER=42 MROOM_FORGE_TOKEN=fake-forge-token
  export MROOM_QA_SSH_HOST=box.example.dev MROOM_QA_SSH_KEY="$QA_KEY"
  export MROOM_QA_SSH_KNOWN_HOSTS="box.example.dev ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAInotarealkey"
  export GITHUB_REPOSITORY=example/shop GH_TOKEN=fake-gh-token GITHUB_OUTPUT="$T/github-output"
  # A runner's own: with them, the actions mask secrets and keep scratch files outside $T.
  unset GITHUB_ACTIONS RUNNER_TEMP
}

# api_host <N> [<zone>], web_host <N> [<zone>], site_user <N>: the test side's one copy of how qa_names
# (lib/core/qa.sh) names environment N's sites and their user, for the app shop in the zone qa.example.dev. Tests
# build every such name with these, so a new naming scheme is an edit here and in the tests that pin it.
api_host() { echo "api-$1.${2:-qa.example.dev}"; }
web_host() { echo "go-$1.${2:-qa.example.dev}"; }
site_user() { echo "shop_qa_$1"; }

# ago <seconds>: the time that long before NOW, as Forge writes it.
ago() { date -u -d "@$((NOW - $1))" +%Y-%m-%dT%H:%M:%SZ; }

# forge_set <jq program>: changes the fake Forge's state.
forge_set() { jq "$1" "$FORGE_STATE" >"$FORGE_STATE.new" && mv "$FORGE_STATE.new" "$FORGE_STATE"; }

# site <id> <name> <status> [<created_at> [<updated_at>]]: a site on the fake Forge.
site() {
  local item
  item="$(jq -nc --argjson id "$1" --arg name "$2" --arg status "$3" --arg c "${4:-$(ago 86400)}" --arg u "${5:-}" \
    '{id: $id, name: $name, status: $status, isolated: true, created_at: $c} + (if $u == "" then {} else {updated_at: $u} end)')"
  forge_set ".sites += [$item]"
}

# made_site <id> <N> <api|web> <web root> [<PHP version>]: a site Forge made for environment N earlier, as Forge lists
# one: isolated in the home of the environment's user, its web root absolute, and with a PHP version a PHP site.
made_site() {
  local name user item
  user="$(site_user "$2")"
  if [ "$3" = api ]; then name="$(api_host "$2")"; else name="$(web_host "$2")"; fi
  item="$(jq -nc --argjson id "$1" --arg name "$name" --arg user "$user" --arg web "/home/$user/$name${4%/}" \
    --arg php "${5:-}" '{id: $id, name: $name, status: "installed", user: $user, isolated: true,
      created_at: "2026-10-26T12:00:00Z", root_directory: "/home/\($user)/\($name)", web_directory: $web,
      php_version: (if $php == "" then null else "PHP \($php)" end)}')"
  forge_set ".sites += [$item]"
}

# pr_now <N> <state> <head> [<draft> [<labels as JSON>]]: the pull request as GitHub has it now (gh pr view).
pr_now() {
  jq -n --argjson n "$1" --arg state "$2" --arg sha "$3" --argjson draft "${4:-false}" --argjson labels "${5:-[]}" \
    '{number: $n, state: $state, headRefOid: $sha, isDraft: $draft, isCrossRepository: false,
      labels: ($labels | map({name: .}))}' >"$GH_FAKE/pr-$1.json"
}

# pr_toml <commit> [<toml>]: the pull request's mroom.toml at that commit, as GitHub gives it; the default branch's
# when no other is given.
pr_toml() {
  mkdir -p "$GH_FAKE/contents-$1"
  if [ "$#" -ge 2 ]; then printf '%s\n' "$2" >"$GH_FAKE/contents-$1/mroom.toml"; else cp "$MROOM_CONFIG" "$GH_FAKE/contents-$1/mroom.toml"; fi
}

# process <id> <user> <directory> [<status>]: a background process on the fake Forge.
process() {
  local item
  item="$(jq -nc --argjson id "$1" --arg user "$2" --arg dir "$3" --arg status "${4:-running}" \
    '{id: $id, user: $user, directory: $dir, status: $status, command: "php artisan queue:work", processes: 1}')"
  forge_set ".processes += [$item]"
}

# comment <PR> <id> <login> <body> [<updated_at>]: a comment on the pull request, for the fake GitHub.
comment() {
  local file="$GH_FAKE/comments-$1.json"
  [ -f "$file" ] || echo '[]' >"$file"
  jq --argjson id "$2" --arg login "$3" --arg body "$4" --arg at "${5:-2026-10-26T09:00:00Z}" \
    '. + [{id: $id, user: {login: $login}, body: $body, updated_at: $at}]' "$file" >"$file.new" && mv "$file.new" "$file"
}
# qa_body <state> [<field>...]: the body of a QA environment comment in that state, with fields such as since=<time>.
qa_body() {
  local marker="$1"
  shift
  [ "$#" = 0 ] || marker+=" $*"
  printf '### QA environment\n<!-- mroom-qa: %s -->\n\nSomething.\n' "$marker"
}

# Logs and what the fakes saw.
gate_log() { cat "$GATE/gate.log" 2>/dev/null || true; }
forge_writes() { grep -v '^GET ' "$FORGE_LOG" 2>/dev/null || true; }
gh_log() { cat "$GH_FAKE/gh.log" 2>/dev/null || true; }
order() { grep -v '^forge GET' "$ORDER_LOG" 2>/dev/null || true; }
output_of() { sed -n "s/^$1=//p" "$GITHUB_OUTPUT" 2>/dev/null || true; }
tmp_empty() { [ -z "$(find "$T/tmp" -mindepth 1 -print -quit)" ]; }
lacks() { case "$1" in *"$2"*) return 1 ;; esac; }
