---
name: refine
description: Backlog refinement. List the tracker issues assigned to me, tag each with a Design value, propose which to run, and run /mroom:implement only on the issues I confirm. Never merges.
---

# /mroom:refine: refine my assigned backlog and run what I confirm

Issues live in the tracker that `issues.tracker` names. Read them only through `mroom tracker`.
Only issues assigned to the person running this session count.

**Principles.** A `principle-…` name in parentheses closes a one-line summary of a skill. When that
step applies, Read that skill's `SKILL.md` in full before acting on it: the summary says when, the
file says how. Skills sit next to this skill's own folder in the mroom plugin, or in the app's
`.claude/skills/`. If the skill is not installed, go on without it.

## Rules

- Never merge, approve, deploy or release on your own. A person does each of these.
- Tracker writes: only the state of the issue being worked, and comments on it.
- Ask the person before you create an issue or a label.
- Never touch production. Never read secrets, tokens or credential files.
- This skill reads the tracker and writes nothing to it. `/mroom:implement` does the writes.

## 1. Query (read-only)

`mroom tracker list --mine --open --limit 250`. It takes the 250 most recently updated issues,
then lists them by priority. Each issue has its id, title, state, priority, labels, url and branch.

When `mroom tracker` exits 3, there is no tracker (`issues.tracker = "none"`). Say so, and offer to
run `/mroom:implement` on a task the person writes. Stop there.

## 2. Tag and show the list

For each issue show: id, title, state, priority, a size guess (S, M or L), whether a branch or PR
already exists (`gh pr list --head <branch> --state all`), and a **Design** value:

| Design | Meaning | Build behaviour |
|---|---|---|
| `no` | No screen or flow change (see below). | `/mroom:implement` comments the decisions, then builds. |
| `drawn` | A `Design approved by` comment links the design. | Build against it. |
| `needed` | A new screen, or a changed flow. | **Do not build.** Use `/mroom:deliver <id> --design`. |

`no` includes fixes inside an existing pattern: other labels or numbers in a table, a reason
next to a disabled button, a button that now works.

Decide Design now, at planning time, not mid-build. Read each issue's comments with
`mroom tracker get <id>`. An issue whose latest design comment is `Design for review:`, with no
`Design approved by` after it, is waiting for a person. Skip it.

Order the proposal so each issue lands in a state that can be checked before the next starts,
smallest verifiable first (`principle-sequence-verifiable-units`).

Issues the bot persona filed are listed but not selected unless the person picks them.
`mroom tracker get` shows an issue's creator; the persona's name is `persona.name`.

Issues labelled `lesson`, and issues that report the same mistake twice, go together as one batch
named **`correct`** or **`correct-<topic>`**. That name makes `/mroom:deliver` work it with the
`correct` skill, so use it exactly.

## 3. Confirm

Ask with `AskUserQuestion` (multi-select) which issues to run. Run **only** the confirmed ones.
`needed` issues are never built here; offer to draw them with `/mroom:deliver --designs`.

## 4. Run

- Run `/mroom:implement` for each confirmed issue, each in its own worktree. A `correct…` batch
  goes to `/mroom:deliver <batch name>` instead. Independent issues may
  run in parallel sub-agents. Keep it to 2 or 3 at once, since each runs its own tests.
- Push before QA. Each pull request gets its own QA environment when the repository runs mroom's
  QA workflows, so two PRs can be checked at once.

## 5. Report

One line per issue: id, PR link, CI, QA result, tracker state. Everything ends at the review state
(`issues.state_review`). A person merges.
