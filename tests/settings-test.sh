#!/usr/bin/env bash
# shellcheck disable=SC2088  # ~ in a Read rule is text, never expanded here
# Tests the settings fragments in settings/: each is valid and well formed, and together, merged the way
# `mroom init` will merge them (every list joined; deny beats ask, ask beats allow, as in Claude Code), they
# keep the intent of the rules they came from: agents never merge, approve, release, force-push or read
# secrets, and pushes, releases and database resets ask a person first.
#
#   tests/settings-test.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dir="$ROOT/settings"
fragments="base laravel-vite forge tracker-linear"
failures=0
count=0

fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }
check() { # check <what it means> <command...>
  local what=$1
  shift
  count=$((count + 1))
  "$@" || fail "$what"
}

# --- Each fragment -------------------------------------------------------------------------------
for name in $fragments; do
  f="$dir/$name.json"
  check "$name.json exists" test -f "$f"
  check "$name.json is JSON" jq -e . "$f" >/dev/null
  # Only permissions, only allow, ask and deny, each a non-empty list of strings.
  check "$name.json has only permissions.allow/ask/deny, each a list of strings" \
    jq -e '(keys == ["permissions"])
      and (.permissions | keys - ["allow", "ask", "deny"] == [])
      and ([.permissions[] | type == "array" and length > 0 and all(type == "string")] | all)' "$f" >/dev/null
  # Every rule is Tool(specifier), for the tools these fragments use.
  bad=$(jq -r '.permissions[][] | select(test("^(Bash|Read)\\(.+\\)$") | not)' "$f")
  check "$name.json rules are Bash(...) or Read(...): $bad" test -z "$bad"
  dup=$(jq -r '[.permissions[][]] | group_by(.) | map(select(length > 1) | .[0]) | .[]' "$f")
  check "$name.json repeats no rule: $dup" test -z "$dup"
  # No app's repository: GitHub paths use gh's {owner}/{repo}.
  lit=$(jq -r '.permissions[][] | select(test("repos/") and (test("repos/\\{owner\\}/\\{repo\\}/") | not))' "$f")
  check "$name.json names no repository: $lit" test -z "$lit"
done
listed=$(for f in "$dir"/*.json; do basename "$f" .json; done | sort | tr '\n' ' ')
check "settings/ holds exactly the four fragments (has: $listed)" test "$listed" = "base forge laravel-vite tracker-linear "

# --- Merged --------------------------------------------------------------------------------------
merged=$(cd "$dir" && jq -s '{permissions: {
    allow: [.[].permissions.allow // [] | .[]],
    ask: [.[].permissions.ask // [] | .[]],
    deny: [.[].permissions.deny // [] | .[]]}}' base.json laravel-vite.json forge.json tracker-linear.json)
dup=$(printf '%s' "$merged" | jq -r '[.permissions[][]] | group_by(.) | map(select(length > 1) | .[0]) | .[]')
check "no rule is in two fragments or two lists: $dup" test -z "$dup"

rules() { printf '%s' "$merged" | jq -r --arg l "$1" --arg t "$2" \
  '.permissions[$l][] | select(startswith($t + "(")) | .[($t | length) + 1:-1]'; }
allow_bash=$(rules allow Bash)
ask_bash=$(rules ask Bash)
deny_bash=$(rules deny Bash)
deny_read=$(rules deny Read)

# matches <rules> <command>: an approximation of Claude Code's Bash matcher: `X:*` is the prefix X followed
# by nothing or a space, anything else is a glob over the whole command.
matches() {
  local rule prefix
  while IFS= read -r rule; do
    [ -n "$rule" ] || continue
    if [[ $rule == *:\* ]]; then
      prefix=${rule%:\*}
      [[ $2 == "$prefix" || $2 == "$prefix "* ]] && return 0
    else
      # shellcheck disable=SC2053 # the rule is a glob on purpose
      [[ $2 == $rule ]] && return 0
    fi
  done <<<"$1"
  return 1
}

decide() {
  if matches "$deny_bash" "$1"; then echo deny
  elif matches "$ask_bash" "$1"; then echo ask
  elif matches "$allow_bash" "$1"; then echo allow
  else echo none; fi
}

want() { # want <deny|ask|allow|none> <command>
  local got
  count=$((count + 1))
  got=$(decide "$2")
  [ "$got" = "$1" ] || fail "(want $1, got $got): $2"
}

# Read(...) paths: `**` is any folders, `*` any name; ~ is the home folder, ./ the project.
read_denied() {
  local rule pattern
  while IFS= read -r rule; do
    pattern=${rule//\*\*/__ANY__}
    pattern=${pattern//\*/__ONE__}
    pattern=${pattern//__ANY__/*}
    pattern=${pattern//__ONE__/*}
    pattern=${pattern#./}
    # shellcheck disable=SC2053 # a glob on purpose
    [[ $1 == $pattern || ( $pattern == '*/'* && $1 == ${pattern#\*/} ) ]] && return 0
  done <<<"$deny_read"
  return 1
}
read_want() { # read_want <deny|none> <path>
  local got=none
  count=$((count + 1))
  read_denied "$2" && got=deny
  [ "$got" = "$1" ] || fail "(Read: want $1, got $got): $2"
}

# Never: merging, approving, releasing or deploying.
want deny 'gh pr merge 12 --squash'
want deny 'gh pr review 12 --approve'
want deny 'gh api -X PUT repos/o/r/pulls/12/merge'
want deny 'gh api repos/o/r/pulls/12/merge -X PUT'
want deny 'gh api repos/o/r/pulls/12/reviews -f event=APPROVE'
want deny "gh api graphql -f query='mutation { mergePullRequest(input: {}) { clientMutationId } }'"
want deny "gh api graphql -f query='mutation { enablePullRequestAutoMerge(input: {}) { clientMutationId } }'"
want deny "gh api graphql -f query='mutation { enqueuePullRequest(input: {}) { clientMutationId } }'"
want deny "gh api graphql -f query='mutation { approveDeployments(input: {}) { clientMutationId } }'"
want deny 'gh api -X POST repos/o/r/releases -f tag_name=v1.2.3'
want deny 'gh api --method PATCH repos/o/r/releases/1 -F draft=false'
want deny 'gh api -X DELETE repos/o/r/releases/1'
want deny 'gh api -X POST repos/o/r/actions/runs/1/pending_deployments -f state=approved'
want deny 'gh release delete v1.2.3 --yes'
want deny 'gh workflow run deploy-production.yml'
want deny 'gh workflow run --ref main deploy-production'
want deny 'gh secret set X'
want deny 'gh repo delete o/r --yes'
want deny 'gh auth token'

# Never: force-pushing, pushing tags or the default branch, or skipping hooks.
want deny 'git push --force origin feat/x'
want deny 'git push -f origin feat/x'
want deny 'git push origin feat/x -f'
want deny 'git push --force-with-lease origin feat/x'
want deny 'git push --mirror origin'
want deny 'git push --tags origin'
want deny 'git push --follow-tags origin feat/x'
want deny 'git push origin +feat/x'
want deny 'git push origin HEAD:main'
want deny 'git push origin HEAD:release'
want deny 'git push origin HEAD:master'
want deny 'gh workflow run deploy.yml'
want deny 'gh workflow run "Deploy production"'
want deny 'gh api repos/o/r/pulls/1/reviews -f event=approve'
want deny 'gh auth git-credential get'
want deny 'gh api -X PATCH repos/o/r/git/refs/heads/x -F force=true'
want deny 'gh api repos/o/r/git/refs -f ref=refs/tags/v1 -f sha=abc'
want deny 'gh pr update-branch 12 --rebase'
want deny 'gh repo sync o/fork --force'
want deny 'git commit --no-verify -m x'
want deny 'git reset --hard origin/main'
want deny 'git branch -D feat/x'

# Never: reading secrets, or deleting in bulk.
want deny 'cat .env'
want deny 'cat backend/.env'
want deny 'cat ~/.ssh/id_ed25519'
want deny 'cat ~/.forge-token'
want deny 'cat ~/.config/mroom/secrets/forge-token'
want deny 'forge deploy'
want deny 'rm -rf build'
want deny 'find . -name "*.log" -delete'
read_want deny .env
read_want deny backend/.env
read_want deny backend/.env.testing
read_want deny .env.local
read_want deny frontend/.env.production
read_want deny '~/.ssh/id_ed25519'
read_want deny '~/.config/gh/hosts.yml'
read_want deny '~/.config/gh-dev/hosts.yml'
read_want deny '~/.aws/credentials'
read_want deny '~/.config/mroom/secrets/slack.env'
read_want deny '~/.claude/.credentials.json'
read_want deny '~/.claude-work/.credentials.json'
read_want deny '~/.forge-token'
read_want deny '~/.laravel-forge/config.json'
read_want deny '~/.config/forge/token'
read_want deny backend/.env.staging
read_want deny '~/.git-credentials'
read_want deny '~/.netrc'
read_want deny '~/.config/composer/auth.json'
read_want deny '~/.docker/config.json'
read_want none .env.example
read_want none backend/app/Models/User.php

# The tracker holds the issues: no GitHub issue writes (tracker-linear.json).
want deny 'gh issue create --title x'
want deny 'gh issue comment 1 --body x'
want deny 'gh issue edit 1 --add-label x'
want deny 'gh issue close 1'
want deny 'gh issue delete 1'
want allow 'gh issue view 1'

# A person says yes first.
want ask 'git push -u origin feat/x'
want ask 'git push origin HEAD'
want ask 'gh release create v1.2.3 --generate-notes'
want ask 'gh release edit v1.2.3 --draft=false'
want ask 'gh workflow run ci.yml'
want ask 'gh release create v1.2.3 --draft --target abc123 --generate-notes'
want ask 'mroom tracker create --allow-create --title x'
want ask 'mroom errors resolve SHOP-1A2'
want ask 'mroom persona create --key sentry:1001 --title x'
want ask 'mroom persona comment SHOP-12'
want allow 'mroom tracker owned SHOP-12'
want allow 'mroom errors new 40'
want allow 'mroom persona find sentry:1001'
want ask 'forge-api --secret GET sites/1/environment'
want allow 'mroom tracker get SHOP-12'
want allow 'mroom tracker list --mine --open'
want allow 'mroom tracker find sentry:1001'
want allow 'mroom errors search is:unresolved'
want none 'mroom tracker comment SHOP-12'
want none 'mroom tracker state SHOP-12 Done'
want ask 'git restore src/x.ts'
want ask 'php artisan migrate'
want ask 'php artisan db:wipe'
want ask 'php artisan db:seed'
want ask 'php artisan tinker'
want ask 'php artisan config:show database'

# Everyday work runs without a prompt.
want allow 'git status'
want allow 'git diff origin/main'
want allow 'git log --oneline -5'
want allow 'git switch -c feat/x'
want allow 'git add lib/guard'
want allow 'gh pr view 12 --json state'
want allow 'gh pr create --draft --title "feat: x" --body-file /tmp/b.md'
want allow 'gh pr checks 12 --watch'
want allow 'gh pr update-branch 12'
want none 'gh pr review 12 --comment -b ok'
want none 'gh pr review 12 -b ok'
# Ask beats allow, so a workflow run always asks, qa-plan's too.
want ask 'gh workflow run qa-plan.yml -f pr_number=12'
want allow 'gh api repos/{owner}/{repo}/pulls/12/comments'
want allow 'gh release view v1.2.3'
want allow 'gh auth status'
want allow 'php artisan test --compact --parallel'
want allow 'composer install'
want allow 'vendor/bin/pint --dirty'
want allow 'pnpm test'
want allow 'npm run build'
want allow 'forge-api GET /servers'
want none 'forge-api POST /servers/1/sites'
want allow 'mroom status'
want allow 'mroom config get app.name'
want allow 'mroom guard check "git status"'
want none 'mroom guard hook'
want none 'mroom init'

echo "$count cases, $failures failed"
[ "$failures" = 0 ]
