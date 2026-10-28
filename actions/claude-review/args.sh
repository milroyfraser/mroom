#!/usr/bin/env bash
# args.sh — prints the Claude review's claude_args (actions/claude-review): the tool allowlist and what it
# denies. The allowlist is the source's: reading files, reading issues and pull requests, and commenting, but
# only on this pull request, so an injected prompt cannot post a review on another one. The deny rules keep
# the reading tools out of what holds a token: the checkout's .git (the action writes its token into the
# remote's URL), the runner's temp folder and Claude's own settings, and /proc and /sys (the process
# environment). gh pr comment may not read its body from a file. The runner sandbox (design 8.5, phase 2b)
# is the real box; these are the narrowest rules until then.
#
# Env: PR, GITHUB_WORKSPACE, RUNNER_TEMP, all checked.
set -euo pipefail

fail() { echo "::error title=Claude review::$1" >&2; exit 1; }
[[ "${PR:-}" =~ ^[0-9]+$ ]] || fail "PR must be a pull request number."
for var in GITHUB_WORKSPACE RUNNER_TEMP; do
  [[ "${!var:-}" =~ ^/[A-Za-z0-9_./-]+$ && ! "${!var}" =~ (^|/)\.\.(/|$) ]] || fail "$var must be a plain absolute path."
done

allowed="Read,Grep,Glob,Bash(gh issue view:*),Bash(gh search:*),Bash(gh issue list:*),Bash(gh pr comment $PR:*),Bash(gh pr diff:*),Bash(gh pr view:*),Bash(gh pr list:*)"
denied="Read(/${GITHUB_WORKSPACE%/}/.git/**),Read(/${RUNNER_TEMP%/}/**),Read(~/.claude/**),Read(//proc/**),Read(//sys/**)"
denied+=",Bash(gh pr comment $PR --body-file:*),Bash(gh pr comment $PR -F:*)"
printf -- '--allowed-tools "%s" --disallowed-tools "%s"\n' "$allowed" "$denied"
