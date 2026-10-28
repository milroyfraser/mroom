---
name: deliver
description: Deliver a tracker issue end to end, up to a merge-ready handoff (a person merges and releases). /mroom:deliver <id> = design gate, then /mroom:implement, then QA; /mroom:deliver <id> --design = draw and get design approval only; /mroom:deliver --designs = draw every waiting design in one sitting; /mroom:deliver alone runs /mroom:refine.
---

# /mroom:deliver: one issue from design to a merge-ready PR

Issues live in the tracker that `issues.tracker` names. Read and write them only through
`mroom tracker`. When it exits 3, there is no tracker: the pull request holds what the issue would
(the task, the design link, the notes).

**Principles.** A `principle-…` name in parentheses closes a one-line summary of a skill. When that
step applies, Read that skill's `SKILL.md` in full before acting on it. If the skill is not
installed, go on without it.

## Rules

- Never merge, approve, deploy or release on your own. A person does each of these.
- Tracker writes: only the state of the issue being worked, and comments on it.
- Ask the person before you create an issue or a label.
- Never touch production. Never read secrets, tokens or credential files.
- Never add the `qa` label. It is a person's switch.
- Push early: after the first commit, push and open a draft PR linked to the issue
  (`/mroom:implement` step 4). Mark it ready only at hand-off.

## Routing

| Invocation | Action |
|---|---|
| `/mroom:deliver` | Run `/mroom:refine`. |
| `/mroom:deliver <id>` | The design gate (below) if the issue needs a design, then `/mroom:implement <id>`. |
| `/mroom:deliver <id> --design` | The design gate only. Stop after approval; build nothing. |
| `/mroom:deliver <id> --no-design` | Treat the issue as Design `no` and go straight to `/mroom:implement`. |
| `/mroom:deliver --designs` | The design gate for every issue `/mroom:refine` tags `needed`, one at a time, asking once per design. |
| `/mroom:deliver <id>` with earlier work | Resume (below). |
| `/mroom:deliver correct…` (a batch from `/mroom:refine`) | Read the `correct` skill in full, and follow it through `/mroom:implement`'s branch and PR. |

## Resume: carry on where a stopped session left off

Sessions get stopped mid-task. `/mroom:deliver <id>` (and `/mroom:implement <id>`) first looks for
the issue's earlier work and continues it. Never start a second branch or PR.

1. **Its PR.** `gh pr list --state open --search "<id> in:title,body" --json number,isDraft,headRefName,url`,
   and `gh pr list --head <branch>` for the issue's branch (`mroom tracker get <id>` shows it).
   - A draft PR is unfinished work. Check out its branch in a worktree (`git worktree list` may
     already have one) and continue `/mroom:implement` from step 2. Read the PR body, its commits
     and the issue's comments for what was done.
   - A ready PR: read `gh pr checks <pr>`, fix failures, answer review comments, and read the QA
     result for the head commit (`/mroom:implement` step 6). Push the fixes. If the PR is behind
     the default branch, `gh pr update-branch <pr>`.
2. **A worktree with unpushed work.** `git worktree list`, then `git -C <path> log @{u}..` (or
   `git -C <path> log origin/<default>..` for a branch never pushed). If one is on the issue's
   branch, work there. Push it first (`git push -u origin <branch>`), so it is saved, then open the
   draft PR and continue. Never `git reset --hard` or delete it to start over.
3. **Neither:** start fresh with `/mroom:implement`.

Say in the first line of the report which of these it resumed from.

## Report, and repeated trouble

End with one line per issue: PR link, CI, the QA result for the head commit, tracker state, and
what the person still has to do (merge, release, a manual step).

If the same issue parked twice for the same reason, or CI failed on a test that passes when run
alone, Read the `correct` skill. Either fix the class now, or report it as a lesson that names both
times. Filing a `lesson` issue needs the person's OK first (`mroom tracker create --allow-create`).

## Can this session draw?

Check that this session **lists the Artifact tool**. If it does not, stop and tell the person.

## Design gate

The design source is Claude Design canvases (the Artifact tool, intent `design`).

1. **Does it need a design?** A new screen or a changed flow does. A fix inside an existing
   pattern does not: comment the decisions on the issue and build. `--design` forces it.
2. **Draw.** Call Artifact with `action: "quickstart"` and `intent: "design"`, then load
   `artifact-design`. Use the app's design system, and its `DESIGN.md` if it has one.
   - One canvas per issue (or per group of related issues).
   - A `Main` board for the flow; each state and variant on its own board.
   - If nothing in the app does the interaction yet, draw 2 or 3 truly different options and
     recommend one (`principle-exhaust-the-design-space`). A screen that follows an existing
     pattern gets one design.
   - When scope and polish pull apart, choose fewer, finished features over more rough ones
     (`principle-experience-first`).
   - Never publish a stand-in mockup.
3. **Post it for approval.** `mroom tracker comment <id> < design.md`, a comment whose first line
   is `Design for review: <canvas link>`, then the decisions worth the person's eye and the
   assumptions made. When `mroom tracker` exits 3, put it in the PR body instead.
4. **Ask once** with `AskUserQuestion`: approve / approve with changes / later.
   - **approve:** comment `Design approved: <canvas link>`.
   - **approve with changes:** redraw, post again, ask again.
   - **later:** leave it. The issue is parked, and the next run resumes it.
5. With `--design`, stop here. Otherwise go on to `/mroom:implement`, which refuses to build
   against a design that is not approved.

QA later compares the screenshots of every touched screen to the canvas, board by board
(`/mroom:implement` step 6).
