# Production access

Who may see the app's production data, how, and what a session gets instead. The app's own runbook,
when it has one, wins over this page. This is engineering practice, not legal advice: what the law
asks of the app (a data processing agreement, a lawful basis, retention) is for the people who answer
for it.

## Four levels

Each level is narrower than the one before and better logged. Use the lowest level that answers the
question.

| Level | Who | What |
|---|---|---|
| 0, default | everyone, every agent | No production personal data. Error tracking with ids only, logs with ids and counts, a masked QA copy, the feature specs. |
| 1, support | support staff, developers | The app's admin panel, signed in with MFA. Every action lands in an activity log. |
| 2, read-only data | named developers, rarely | One personal role that expires (30 days at most) on the read replica, through views that leave out or mask personal columns. Over a private network with MFA, with a statement audit log. Nothing is copied off the screen. |
| 3, break-glass | the lead developer, during an incident | An incident issue first, and a second person told. Their own identity with MFA, for a set time. Rotate any secret touched. Data fixes ship as reviewed commands with a dry run, never typed by hand. Everything is recorded in the incident issue. |

A production console (a shell on a server, a REPL in the app) is level 3, whatever is typed in it.

## Agents stay at level 0

A session or an agent never holds a production role, a key or a token, and never reads production. The
most it gets is an aggregate, non-personal figure that a person pulled for it, through the check below.

Personal data that reaches an AI provider makes that provider a sub-processor of the app. That needs a
data processing agreement, the provider on the app's published sub-processor list, and notice to
customers, all before the first byte is sent.

## A read-only check a session hands to a person

When a session needs a production fact (how many rows a backfill would touch, whether a case exists), it
writes a check and a person runs it. Before handing it over, the session confirms each point and says
so; a check that fails one is rewritten.

1. **Read-only by construction.** For a SQL database, the whole check runs in one transaction that
   starts with the database's read-only mode (Postgres: `SET TRANSACTION READ ONLY` and
   `SET LOCAL statement_timeout = '30s'`; MySQL: `START TRANSACTION READ ONLY`), so any write is refused
   and a slow query stops. No app methods that save, queue jobs, send mail or call an API.
2. **Aggregate, non-personal output.** Counts, yes or no, sums, distributions, and the names or domains
   of organisations when the decision needs them. Never a person's name, email, phone or IP address, and
   never free text (titles, notes, descriptions, messages). The query may filter on free text, as long
   as only a count comes out. Ids only when the next step needs them, and never a user's.
3. **Bounded.** Indexed filters or a time window. Name any scan of a large table before handing the
   check over.
4. **Tested first** on a local database or a masked QA copy. Say the result came from there.
5. **Explained.** What each number means, and which decision each outcome leads to.
6. **Recorded.** The person notes the command and its output in the tracker issue it serves (with no
   tracker, on the pull request). Only that output comes back to the session.

Who runs it: while no admin screen and no level 2 view answers the question, the lead developer may run
a check that meets all six points without opening an incident, recording it in the tracker issue
instead. A question asked a second time becomes an admin screen, so nobody needs the check again.

The workflow skills (`implement`, `fix-issue`, `deliver`) carry these six points, and the session Room's
Rollout tab gives an unknown number as such a check.
