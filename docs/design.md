# mroom design

**TL;DR:** mroom (Machine Room) is a system for building software with Claude Code agents, for **Laravel + Vite
apps hosted on Laravel Forge, with code on GitHub**. Agents take an issue to a merge-ready, QA'd pull request on a
shared Linux box. Four requirements drive it (section 1), and one rule comes first: PR code never sees a secret that
reaches beyond its own QA environment (D6). mroom is extracted from the machine room of a production Laravel + Vite app (the
pilot app), which adopts it back one phase at a time (D8). It ships as a Claude Code plugin, reusable GitHub workflows and a box CLI. Each app
describes itself in one committed `mroom.toml`, and no mroom script names a company, host, id or channel.

Status: draft, 25 Oct 2026; phase 0 done, phase 1 under way. MIT licence. Repository: `milroyfraser/mroom`.

## 1. Requirements, and what mroom is

### 1.1 Requirements

1. **Maintain human-readable, clean code.** People review what agents write, so the code must read well to a
   person.
2. **Release with confidence based on clarity.** Before a release, know exactly what ships and what could go
   wrong. After it, know that the new release is the one running and that it is healthy.
3. **Fast, no-surprise CI/CD workflow by bringing everything closer to production.** Prove each change under
   production-like conditions, as fast as possible: quick checks on every push, and production-like checks when
   the change touches what they cover.
4. **Do everything AI/agent can before involving a human.** A person's time goes to decisions: what to build,
   whether a change is right, when to release. Agents do the rest and hand over the evidence. A person should never
   have to catch the same mistake twice: `/correct` turns a repeated mistake into a check. This is how mroom gets
   better over time; it is not a separate goal.

One rule comes before all four: **PR code never sees a secret that reaches beyond its own QA environment** (D6,
section 8). When a requirement and the rule disagree, the rule wins.

Being open source and working for any Laravel + Forge app shape how mroom ships (D2, D7, D8). They do not decide
what is built first: a phase is done only when it improves a requirement's measure on the pilot app (section 11).

### 1.2 How each requirement is measured

Each requirement has one or two measures, counted on the pilot app, which adopts each phase (D8), not on the
example configs. Each measure says how it is counted, so anyone can repeat it. Most come from git, GitHub and the
error tracker; three need a record that a phase starts (marked *new record*). The pilot app keeps its own numbers;
an app that adopts mroom records its baseline before each phase. The targets are first proposals.

| Requirement | Measure, and how it is counted | Phase | Target |
|---|---|---|---|
| 1. Clean code | Files over 500 lines in the backend (tests left out): how many, and their total lines | 3 | Neither grows in any release |
| | Entries in the static-analysis baselines (Deptrac today; PHPStan or Larastan when added) | 3 | Never grows |
| 2. Release confidence | Releases whose live commit `deploy-verify` confirmed matches the tag | 4 | Every release |
| | Time from a release to the first report of a problem it caused (*new record*: the `regression` label) | 5 | Under an hour |
| 3. Fast, no-surprise CI/CD | Median time to the slowest required check on a PR's first push (`tools/ci-first-push.sh`) | 4 | Under 4 minutes |
| | Production problems per release (*new record*: the `regression` label) | 2a | Falling each month |
| 4. Agents first | Product PRs whose QA plan asked for a browser test, but which reached a person without one passing on their last commit; waits for a QA slot counted apart | 2b | Under 1 in 10 |
| | Box or pipeline failures that a person noticed before mroom reported them (*new record*: each failure's issue says who noticed it first) | 1 | None |

Not counted yet, and worth adding: a person's messages to agents per merged PR, from the session logs on the box.
Commits do not show a person's work, because agents make almost all of them.

### 1.3 What mroom gives a team

- **A shared agent box**: one worktree, test database and Redis prefix per session; one Claude, GitHub and git
  identity per developer; a dev site served from a pushed branch under a lock; resume after a restart; nightly
  Claude Code updates and worktree clean-up; box health (`mroom status`, `mroom doctor`) and a watchdog that
  reports the box's own failures to chat.
- **An agent workflow**: `/refine` → `/deliver` → `/implement` → stop at a PR in review; `/release` on a person's
  say-so. Principle skills named at the step that needs them.
- **Guardrails**: agents never merge, approve, deploy, release or read secrets; enforced by a command parser,
  not only prefix rules.
- **Per-PR QA environments** on the box, each with its own seeded database (or an opt-in masked snapshot) and the
  same services as production wherever it can have its own copy (section 9), and **browser QA** by an agent that
  proves each change as a seeded user.
- **PR checks**: conventional titles, release-note labels, the Claude review and its findings check.
- **CI/CD defaults**: CI templates with the measured patterns of section 10, and a deploy step that ships the
  release tag, checks that the new release is live, and rolls back by tag.
- **A bot persona** (name configurable) that keeps one status note per PR on the issue, pings a person only when
  needed, and triages alerts into issues.

Not goals: hosts other than Forge or trackers other than Linear in v1, non-Laravel stacks, macOS boxes. mroom
starts the host's deploy and checks that the new release is live; the host (Forge) still runs the deploy.

## 2. Decisions

| # | Decision | Why |
|---|---|---|
| D1 | Laravel + Vite on Forge, GitHub, Postgres, Redis. Single app **or** backend/frontend folders | The two apps it grew in differ exactly there: one is a single app, the other has two folders |
| D2 | Distribution: plugin + reusable workflows/composite actions + box installer; `mroom init` only writes app-owned files | Maintained code stays in mroom and is pinned by version; no drift from copies |
| D3 | Config: `mroom.toml` in the app repo, `~/.config/mroom/box.env` on the box, secrets in separate mode-600 files | Repo facts travel with the code; box facts and secrets never do |
| D4 | Behaviour config can't express goes in app hooks (`.mroom/hooks/*`) at fixed points | `site-pull` and `wt new` are recipes, not values |
| D5 | Adapters: tracker (Linear, or none), chat (Slack), errors (Sentry, optional), host (Forge) | v1 supports what exists; the seam allows more |
| D6 | PR code never sees a secret that reaches beyond its own QA environment (section 8): a job that holds a secret never runs PR code, and a QA environment holds only credentials for its own QA resources. Hard requirement, including for QA provisioning | A common QA setup runs PR code in a job that also holds a deploy token; mroom must not |
| D7 | MIT. Vendored pstack skills keep their MIT `LICENSE` and attribution; a `NOTICE` lists them | MIT is compatible and simplest |
| D8 | New repo with a fresh history. The pilot app is not changed to build mroom; it adopts each phase once that phase Works, in its own PR, and drops its own copy of that part | The pilot app's history holds names, emails and ids; the pilot app is where each phase proves it helps (D10) |
| D9 | CI stays on GitHub Actions with the section 10 defaults; a control-plane package is deferred | The measured waits were caches, apt and shard balance, not runner start-up |
| D10 | Requirements first (section 1): from phase 1 on, a phase is done when it Works on the example configs and improves its measure on the pilot app | Works proves mroom runs outside the pilot app; only the measure proves it helps |
| D11 | CD is in scope: the app reports the commit and tag it runs, the deploy waits until they match the release, and a rollback deploys the previous tag | Release confidence needs to know what is running; a fixed wait and a health ping cannot tell |
| D12 | QA uses the same services as production wherever each QA environment can have its own copy; any other choice is a swap, declared in `[qa.parity]`. Data is seeded by default; a masked snapshot is opt-in, under the rules of section 9 | Logging mail and using the local disk would move QA away from production; copying production data by default would put customer data at risk |
| D13 | QA environments use mroom's own Forge client (phase 1), not Laravel Harbor | Harbor creates and removes sites, which that client already does. Its documented setup holds the Forge token in a `pull_request` job (against D6), it creates empty databases where mroom clones a template, and its `.env` merge has open bugs with quotes, `#` and multi-line values |

## 3. Host requirements

- Box: Linux with `/proc`, GNU coreutils (`stat -c`, `date -d`, `sha1sum`, `base64 -w0`, `timeout`), bash 5, git, jq, curl, python3
  ≥ 3.11 (`tomllib`), tmux, flock, supervisord (Forge's), Postgres ≥ 13 with a role that has `CREATEDB` and owns
  the QA template, Redis with phpredis, PHP and composer, Node and npm or pnpm, `gh`. Root once, for `mroom baseline`.
  Phase 0 needs only Linux, bash 5, python3 ≥ 3.11, jq and git; `install.sh` checks these and names what is missing.
- Installing a release: `install.sh --version vX.Y.Z` downloads it with `gh` when gh is signed in, and with plain
  `curl` otherwise.
- Forge: one server for the box, a **Forge team that holds only that server**, and a token from an account in
  only that team.
- DNS: a wildcard record `*.<zone>` to the box (or a wildcard certificate in Forge).
- QA services (section 9): an S3-compatible store on the box (for example MinIO) when `qa.parity.files` is
  `same`; Reverb on the box, with an app per environment, when `qa.parity.broadcast` is `same`; and a mail catcher
  with a login (for example Mailpit) when `qa.parity.mail` is `catcher`.
- GitHub: a repo with Actions, three environments (`qa`, `persona`, `production`; section 8), a ruleset on the
  default branch.
- Claude: a Claude subscription per developer (Remote Control), a `CLAUDE_CODE_OAUTH_TOKEN` for Actions.

## 4. Repository layout

```
mroom/
  bin/mroom                     front door (today scripts/dev-box/mroom)
  bin/forge-api                 agent-facing Forge CLI (guards: --write, --secret, path pinning)
  lib/                          box commands: wt, site, site-pull, user, keys, baseline, agent-env, memory-preflight,
                                job, watchdog
  lib/core/                     config reader, forge client, chat adapter (Slack), tracker/errors adapters, job
                                records, the watchdog's probes, util
  plugin/                       the Claude Code plugin
    .claude-plugin/plugin.json
    skills/                     refine, deliver, implement, release, forge, blast-radius, correct, verify-app,
                                principle-*, typescript-best-practices (vendored, with LICENSE)
    agents/qa-engineer.md
    commands/clean-review.md, crap.md
    hooks/hooks.json            SessionStart banner, PreToolUse guard, WorktreeCreate/Remove
  actions/                      composite actions: qa-up, qa-down, qa-reap, qa-browser, pr-status, triage,
                                deploy-verify, regression-label, ...
  .github/workflows/            reusable workflows (on: workflow_call) that call ./actions at the same ref
                                plus mroom's own CI
  templates/                    copied once by `mroom init`: ci-backend, ci-frontend, ci-e2e, deploy-production,
                                dependabot, .mcp.json, CLAUDE.md policy block, mroom.toml, hooks/*
  settings/                     settings fragments: base, laravel-vite, forge, tracker-linear
  examples/single-app/, examples/two-folder/   neutral configs (and, later, hooks) for the two layouts of D1
  tests/                        shell tests (offline, fake PATH tools), fixtures
  install.sh                    copies a release or checkout into ~/.local/share/mroom/<version>, links
                                ~/.local/bin/mroom to it, checks host requirements
  LICENSE, NOTICE, README.md, docs/
```

`mroom` is installed from a tagged release (`install.sh --version v1.2.0`), not from the app checkout, so the
dev site switching branches never rewrites mroom (a script that switches the checkout it runs from must copy
itself somewhere else first).
`install.sh` always installs a **copy** under `~/.local/share/mroom/<version>/` and points `~/.local/bin/mroom` at
it; it never links into a checkout, so even an install from a mroom checkout (`./install.sh`, for development) is
not changed by a later `git switch` there. Re-running replaces that version in place; `--uninstall` removes every
version and the link and keeps `~/.config/mroom`.

The real configs that prove D1 are validated privately against these examples and are not committed (D8).

## 5. Configuration

### 5.1 `mroom.toml` (app repo, committed)

Read only through `mroom config get <key>` (python3 `tomllib`, validated against a schema; a missing required key
fails with its name and an example). Workflows and hooks use the same reader. Proposed keys:

```toml
[app]
name = "shop"                      # used in database names, Redis prefixes, labels
backend_dir = "backend"            # "." for a single Laravel app
frontend_dir = "frontend"          # "." for Vite inside the Laravel app; "" for no separate frontend site
package_manager = "pnpm"           # npm | pnpm
php = "8.4"
version_path = "/version"          # returns {"release": "<tag>", "commit": "<sha>"}; section 9

[app.build]
frontend = "pnpm build"
frontend_env = { VITE_REVERB_APP_KEY = "env:REVERB_APP_KEY" }
after_deploy = ["config:clear", "route:cache"]   # artisan commands
daemons = ["horizon", "reverb"]
queues = ["default", "mail"]

[tests]
command = "php artisan test --compact --parallel"
database_pattern = "{app}_{slug}_testing"   # must satisfy the app's own test-database guard
suites_glob = "app/*/Tests"                 # for the path-aware pre-push; empty = no per-suite runs

[issues]
tracker = "linear"                 # linear | none
id_pattern = "SHOP-[0-9]+"         # worktree slugs, PR title scopes, issue links
url = "https://linear.app/<workspace>/issue/{id}"

[pr]
required_checks = ["test", "lint", "e2e", "check-title"]

[qa]
zone = "<qa-zone>"                 # api-<PR>.<zone>, go-<PR>.<zone>
max_envs = 5
ttl_days = 5
template_database = "qa_template"
persona_domain = ".test"           # sign-in codes are only ever read for these addresses
db_read_allowlist = []             # REQUIRED when browser QA is on: tables and columns the agent may read

[qa.parity]                        # how QA runs each production service (section 9); defaults shown
database = "seeded"                # seeded (factories) | snapshot (opt-in masked copy, section 9)
mail = "catcher"                   # catcher (SMTP to the box's catcher) | log
broadcast = "same"                 # same (a Reverb app per environment) | log
files = "same"                     # same (a bucket per environment and file disk) | local

[persona]
name = "Agent"                     # the name people see on notes and pings
```

**Required keys and defaults, by phase.** A key becomes required in the phase whose command cannot run without it;
until then a reader passes its own fallback (`mroom config get <key> --default <value>`).

| Keys | Required from | Default |
|---|---|---|
| `app.name` | phase 0 | none: required |
| `app.backend_dir`, `app.frontend_dir`, `app.package_manager`, `app.php`, `app.build.*`, `tests.*` | phase 1 decides | phase 1 decides |
| `app.version_path` | phase 2 decides | `/version` |
| `qa.*` (`qa.db_read_allowlist` has no default, ever; section 8.6) | phase 2 decides | phase 2 decides; `qa.parity.*` defaults to the values above |
| `issues.*` | phase 3 decides | phase 3 decides |
| `pr.required_checks` | phase 4 decides | phase 4 decides |
| `persona.name` | phase 5 decides | phase 5 decides |

**Validation** (`mroom config validate`, and before every `get`):

- A missing required key fails with its name and an example line; a wrong type fails with the key's name. Types:
  string, whole number ≥ 1 (`qa.max_envs`, `qa.ttl_days`), list of strings, table of strings
  (`app.build.frontend_env`), or one of a fixed set (`app.package_manager`: npm | pnpm; `issues.tracker`:
  linear | none; each `qa.parity.*` key: the values listed above).
- `app.name` matches `[a-z][a-z0-9_]{0,31}`, since it is built into database names and Redis prefixes.
- `tests.database_pattern` contains `{slug}`, so each worktree gets its own database.
- `issues.url` contains `{id}`.
- `issues.id_pattern` compiles as a **Python** regular expression (`re`), not POSIX ERE; patterns used by shell
  tools later must stay in the common subset.
- An unknown key warns (with a close match, if any) and is ignored; it never fails.

### 5.2 Box config (`~/.config/mroom/`)

- `box.env`: `MROOM_BOX_NAME`, `MROOM_FORGE_ORG`, `MROOM_FORGE_SERVER`, `MROOM_REPO_URL`, `MROOM_SITE_API`,
  `MROOM_SITE_WEB`, `MROOM_SLACK_LOG_CHANNEL`, `MROOM_ENV` (local | devbox | review | debug | custom),
  `MROOM_WATCH_MCP` (the MCP servers the watchdog checks: `name=URL` items, each URL with no query, fragment or
  credentials). Box jobs keep their schedule in the host's scheduler (a Forge scheduled job runs
  `mroom job run <name> --every <duration> -- <command>`), so `box.env` holds no job times.
  **Parsed, never sourced**: each file has its own allowed keys.
  Read with `mroom config box [<KEY>]`; `$MROOM_BOX_ENV` overrides the path.
- **Syntax** of `box.env`: `KEY=value` lines, blank lines and `#` comments, nothing else. A value is bare (letters,
  digits and `_ . / : @ % + , = -`), or in single quotes (anything but `'`), or in double quotes (no `"`, `\`, `$`
  or backquote). No `export`, no spaces around `=`, no expansion. A line that breaks these rules, an unknown key or
  a repeated key refuses the whole file; errors name the line and the key, never the value.
- **Per box user.** `~/.config/mroom/` is in the home of the OS user that runs mroom. On a box where every
  developer works as one OS user (Forge's `forge`), there is one `box.env` and it is the box's. With one OS user
  per developer, each user has their own copy; the keys are facts about the box, so the copies must agree, and
  phase 1 decides how they are kept in step (for example `mroom user setup` writing them from one source).
- `secrets/forge-token`, `secrets/slack.env`, `secrets/mcp.env`: mode 600, read by one function each, never printed.
- `environments.toml` (optional): environment names and their rule text, for the banner. The default set is
  `local`, `devbox`, `review`, `debug` with neutral text.

An environment variable named like a `box.env` key (`MROOM_BOX_NAME`, `MROOM_ENV`, ...) overrides that key, and is
validated the same way; this applies to `box.env` keys only. `mroom.toml` has no environment overrides:
`MROOM_CONFIG` only chooses which file is read. Test seams (`MROOM_PROC`, `MROOM_TMUX`, ...) stay environment-only
and undocumented for users.

## 6. Hooks (app repo, `.mroom/hooks/`)

Each hook is an executable, gets its inputs as `MROOM_*` environment variables and the working directory, must be
idempotent, and fails the step when it exits non-zero unless marked optional. mroom ships a default for each, built
from `mroom.toml`; a hook replaces the default, and can call it (`mroom default <hook>`).

| Hook | When | Default |
|---|---|---|
| `site-deploy` | `mroom site pull`, after checkout | composer install, `migrate --force`, `after_deploy`, frontend build with `frontend_env`, restart `daemons` |
| `wt-setup` | `mroom wt new`, after the worktree exists | copy `.env`, composer and package-manager install, create the test database, write `.wt-env` |
| `wt-teardown` | `mroom wt done` | drop the worktree's test databases, clear its Redis keys (prefix-guarded) |
| `test-db-created` | after any test or QA database is created | none (an app might run `CREATE EXTENSION vector` here) |
| `qa-signin` | browser QA needs to sign a persona in | none: the app must provide `php artisan mroom:signin-code <email>` or this hook |
| `qa-fixtures` | each QA deploy, after migrations | `php artisan mroom:qa-fixtures` if it exists |

An app's own hooks (code generation, cache warm-up, test fixtures) live in the app's repository, not in mroom.

## 7. Adapters

Shell function interfaces in `lib/core/`, chosen by config. v1 implements the first column.

| Adapter | Functions | v1 | Later |
|---|---|---|---|
| tracker | `issue_get`, `issue_set_state`, `issue_comment_upsert`, `issue_create`, `issue_find_by_marker`, `issue_owned_by_bot`, `attach_image` | Linear; `none` (notes on the PR, images as artifact links) | GitHub Issues (search over hidden markers must be verified first) |
| chat | `chat_post`, `chat_update`, `chat_mention <github-login>` | Slack (bot token, `chat:write`) | Discord or Teams webhooks |
| errors | `errors_new_since`, `errors_count_for_release`, `errors_crons_failing` | Sentry (org, region from config), optional | |
| host | `host_sites`, `host_site_create`, `host_daemon_*`, `host_jobs_*`, `host_cert_*`, `host_deploy` | Forge v2 (one client: retries, 429, pagination) | |

The agent-facing `forge-api` keeps its guards (writes need `--write`, secret paths need `--secret`, paths pinned to
the configured server) and uses the same client.

## 8. Security model

Invariants, each with a test:

1. **No secret next to PR code.** Jobs that hold secrets check out only the default branch of the app (for
   `mroom.toml` and hooks) and mroom's actions at the pinned tag. PR code runs only in jobs with no secrets, and on
   the box only in a QA site whose `.env` holds credentials for that environment's own resources.
2. **QA provisioning keeps PR code away from every secret:**
   - `qa-plan` (`pull_request`, no secrets): scope the change with path rules, build the frontend from the PR with
     public values only, upload `dist/` and `plan.json` as artifacts. A Claude step that judges whether a user
     could notice the change runs later, in a job with default-branch code, boxed as in 8.5, reading the diff as
     data.
   - `qa-up` (`workflow_run` on qa-plan, environment `qa`, default-branch code only): create the site and
     database, write `.env`, tell **Forge** to deploy the PR branch (the box pulls it; the runner never executes it),
     rsync the `dist/` artifact as data.
   - The Forge token belongs to an account whose only team holds the box (`mroom doctor` warns when the token sees
     another server).
   - Box operations go through a forced-command SSH gate covering `db-create`, `db-drop`, `redis-clear`, `env-sha`,
     `signin-code`, `db-read`, and for the QA services `bucket-create`, `bucket-drop`, `reverb-app-add`,
     `reverb-app-remove`, `mail-read` and `template-load`. No CI key gets a shell on the box. The gate is installed
     from a release by a person.
   - QA sites use Forge site isolation (their own Unix user), so a PR's code cannot read the dev site's `.env`.
3. **Agents never merge, approve, deploy, release, or read secrets.** Settings fragments plus a `PreToolUse`
   `mroom guard` that parses each Bash command and refuses, among others, `gh api` writes to `/merge`, `/reviews`
   with approve, and `/releases`; `gh pr merge`, `gh pr review --approve`, force-push in any form, reading
   `.env*`, `~/.ssh`, `~/.config/gh`, `~/.config/mroom/secrets` through any command. Prefix rules stay as a second
   layer. Release still goes through `gh release create`, which always asks.
4. **Untrusted text is data.** PR text, alert text and issue text are escaped before Markdown, mrkdwn or a check
   summary; payloads go through stdin or files, never argv.
5. **Claude on a runner is boxed.** The sandbox (dedicated users, `env -i`, sudoers allowing exactly the
   wrappers, root-owned inputs), the tool allowlist and the pinned action ship as one locked block; `bwrap-probe`
   and `allowlist-probe` run in mroom's CI on every Claude Code bump.
6. **The read-only data boundary is explicit.** `qa.db_read_allowlist` has no default; browser QA refuses to start
   without it, and a test runs the allowlist against the app's schema.
7. **Shared-box isolation is checked.** `mroom doctor --app` verifies the app honours `DB_DATABASE`,
   `REDIS_PREFIX`, `CACHE_PREFIX`, `SESSION_COOKIE` and the XSRF cookie name, since environments share one box.
8. **Secrets per GitHub environment.** `qa` holds the box and Forge credentials; `persona` (default branch only)
   holds the tracker and chat tokens; `production` (release tags only) holds the deploy credential. None is
   readable from a `pull_request` job.
9. **Each QA environment's services are its own.** Its database, its bucket for each file disk (with its own key)
   and its Reverb app are created and removed through the gate, and `mroom doctor --app` checks that the app uses
   them. Only the gate holds the mail catcher's login; `mail-read` returns mail for `qa.persona_domain` addresses in
   one environment only.

## 9. The app contract

What a Laravel app must have or add, documented in `docs/app-contract.md` and checked by `mroom doctor --app`:

- `GET /up` returns 200, and `app.version_path` (default `/version`) returns `{"release": "v1.2.3", "commit":
  "<sha>"}` with `Cache-Control: no-store`. The deploy writes both values from the code it checked out (`git
  describe --tags --exact-match`, `git rev-parse HEAD`) into a file in the release, never from config set
  separately, so the endpoint reports the code that is running. Queue workers and daemons log the same values when
  they start. With a separate SPA, the frontend build writes them to `version.json`. A deploy waits on these
  (section 10). In a QA environment the PR's own code serves the endpoint, so browser QA reads the deployed commit
  through the gate (`env-sha`) instead.
- Honours the isolation keys in section 8.7; with a separate SPA, also `CLIENT_URL`, `CORS_ALLOWED_ORIGINS` and
  `SANCTUM_STATEFUL_DOMAINS`.
- Uses the same services as production wherever a QA environment can have its own copy (section 8.9): a bucket for
  each file disk on the box's S3-compatible store, a Reverb app on the box's Reverb, and SMTP to the box's mail
  catcher. Any other choice is a *swap*: a driver or service that differs from production. An app whose production
  mailer is an API (Resend, Postmark, SES) swaps to SMTP to reach the catcher; `log` and `local` are swaps too.
  `[qa.parity]` declares each one, and `mroom doctor --app` lists every swap as a known gap from production.
- Migrations are expand/contract across two releases, so the previous release can run on the new schema. This is
  what makes a rollback by tag safe (section 10).
- A Postgres template database. By default (`database = "seeded"`) the app's factories and seeders fill it. A masked
  snapshot (`database = "snapshot"`) is opt-in, and follows these rules:
  - Masking and filtering run in production, as views, and the pull uses a role that can read only those views.
  - Customer rows are left out, so companies and users come from factories. Free text is masked unless it is
    declared public.
  - A test fails when an exported column has no masking decision.
  - The pull runs where PR code never runs (a scheduled job on the default branch, in its own GitHub environment)
    and loads the box's template through the gate (`template-load`).
  - Files are never copied, so rows that point at production files show as missing in QA.
  - Anything in the snapshot can appear in screenshots sent to the model provider and in PR comments, so it must
    hold nothing that may not leave the company.
- An idempotent fixtures command creating persona accounts on `qa.persona_domain`, one per role or state, and a
  persona list the browser agent reads (`php artisan mroom:personas --json` or a committed file).
- A way to sign a persona in: `mroom:signin-code <email>` (for one-time codes) or a password in the persona list.
- A test-database guard that accepts `tests.database_pattern` (mroom ships a `TestCase` snippet).
- A `QA_ENV_TEMPLATE` secret with test-mode keys only.

## 10. CI/CD defaults (measured)

Measured on the pilot app's GitHub Actions in October 2026: a Laravel + Vite monorepo with
~5,400 backend tests over per-domain phpunit suites, a sharded vitest suite and a Pest browser suite.

**Where the time went.** A runner started in 3 to 4 s and service containers in ~30 s. Dependency
installs cost 20 to 37 s per job. The waits came from three things: an apt download of Playwright's
system libraries (19 MB) that a slow Ubuntu mirror served at 27 kB/s in ~1 of 7 runs (2.5 to 12 minutes,
for 6 s of e2e tests); backend shards split by suite name rather than time (one shard 261 s, another
90 s); and caches that only ever existed per PR.

| | Before | After |
|---|---|---|
| Slowest backend shard | mean 301 s, p50 324 s (48 runs) | mean 242 s (4 runs) |
| e2e | mean 298 s, p90 565 s, max 921 s (47 runs) | mean 204 s, max 226 s |
| First push of a PR (cold) | backend p50 273 s, e2e p50 245 s, max 469 s | measured by `tools/ci-first-push.sh` |

**Patterns the CI templates ship:**

1. **Save caches on the default branch, restore them in PRs.** A run restores from its own ref and the
   default branch only, so caches saved by PR jobs help that PR's re-runs and nothing else, and they fill
   the 10 GB store (it was at 10.4 GB with 55 caches over 19 PRs). One warm workflow saves on the
   default branch (lockfile changes, weekly), PR jobs use `actions/cache/restore`. Keys and paths must
   match exactly; editing the warm workflow must run the jobs that restore from it.
2. **Cache apt's downloads for anything apt installs in CI.** Point `Dir::Cache::Archives` at a folder
   outside `$HOME` (so apt still downloads as `_apt`), key it on the lockfile that pins the tool plus the
   ISO week, run `apt-get autoclean` before the weekly save. apt still checks each file against the
   signed index.
3. **Cache the installed `vendor/`, with a fallback key.** On a changed lock the previous `vendor/` is
   restored and `composer install` reconciles it; composer's own download cache is then unnecessary.
4. **Shard by measured time, not by name.** Ship a measuring mode (one job per suite) and record the
   times in the workflow; keep one catch-all shard that excludes the named suites, so a new suite runs.
5. **Know which job names are required checks.** Changing a sharded job's count renames its checks; that
   needs a ruleset change, so templates keep a fixed aggregate check (`test`) that the ruleset requires.
6. **Measure the first push, not re-runs.** Re-runs of one PR are warm by construction.

7. **Reuse the e2e build; build it lighter.** The e2e job built the SPA (60 to 70 s) for 6 s of tests.
   One composite action keys the build on everything it reads (frontend source minus tests, public
   assets, `index.html`, config, env files, lockfile, the action itself, Node's major.minor), restores
   it, builds on a miss, and saves it from a warm workflow on the default branch. A PR that leaves the
   frontend alone (4 in 10) restores it: e2e 129 to 152 s, from 181 to 226 s. `build:e2e` drops source
   maps but stays minified: `vite build` 27.6 s, from 51 s (36 s unminified, so minifying is faster as
   well as closer to production).

**The deploy (CD).** The usual deploy fires the host's deploy hook, sleeps, and checks that a health route
answers. It passes even when the deploy failed on the host, and the hook deploys the branch tip, which may not be
the tag. The deploy template adds three patterns instead:

8. **Deploy the release tag, never the branch tip,** so every part of the app ships the same commit. The deploy
   points a `release` branch at the tag's commit, and the host deploys that branch (on Forge, Quick Deploy watches
   `release`). Only the deploy workflow pushes `release`, under one concurrency group, and `mroom guard` refuses
   it to agents. Forge's deploy trigger also accepts a commit (`forge_deploy_commit`), but only passes it to the
   deploy script, which would have to check it out.
9. **Wait for the new release, not for a fixed time.** A maintained `deploy-verify` action polls
   `app.version_path` (and a separate SPA's `version.json`) with a cache-busting query until it reports the tag's
   commit three times in a row, and fails after a time limit (10 minutes by default). `/release` reads the same
   endpoint to list what will ship: the commits between the live release and the new tag.
10. **Roll back by tag.** A rollback deploys the previous tag through the same step, started by a person. It is
    safe because migrations are expand/contract (section 9); the old code must also run jobs that the new code
    queued, and the deploy restarts workers and clears caches.

**Next levers, by measured size:** the frontend unit shards (~226 s, fixed by required check names),
service container start (~30 s per job), and runner speed itself, which moved the same shard by ~25%
between runs.

**A control-plane package is not a speed lever.** Replacing Actions with a Laravel package (Horizon-
style, GitHub App webhooks and check runs, executors on a box) gains speed only through warm executors,
which a self-hosted runner gives without replacing anything, and it needs a box sized for 8 or more
parallel jobs and a sandbox per job. Its real value is orchestration: ~700 short glue runs a day and no
hidden-comment state. It stays an open question (section 14), not part of v1.

## 11. Phases

Each phase is usable without the next. From phase 1 on, a phase is done when two things hold (D10):

- **Works:** both `examples/single-app` and `examples/two-folder` run in tests, and, where a box is needed, on a
  real box. Once a phase Works, the next one can start.
- **Moves:** the pilot app adopts the phase (D8), and within 4 weeks the phase's measure from section 1.2 is better
  than its baseline, while every other measure stays at least as good. The record gives the commands, the
  commit and the window. A phase whose measure does not move is reworked before more is built on it.

No real project's name is committed (D8): the apps mroom grew in stay private validation.

QA environments come straight after the box, because they serve requirements 3 and 4 most. Per-PR sites alone are
not new: Laravel Cloud has preview environments, and Laravel Harbor creates them on Forge (D13). What mroom adds is
D6-safe provisioning, a template database per environment, slots on a shared box, and browser QA by an agent.
Phase 2 comes in two steps, so environments work before browser QA depends on them.

| Phase | Contents | Done when |
|---|---|---|
| 0. Skeleton (merged, #1) | repo, LICENSE, NOTICE, README, CI (shellcheck, tests), `mroom config`, `install.sh`, release tagging | **Works:** `install.sh` on a fresh Ubuntu box installs `mroom`, `mroom config get app.name` reads an example |
| 1. Box | `mroom` and `lib/*` generalised (config instead of hard-coded names, slug rules and paths), `forge-api`, Forge client, hooks with defaults, settings fragments, `mroom guard`, plugin hooks (banner, guard, worktree), `mroom init`, box job records (`mroom job run`); a box watchdog (an MCP probe, processes killed for lack of memory, failed box jobs and scheduled workflows, each posted to chat); the `regression` label (a PR that fixes a production problem names the release that caused it, `Breaks: v1.2.3`), so later phases have a baseline | **Works:** a new box is set up from the README, `box.env` and `mroom.toml` alone; no app's name appears in mroom's code. **Moves (4):** fewer box or pipeline failures are noticed by a person before mroom reports them |
| 2a. QA environments | qa-plan (path rules), qa-up, qa-down, qa-reap, the gate and its operations, Forge site isolation, the app contract, `mroom doctor --app`, the template database (seeded, or the opt-in snapshot), the QA services of `[qa.parity]` (section 8.9), `app.version_path`; slots sized from box memory (a memory budget per environment sets `qa.max_envs`) | **Works:** an example app gets `go-<PR>`/`api-<PR>` with its own database, buckets, Reverb app and mail, and the section 8 invariants are tested. **Moves (3):** fewer production problems per release |
| 2b. Browser QA | the runner sandbox (8.5); the plan's Claude step with `blast-radius` (vendored from pstack); the `verify-app` harness (pluggable sign-in) and `qa-engineer` | **Works:** an example app gets a browser QA check on each PR's last commit. **Moves (4):** fewer product PRs reach a person without a needed browser test passing |
| 3. Agent workflow | skills generalised over the tracker adapter and `mroom.toml`; principles vendored; `mroom check size` (a file over 500 lines may not grow, and a static-analysis baseline may not grow), run by the pre-push hook and CI | **Works:** `/implement` takes an issue to a PR on the example app with tracker `none` and with Linear. **Moves (1):** files over 500 lines stop growing, in number and in lines |
| 4. PR checks and CI/CD | conventional title, type labels + release notes, Claude review, review findings, auto-tag (optional); CI templates with the section 10 defaults (cache warming, apt cache, vendor cache, measured shards) and `tools/ci-first-push.sh`; the deploy template (the `release` branch), `deploy-verify` and the `production` environment (section 10, patterns 8 to 10) | **Works:** a repo calling the reusable workflows gets the checks, and a deploy in tests (with a fake host) waits until the live commit matches the tag. **Moves (2):** every release confirms its live commit. First-push CI time stays under 4 minutes (the pilot app already has the section 10 patterns) |
| 5. Persona | PR notes and pings (`pr-status`), alert triage, alarm and guard | **Works:** the example repo gets one note per PR and deduplicated pings; triage files one issue per alert key. **Moves (2):** the time from a release to the first report of a problem it caused falls |

## 12. Where each part comes from

mroom starts from a working machine room in the pilot app, and each part comes over with names, hosts and ids
turned into config:

| mroom | Starts from | What changes |
|---|---|---|
| `bin/mroom`, `lib/*` | the box scripts | config and hooks; one `MROOM_*` family of names; `~/.config/mroom` |
| `lib/core/forge.sh`, `bin/forge-api` | two Forge clients (CI and agent) | merged into one client; guards kept in the CLI |
| `lib/core/chat.sh` | the Slack progress helper | the chat adapter |
| `plugin/skills/*`, `verify-app` | the workflow, principle and QA skills | tracker adapter, `mroom.toml`, neutral examples |
| `plugin/commands/crap.md`, `bin/crap` | the CRAP metric command | the tool comes along |
| `settings/*`, `mroom guard` | the committed permission rules | split into fragments, plus a command parser |
| `templates/hooks/*` | the lean pre-push and pre-commit hooks | driven by config; one hooks path everywhere |
| `actions/qa-*`, workflows | the QA environment scripts and workflows | the provisioning of section 8.2 |
| `actions/pr-status`, `review-findings`, `triage` | the PR status notes, review findings and alert triage | persona name, adapters, constants into config |
| `templates/ci-*`, `deploy-production` | the backend, frontend and end-to-end CI, and the production deploy | placeholders; the deploy points the `release` branch at the tag |
| `actions/deploy-verify` | the deploy's fixed sleep and health ping | waits until `app.version_path` reports the tag's commit |
| pstack sync | the weekly upstream check | keeps mroom's vendored skills current |

Left in the pilot app: its frontend hosting, its translation workflow, its data masking and export (mroom loads the
result; section 9), its fixtures and feature files, and its own teams, channels and people.

## 13. Before publishing

- Trademark search for "mroom" (Mudroom exists) and the npm, PyPI, crates.io and Homebrew name check again.
- Confirm pstack's licence at the pinned commit in `cursor/plugins` and the repository's top-level licence; write
  `NOTICE`. Compare the two principle skills that look truncated with upstream.
- Publish from a fresh history (one commit), and scan it for names, emails, ids and tokens first.

## 14. Open questions

1. Reusable workflows and their scripts: verify that a `workflow_call` workflow can reference composite actions
   at its own ref without the caller repeating the version, or document the one-line pin. Phase 2a (QA
   environments) needs the answer now.
2. Plugins cannot set permissions (to verify): if so, `mroom init` merges the settings fragments into
   `.claude/settings.json`, and `mroom update` re-merges the parts it owns between markers.
3. Forge site isolation for QA sites: confirm it works with per-PR sites, the queue worker and the box gate.
4. A control-plane package (section 10): build it later only for orchestration, not for speed.
5. The bot's GitHub identity: PR notes and checks run as `github-actions`; the persona's Linear and Slack apps are
   per team. Document the one-time setup.
6. QA services (section 8.9): pick the box's S3-compatible store and confirm a key per bucket; confirm the box's
   Reverb can add and remove apps, and how short its restart is if it must restart; decide how the mail catcher
   tells environments apart (a header, or the sender).
