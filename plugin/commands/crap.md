---
description: CRAP triage of the backend code you changed (coverage crossed with complexity). Reports only methods in your own changed files, and applies nothing without asking.
argument-hint: "[base ref, such as origin/main]"
---

# CRAP triage (changed code only)

Answer one question: **did the code I just wrote make this worse?** Run the CRAP metric (test
coverage crossed with cyclomatic complexity) over what you touched, and report only methods in
your own changed files.

It is not a whole-codebase report. The worst old methods are the same every run and become
wallpaper; inherited debt is not this command's job.

Backend only: CRAP needs PHP line coverage. For the frontend, the app's unit tests report coverage
and hold their own thresholds.

## Rules

- Never commit, push, merge or approve. The developer reviews and commits.
- Never read secrets, tokens or credential files, and never touch production.
- Apply nothing without asking (step 6).

## Instructions

1. **Run it** from the backend folder (`app.backend_dir`): `bin/crap --changed`, or
   `bin/crap --changed=<ref>` when `$ARGUMENTS` names a base ref. It finds what the diff touched
   (committed, unstaged and untracked), narrows coverage to your changed production files, and
   prints a table.

   If the app has no `bin/crap`, say so and stop. If it stops on its own (nothing under `app/`
   changed, only tests changed, no coverage driver, or another run holds the lock), relay that
   and stop. Do not run the suite to report on nothing.

2. **Read the table.** Every row is already a method in a file you changed. The columns are
   `CRAP`, `CX` (complexity), `COVERAGE`, `UNTESTED` ("12 of 14" means paths no test walks) and
   `METHOD`.

3. **Triage what is there**, worst first:
   - 🔴 CRAP over 100, or complexity over 15: too many paths to test well. Split it.
   - 🟡 CRAP 30 to 100: add the missing tests, or reduce the branching.
   - 🔵 CRAP 10 to 30: note it; no action unless the fix is trivial.
   - Below 10 is fine. Don't list it.

   CRAP is `complexity² × (1 - coverage)³ + complexity`, so at full coverage it is the plain
   complexity. A high score means *untested* branching, not branching alone. Say which of the two
   drives each finding, because the fix differs: a test, or a refactor. A fully covered method
   that still scores high needs no more tests.

4. **Read each flagged method before proposing anything.** Give a concrete fix (the guard clause to
   extract, the untested branch to cover), not "consider reducing complexity". Where a method is
   long but straight, say so and leave it.

5. **Report plainly.** If nothing you touched is over the line, say exactly that in one line. Do
   not pad the report with the codebase's old offenders.

6. **Apply nothing without asking.** Extracting a helper or covering a branch changes risk and the
   test surface. Show the findings, then stop. If the developer's request already asked you to fix
   what you find, apply only safe, local refactors, then run `bin/crap --changed` and the app's
   formatter again.

## Arguments

- `$ARGUMENTS`: an optional base ref to diff against (such as `origin/main`), passed on as
  `--changed=<ref>`.
