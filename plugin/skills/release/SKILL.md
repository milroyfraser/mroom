---
name: release
description: Prepare a release from the default branch for a person to publish, on their say-so. Finds the version, lists what ships, flags risky changes and release steps, drafts the notes, asks once, creates a draft release (gh release create --draft, which always prompts), waits for the person to publish it on GitHub, then watches the deploy and checks the version and the error tracker, read-only. Use for /mroom:release.
disable-model-invocation: true
---

# /mroom:release: the default branch to production, on a person's say-so

A release ships everything merged since the last one to customers. Publishing it starts the
production deploy, and nothing stops the deploy after that. So this skill only **drafts** the
release. A person checks the draft and publishes it on GitHub.

## Rules

- Never merge, approve, deploy or release on your own. A person does each of these.
- Tracker writes: only the state of the issue being worked, and comments on it. This skill
  writes nothing to the tracker.
- Ask the person before you create an issue or a label.
- Never touch production. Never read secrets, tokens or credential files.
- Run only in a session the person is watching, and only when they ask. Never from a routine, a
  background agent, or a session that bypasses permissions; never on your own initiative.
- Ask once with `AskUserQuestion` before the draft. `gh release create` and `gh release edit`
  always prompt the person too (an `ask` rule in mroom's settings). If either is declined, stop:
  that is the answer.
- Always create the release with `--draft`. Never publish, delete or edit a published release,
  push a tag, or run a deploy workflow. Production checks are read-only: the app's public version
  path and the error tracker.

## 1. What would ship

1. The default branch: `gh repo view --json defaultBranchRef --jq .defaultBranchRef.name`. Then
   `git fetch --tags origin <default>`.
2. **The last release:** what production runs. With `release.production_url` set,
   `curl -s <production_url><version_path>` reports its `release` (`app.version_path`, `/version`
   by default). Otherwise, or when that fails, the newest published release:
   `gh release list --exclude-drafts --limit 1 --json tagName --jq '.[0].tagName'`. A draft is not a
   release. Drop `release.tag_prefix` from the tag to get its version.
3. **The version.** If the repository tags the default branch on every merge (`vX.Y.Z`), take the
   newest: `git describe --tags --abbrev=0 --match 'v[0-9]*' origin/<default>`. If it does not
   point at `origin/<default>`, the newest merge has no tag yet: wait for it, or stop and say so.
   Otherwise work it out from the Conventional Commits since the last
   release: a breaking change (`!` or `BREAKING CHANGE`) bumps the major, a `feat` the minor, any
   other change the patch. If it is not newer than the last release, stop: there is nothing to
   release.
4. **The tag:** `release.tag_prefix` (empty by default) and then the version, such as `v1.4.0` or
   `release-v1.4.0`. It goes on the version's commit.
5. **CI:** the checks on the version's commit must be green:
   `gh api repos/{owner}/{repo}/commits/<sha>/check-runs --jq '.check_runs[] | [.name, .conclusion] | @tsv'`.
   If one failed or is still running, stop and say which. A check in `pr.required_checks` that runs
   only on pull requests (a title check, say) is not on this commit; the default branch's ruleset
   already required it on each merged PR.
6. **What ships:** `git log --format='%h %s' <last release tag>..<sha>`, one line per merged PR.

## 2. Flag what needs the person's eye

For every PR in the range, check these, and list each hit with its PR number:

- **Billing:** payments, subscriptions, seats, invoices or plans, by path or by title.
- **Migrations:** files under the app's `database/migrations/` (`app.backend_dir`). Expand and
  contract: a contract step must not ship with code that still uses the old shape.
- **Steps before or after the deploy:** PR bodies that say "before release", "rollout", "deploy
  note" or "one-time setup". New env vars (the diff of `.env.example`), new queues, new scheduled
  commands (`routes/console.php`), new webhook events, and settings an outside provider needs
  first.
- **Fixes under another title:** a `chore`, `docs` or `refactor` PR whose body or commits fix
  what a user sees. Release notes will not list it as a fix, so add it by hand.

## 3. Ask once

Show the person the version, the tag, the list, the flags and the draft notes (GitHub's generated
notes, plus an "Also fixed" section for step 2's hidden fixes). Ask with `AskUserQuestion`:
**release now** / **not now**. On "not now", stop.

## 4. Draft it; the person publishes

```
gh release create <tag> --draft --target <sha> --title "<version>" \
  --generate-notes --notes-start-tag <last release tag> --notes-file <extra notes>
```

If a draft for this tag already exists (`gh release view <tag> --json isDraft`), create no second
one. Use that draft, and update its notes with `gh release edit <tag> --notes-file <file>` if they
changed. Never drop `--draft` from these commands.

The command prompts the person. A draft creates no tag and starts nothing. Give the person its
link (`gh release view <tag> --json url --jq .url`) and the version's commit. Ask them to check
that the draft's **Target** is that commit, then click **Publish release** on GitHub. Anyone with
Write can change a draft's target, so the person checks it, not this session.

When they say it is published, confirm with `gh release view <tag> --json isDraft,publishedAt`.
Still a draft means it was not published: ask again, or stop.

## 5. Watch the deploy (read-only)

1. Find the runs the release started: `gh run list --event release --limit 5`.
2. `gh run watch <id>` for each. If one fails, report the failing step from
   `gh run view <id> --log-failed`, and stop. A rollback is the person's decision.
3. **The version:** `curl -s <production_url><version_path>` must report the release's tag and its
   commit. Without `release.production_url`, say that the check was skipped.
4. **The error tracker:** issues first seen since the deploy started, for example
   `mroom errors search 'is:unresolved firstSeen:-2h' --environment production --period 24h`, with
   the window set from the deploy run's start, and the error tracker's name for production (often
   `production`). List any, with their counts. When `mroom errors` exits 3, there is no error
   tracker: say so.
5. For each production step flagged in step 2, **remind** the person. Never run it.

## 6. Report

One block: the release and its link, what shipped (PR numbers), the deploy runs and their result,
the version check, new error issues, and any flagged production steps still to do.
