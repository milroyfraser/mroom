---
description: Clean-code review of a change set by a fresh reviewer that did not write it (10 dimensions, severity-tagged findings, a verdict). Never commits.
argument-hint: "[base ref, such as origin/main]"
---

# Clean-code review (SOLID and the app's own standards)

Run the clean-code gate on a change set, with a **fresh reviewer that did not write the code**,
before the work is reported done or committed.

The standards are the app's `CLAUDE.md` files and the 10 dimensions below. Where the app's
`CLAUDE.md` says more, it wins.

## Rules

- Never commit, push, merge or approve. The developer reviews and commits.
- Never read secrets, tokens or credential files, and never touch production.
- Never apply an architectural change without the developer's OK.

## Instructions

1. **Find the diff to review:**
   - If `$ARGUMENTS` names a base ref (such as `origin/main`), review `git diff <ref>...HEAD`.
   - Else, if there are uncommitted changes, review `git diff HEAD` (staged and unstaged).
   - Else, review the last commit: `git diff HEAD~1...HEAD`.
   - Write the diff (`git diff -U10 …`) and `git diff --stat` to one scratch file, so the reviewer
     reads it in one pass. Do not paste it into your own context.

2. **Size the review** to the change:
   - **Small** (1 file, under 50 lines): inline checks only: naming, functions, formatting,
     error handling.
   - **Medium** (2 or 3 files, 50 to 500 lines): all 10 dimensions, on the changed code.
   - **Large** (4 or more files, over 500 lines, a new module): all 10 dimensions, the
     architecture first, then the details.

3. **Start a fresh reviewer sub-agent** (the Agent tool; it must NOT be the author). Give it the
   diff file's path, and review against the **10 dimensions** (🔴 = blocking):
   1. **Naming** 🔴: names that say what they mean, in the domain's own words; no cryptic or
      misleading names; a property and its method don't repeat the same noun.
   2. **Functions** 🔴: under 40 lines, 0 to 3 arguments, one job, no flag arguments or hidden
      side effects.
   3. **Classes** 🔴: one reason to change, high cohesion, low coupling. SOLID, above all
      interface segregation (each injected interface fully used) and dependency inversion
      (depend on abstractions).
   4. **Error handling** 🔴: exceptions over error codes; no bare or empty catch; no null for a
      failure; exceptions carry context (ids, never personal data); input checked at the edge.
   5. **Comments** 🟡: say why, not what; no commented-out or dead code.
   6. **Formatting** 🟡: consistent; lines of at most 120.
   7. **Tests** 🔴: Zero, One, Many, Boundaries, Interface, Exceptions, Simple; one test class
      per use case; names that state the outcome; assertions on what a user of the code sees, not
      on table counts; no test without an assertion.
   8. **Architecture** 🟡: dependencies point inward (IO, then adapters, then use cases, then the
      domain); the domain is free of the framework; use cases stay thin.
   9. **Patterns** 🟡: each pattern solves a real problem; no abstraction for its own sake.
   10. **Professional** 🟡 (🔴 if it got worse): leave the code better than you found it; match
       the sibling files; no dead or unused code.

4. **Ask for severity-tagged findings**, each with `file:line`, the rule it breaks and the concrete
   fix: **🔴 CRITICAL**, **🟡 WARNING** or **🔵 SUGGESTION**. Show this list first. It is the main
   output; the developer can act on it even if nothing is changed for them.

5. **Verdict:** **PASS** (no 🔴), **PASS WITH WARNINGS** (no 🔴, at least one 🟡, with why it can
   wait), or **FAIL** (at least one 🔴). Work is not done while any 🔴 is open.

6. **Act on the findings by tier:**
   - **Fix only safe refactorings yourself:** mechanical, local, and the same behaviour: rename a
     local, delete dead code, a magic number to a named constant, extract a private helper, guard
     clauses, a table-count assertion to an assertion on what the code returns. Then run the
     affected tests and the app's formatter again.
   - **Ask first for anything bigger:** a public API or interface, a widely used name, moving files
     between layers or modules, any architectural change, or anything large (over about 30
     minutes, or many files). Show the change and why, then STOP and wait for the developer to
     approve, decline or defer.
   - **Leave 🔵 suggestions** as suggestions unless the developer asks for them.

7. **Close out:** report the verdict, what was fixed, what waits for the developer, and what is
   left. Do not call the work done while a 🔴 is open.

## Arguments

- `$ARGUMENTS`: an optional base ref to diff against (such as `origin/main`). By default the
  uncommitted changes, then the last commit.
