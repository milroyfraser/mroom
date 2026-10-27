# mroom design

**TL;DR:** mroom (Machine Room) is a system for building software with Claude Code agents, for **Laravel + Vite
apps hosted on Laravel Forge, with code on GitHub**. Agents take an issue to a merge-ready, QA'd pull request on a
shared Linux box. Four requirements drive it (section 1), and one rule comes first: PR code never sees a secret that
reaches beyond its own QA environment (D6). mroom is extracted from the machine room of a production Laravel + Vite app (the
pilot app), which adopts it back one phase at a time (D8). It ships as a Claude Code plugin, reusable GitHub workflows and a box CLI. Each app
describes itself in one committed `mroom.toml`, and no mroom script names a company, host, id or channel.

Status: draft, 25 Oct 2026. Phase 0 is done; the pilot app adopted phase 1 on 25 Oct, and its measure is counted until 22 Nov. Phase 2a is under way: GitHub's documentation answers open question 1, and spikes on the pilot app's box, with a review of them, answer question 6 and part of question 3 (D14 to D20). MIT licence. Repository: `milroyfraser/mroom`.

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

- **A shared agent box**: one worktree, test database and Redis prefix per session, with every session signing in
  to Redis as the box's own user (D15); one Claude login per developer, on one GitHub account for the box's
  agents (D22); a dev site served from
  a pushed branch under a lock; resume after a restart; nightly Claude Code updates and worktree clean-up; box
  health (`mroom status`, `mroom doctor`) and a watchdog that reports the box's own failures to chat.
- **An agent workflow**: `/refine` → `/deliver` → `/implement` → stop at a PR in review; `/release` on a person's
  say-so. Principle skills named at the step that needs them.
- **Guardrails**: agents never merge, approve, deploy, release or read secrets; enforced by a command parser,
  not only prefix rules, and gated by GitHub, where only people's approvals count and a person approves each
  deploy (D22).
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
| D14 | The QA file store is Garage, not MinIO | MinIO's free binaries are gone: its download server answers 410 and its repository was archived in April 2026. Garage is one binary whose keys are granted bucket by bucket, which is what a key per environment needs; in the spike, a second environment's key got 403 reading and writing the first one's bucket. Garage has no object ACLs or bucket policies, so public files go through its website endpoint, and an app that sets per-file visibility declares that disk a swap (section 9) |
| D15 | Every client of the box's Redis signs in as an ACL user, and the default user is off. A QA environment's user reaches only keys and channels under its own prefix, and no command that acts on the whole server | Forge site isolation keeps a PR's code out of other users' files, but not out of a Redis with no password: there it could read every environment's data and push jobs onto a queue whose workers run as `forge`. A key pattern limits only the keys a command declares, so the user gets only Redis's own types and functions, none of a module's commands (which may declare fewer keys than they read), and loses the commands among them that flush, watch, list or debug the whole server, or reset its scripts (section 8.9). Agent sessions, worktrees and the dev site run as the box's OS user and share one Redis user, since they can read each other's files anyway. That user still must not flush the QA environments' keys, so it is denied `@dangerous` too, or the QA environments use a Redis database it cannot select |
| D16 | mroom runs one Reverb host for the QA environments, with an app provider that reads its apps from a file | Reverb's default provider reads its apps from config once, when the server starts, so adding an app means a restart. Reverb picks its provider through a Laravel manager, so a provider registered with `ApplicationManager::extend` that reads a file on each lookup adds and removes an environment's app without one, and no environment runs a Reverb process of its own. This comes from Reverb's source; building the host proves it. An environment's public app key comes from its PR number, so qa-plan can build the frontend without secrets, and its secret is random. An app id belongs to one PR only, because a removed app's open sockets stay open until they close |
| D17 | Each QA environment's sites are Forge isolated sites in the home of one Unix user of its own, `<app>_qa_<N>`. The gate puts the PR's code into them as data, so no git credential is on the site, and its nginx config sets `disable_symlinks if_not_owner` | Isolation runs the site's PHP and its queue worker as that user, and an ACL keeps the user out of `forge`'s home; deleting the site removes the user. The spike created the worker with the site user through the API, though Forge's API spec lists only `root` and `forge`, so qa-up reads the new process back and deletes it unless it runs as the site user. A deploy key on the site would let any code there, a dependency's install script included, read the whole repository until someone revoked it, against D6. So qa-up fetches the PR's tree by commit, as data, and the gate unpacks it as the site user, the way `dist/` already arrives. `code-put` replaces the whole tree except `.env` and `storage/`, skips any `.env` in the tarball, and refuses links at `.env`, `storage` and `bootstrap/cache`. QA sites use Forge's standard deployments, because its zero-downtime script clones the repository. nginx runs as `forge` and follows symlinks; without the setting, a PR could link a file in its site to a secret in `forge`'s home and download it |
| D18 | Each QA environment has its own Postgres role, which owns only that environment's database, and no environment's role can connect to any other database | Isolation and D15 do not cover Postgres either: with one shared login, a PR's code could read, change or drop every QA database, the template and the dev site's database. Postgres lets every role connect to every database by default (`CONNECT` for `PUBLIC`), and every new database gets that grant again, since database-level grants are not copied from the template. So `pg_hba.conf` lets a QA role connect only to the database named after it (`sameuser`, for the group of QA roles), with the gate's own role on a line above, since it belongs to the group too, and `db-create` revokes the grant as well. mroom requires 16 or later: before 16, a role that may create roles may also grant itself any role, the administrator ones included, and from 15 `PUBLIC` can no longer create objects in the `public` schema (doctor checks it, since an upgrade or a restore keeps the old permissions). A cloned database's objects keep the template owner, so the template's objects belong to a role that owns nothing else, and `REASSIGN OWNED` hands them to the environment's role. It also moves databases and tablespaces, so the gate refuses to run while that role owns one |
| D19 | Mail is caught by Mailpit. Each environment sends with its own SMTP login, `mail-read` matches mail on the login that sent it, and the gate restarts Mailpit when it adds or removes a login | Tested on the box: Mailpit reads its login file only when it starts, so a new login needs a restart: the gate stops Mailpit, which runs as the box user, and systemd starts it again. Stored mail survives, and a queued mail that fails during the restart is retried when its job allows more than one try (`mroom doctor --app` checks). Tags can be forged: a mail with an `X-Tags` header or a plus address gets the tag it names, so those sources are turned off, and `mail-read` matches the `Username` field, which only a login sets: SMTP, or the API login only the gate holds. A port is free while its server restarts, and any user on the box may take a free port, with the logins apps send to it, so Mailpit listens only on Unix sockets in the box user's own folder, and mroom's mail relay pipes apps' TCP mail to it. systemd holds the relay's port from boot, as root (a socket unit), so it stays held while the relay restarts too; the gate gives a login only while that socket is active on the port, or the relay itself holds it (found in three reviews, 26 Oct). Mailpit and the relay are systemd services that start again however often they stop, each Mailpit running a second before the next restart (3 under a supervisor such as Forge's daemons, which gives up after three quick stops), confined to their own files. A person installs the units as root from a script that holds their text, so root reads no file the box user can write |
| D20 | A Forge token that can add SSH keys, run commands or recipes, read the sudo or database password, edit nginx or deploy scripts, or create daemons or scheduled jobs reaches `forge` or root. Only the `qa` environment holds such a token. The box's token has none of those scopes except nginx, which gives nothing beyond what its users already have as `forge` | Forge's API spec lets a daemon run as `root`; a scheduled job, a recipe and an SSH key take a user of the caller's choice; a deploy script runs as its site's user, which for the dev site is `forge`; and scopes cover the whole account, not one site. qa-up creates workers, so its token reaches root and is guarded by who holds it (sections 8.1, 8.8). Every developer on the box can read the box's token and every agent can use it through `forge-api`, so it keeps reads and site settings, and a person sets up daemons and scheduled jobs with a short-lived token |
| D21 | What root installs comes from a release, never from the box: mroom's root recipe, saved in Forge and run as root, downloads `lib/root-setup` at a release tag, checks it against the SHA-256 that release's README names, and runs it with the box's values. `mroom baseline` only says whether the installed units are that release's | The box user runs agents that may be compromised (8.1), so whatever the box prints may have been changed, and a checklist of unit lines to refuse always misses one that grants root (`AmbientCapabilities=`, `LoadCredential=`, `StandardOutput=file:`, `RuntimeDirectory=`). A Forge recipe runs as root over Forge's own SSH connection, outside the box user's shell, and the box's token holds no recipe scope (D20; even `recipe:view` runs saved recipes). A tag, never a commit, because GitHub serves a fork's commits under the repository's address; the SHA-256 pins the file. `root-setup` reads no file the box user can write and checks `site-op` against the SHA-256 it holds; CI runs it as root in the mail, files and site jobs, and `tests/root-test.sh` checks every unit line against an allowlist. What it trusts is this repository's tags and README, so nothing on the box may write to the repository. One limit stays: systemd, as root, resolves the units' bind paths in the box user's home whenever a service starts (open question 8) |
| D22 | Every session on the box works on GitHub as one account of the agents' own (`github.agent_login`): Write on the app's repository, never maintain or admin, never a developer's account, and the box's only GitHub credential, with no Forge server key on any GitHub account and no developer's login, token or forwarded SSH agent on the box. On GitHub, only people can give an approval that counts or let a deploy run: review from code owners, who are all people (the default branch's `CODEOWNERS`), approval of the most recent push, no ruleset bypass the agents' account holds, and `production` deploying only release tags, each approved by a person (8.8). A profile commits under its developer's name and any other session as the agents' account; chat pings for an agent's pull request go to the author of its first commit | Agents can use every credential their OS user can read, which on a box where every developer works as `forge` is every login there. A developer's login can approve pull requests, so a required approval could be given from the box, and an admin's could lift the branch rules. Write alone is not enough either: GitHub counts the approval of any Write account that did not open the pull request or push to it last, lets an Actions workflow approve one while Actions may approve pull requests, and lets Write publish a release on any commit; code-owner review counts only the people `CODEOWNERS` names, read from the default branch. Forge puts the server's own key on the GitHub account connected to Forge unless "Add server's SSH key to source control providers" is unticked, which gives the box every repository that account reaches. The developer whose session opened a pull request may approve it; whether another developer must is a separate rule. The `gh` login downloads mroom's releases, but nothing on the box may write to mroom's repository (D21) |

## 3. Host requirements

- Box: Linux with `/proc`, GNU coreutils (`stat -c`, `date -d`, `sha1sum`, `base64 -w0`, `timeout`), bash 5, git, jq, curl, python3
  ≥ 3.11 (`tomllib`), tmux, flock, supervisord (Forge's), Postgres ≥ 16 (D18) with a role for the gate that has
  `CREATEDB` and `CREATEROLE`, belongs to the role that owns the QA template's objects (and nothing else), and can
  `SET ROLE` to each environment's role, plus a `pg_hba.conf` rule that lets QA roles reach only their own
  database; Redis ≥ 7 with phpredis, its ACL users in an `aclfile` and the default user off (D15); PHP and
  composer, Node and npm or pnpm, `gh`, and `fs.protected_hardlinks = 1` (Ubuntu's default). Root once, for
  `mroom baseline`.
  Phase 0 needs only Linux, bash 5, python3 ≥ 3.11, jq and git; `install.sh` checks these and names what is missing.
- Installing a release: `install.sh --version vX.Y.Z` downloads it with `gh` when gh is signed in, and with plain
  `curl` otherwise.
- Forge: one server for the box, a **Forge team that holds only that server**, and tokens from an account in
  only that team. Each token gets only the scopes of the calls its user makes (Forge's API reference names the
  scope of every endpoint). A token that can create daemons or scheduled jobs, or change a deploy script, counts
  as root (D20). Create the server with "Add server's SSH key to source control providers" unticked, or take that
  key off the GitHub account and the box (D22).
- DNS: a wildcard record `*.<zone>` to the box (or a wildcard certificate in Forge).
- QA services (section 9), installed by `mroom baseline`, running as `forge` and listening on localhost only. Browsers
  reach the ones they need through nginx on the box, on host names under the zone, with TLS:
  - Garage (D14) when `qa.parity.files` is `same`. Its S3 API gets a host of its own, `s3.<zone>`, because S3
    signatures cover the host; apps use path-style addressing, so every bucket stays under that host and its
    certificate. Public files go through its website endpoint, on `files.<zone>/<bucket>/<path>`: nginx takes the
    bucket from the path and names it to Garage as a host under an internal root domain, so one certificate
    serves every bucket. Its S3, web and admin endpoints listen only on Unix sockets in a folder only `forge`
    can open, its RPC stays in a network of its own (`PrivateNetwork`), and it runs confined, as a systemd
    service whose unit root installs with mroom's root recipe (D21). Its secrets come from
    `rpc_secret_file` and `admin_token_file`, and `metrics_token_file` closes `/metrics`.
  - mroom's Reverb host (D16) when `qa.parity.broadcast` is `same`, over WebSockets.
  - Mailpit (D19) when `qa.parity.mail` is `catcher`, run as `mailpit --listen unix:<folder>/http.sock:0600
    --smtp unix:<folder>/smtp.sock:0600 --database <file> --smtp-auth-file <file> --smtp-auth-allow-insecure
    --tags-username --tags-disable x-tags,plus-addresses --ui-auth-file <file> --max 0 --max-age 7d`, in a
    folder only `forge` can open, behind mroom's mail relay (`lib/mail-relay`), which pipes each connection
    to the SMTP socket. systemd holds `127.0.0.1:1025` for the relay from boot, as root
    (`mroom-mail-relay.socket`); the relay and Mailpit are systemd services run as `forge`, confined to
    their own files. Root installs the three units with mroom's root recipe (D20, D21): a release's
    `lib/root-setup`, which reads no file the box user can write. Without TLS, Mailpit refuses to start with a
    login file unless plain-text login is allowed, which is safe on the box. By default it keeps only 500 mails
    for all environments together, so `--max 0` lifts that and `--max-age` trims by age.

  Each service's secrets, data and config sit under `forge`'s home, files mode 600 and directories 700, where no
  site user can read them: binaries and data in `~/.local/share/mroom-services`, which an uninstall of mroom
  leaves alone, and logins in `~/.config/mroom/secrets`. mroom commits the SHA-256 of each binary it was tested with, and `mroom baseline`
  refuses any other: Garage publishes no checksums, and Mailpit's only digest is the one GitHub keeps.
- GitHub: a repo with Actions, three environments (`qa`, `persona`, `production`; section 8), a ruleset on the
  default branch that requires review from code owners, a `CODEOWNERS` that names only people, and an account for
  the box's agents with Write (D22).
- Claude: a Claude subscription per developer (Remote Control), a `CLAUDE_CODE_OAUTH_TOKEN` for Actions.

## 4. Repository layout

```
mroom/
  bin/mroom                     front door (today scripts/dev-box/mroom)
  bin/forge-api                 agent-facing Forge CLI (guards: --write, --secret, path pinning)
  lib/                          box commands: wt, site, site-pull, user, keys, baseline, agent-env, memory-preflight,
                                job, watchdog, gate (the forced command CI reaches the box through, 8.2),
                                site-op (the gate's work inside a QA site, as its user, D17), mail-relay (holds
                                the SMTP port for Mailpit, D19)
  lib/core/                     config reader, forge client, chat adapter (Slack), tracker/errors adapters, job
                                records, the watchdog's probes, util, the QA services' pinned builds (pins.txt)
  plugin/                       the Claude Code plugin
    .claude-plugin/plugin.json
    skills/                     refine, deliver, implement, release, forge, blast-radius, correct, verify-app,
                                principle-*, typescript-best-practices (vendored, with LICENSE)
    agents/qa-engineer.md
    commands/clean-review.md, crap.md
    hooks/hooks.json            SessionStart banner, PreToolUse guard, WorktreeCreate/Remove
  actions/                      composite actions: qa-up, qa-down, qa-reap, qa-browser, pr-status, triage,
                                deploy-verify, regression-label, ...
  reverb-host/                  a small Laravel app that runs one Reverb for every QA environment, with an app
                                provider that reads its apps from a file (D16)
  .github/workflows/            reusable workflows (on: workflow_call) that check out mroom at job.workflow_sha
                                and call its actions from there (section 14, question 1), plus mroom's own CI
  templates/                    copied once by `mroom init`: ci-backend, ci-frontend, ci-e2e, deploy-production,
                                dependabot, .mcp.json, CLAUDE.md policy block, mroom.toml, hooks/*
  settings/                     settings fragments: base, laravel-vite, forge, tracker-linear
  examples/single-app/, examples/two-folder/   neutral configs (and, later, hooks) for the two layouts of D1
  tests/                        shell tests (offline, fake PATH tools), fixtures
  install.sh                    copies a release or checkout into ~/.local/share/mroom/<version>, links
                                ~/.local/bin/mroom (and forge-api) to it, checks host requirements
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
frontend_env = { VITE_REVERB_APP_KEY = "env:REVERB_APP_KEY" }   # in QA, mroom sets the key from the PR (D16)
after_deploy = ["config:clear", "route:cache"]   # artisan commands
daemons = ["horizon", "reverb"]          # QA skips reverb: mroom's Reverb host serves it (D16)
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

[github]
agent_login = "<agents-account>"   # the box's one GitHub account (D22); `mroom user setup` refuses any other
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
- `app.name` matches `[a-z][a-z0-9_]{0,31}`, since it is built into database names and Redis prefixes. A Redis
  prefix puts `:` after each part (`shop:`, `shop:qa12:`), a character no name contains, so no app's or
  environment's ACL pattern matches another's keys.
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
| `qa-deploy` | each QA deploy, after the gate unpacks the tree | composer install, `migrate --force`, `after_deploy`; no git and no frontend build, since the frontend arrives as `dist/` (D17) |
| `qa-fixtures` | each QA deploy, after migrations | `php artisan mroom:qa-fixtures` if it exists |

An app's own hooks (code generation, cache warm-up, test fixtures) live in the app's repository, not in mroom.

## 7. Adapters

Shell function interfaces in `lib/core/`, chosen by config. v1 implements the first column.

| Adapter | Functions | v1 | Later |
|---|---|---|---|
| tracker | `issue_get`, `issue_set_state`, `issue_comment_upsert`, `issue_create`, `issue_find_by_marker`, `issue_owned_by_bot`, `attach_image` | Linear; `none` (notes on the PR, images as artifact links) | GitHub Issues (search over hidden markers must be verified first) |
| chat | `chat_post`, `chat_update`, `chat_mention <github-login or commit email>` | Slack (bot token, `chat:write`) | Discord or Teams webhooks |
| errors | `errors_new_since`, `errors_count_for_release`, `errors_crons_failing` | Sentry (org, region from config), optional | |
| host | `host_sites`, `host_site_create`, `host_daemon_*`, `host_jobs_*`, `host_cert_*`, `host_deploy` | Forge v2 (one client: retries, 429, pagination) | |

The agent-facing `forge-api` keeps its guards (writes need `--write`, secret paths need `--secret`, paths pinned to
the configured server) and uses the same client.

## 8. Security model

Invariants, each with a test:

1. **No secret next to PR code.** Jobs that hold secrets check out only the default branch of the app (for
   `mroom.toml` and hooks) and mroom's actions at the pinned tag. PR code runs only in jobs with no secrets, and on
   the box only in a QA site that runs as its own user (D17) and whose `.env` holds credentials for that
   environment's own resources. "PR code" here means code that reaches the box through qa-up; what a developer or
   agent runs in a worktree or on the dev site runs as `forge`, and is trusted as they are, with what `forge`
   holds: on GitHub, only the agents' account (D22).
2. **QA provisioning keeps PR code away from every secret:**
   - `qa-plan` (`pull_request`, no secrets): scope the change with path rules, build the frontend from the PR with
     public values only, upload `dist/` and `plan.json` as artifacts. A Claude step that judges whether a user
     could notice the change runs later, in a job with default-branch code, boxed as in 8.5, reading the diff as
     data.
   - `qa-up` (`workflow_run` on qa-plan, environment `qa`, default-branch code only): create the site and the
     environment's services, write `.env` through the gate (`env-put`, as the site user, so nothing follows a link
     the PR's code left there), fetch the PR's tree by commit (GitHub's tarball, as data) and send it
     and the `dist/` artifact through the gate. The gate records the commit in its own state and unpacks both as
     the site user. Then **Forge** runs the deploy script (the `qa-deploy` hook), which pulls nothing (D17). The
     runner never executes PR code.
   - The Forge token belongs to an account whose only team holds the box (`mroom doctor` warns when the token sees
     another server). It creates workers, so it counts as root (D20), and only `qa` holds it.
   - Box operations go through a forced-command SSH gate covering `db-create` (with the environment's role),
     `db-drop`, `redis-user-add`, `redis-user-remove`, `redis-clear`, `code-put`, `dist-put`, `env-put`, `env-sha`,
     `signin-code`, `user-clean`, `db-read`, and for the QA services `bucket-create`, `bucket-drop`,
     `reverb-app-add`, `reverb-app-remove`, `mail-user-add`, `mail-user-remove`, `mail-read`, `mail-clear` and
     `template-load`. No CI key gets a shell on the box. The gate is installed from a release by a person.
   - Gate operations that touch a site's files or run its code (unpacking in `code-put` and `dist-put`, hashing
     `.env` in `env-sha`, `signin-code` and `user-clean`) run as that site's user. The gate calls `site-op`, a
     root-owned copy of its release's own, through one sudoers rule that lets `forge` run it as any of Forge's
     isolated users and never as root (root installs both with mroom's root recipe, D21). So the gate
     never runs a PR's code or follows its links as `forge`, and `user-clean` needs no root either: a user may
     stop its own processes and delete its own files. `site-op` runs only as a QA site's user, on that
     environment's own sites. The rule still lets `forge`, and so every agent on the box, put code into a QA
     site and run its sign-in command; QA sites hold only QA data, and `forge` can already read every isolated
     site's files on Forge. The commit `env-sha` reports comes from the gate's own
     state, written as `forge` outside the site, never from a file the site can write.
   - QA sites are isolated (D17) and sign in to Redis and Postgres as their own users (D15, D18), so a PR's code
     cannot read the dev site's `.env` or another environment's data, or push jobs onto a queue whose workers run
     as `forge`.
3. **Agents never merge, approve, deploy, release, or read secrets.** Settings fragments plus a `PreToolUse`
   `mroom guard` that parses each Bash command and refuses, among others, `gh api` writes to `/merge`, `/reviews`
   with approve, and `/releases`; `gh pr merge`, `gh pr review --approve`, force-push in any form, reading
   `.env*`, `~/.ssh`, `~/.config/gh`, `~/.config/mroom/secrets` through any command. Prefix rules stay as a second
   layer. Release still goes through `gh release create`, which always asks. These are best effort, and GitHub
   is the gate: the box holds one GitHub identity, the agents' own, which may write the app's repository and
   nothing else, never administers it, and cannot approve its own pull requests; review from code owners, who
   are people, makes every approval that counts a person's; and `production` waits for a person to approve each
   deploy (D22).
4. **Untrusted text is data.** PR text, alert text and issue text are escaped before Markdown, mrkdwn or a check
   summary; payloads go through stdin or files, never argv.
5. **Claude on a runner is boxed.** The sandbox (dedicated users, `env -i`, sudoers allowing exactly the
   wrappers, root-owned inputs), the tool allowlist and the pinned action ship as one locked block; `bwrap-probe`
   and `allowlist-probe` run in mroom's CI on every Claude Code bump.
6. **The read-only data boundary is explicit.** `qa.db_read_allowlist` has no default; browser QA refuses to start
   without it, and a test runs the allowlist against the app's schema.
7. **Shared-box isolation is checked.** `mroom doctor --app` verifies the app honours `DB_DATABASE`,
   `DB_USERNAME`, `REDIS_USERNAME`, `REDIS_PREFIX`, `HORIZON_PREFIX`, `CACHE_PREFIX`, `SESSION_COOKIE` and the XSRF
   cookie name, since environments share one box. `HORIZON_PREFIX` must start with the environment's Redis prefix,
   because Horizon replaces the connection's prefix with its own.
8. **Secrets per GitHub environment.** `qa` (default branch only) holds the box and Forge credentials, which reach root (D20); `persona` (default branch only)
   holds the tracker and chat tokens; `production` (release tags only, each deploy approved by a person other
   than the one who started it) holds the deploy credential, since Write can tag any commit (D22). None is
   readable from a `pull_request` job.
9. **Each QA environment's services are its own.** Its database and the role that owns it (D18), its app key, its
   Redis user (D15), a bucket with its own key for each file disk, its Reverb app (D16) and its mail login (D19)
   are created and removed through the gate, and `mroom doctor --app` checks that the app uses them.
   - The Redis user gets Redis's own data types and the functions an app needs, never `@all`, for keys and
     channels under the environment's prefix only, and loses the commands among them that flush, watch, list,
     count or debug the whole server or reset its scripts: for example `reset on #<sha256> ~shop:qa12:*
     &shop:qa12:* +@keyspace +@string +@hash +@list +@set +@sortedset +@stream +@bitmap +@hyperloglog +@geo
     +@pubsub +@scripting +@transaction +@connection -@dangerous -scan -randomkey -dbsize -client|tracking
     -pubsub|channels -pubsub|shardchannels -pubsub|numsub -pubsub|shardnumsub -pubsub|numpat -function
     -script|flush -script|kill -script|debug`. A module's commands carry only the module's own categories (and
     `@read`, `@write` and the like), so none is given. That matters: Redis checks the keys a command declares,
     and a module command may declare fewer than it reads (Redis 8's `JSON.MGET` and `CMS.MERGE` declare only
     their first key) or none at all (its query engine and time series). The gate refuses to set a user if a
     loaded module puts a command in one of those categories. Naming no module also keeps the `aclfile`
     loadable if a module goes, which a rule such as `-@json` would not, and a server command added later
     stays out unless it joins one of those categories. The rule starts with `reset`, because `ACL SETUSER`
     only adds to a user, so running it again would keep an old password. Users live in an `aclfile` that the
     gate rewrites with `ACL SAVE`, which also keeps `user default off`. The gate refuses to run while the
     default user is on, and saves first, so a Redis that cannot save is refused before a password changes.
     Turning the default user off leaves its open connections signed in, so the rollout closes them
     (`CLIENT KILL USER default`).
   - One Redis keeps environments' data apart, not their load: a long script or a large write from one PR slows
     every environment and the dev site. `SCRIPT DEBUG`, which would stop the server, is withheld.
   - `redis-clear` runs `SCAN` and `UNLINK` inside Redis, one slice of the keyspace per call, so no key name
     leaves it: a name may hold a newline, and read back line by line it would become two, one of them
     outside the prefix.
   - Each environment's file disk has a bucket of its own on the box's Garage, and a key that reaches that bucket
     alone, made new on every `bucket-create`; only the gate holds Garage's admin token, and only `forge` can
     reach its endpoints, Unix sockets in its own folder. Teardown (`bucket-drop`) finds the environment's
     buckets and keys by name, deletes the keys, and empties and deletes each bucket, with a key made for
     that alone.
   - What root installs (`site-op`, its sudoers line and the services' systemd units) comes from a release:
     mroom's root recipe runs `lib/root-setup` at a tag, checked against the SHA-256 that release's README
     names, and nothing `mroom baseline` prints is run as root (D21).
   - Only the gate holds the mail catcher's API login, and only `forge` can reach its API, a Unix socket in its
     own folder. `mail-read` returns mail sent with one environment's login to `qa.persona_domain` addresses
     alone, and teardown deletes that environment's mail (`mail-clear`). The SMTP port apps send their logins
     to is held by systemd from boot, as root, also while the relay restarts, so no site user can take it;
     `mail-user-add` gives a login only while the listener on `127.0.0.1` at that port is the socket, active
     as systemd reports it, or the relay itself.
   - Before qa-down deletes a site, `user-clean` stops the site user's processes and removes its files outside
     its home (in `/tmp`, `/var/tmp`, `/dev/shm`, `/var/crash`, `/run/lock` and `/dev/mqueue`), its System V IPC
     objects and its crontab, as that user, since the next user can be given the same UID. qa-down deletes the
     site's daemons first, since supervisor restarts what is killed. PHP-FPM's master does the same for its pool's
     workers, so they are stopped once, which ends any request in flight, and their fresh replacements stop when
     Forge deletes the site, right after; a request in that gap could still leave a file.
   - `mroom doctor` checks the box: the default Redis user is refused; no QA role can reach another database, and
     `PUBLIC` can neither connect to the QA databases, the template or the dev site's database nor create in their
     `public` schema; each GitHub environment keeps its branch rule; each QA site's nginx config, set from an nginx
     template when the site is created, has `disable_symlinks if_not_owner`; each QA worker runs as its site's
     user; `/home/forge` keeps its `group:isolated:---` entry; sshd refuses the isolated group (`DenyGroups
     isolated`), so a PR's code cannot add a key and log in, and forwards no SSH agent (`AllowAgentForwarding
     no`), so a developer's keys never reach a session; each PHP-FPM socket admits only its own site and nginx;
     `fs.protected_hardlinks` is 1; and on GitHub (D22), `gh auth status` lists one account, the agents', with
     push on the app's repository but neither maintain nor admin, no key in `~/.ssh` signs in as any other
     account, no checkout's remote holds a token, the default branch's ruleset requires code-owner review with
     no bypass for the agents' account, and `production` has required reviewers.

## 9. The app contract

What a Laravel app must have or add, documented in `docs/app-contract.md` and checked by `mroom doctor --app`:

- `GET /up` returns 200, and `app.version_path` (default `/version`) returns `{"release": "v1.2.3", "commit":
  "<sha>"}` with `Cache-Control: no-store`. The deploy writes both values from the code it checked out (`git
  describe --tags --exact-match`, `git rev-parse HEAD`) into a file in the release, never from config set
  separately, so the endpoint reports the code that is running. Queue workers and daemons log the same values when
  they start. With a separate SPA, the frontend build writes them to `version.json`. A deploy waits on these
  (section 10). In a QA environment the PR's own code serves the endpoint, so browser QA asks the gate instead:
  `env-sha` reports the commit the gate recorded when it unpacked the tree (D17). The gate also writes the version
  file, `version.json` in the backend with `"release": null`, since a tarball has no git history.
- Honours the isolation keys in section 8.7; with a separate SPA, also `CLIENT_URL`, `CORS_ALLOWED_ORIGINS` and
  `SANCTUM_STATEFUL_DOMAINS`.
- Uses the same services as production wherever a QA environment can have its own copy (section 8.9): a bucket for
  each file disk on the box's Garage (D14), an app on mroom's Reverb host (D16), and SMTP to the box's mail catcher
  with the environment's own login (D19). Any other choice is a *swap*: a driver or service that differs from production. An app whose production
  mailer is an API (Resend, Postmark, SES) swaps to SMTP to reach the catcher; `log` and `local` are swaps too.
  `[qa.parity]` declares each one, and `mroom doctor --app` lists every swap as a known gap from production.
- Sets each file disk's endpoint to the store's public host, with path-style addressing, not an internal host
  plus a `temporary_url`: S3 signatures cover the host, and Laravel swaps in `temporary_url` after signing, which
  breaks the URL.
- Runs nothing in QA that the environment's Redis user is refused (D15): `cache:clear` and `optimize:clear` (on a
  Redis store they run `FLUSHDB`), or `cache:prune-stale-tags` and `horizon:clear-metrics` (they use `SCAN`).
  phpredis reports a refused `FLUSHDB` as success, so `mroom doctor --app` looks for these in the deploy steps and
  the schedule. The gate's `redis-clear` clears one environment's keys.
- Runs from GitHub's tarball of the PR's commit (D17): there is no `.git` folder, files marked `export-ignore`
  are left out, LFS files are pointers unless the repository includes LFS objects in its archives, and git
  submodules are missing.
- Installs only from public package registries in QA, since no registry credential reaches the site or qa-plan
  (question 7).
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
- A `QA_ENV_TEMPLATE` secret with third-party test-mode keys only. It holds no credentials for anything on the box
  and no app key: mroom writes each environment's own (section 8.9). Its test-mode keys are shared by every
  environment (section 14, question 7).

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
| First push of a PR (cold) | backend p50 273 s, e2e p50 245 s, max 469 s (6 and 7 PRs) | backend p50 262 s, e2e p50 151 s, max 210 s (12 and 15 PRs) |

First pushes after the change were measured on 27 Oct 2026 with `tools/ci-first-push.sh`, over every PR opened
since cache warming merged on 23 Oct whose first push ran tests: the slowest backend shard mean 250 s, p90
275 s, max 285 s (before: mean 283 s, p90 325 s, max 339 s); e2e mean 165 s, p90 209 s, max 210 s (before:
mean 267 s, p90 293 s, max 469 s). Every e2e first push restored its four dependency caches (`vendor`,
`pnpm-store`, `playwright`, `playwright-debs`), and the apt step took 13 to 30 s. The 8 in 15 that left the
frontend alone also restored the e2e build (pattern 7) and took 123 to 151 s; the others took 178 to 210 s.

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
   `release`). Only the deploy workflow pushes `release`, under one concurrency group: a ruleset on `release`
   lets only the deploy key held in `production` push it, since the agents' account has Write (D22), and
   `mroom guard` refuses it to agents. The deploy refuses a tag whose commit is not on the default branch.
   Forge's deploy trigger also accepts a commit (`forge_deploy_commit`), but only passes it to the deploy
   script, which would have to check it out.
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
| 2a. QA environments | qa-plan (path rules), qa-up, qa-down, qa-reap, the gate and its operations, Forge site isolation with code delivered as data (D17), a Redis user (D15), a Postgres role (D18) and an app key per environment, the app contract, `mroom doctor --app`, the template database (seeded, or the opt-in snapshot), the QA services of `[qa.parity]` (section 8.9; D14, D16, D19) with pinned checksums (section 3), `app.version_path`; slots sized from box memory (a memory budget per environment sets `qa.max_envs`) | **Works:** an example app gets `go-<PR>`/`api-<PR>` with its own database and role, app key, Redis user, buckets, Reverb app and mail login, and the section 8 invariants are tested. **Moves (3):** fewer production problems per release |
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
| `reverb-host/` | the dev site's Reverb daemon | one Reverb for every QA environment, its apps read from a file (D16) |
| `mroom baseline` (QA services) | Garage and Mailpit as run in the phase 2a spikes | pinned binaries with committed checksums; each service's secrets under `forge`'s home |
| `actions/pr-status`, `review-findings`, `triage` | the PR status notes, review findings and alert triage | persona name, adapters, constants into config |
| `templates/ci-*`, `deploy-production` | the backend, frontend and end-to-end CI, and the production deploy | placeholders; the deploy points the `release` branch at the tag |
| `actions/deploy-verify` | the deploy's fixed sleep and health ping | waits until `app.version_path` reports the tag's commit |
| pstack sync | the weekly upstream check | keeps mroom's vendored skills current |

Left in the pilot app: its frontend hosting, its translation workflow, its data masking and export (mroom loads the
result; section 9), its fixtures and feature files, and its own teams, channels and people.

What the pilot's scripts learned after this table was drawn, which their ports keep:

- **GitHub (D22; `mroom user`, phase 1).** A profile (a developer's own Claude folder, commit author and Remote
  Control daemon, all as the box's one OS user) gets no GitHub login of its own, and `mroom user setup` refuses
  unless the box's `gh` login is `github.agent_login`. An older profile's own `gh` folder (`GH_CONFIG_DIR`) comes
  out of its settings; once the profile's daemon has restarted without it, setup deletes the folder and the token
  in it, and tells the developer to revoke that token on GitHub, since any session could have copied it.
  `mroom status` flags a daemon still started with such a folder. A session outside any profile commits as the
  agents' account.
- **Forge's server key (D22).** Forge had put the box's server key on the GitHub account connected to it, so
  every session could push as that account over SSH. The key came off the account and the box, and git over SSH
  now offers only the agents' key (`IdentitiesOnly`).
- **Pings (`actions/pr-status`, phase 5).** Chat pings for an agent's pull request go to the author of its first
  commit, since a profile commits under its developer's name. The chat user map, a file in the app's repository
  keyed by GitHub login or commit email, names that author's chat user: by the commit's GitHub account when the
  map has it, else by its email. Later commits, such as a reviewer's committed suggestion or a bot's fix, never
  count. A first commit the map knows by neither, such as the agents' own or a bot's, pings the developer the map
  names for the agents' account.
- **Forge logs (`mroom user`, phase 1).** The box's Forge token holds no scope for reading a background process's
  log, and Forge answers 403. Setup says the log is unreadable and goes on, instead of stopping under `set -e`
  before the profile clean-up above; the port tests that clean-up with an unreadable log.
- **The dev site's lock (`mroom site`, phase 1).** A pull that stops before it changes the served checkout (it
  finds uncommitted changes there, or cannot fetch or switch to the branch) gives back a lock it took, never one
  the pull's owner held before it started. An owner's expired lock is taken anew, not renewed, so such a pull
  gives it back too. A failure after the switch keeps the lock, since the site may be half switched.

## 13. Before publishing

- Trademark search for "mroom" (Mudroom exists) and the npm, PyPI, crates.io and Homebrew name check again.
- Confirm pstack's licence at the pinned commit in `cursor/plugins` and the repository's top-level licence; write
  `NOTICE`. Compare the two principle skills that look truncated with upstream.
- Publish from a fresh history (one commit), and scan it for names, emails, ids and tokens first.

## 14. Open questions

1. Reusable workflows and their scripts: verify that a `workflow_call` workflow can reference composite actions
   at its own ref without the caller repeating the version, or document the one-line pin. **Answered:** GitHub's
   contexts reference gives `job.workflow_repository` and `job.workflow_sha`, the repository and commit of the
   workflow file that defines the current job, which in a reusable workflow is the called one. mroom's reusable
   workflows check out `job.workflow_repository` at `job.workflow_sha` and run their composite actions from that
   checkout, so the caller pins mroom once. Neither property exists on GitHub Enterprise Server.
2. Plugins cannot set permissions (to verify): if so, `mroom init` merges the settings fragments into
   `.claude/settings.json`, and `mroom update` re-merges the parts it owns between markers.
3. Forge site isolation for QA sites: confirm it works with per-PR sites, the queue worker and the box gate.
   **Partly answered (D17):** a site created with `is_isolated` and `isolated_user` gets its own user and PHP pool,
   its worker, created through the API, runs as that user, and the user cannot enter `forge`'s home. Still to test:
   whether one site user can read another's files or connect to another's PHP-FPM socket; whether Forge deploys a
   site that has no repository; which user Forge writes a site's `.env` as; and the gate's site operations, once
   the gate is built.
4. A control-plane package (section 10): build it later only for orchestration, not for speed.
5. The bot's GitHub identity: PR notes and checks run as `github-actions`; the persona's Linear and Slack apps are
   per team. Document the one-time setup. (The box's agents push and open pull requests as their own account, D22.)
6. QA services (section 8.9): pick the box's S3-compatible store and confirm a key per bucket; confirm the box's
   Reverb can add and remove apps, and how short its restart is if it must restart; decide how the mail catcher
   tells environments apart (a header, or the sender). **Answered:** Garage, with a key per bucket proven (D14);
   a Reverb host whose provider reads a file, so no restart (D16, from Reverb's source until the host is built);
   and Mailpit, which tells environments apart by the SMTP login that sent each mail, and restarts when the gate
   changes a login (D19).
7. D6 and shared credentials: `QA_ENV_TEMPLATE` gives every environment the same test-mode keys (a payment
   provider's, for example), which reach beyond one environment, and an app with private packages would need a
   registry credential on the site or in qa-plan. Decide whether test mode is the one accepted exception, since it
   holds no real data, or whether each environment gets its own keys where the provider allows it; and whether
   private registries are supported at all (section 9 says not for now).
8. The services' bind paths (D21): systemd resolves each `BindPaths=` and `BindReadOnlyPaths=` source as root,
   following links, before a service drops to the box user, and those sources sit in the box user's home. So
   the box user can bind into its own service a folder it could not reach through a parent it cannot enter,
   and read what is world-readable there. Moving every bind source under a folder root owns, with only the
   leaves the box user's, closes it; until then the limit is the box user reading such files.
