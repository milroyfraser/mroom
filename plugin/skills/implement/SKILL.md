---
name: implement
description: Take ONE tracker issue (or, with no tracker, one written task) from branch to a review-ready PR. Implement, run the affected tests, open the PR, wait for CI and QA on the PR's own environment, move the issue to review, then STOP. Never merges or deploys.
---

# /mroom:implement: one issue to review

Argument: an issue id that matches `issues.id_pattern`, such as `SHOP-123`. With no tracker, the
argument is the task in the person's words, or an open PR to carry on.

**Principles.** A `principle-…` (or `typescript-best-practices`) name in parentheses closes a
one-line summary of a skill. When that step applies, Read that skill's `SKILL.md` in full before
acting on it: the summary says when, the file says how. Skills sit next to this skill's own
folder in the mroom plugin, or in the app's `.claude/skills/`. If the skill is not installed, go
on without it.

## Rules

- Never merge, approve, deploy or release on your own. A person does each of these.
- Tracker writes: only the state of the issue being worked, and comments on it.
- Ask the person before you create an issue or a label.
- Never touch production. Never read secrets, tokens or credential files.
- Tests run only against a test database: the worktree's own, named by `tests.database_pattern`.
  Never point tests at a dev, QA or production database.
- Never add the `qa` label. It is a person's switch.

**No tracker.** Every `mroom tracker` call exits 3 when `issues.tracker` is `none`. Then skip the
tracker step and put its note on the pull request instead: in the body, or with `gh pr comment`.

## 0. Preconditions

1. `mroom tracker get <id>`: title, state, labels, branch, description and comments. Stop if its
   `state_type` is `completed` or `canceled`, or if `assigned_to_me` is false (it is not yours),
   unless the person asked you to work it.
2. **Design gate.** If the issue is a new screen or a changed flow (see `/mroom:refine`, Design), it
   needs an approved design: a `Design approved by` comment after its last `Design for review:`
   one.
   Otherwise stop and tell the person to run `/mroom:deliver <id> --design`. Never build against a
   design that is not approved.
3. Work in a worktree of your own, never in a checkout another session can switch.

## 1. Branch

**Resume first.** If the issue already has a PR (draft or ready), or a worktree with unpushed
commits on its branch, continue that work. `/mroom:deliver`, "Resume", says how to find it.

The branch is the issue's `branch` from `mroom tracker get` (the tracker links it to the issue).
With no tracker, use `<type>/<short-slug>`, such as `fix/empty-seat-override`.

1. Find the default branch: `gh repo view --json defaultBranchRef --jq .defaultBranchRef.name`.
2. `git fetch origin <default>`, then
   `git worktree add ../<repo>-<slug> -b <branch> origin/<default>` (or `git worktree add <path> <branch>`
   when the branch exists). Work only in that folder.
3. Set it up the way the app's `CLAUDE.md` says: dependencies, `.env` from the app's example file,
   and its own test database (`tests.database_pattern`).
4. Move the issue to the started state:
   `mroom tracker state <id> "$(mroom config get issues.state_started --default 'In Progress')"`.
   If the team has no state of that name, `mroom tracker` names the ones it has: stop and ask the
   person to set `issues.state_started`.

Check `git status -sb` before every commit. Never commit on the default branch.

## 2. Implement

For a Design `no` issue, first comment the decisions you made on the issue
(`mroom tracker comment <id> < decisions.md`), so a person can see them before review.

Follow the app's `CLAUDE.md` files. Migrations are expand then contract, so a rollback stays safe.
Run the app's formatters after editing (for Laravel, `vendor/bin/pint --dirty`).

- Before adding anything, look for what to remove first: dead code, redundant guards, the old
  path (`principle-subtract-before-you-add`).
- For a bug, reproduce it and fix it where the system first went wrong. A guard is a fix only when
  the state it handles is legitimate (`principle-fix-root-causes`).
- When choosing data shapes, make illegal states unrepresentable, and parse outside data at the
  edge (`principle-type-system-discipline`).
- When a change adds another branch to an if/else chain, or a second flag that must stay in step
  with the first, model the state instead: an enum, a state machine, a lookup table
  (`principle-model-the-domain`).
- Validation, error handling and adapters live at the system's edges; inner code trusts its types
  (`principle-boundary-discipline`).
- When replacing an internal API, move every caller and delete the old one in the same PR
  (`principle-migrate-callers-then-delete-legacy-apis`).
- Jobs, commands, webhooks and anything retried must reach the same end state after a partial run
  (`principle-make-operations-idempotent`).
- Editing `.ts` or `.tsx` files (`typescript-best-practices`).

## 3. Affected tests only

Tests call the code as its users do and assert what they can see: a test must fail when that
behaviour breaks, and keep passing when only the inside changes
(`principle-test-behavior-not-implementation`).

- Backend: the app's test command (`tests.command`) with a filter for the classes you touched.
- Frontend: the tests for the changed paths (for Vitest, `vitest run <paths>`).
- CI runs the whole suite. Run the affected tests yourself before pushing; a pre-push hook, if the
  app has one, may run only part of them.
- When two fixes that share one assumption have failed the same check, write the assumption down
  and test it directly before a third fix (`principle-attack-the-premise`).

## 4. Commit and push early

A Conventional Commit with the issue id as scope: `fix(SHOP-123): handle an empty seat override`.
Push with `git push -u origin <branch>`; let the pre-push hook run. Retry network failures only.

**Push after your first commit, and open a draft PR right away**, before the work is done. Sessions
get stopped, and work that lives only in a worktree is stranded, where nobody can see it.

1. After the first commit: `git push -u origin <branch>`, then `gh pr create --draft` with the
   title of step 5, and a body that links the issue: its id and its link (`issues.url`, with the
   id in place of `{id}`). With no tracker, the body holds the task instead.
2. Push after every later commit too.
3. Mark it ready (`gh pr ready <pr>`) only when the work is done (step 6).

## 5. Pull request

**Prove it safe beyond the diff first** when the change reaches past its own files: shared code,
config, migrations, a schema, package or tool config; sign-in, sessions, cookies or OAuth;
payments; an outside provider's API; queued, scheduled or retried work; or config that differs
per environment. Then Read the `blast-radius` skill in full, if it is installed, and add a
`## Safe because` section to the PR body. Its proof is a test or a script that ran, not a
paragraph.

Fill in the draft PR (`gh pr edit`):

- **Title:** `<type>(<id>): <description>`, a Conventional Commit.
- **Body:** the repository's PR template, if it has one. The issue link, Summary, Changes, Testing
  and `## QA`. When the PR fixes a problem a release caused in production, fill the `Breaks:` line
  with that release (`Breaks: v1.2.3`) and add the `regression` label. Otherwise leave it empty.

## 6. QA: mark ready, then check the head commit

When the work is complete and the affected tests pass, mark the PR ready: `gh pr ready <pr>`.
Drafts get no QA, so this starts it.

Done means checked on the real thing (the running app, the actual row, the actual mail), not
inferred from a passing test or a report (`principle-prove-it-works`).

1. **Wait for the checks on your head commit:** `gh pr checks <pr> --watch`. The ones the default
   branch requires are in `pr.required_checks`. Right after a push, checks may still be the
   previous commit's; a check for an older commit says nothing about this one.
2. **The QA environment.** When the repository runs mroom's QA workflows, the PR gets its own
   environment when a user could notice the change: `api-<PR>.<zone>`, and `go-<PR>.<zone>` for a
   frontend of its own (`qa.zone`). Its `### QA environment` comment on the PR says when it is up,
   or why it was skipped.
3. **Browser QA.** If the repository runs a browser QA check for the head commit, read its result
   and its PR comment:
   - `success`: every row passed.
   - `failure`: a row failed. Fix it on the branch and push; QA runs again on the new commit.
   - `neutral`: something was not verified. Make it verifiable (missing data goes into the app's QA
     fixtures) and push, or name it in the PR with its unmet precondition.
   - `skipped`: nothing a user could notice. If you disagree, say so in the PR and ask a person
     to add the `qa` label.

   With no browser QA check, check the change yourself on the PR's QA environment, as a seeded
   user, in a browser tool. Never on production.
4. **Design compare.** If the issue had a design, compare the screenshots of every touched screen
   to the canvas, board by board. Fix any mismatch on the branch before review.
5. **Fill `## QA`** in the PR body for the head commit: environment, roles, screens, result and
   evidence, or `n/a: no user-facing change` with the reason.

**If the PR falls behind the default branch,** update it on GitHub with `gh pr update-branch <pr>`,
then `git pull --ff-only` in the worktree before any later commit. Never merge the default branch
locally and push to bring a PR up to date.

## 7. Hand off and STOP

- `gh pr checks <pr>` (read-only) to report CI.
- Move the issue to the review state:
  `mroom tracker state <id> "$(mroom config get issues.state_review --default 'In Review')"`.
- `mroom tracker comment <id> < note.md`: the PR link and the QA result for the head commit. When
  `mroom tracker` exits 3, put the note on the PR with `gh pr comment <pr> --body-file note.md`.
- Stop. No merge, no deploy, no more state changes. Keep the worktree: review fixes go there. After
  the PR merges, the person (or a later session) removes it with `git worktree remove <path>`.
