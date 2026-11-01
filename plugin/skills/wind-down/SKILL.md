---
name: wind-down
description: End the working day. Turn the session Room to its wind-down mood, bring every piece of running work to a state that can be paused and restarted later, and run a retrospective of the day's learnings, one card at a time, each an observation with its recommended action items. Never merges.
---

# /mroom:wind-down: pause the day and look back

Use it when the developer says they are wrapping up. It leaves nothing half-done in a way that
can't be picked up again, and it turns what the day taught into a short list they read one card at
a time.

## Rules

- Never merge, approve, deploy or release on your own. A person does each of these.
- Tracker writes: only the state of the issue being worked, and comments on it.
- Ask the person before you create an issue or a label.
- Never touch production. Never read secrets, tokens or credential files.
- Never answer a permission prompt for the developer.
- Pausing is not deleting. Never rm -rf, never force-push, never discard a branch or a worktree
  with unpushed work. Anything that can't be paused cleanly goes on a to-do for the developer.
- Never get past a refused command another way. Write it down for the developer instead.
- Keep everything on the Room short and in simple English.

## 1. Wind-down mood

Write `meta/winddown` on the session Room: `{on: true, at, note, paused: []}`. The page turns to its
dusk palette at once, with a floating crescent moon and twinkling stars. `note` says in a few words why (e.g. "End of day"), and `paused` fills in as
step 2 goes.

## 2. Bring work to a pausable state

For each kind of running work, reach a point where it can stop and start again from what's on
GitHub and the Room alone:

- **Helpers building a PR:** let each finish its current step (a push, a CI run). Each must leave
  its branch pushed, the PR opened (as a draft when it isn't ready), and its worktree removed. A
  helper still mid-change is told to commit and push what it has as a draft, with what's left in
  the PR body.
- **Reviews and security checks:** let them report. Record each verdict on its card. A check that
  can't finish tonight writes down what it covered and what's left.
- **Watchers** (merge watcher, scheduled runs): stop them only when the developer asks. Otherwise
  say in `paused` that they keep running.
- **Cards:** every open PR has a card with its current verdicts. `meta/next` names the first thing
  for tomorrow, with `text` saying it can wait until then.
- **Leftovers:** worktrees, scratch copies and box test folders that you may not remove go on the
  cleanup to-do, with the exact commands.

Add a one-line entry per item to `paused` ("3 PRs ready for review", "merge watcher keeps running").
When everything is paused, write a feed entry saying so.

## 3. Retrospective

Look back over the whole session: what went well, what cost time, what went wrong and was fixed.
Group it into a handful of learnings (usually 5 to 12), ranked by impact. Write each as a doc in
the Room's `learnings` collection:

```
{ order, title, observation,
  actions: [ { text, rec } ],
  status: "open" }
```

- `title`: the learning in a few words.
- `observation`: what was seen, with the PRs or events that show it.
- `actions`: the recommended action items, concrete changes (a check, a rule, a tool, a template
  change). Each `rec` is Claude's recommendation: how to do it, how big it is, and whether it needs
  the developer's decision first.

The page shows one learning at a time on top of "Your next step", with "Learning n of N". Each
action item has a check box: the developer ticks the ones they confirm and presses the button twice
(the first click arms it, the second saves; the next card shows at once while the save finishes in
the background). The page writes `status: "done"` and `confirmed` (the
indexes of the ticked items in `actions`) and shows the next card. "Back" opens the previous card
with its saved ticks so the developer can change them; saving there steps forward through the
cards already read. Keep the learning generic when it
is about the tool, and name the project only on that project's own Room.

## 3b. Report and follow-through

Record the retrospective where the project is managed: one report issue in the tracker that
`issues.tracker` names, written through `mroom tracker` (a GitHub issue, a Linear issue, …), labelled
or titled as a retrospective with its date. It lists each learning, its observation, and per action
item the developer's decision (confirmed, declined, or not read yet), and later what was done with a
link. Put its link in `meta/winddown.report`; the page shows it. When the tracker write needs the
developer (a refused command, or a rule that asks first), give them the ready command and the text. When
`mroom tracker` exits 3, there is no tracker: keep the report as a Markdown file the developer can
file where they manage the project, and link it in the chat.

Decisions arrive after this skill ends, so every regular check and every restart looks at
`learnings`: for each confirmed action item without `acted[i]`, act on it as its `rec` says (start a
helper, open a PR, add a to-do with the ready command when it needs the developer) and write
`acted: {"<i>": {state: "doing"|"done", outcome, link, at}}`. Set `state: "done"` once the work has
landed (a merged PR, a filed issue, a settings change made). An item that was read and not ticked is
declined: record it as such in the report and do nothing. Update the report as items move, and close
it when every action item is done or declined.

The page keeps the retrospective section only while something is left: a card not read, or a
confirmed action not done. After the last card it lists the confirmed actions still open with their
state, and the section disappears once all are addressed.

## 4. Hand over

In the chat, say in a few lines: what is paused and where, what is first tomorrow, and that the
retrospective is on the Room. Point to the report. Act only on confirmed action items, as step 3b says; items left unticked are
declined.

## Restarting

When the developer writes again after more than 5 minutes, write `meta/wave` `{at}` first (the page
waves hello where the moon sits) and keep `meta/presence.lastUserAt` current.

The next session reads `meta/winddown`, the open cards and `meta/next`, starts the watchers again,
and sets `meta/winddown.on` to false. That turns the page back to its day mood.
