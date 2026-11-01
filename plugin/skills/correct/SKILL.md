---
name: correct
description: "Find the mistakes agents keep repeating in this repo and make each one impossible. Try architecture first, then types, then a lint or architecture check whose error names the fix, then a behaviour test, and write docs last. Prove each check fails on a real past mistake. Use for /mroom:correct, for a `correct…` batch, or when the same mistake or red gate has happened twice."
disable-model-invocation: true
---

> Adapted from [pstack `correct`](https://github.com/cursor/plugins/tree/0b8e952052d482ee6de06deebf14d590d77b1b34/pstack/skills/correct),
> MIT (see `LICENSE`), at commit `0b8e952052d4`. Changes: the inputs, levels, gate and exception
> syntax are mapped to mroom's apps (a Laravel backend, a Vite frontend, the tracker through
> `mroom tracker`), and the rule table lives in the app's root `CLAUDE.md`.

# Correct

The same mistakes keep reaching review, CI or QA. Change the repo so the next agent can't make
them.

Assume every contributor is an agent that sees only the files it opened, copies the nearest
example, and takes the shortest path that compiles. Design the repo so a change that looks right
from one file is right for the whole repo.

## Rules

- Never merge, approve, deploy or release on your own. A person does each of these.
- Tracker writes: only the state of the issue being worked, and comments on it.
- Ask the person before you create an issue or a label.
- Never touch production. Never read secrets, tokens or credential files.

## Find the mistake classes

A class counts once it has happened **twice**. Read, newest first:

- **Tracker issues labelled `lesson`**, open and closed: `mroom tracker list --label lesson`. When
  `mroom tracker` exits 3, there is no tracker: look for `lesson` notes in PR bodies and comments
  instead (`gh pr list --state merged --search "lesson in:body,comments"`).
- **Red-then-green CI.** Failed PR runs:
  `gh run list --status failure --event pull_request --json databaseId,workflowName,headBranch`,
  then `gh run view <id> --log-failed` for the failing test and assertion. The same test failing on
  unrelated branches is a flaky gate, and counts each time.
- **Review comments** on merged PRs (the Claude review's and people's), counting themes across PRs.
  A theme the reviewer has to *check* every time ("make sure X is in Y") is a rule nothing enforces.
- **Reverts and fix-of-a-fix commits** (`git log --grep`), and the parks and stops in
  `/mroom:deliver` reports.
- **The person's corrections** in Claude's memory notes.

Classify every hit before counting it. A reviewer's routine reminder, or a rule a tool already
enforces (formatting, a translation check), is not a mistake.

## Fix each class at the highest level that works

1. **Architecture.** One supported way to do each job, and one owner per piece of state. Replace
   hand-synced lists with one source of truth, and delete the old way an agent would copy. Make
   behaviour independent of what it must not depend on: wall-clock time, row order, process order.
2. **Types.** Make the bad state unwritable: PHP enums, readonly value objects,
   `declare(strict_types=1)`; TypeScript discriminated unions, branded types, `strict`, generated
   API types.
3. **A check whose error names the fix.**
   - **Backend:** a static-analysis or architecture rule (PHPStan, Deptrac), or a test that scans
     source files and fails with the file, the line and the replacement.
   - **Frontend:** ESLint `no-restricted-imports` or `no-restricted-syntax` with a `message`, a
     boundaries rule, or a custom rule.
   - **If the pattern is common,** fail only on new cases: a baseline the check refuses to grow.
4. **A behaviour test.** Call the code as its users do. Fix or delete a test that still passes
   when the behaviour it checks breaks, or that fails when only the inside changes.
5. **`CLAUDE.md` last,** only for judgment calls. Nothing fails when an agent skips it.

## Fix and prove

Fix the most frequent class now, one commit per class, through `/mroom:implement`'s branch and PR.

- **Prove it.** Each new check or test must fail on a **real past mistake**: feed it the offending
  line word for word from `git log`, reproduce the failure every time (freeze or step the clock,
  shuffle the rows), or revert the fix and show it go red. Paste the red run and the green run in
  the PR.
- **Same command locally and in CI.** The gate is the pre-push hook plus the checks the default
  branch requires (`pr.required_checks`). A check that runs in only one of them is not a check.
- **Exceptions** go on the offending line with a reason, such as
  `// eslint-disable-next-line <rule> -- <why>`, or the scanning test's own escape comment. Never
  widen a baseline to let a new case in.

## Keep the rule table

The app's root `CLAUDE.md` keeps a "Common mistakes" table that pairs each rule with what enforces
it. Write an **`Enforced by`** entry only for enforcement you checked exists (the test file, the CI
step, the lint rule, the settings deny rule, the runtime guard); otherwise write "Review". When a
mistake repeats, fix it at the highest level in the same change and move its row off "Review".
Drop a row once its mistake can't happen.

**Reply:** each class with its evidence (links to the runs, PRs or commits), the level you picked
and why a higher level didn't work, and the proof that the check fails on the real mistake.
