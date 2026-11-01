# mroom

mroom (Machine Room) is a system for building software with Claude Code agents, for **Laravel + Vite
apps hosted on Laravel Forge, with code on GitHub**. Agents take an issue to a merge-ready, QA'd pull
request on a shared Linux box. It has four requirements:

1. Maintain human-readable, clean code
2. Release with confidence based on clarity
3. Fast, no-surprise CI/CD workflow by bringing everything closer to production
4. Do everything AI/agent can before involving a human

One rule comes first: PR code never sees a secret that reaches beyond its own QA environment.

It will ship as a Claude Code plugin (skills, agents, commands, hooks), reusable GitHub workflows with
composite actions, and a box CLI with an installer. Each app describes itself in one committed
`mroom.toml` and a few hook scripts; each box in `~/.config/mroom/`. Nothing in an mroom script names a
company, host, id or channel.

The full design, including how each requirement is measured, is in [docs/design.md](docs/design.md).

## Status

**Pre-alpha, phase 1 of 6 under way.** What exists today: the skeleton (the `mroom` front door,
`mroom config`, the one reader of `mroom.toml` and `box.env`, `install.sh`, tests and CI) and the first
part of phase 1: the [box watchdog](#box-watchdog) with its job records, the
[regression label](#regression-label) check with its measures, and the
[guard, the plugin's skeleton and the settings fragments](#guard-and-settings); from phase 3, the
[tracker and error-tracker adapters](#tracker-and-error-tracker) and the [workflow skills](#workflow-skills);
ahead of its phase, part of phase 4: the [Claude review](#claude-review) and its
[review findings](#review-findings) check; and, from phase 5, [alert triage](#alert-triage) with its alarm and
its guard, and ahead of it the persona's [PR status](#pr-status) notes and pings. Every other command prints
`not yet: phase N`. The phases and what each delivers are in
[section 11 of the design](docs/design.md#11-phases). Expect breaking changes in every `0.x` release.

## Host requirements

What phase 0 needs on the box; `install.sh` checks each and says what is missing:

- Linux (macOS is not a supported box)
- bash 5 or newer
- python3 3.11 or newer (for `tomllib`; no other Python packages)
- jq and git

`mroom job` also needs flock; the box watchdog needs curl, flock and `timeout` (coreutils), and `gh`
signed in for the workflow check. Each names any missing tool when it starts. Later phases need more
(tmux, Postgres, Redis, PHP, Node, a Forge server; see
[section 3 of the design](docs/design.md#3-host-requirements)). On Ubuntu 24.04:

```bash
sudo apt-get install -y python3 jq git
```

## Install

From a checkout (installs exactly what is checked out):

```bash
git clone git@github.com:milroyfraser/mroom.git && cd mroom
./install.sh
```

A tagged release (the way a shared box should run it, so switching branches in a checkout never changes
the installed mroom):

```bash
./install.sh --version v0.4.0
```

Either way mroom lands in `~/.local/share/mroom/<version>/` and `~/.local/bin/mroom` links to it. Make
sure `~/.local/bin` is on your `PATH`. Running `install.sh` again replaces that version in place.
`--prefix <dir>` installs under another folder, `--force` replaces a `~/.local/bin/mroom` that some other
tool put there, and `./install.sh --uninstall` removes every installed version and the link (it keeps
`~/.config/mroom`). `--version` downloads with `gh` when it is signed in, and with `curl` otherwise.

```bash
mroom version            # 0.4.0
mroom version --source   # the release or checkout it was installed from
mroom help
```

## Configuration

### `mroom.toml` (in the app's repository)

Each app commits one `mroom.toml` at its root. `mroom config` finds it by walking up from the current
folder, or reads `$MROOM_CONFIG` when that is set. Two complete examples:

- [examples/single-app/mroom.toml](examples/single-app/mroom.toml): one Laravel app with Vite inside it
- [examples/two-folder/mroom.toml](examples/two-folder/mroom.toml): a Laravel API and a Vite SPA in two folders

The smallest valid file:

```toml
[app]
name = "shop"
```

Only `app.name` is required in phase 0. Later phases make more keys required as the commands that read
them arrive (for example `qa.zone` and `qa.db_read_allowlist` with QA environments in phase 2).
`mroom config keys` lists every key, its type, whether it is required, and mroom's default where it has one:
`app.version_path` (`/version`), `qa.max_envs` (5) and `qa.env_memory_mb` (1024). `get` gives that default when
the file leaves the key out, whatever `--default` says, so every reader agrees.

```bash
mroom config get app.name                  # shop
mroom config get app.build.daemons         # one item per line
mroom config get app.build.daemons --json  # ["horizon", "reverb"]
mroom config get app.build --json          # a whole table, as JSON
mroom config get app.php --default 8.4     # a fallback when the key is not set
mroom config get errors.org --optional     # nothing when the key is not set
mroom config get app.version_path          # /version, mroom's default, when the file has none
mroom config validate                      # check the whole file
mroom config path                          # which mroom.toml was found
mroom config keys                          # every key the schema knows
```

Strings print raw, lists one item per line, tables of strings as `KEY=value` lines, and `--json` prints
JSON. `--default` takes the key's type: a number for a number, JSON for a list or table
(`--default '[]'`). `--optional` prints nothing (`null` with `--json`) and exits 0 for a key that is
not set. A missing required key fails with its name and an example line; a wrong type fails
with the key's name (`get` reports only errors that concern the key it reads, `validate` reports all).
An unknown key is ignored, and `validate` warns about it, with a suggestion when it looks like a typo.
Exit codes: `0` success, `1` a config error or a key that is not set, `2` a usage error.

### `box.env` (on the box)

Facts about the box itself live in `~/.config/mroom/box.env` (or `$MROOM_BOX_ENV`), never in the app
repository:

```bash
MROOM_BOX_NAME=box-one
MROOM_ENV=devbox
MROOM_SITE_WEB=go.example.dev
```

The file is **parsed, never sourced**: only `KEY=value` lines with an allowed key, blank lines and `#`
comments are accepted, with no leading whitespace, no `export` and no spaces around `=` (trailing
whitespace and CRLF line endings are fine). Values are plain, or quoted with `'...'` or `"..."` (no `$`,
backquotes or backslashes inside double quotes). Any other line, an unknown key or a repeated key refuses
the whole file; error messages name the line and key, never the value. An explicit `$MROOM_BOX_ENV` must
exist; only the default file may be missing. An environment variable named like an allowed key overrides
the file, and is held to the same rules (no `$`, quotes, backslashes or control characters).

```bash
mroom config box MROOM_ENV     # devbox
mroom config box               # every key that is set
mroom config path --box        # where box.env is read from
```

Allowed keys today: `MROOM_BOX_NAME`, `MROOM_FORGE_ORG`, `MROOM_FORGE_SERVER`, `MROOM_REPO_URL`,
`MROOM_SITE_API`, `MROOM_SITE_WEB`, `MROOM_SLACK_LOG_CHANNEL`, `MROOM_ENV`
(`local | devbox | review | debug | custom`), and `MROOM_WATCH_MCP` (the watchdog's MCP servers: see
below). Secrets never go in `box.env`; they live in their own mode-600 files in
`~/.config/mroom/secrets/`.

## Box watchdog

The box reports its own failures to its log channel, so a person is not the first to find them. Every 10
minutes `mroom watchdog run` checks:

- **MCP servers** listed in `MROOM_WATCH_MCP`. A server is up when an MCP `initialize` request gets a
  JSON-RPC answer, or a 401 or 403 (it answered and wants a login). Anything else is a failure: no answer, a
  redirect, a page that is not JSON-RPC, a 404, a 5xx.
- **Memory**: processes the kernel killed for lack of memory (`oom_kill` in `/proc/vmstat`), and restarts
  of the box. It names the processes when the box user may read the kernel log (the `systemd-journal` or
  `adm` group).
- **Disk**: a filesystem holding `/` or the home folder that is 90% full or more.
- **Box jobs** run through `mroom job run`: a failed last run, no finished run within twice its `--every`,
  or a record it cannot read.
- **Scheduled workflows** of the repository in `MROOM_REPO_URL`, once an hour through `gh`: a workflow
  that still exists and is switched on and whose newest finished scheduled run failed (cancelled and
  skipped runs do not count), among the repository's newest 1,000 scheduled runs. When `gh` fails, the
  check itself is reported; a workflow that was failing stays failing until a run succeeds, or until it
  is deleted or switched off.

It posts a failure when two checks in a row have seen it (so one slow answer posts nothing), once more
when it is over (`✅ … OK again after 3h 12m`), and an event (a kill, a restart) at once. A message Slack
did not take waits for the next run, with Slack's reason in the run's output; at most 50 wait, and when
more do, the oldest go and one line says how many.

**Set it up.** In `~/.config/mroom/box.env`:

```bash
MROOM_BOX_NAME=box-one
MROOM_SLACK_LOG_CHANNEL=C0123LOG
MROOM_REPO_URL=git@github.com:example/shop.git
MROOM_WATCH_MCP='app=https://api.example.dev/mcp docs=https://docs.example.dev/mcp'
```

Each `MROOM_WATCH_MCP` item is `name=URL`, or a bare URL named by its host. A name is lowercase letters,
digits, `_` and `-`, at most 40, and each server needs its own. A URL is plain characters with no query,
fragment or credentials; a key in its path is fine, because the watchdog keeps URLs off command lines and
shows only the host in messages. The Slack bot needs `chat:write` and an invitation to the channel; its
token goes in `~/.config/mroom/secrets/slack.env` as one line `SLACK_BOT_TOKEN=xoxb-…`, owned by the box
user with mode 600 (the watchdog refuses it otherwise). Without chat, the run prints its messages and
keeps them for when chat works. Then try it:

```bash
mroom watchdog run --dry-run       # checks everything; prints what it found and what it would post
```

Schedule it as a Forge scheduled job, as the box user (`forge`), with the custom cron `*/10 * * * *`.
Cron's `PATH` leaves out `~/.local/bin`, where `mroom` and often `gh` live, so run it through a login
shell, which reads the user's own `PATH`, and name `mroom` by its full path:

```bash
env HOME=/home/forge bash -lc '/home/forge/.local/bin/mroom job run watchdog --every 10m -- /home/forge/.local/bin/mroom watchdog run'
```

The watchdog cannot report that it stopped itself, so give it a heartbeat: put a heartbeat URL (a Forge
scheduled job's heartbeat, or any monitor that alerts when it is not called) in
`~/.config/mroom/secrets/heartbeat.url`, mode 600, and each finished run calls it.

```bash
mroom watchdog status              # what is failing now; exits 1 while something fails or it has stopped
mroom watchdog report --since 30d  # the failures of that time (also those that started earlier and were
                                   # still going), how long each lasted, and the events
mroom job list                     # each box job's last run, exit code and state
```

**Box jobs.** Wrap each scheduled job in `mroom job run <name> --every <duration> -- <command>`, through a
login shell under cron, as above. It appends the output to `~/.local/state/mroom/jobs/<name>.log`,
records when the run started and ended and its exit code, exits with that code, and refuses to overlap a
run of the same job still going. A job name is lowercase letters, digits and `-`, at most 40. To stop
watching a job that no longer runs, delete its `jobs/<name>.json`.

The watchdog keeps its state and its record in `~/.local/state/mroom/` (or `$XDG_STATE_HOME/mroom/`),
readable only by the box user: `watchdog.json`, and `watchdog.log` with one JSON line for each failure's
start and end and each event. Its MCP check sends no login, so it finds servers that fail or vanish, not
an expired login.

## Memory preflight

`mroom memory-preflight <MB> [<what>]` stops work the box cannot hold before it starts, since the kernel ends a
build that runs out of memory half way, with whatever it had done left as it was. It exits 1, saying why, when
the box's RAM available and free swap (`/proc/meminfo`) hold less than `<MB>` more, 0 otherwise, and 2 for a
usage error;
`MROOM_SKIP_MEMORY_CHECK=1` skips it, and a host without a readable `/proc/meminfo` skips it with a note.

```bash
mroom memory-preflight 4096 "the frontend build" && pnpm build
```

## Doctor

`mroom doctor` says whether the box is as mroom needs it, and `mroom doctor --app [<dir>]` also whether an app's
mroom setup fits the box (design 8.7, 8.9 and 9). Run it as the box user, on the box: after setting the box up,
after an upgrade, and whenever the app's `mroom.toml` or its workflow pins change. Each check prints a line,
`ok`, `warn` or `fail`, and under a `warn` or a `fail` the fix. It exits 1 when a check fails (a `warn` passes),
2 for a usage error. It changes nothing and prints no secret: it reads the gate's secret files only to see that
they are there, mode 600 and complete, and signs in to Postgres and Redis as the gate to read settings, never data.

```bash
mroom doctor                     # the box
cd ~/shop && mroom doctor --app  # the app whose mroom.toml is found from here, and the box against it
```

With `--app`, the app's checks:

- **config**: `mroom.toml` validates (`mroom config validate`); an unknown key warns. The rest of the app's checks
  wait until it does. Without `qa.zone` the app has no QA environments, and the QA checks are skipped.
- **workflow qa-plan, qa-up, qa-down, qa-reap**: a workflow in `.github/workflows` calls each of mroom's QA
  workflows, pinned to the release tag the box runs, and passes by name the secrets it takes. A pin newer than the
  box says to upgrade the box first, since the box goes before the pins; one older, or a branch or a commit, says
  to pin the box's tag. **pins**: any other use of mroom's workflows or actions is pinned to that tag too.
- **parity**: each `[qa.parity]` value that is not production's service, a swap, warns as a known gap.
- **sockets**: with `broadcast = "same"` and a frontend, `app.build.frontend_env` maps the four `VITE_REVERB_*`
  values Laravel Echo reads (a warn: a frontend may open no sockets).
- **redis-commands**: no `app.build.after_deploy` command, `.mroom/hooks/qa-deploy` line or scheduled command
  (`routes/console.php`, `app/Console/Kernel.php`, `bootstrap/app.php`) runs `cache:clear`, `optimize:clear`,
  `cache:prune-stale-tags` or `horizon:clear-metrics`, which the environment's Redis user is refused and phpredis
  reports as done.
- **isolation**: the backend reads every setting qa-up sets to keep environments apart: `DB_DATABASE`,
  `DB_USERNAME`, `REDIS_USERNAME`, `REDIS_PREFIX`, `CACHE_PREFIX`, `SESSION_COOKIE`, `SESSION_DOMAIN`,
  `XSRF_COOKIE_NAME`, `HORIZON_PREFIX` when the app has Horizon, and with a frontend of its own `CLIENT_URL`,
  `CORS_ALLOWED_ORIGINS` and `SANCTUM_STATEFUL_DOMAINS`. A config file the app has not published leaves Laravel's
  (or the package's) own, which reads its keys; one it has published must read them itself.
- **health**: the backend has `/up` and `app.version_path` among its routes (a warn: a search can miss a route).

The box's checks, for what the app's `mroom.toml` needs with `--app`, or for the box as it is without:

- **box.env** reads; **names**: `MROOM_APP_NAME`, `MROOM_QA_ZONE`, `MROOM_QA_BACKEND_DIR` and
  `MROOM_QA_PERSONA_DOMAIN` are `mroom.toml`'s `app.name`, `qa.zone`, `app.backend_dir` and `qa.persona_domain`,
  `MROOM_QA_TEMPLATE` is set (and is `qa.template_database` when the file has one), and `MROOM_QA_PHP` runs
  `app.php`. A box with no `MROOM_APP_NAME` has no QA gate, and its checks are skipped.
- **db-read**: `MROOM_QA_DB_READ` holds the same entries as `qa.db_read_allowlist`, in any order; it names those
  only in one or the other. With no `qa.db_read_allowlist`, an `MROOM_QA_DB_READ` warns.
- **gate-keys**: a key in `~/.ssh/authorized_keys` is forced to `mroom gate provision`, each gate key is
  `restrict`-ed and forced to an mroom that runs, with one role alone; a missing `template` key warns, and a missing
  `browser` key warns once the app or the box has an allowlist.
- **secrets**: `pg_service.conf` (with its `[mroom-gate]` service) and `redis-gate.env` are there, mode 600, and
  set their login.
- **postgres**: 16 or later, reached as the gate's role; the gate holds `<app>_qa_objects`, `<app>_qa_envs` and
  `<app>_qa_readers` with `ADMIN OPTION`; the objects role owns no database or tablespace; and `PUBLIC` may connect
  to neither the template nor an environment's database (any other database `PUBLIC` may connect to warns).
  **template**: the template database is loaded, and no load was cut short (a `_next` or `_old` left warns).
- **redis**: 7 or later, reached as the gate's user, with an `aclfile`, and the default user off.
- **site-op**: installed, root's, out of the box user's reach, and this release's.
- **mailpit**, **garage**, **reverb**: each service `[qa.parity]` needs (`mail = "catcher"`, `files = "same"`,
  `broadcast = "same"`) is set up, its login file mode 600, and answers on its socket. Without `--app`, a service
  the box has not set up is left out.
- **memory**: the box's RAM, less `MROOM_QA_RESERVE_MB`, holds `qa.max_envs` environments of `qa.env_memory_mb`;
  fewer warns, none fails.
- **kernel**: `fs.protected_hardlinks` is 1. **sshd**: `DenyGroups isolated` and `AllowAgentForwarding no`,
  read from `sshd_config` and `sshd_config.d/*.conf` outside `Match` blocks (a hint; `sshd -T` as root is the
  answer).

## Forge API

`forge-api` calls the Laravel Forge v2 API of this box, for agents and people. Every call goes to the box's
server (`MROOM_FORGE_ORG` and `MROOM_FORGE_SERVER` in `box.env`), and a path is relative to it:

```bash
forge-api GET sites
forge-api PUT sites/123/nginx --write --data '{"config":"..."}'
forge-api --secret GET sites/123/environment
```

- A path is plain words joined by `/`, starting with a resource name such as `sites`, with an optional
  query. One with an empty, `.` or `..` part, or any percent-encoding, is refused before Forge is called.
- POST, PUT, PATCH and DELETE need `--write`. A path that returns secrets needs `--secret`: a site's env,
  a package registry's credentials, a deploy hook, webhook or heartbeat URL, a command's output.
- The two flags mark a call, so that a permission rule allowing plain reads never matches it and the call
  asks first.
- The token reaches curl on stdin, never a command line or a file, and is not printed even under `bash -x`.
  `--data -` reads the body from stdin; use it for a body with secrets in it, since an inline `--data`
  shows in the process list.
- A 503 is retried, and so is a 502 for GET, PUT and DELETE. A 429 waits for Forge's `Retry-After` (up to
  120 seconds, else 20). A read that timed out is retried; a write never is, since it may have run.

The real pin is the token. Make it from a Forge account whose only team holds the box (design section 3),
since `MROOM_FORGE_SERVER` set in the environment can name any server the token sees. Give it only the
scopes its users need, such as `server:view`, `site:meta` and `site:manage-nginx`. Never give it
`server:delete`, or any scope design D20 lists as reaching `forge` or root: SSH keys, commands or recipes
(any `recipe:*` scope, `recipe:view` too, since it runs any saved recipe), the sudo or database password,
deploy scripts, daemons or scheduled jobs.

To store the token without it showing on screen or in history:

```bash
( umask 077; mkdir -p ~/.config/mroom/secrets
  read -rs t; printf '%s' "$t" >~/.config/mroom/secrets/forge-token; chmod 600 ~/.config/mroom/secrets/forge-token )
```

On a runner, the QA actions use the same client (`lib/core/forge.sh`) with `MROOM_FORGE_ORG`,
`MROOM_FORGE_SERVER` and `MROOM_FORGE_TOKEN` in the environment.

## Guard and settings

Agents never merge, approve, release, force-push or read secrets; a person does that. Two layers
keep them to it (design 8.3), and GitHub is the gate behind both.

**`mroom guard`** is a `PreToolUse` hook on Claude Code's Bash tool. It parses the whole command:
each command in a chain (`;`, `&&`, `||`, `|`, newlines), inside `bash -c`, `eval`, `$(...)`,
backticks, subshells and heredocs, behind wrappers such as `sudo`, `env`, `xargs` and `npx`. It
refuses, among others:

- `gh pr merge`, `gh pr review --approve`, and `gh api` writes to `/merge`, `/merges`, `/reviews`
  with `APPROVE`, `/releases` and `/git/refs`, and GraphQL merges, ref updates and deploy approvals;
- `git push` with any form of force (`-f`, `--force`, `--force-with-lease`, `--mirror`, a `+`
  refspec, abbreviations too), with tags, or to `main`, `master` or `release`; git config or aliases
  that would make a later push do one of those; `gh pr update-branch --rebase`;
- reading `.env*` (not `*.example`), `~/.ssh` (not `*.pub`), `~/.config/gh*`,
  `~/.config/mroom/secrets`, any `*.env` under `~/.config`, `~/.forge-token` and Claude's
  credentials, through the common readers, interpreters, uploads and redirections, or a `cd` into
  their folder; `gh auth token`.

```bash
mroom guard check 'true && git push --force origin feat/x'   # exit 2, and why
mroom guard check 'git push -u origin feat/x'                # allowed
```

**It is a speed bump, not a boundary.** A command built from variables (`$CMD`) or from another
command's output (`cat $(echo x)`), a script file (`bash x.sh`), an alias already in a config file,
`ssh host 'cmd'` or `docker compose exec`, a recursive search of the project (`grep -r KEY .`
reads its `.env` too) or a secret in the environment gets past it. `lib/guard`'s header lists the rest. Without jq or
awk it is off and says so; a command it cannot parse is refused. The real gate is GitHub: the
default branch's ruleset, review by people, and the `production` environment (design D22).

**The plugin** in `plugin/` runs the guard. Claude Code copies a plugin without the rest of this
repository, so its hook runs the installed `mroom guard hook` (from `PATH` or `~/.local/bin`):

```text
/plugin install mroom --marketplace milroyfraser/mroom
```

(On a Claude Code older than 2.1.275: `/plugin marketplace add milroyfraser/mroom`, then
`/plugin install mroom@mroom`.)

**Settings fragments** in `settings/` are the second layer: prefix rules (`allow`, `ask`, `deny`)
for `.claude/settings.json`. A plugin cannot set permissions, so `mroom init` (coming in phase 1)
will merge them into the app's settings:

| Fragment | For |
|---|---|
| `base.json` | every app: git, gh and tracker reads allowed; pushes, releases, filing an issue and resolving an error ask; merges, approvals, force-pushes and secret reads denied |
| `laravel-vite.json` | Laravel and Vite: tests, linters and builds allowed; migrations, seeds and tinker ask |
| `forge.json` | Forge: `forge-api GET` allowed, `forge-api --secret` asks; the Forge CLI and its tokens denied |
| `tracker-linear.json` | a Linear tracker: GitHub issue writes denied |

The merge joins every list. Claude Code checks deny first, then ask, then allow, so an `allow` rule
never overrides an `ask` or a `deny`. `tests/settings-test.sh` checks each fragment and what the
merged set decides for common commands.

## Tracker and error tracker

The workflow skills of phase 3 reach the issue tracker and the error tracker through two adapters
(design section 7). Each picks its backend from `mroom.toml` and prints JSON.

```bash
mroom tracker get SHOP-12                    # title, state, labels, branch, description, every comment
mroom tracker list --mine --open             # my 50 latest open issues, by priority; or --label lesson
mroom tracker find sentry:1001               # the issues whose description holds the marker for an alert
mroom tracker owned SHOP-12                  # whether the token's user filed the issue
mroom tracker comment SHOP-12 < note.md      # adds a comment; the body comes on stdin
mroom tracker state SHOP-12 "In Review"      # the team's state of that name, in any case
mroom tracker create --allow-create --title "Checkout fails" --state Triage --label bug < body.md
mroom errors get SHOP-1A2                    # the error issue and its latest event
mroom errors search 'is:unresolved' --environment production --period 24h --limit 50
mroom errors new 40 --environment production # new, regressed and escalating issues of the last 40 minutes
mroom errors resolve SHOP-1A2
```

```toml
[issues]
tracker = "linear"                 # linear | none
id_pattern = "SHOP-[0-9]+"
team = "SHOP"                      # where `create` files issues (Linear: the team's key)
token_env = "LINEAR_API_KEY"       # the default

[errors]                           # leave the table out for no error tracker
provider = "sentry"
org = "example-org"
region = "us"                      # us | de: where the organisation's data is
id_pattern = "SHOP-[A-Z0-9]+"
token_env = "SENTRY_AUTH_TOKEN"    # the default
```

- **Tokens** come only from the environment variable `token_env` names, never from a file. Its name ends
  in `_TOKEN` or `_API_KEY`, is not one of `MROOM_*`, `GH_*`, `GITHUB_*`, `AWS_*`, `FORGE_*` or `SSH_*`,
  and the two differ, so a changed `mroom.toml` cannot send another secret. A missing or empty token fails
  with the variable's name, never its value. The token reaches curl on stdin, never a
  command line, and an answer that echoes it has it cut out of the message.
- **Hosts are fixed**: `api.linear.app`, and `<region>.sentry.io` for the organisation in `errors.org`.
  No URL comes from config, so a changed `mroom.toml` cannot send a token elsewhere.
- **Listing** needs `--mine` or `--label`, so it never reads a whole backlog. It takes the `--limit`
  (50, at most 250) most recently updated issues, in `issues.team` when that is set, then sorts
  them by priority. `get` says whether the issue is assigned to the token's user (`assigned_to_me`).
- **Finding** an error's issue reads the hidden marker the persona puts in each issue it files,
  one per alert: `<!-- mroom-alert key=sentry:1001 -->`, where the key is the error tracker and the
  error issue's numeric id, and a later alert adds `:<kind>:...` after the id. Linear's search is a
  substring match, so `find` checks each description again and keeps an issue only when the marker
  ends there or goes on with `:`; the marker for `sentry:100` never finds `sentry:1001`'s issue. It
  reads every page, in `issues.team` when that is set, and lists the issues in every state,
  archived ones too, the first filed at the top, each with its `keys`: the keys of its markers that
  are this error's.
- **Creating an issue** needs `--allow-create`; without it, nothing is sent. It files in `issues.team`
  and uses labels that already exist, of that team or the whole workspace (not a parent team's); mroom
  never creates a label.
- **Bodies** come on stdin, so the guard sees the file a body is read from, and are sent as they are,
  up to 64 KiB. A longer one, one with a NUL byte, or one that holds the tracker's token is refused,
  never cut short. A title that holds the token is refused too.
- **Retries**: a 429 (or Linear's `RATELIMITED`) waits for `Retry-After`, or the latest rate-limit
  reset header Linear or Sentry sends, from 1 to 120 seconds (20 when there is none). A request that never
  left (no host, no connection) is retried too. A read, or a write that does the same thing twice (a
  state, a resolve), is also retried after a 5xx or no answer. A comment or a create never is, since it
  may have gone through. No other 4xx is retried, and no redirect is followed (a merged Sentry issue
  says which one it moved to). At most 4 calls.
- **Lists are read to the end**: a Linear connection page by page, a Sentry search by its `Link`
  cursor up to `--limit`. A page that cannot be read fails the call, so a blip never reads as a short
  list. A search fails, too, when the token sees no project, since Sentry then answers `[]` for anything.
- **Exit codes**: `0` done, `1` the tracker or the config failed, `2` a usage error, `3` no tracker
  (`issues.tracker = "none"`) or no `[errors]` table, so a skill can leave its note on the pull request
  instead.

Sentry needs a user or internal integration token; an organisation auth token cannot read issues. It
needs Issue & Event: read, and Organization: read for `search`, which first checks that the token sees
a project. `resolve` also needs Issue & Event: write.

## Alert triage

The persona (design D23) files the error tracker's alerts into the tracker, one issue per alert key,
and pings a person only when triage itself cannot run. It is a reusable workflow,
`.github/workflows/triage.yml`, with the composite action `actions/triage`, which the app calls from a
workflow of its own:

```yaml
# .github/workflows/alerts.yml
name: Alert triage
on:
  schedule:
    - cron: "*/15 * * * *"
  workflow_dispatch:
    inputs:
      live:
        description: Write to the tracker (unticked, a dry run prints what it would file)
        type: boolean
        default: false
permissions:
  contents: read
jobs:
  triage:
    permissions:
      actions: write # the switch-off job turns this workflow off when the tracker drops the markers
      contents: read
    uses: milroyfraser/mroom/.github/workflows/triage.yml@v0.5.0 # the first release with alert triage
    with:
      live: ${{ github.event_name == 'schedule' || inputs.live }}
    secrets:
      MROOM_TRACKER_TOKEN: ${{ secrets.MROOM_TRACKER_TOKEN }}
      MROOM_ERRORS_TOKEN: ${{ secrets.MROOM_ERRORS_TOKEN }}
      MROOM_CHAT_TOKEN: ${{ secrets.MROOM_CHAT_TOKEN }}
```

```toml
[persona]
name = "Agent"                     # the name on every issue, comment and ping it writes
label = "found-by-agent"           # on every issue it files; it must exist, mroom never creates labels
state = "Triage"                   # the state it files issues in (default: the team's)
environment = "production"         # the error tracker's environment it reads (the default)
channel = "C0123456789"            # the chat channel it pings when triage cannot run (a Slack channel id)
```

- **Alerts.** Every 15 minutes it reads the error issues that are new, regressed or escalating in the
  last 40 minutes (`mroom errors new`), since GitHub often starts a scheduled run late. An alert's key is
  `sentry:<id>` for a new issue, and `sentry:<id>:regressed:<day>` or `sentry:<id>:escalating:<day>`
  for a later alert of it. Every alert of the window is looked up, the most urgent first, but at most 10
  issues are filed a run; the rest wait for the next run, which files them while they are still in its
  window. Each of the three searches takes at most 100 issues, and the summary says when one was full:
  alerts past that, or past a longer gap, are missed, so look at the error tracker then.
- **One issue per alert key.** The issue holding an alert carries its hidden marker, `<!-- mroom-alert
  key=sentry:1001 -->`. Triage looks for the key with `mroom tracker find` and files an issue only when
  no issue in any state holds it, archived ones too, so a second run files nothing new, and a cancelled
  issue is not filed again. A later alert of an error is a new issue that links the 20 newest of the
  earlier ones, and a comment on the newest earlier one when the persona filed it. The alerts of one
  error in one run go on one issue. Until an issue of the same kind for that error is done, a later
  alert counts as filed, so a regression that goes on for days, or one a person cancelled, is one issue;
  once that issue is done, the next regression is filed.
- **What an issue holds.** The error, its counts, releases and culprit, and the latest event's exception
  and in-app frames, all redacted first (`lib/core/text.py`): known token and key shapes, bearer tokens,
  `password=`, `secret=`, `token=` and `api_key=` values, a URL's password, email addresses, phone
  numbers and IBANs. It knows shapes, so a secret of no known shape can still pass. The run's summary is
  redacted the same way. An issue shows the last 3 chained exceptions with 8 in-app frames each, takes
  out control and text-direction characters, and is cut at 28000 bytes.
- **The guard** (`mroom persona`) is the persona's only way to write. It files issues only for an alert
  key of this run, in `issues.team`, `persona.state` and with `persona.label`, and assigns no one. It
  comments only on an issue the tracker says the persona's token filed (`mroom tracker owned`), and has
  no command to edit, close, assign, label or delete. An issue filed by an app rather than a user has no
  creator, so it never counts as the persona's. The markers are its own: it escapes every `<!--` in a
  body, so no text, however it nests one, can hold a marker, and it writes one per key; reading an issue
  back, it stops as for a lost marker when it finds one it did not write. It refuses text holding a
  token, defangs links to hosts other than GitHub's, the trackers' and the app's, and caps a run at 10
  issues and 30 comments. A dispatch is a dry run unless `live` is ticked: it prints what it would file,
  and writes nothing.
- **When the tracker drops the markers.** After each issue it files, the guard reads the issue back.
  When a marker is missing, the next run could not find the issue and would file it again, every 15
  minutes. It also searches for each issue as the next run will, three times, since a tracker's search
  may read another form of the description than the one it stores; an issue the search cannot find
  counts as lost too. So nothing more is written in that run, and the workflow's switch-off job turns
  the app's workflow off (`gh workflow disable`) and pings `persona.channel` once. To recover, read the
  issue's description through the tracker's API and check the `<!-- mroom-alert ... -->` lines; if the
  tracker strips HTML comments, or stores them but leaves them out of its search (check how its
  description filter reads the text), the marker's format must change before triage runs again. Merge
  any duplicates, then turn the workflow on again (`gh workflow enable alerts.yml`). If the workflow
  cannot be turned off, the ping asks a person to do it by hand, and repeats every run until someone
  does. A failed read of the issue is not a lost marker: the run fails, and the alarm says so.
- **The alarm.** When a live run's triage job fails (the error tracker or the tracker could not be read
  or written, the guard refused an alert, or a step failed or ran past its 11-minute limit), the alarm
  job pings `persona.channel` with the failed step and the run, at most once a UTC day. Its dedupe is
  the tracker's: before the ping it files the day's issue, keyed `triage:<yyyymmdd>`, and a day whose
  issue exists sends nothing. When that issue cannot be filed, nothing is sent: a missed ping, never one
  every 15 minutes.
- **Without a tracker** (`issues.tracker = "none"`), nothing is filed: the run's summary lists the
  window's alerts. The alarm then has nowhere to record its ping, and sends none; nor does it without a
  chat token or `persona.channel`. A run GitHub cancelled, such as a waiting one a newer run replaced,
  raises no alarm. Without an `[errors]`
  table there is nothing to triage.
- **Secrets** are the `persona` environment's (design 8.8; default branch only): the persona's own
  tracker token (D23, never a developer's), a read-only error-tracker token, and the chat bot's token
  (`chat:write`, invited to the channel). Keep them in the `persona` environment only, never as
  repository or organisation secrets: the called jobs read the environment's own, but where the
  environment has none, the caller's would be used, and a repository secret is readable from any
  branch. Each job checks out only the default branch's `mroom.toml`
  and mroom at the commit of the workflow; the triage job's token reads nothing but the repository,
  and only the switch-off job may turn workflows off.

## Workflow skills

The plugin carries the agent workflow as skills and commands. Each is a Markdown file in `plugin/`
that Claude Code reads; in a session they are `/mroom:<name>`.

| Skill or command | What it does |
|---|---|
| `/mroom:refine` | lists my open issues, tags each with a Design value, and runs `/mroom:implement` on the ones I confirm |
| `/mroom:deliver <id>` | a design gate when the issue needs one (a canvas, approved in a comment), then `/mroom:implement`; resumes stopped work |
| `/mroom:implement <id>` | one issue to a PR in review: a worktree, the change, the affected tests, a draft PR, CI and QA on the PR's environment, then stop |
| `/mroom:fix-issue <error id>` | one error issue to a fix in review: reads the error and its latest event, finds the issue the persona filed (`mroom tracker find`), works on a branch that names both ids, reproduces the error with a failing test before it fixes it, and links the error issue only through `Fixes <error id>` lines, on the fixing commit and in the PR body; never resolves it |
| `/mroom:release` | only when a person asks: what ships, what to watch, the notes, one question, then a **draft** release that the person publishes; then a read-only watch of the deploy |
| `/mroom:correct` | finds a mistake agents repeat, and adds the highest check that stops it (adapted from pstack, MIT) |
| `/mroom:forge` | Forge through `forge-api` only: reads free, writes asked first, secrets never printed |
| `/mroom:clean-review` | a clean-code review by a fresh sub-agent, with a verdict; never commits |
| `/mroom:crap` | CRAP triage of the backend methods you changed, with the app's `bin/crap` |

- **The tracker** is reached only through `mroom tracker` and `mroom errors`. When either exits 3
  (no tracker), the skill puts its note on the pull request instead.
- **Rules in every skill:** an agent never merges, approves, deploys or releases; a person does.
  Tracker writes are only the state of the issue being worked and comments on it. A skill asks
  before it files an issue or a label, never touches production, and never reads a secret.
- **Release asks twice:** once in the session, and again through the `ask` rule on
  `gh release create` in `settings/base.json`. It only ever drafts; publishing is a person's click.
- **From `mroom.toml`:** the issue id and link (`issues.id_pattern`, `issues.url`), the started and
  review states (`issues.state_started`, `issues.state_review`; `In Progress` and `In Review` by
  default), the test command and database (`tests.*`), the required checks (`pr.required_checks`),
  the QA zone (`qa.zone`), and, for a release, the tag's prefix and the production origin whose
  `app.version_path` it reads (`release.tag_prefix`, `release.production_url`).

```toml
[issues]
state_started = "In Progress"
state_review = "In Review"

[release]
production_url = "https://app.example.dev"   # an https origin, no path
tag_prefix = ""                              # "release-" gives release-v1.2.3
```

The settings fragment `base.json` allows the adapters' reads (`mroom tracker get`, `list`,
`find`, `owned`, `backend`; `mroom errors get`, `search`, `new`, `backend`; `mroom persona find`,
`owned`) and asks before `mroom tracker create`, `mroom errors resolve` and the guard's writes
(`mroom persona create`, `comment`). `tests/skills-test.sh` checks the skills as a contract: their frontmatter,
that every `mroom` command, skill and key they name exists, the rules above, the release's draft and
question, that no skill resolves an error issue, and that none names a host, an IP address, an id or
an email address. For `fix-issue` it also checks that the branch names both ids, that a failing test
comes before the fix, that the only links are the `Fixes` lines, and that it stops at a PR in review.
Names of people and projects come from `$MROOM_PRIVATE_WORDS`, a file of patterns kept outside the
repository.

Not here yet: `blast-radius` (later in phase 3), the principle skills (named in the
skills, read when installed), and `verify-app` with `qa-engineer` (phase 2b).

## QA gate

CI never gets a shell on the box (design 8.2). The QA runner's SSH key is forced to `mroom gate`, which
runs only the operations of its role and builds every name itself, so a request can reach nothing but its
own environment. Each role is a key of its own: `provision` for qa-up and qa-down, `browser` for browser QA's
checks, and `template` for the job that builds the QA template. The `provision` role has:

| Operation | What it does |
|---|---|
| `db-create <N> [--rotate]` | a Postgres role and a database of their own for QA environment N, cloned from the template (D18); prints `DB_DATABASE`, `DB_USERNAME` and `DB_PASSWORD` for the environment's `.env` |
| `db-drop <N>` | the environment's database and role |
| `redis-user-add <N> [--rotate]` | a Redis user of its own, limited to its prefix `<app>:qa<N>:` (D15); prints `REDIS_USERNAME`, `REDIS_PASSWORD`, `REDIS_PREFIX`, `HORIZON_PREFIX`, `REDIS_HOST` and `REDIS_PORT`. A user already as the gate left it is left alone, so its connections stay open |
| `redis-user-remove <N>` | the environment's Redis user, which also closes its connections |
| `redis-clear <N>` | every key under the environment's prefix, in every Redis database |
| `code-put <N> <commit>` | the PR's tree, GitHub's tarball of that commit on stdin, into the environment's API site (D17); the gate records the commit |
| `dist-put <N>` | the frontend's built files, a tarball on stdin, into the environment's web site |
| `env-put <N>` | the API site's `.env`, on stdin, written as the site user (mode 600), replacing rather than following any link the PR's code left there; prints `env=` its SHA-256 |
| `probe-link <N> api\|web` | a link at the site's web root to the installed `site-op`, which is root's own: nginx must refuse to serve it, and qa-up asks for it before any code goes in (D17) |
| `env-sha <N>` | `env=` the SHA-256 of the API site's `.env` (or `missing`), and `commit=` the commit `code-put` recorded (or `none`) |
| `signin-code <N> <email>` | a sign-in code for a persona address, from the app's `php artisan mroom:signin-code <email>` or its `qa-signin` hook |
| `app-key <N> [--rotate]` | `APP_KEY`, the environment's Laravel app key |
| `user-clean <N>` | stops the site user's processes (PHP-FPM's pool workers once: their master starts fresh ones, which end with the site) and deletes its files in `/tmp`, `/var/tmp`, `/dev/shm`, `/var/crash`, `/run/lock` and `/dev/mqueue`, its IPC objects and its crontab, before qa-down deletes the sites |
| `mail-user-add <N> [--rotate]` | an SMTP login of its own on the box's Mailpit (D19), given only while systemd's socket for mroom's mail relay holds the SMTP port; prints `MAIL_MAILER`, `MAIL_HOST`, `MAIL_PORT`, `MAIL_USERNAME` and `MAIL_PASSWORD`. Mailpit restarts only when its logins changed |
| `mail-user-remove <N>` | the environment's SMTP login |
| `mail-read <N> <email>` | as JSON, the newest five mails the environment's login sent to a persona address (To, Cc or Bcc), and only to personas: sender, recipients, subject and text |
| `mail-clear <N>` | every mail the environment's login sent |
| `bucket-create <N> <disk> [public] [--rotate]` | a bucket on the box's Garage (D14) for one of the app's file disks, and a key that reaches that bucket alone; `public` turns on its website access. Prints `BUCKET`, `ACCESS_KEY_ID`, `SECRET_ACCESS_KEY`, `REGION`, `ENDPOINT`, `PATH_STYLE`, and `URL` for a public disk |
| `bucket-drop <N>` | every bucket the environment has, whatever its disks: their keys deleted, and each bucket emptied and deleted |
| `reverb-app-add <N>` | an app of its own on mroom's Reverb host (D16), which reads its apps from a file on every lookup, so nothing restarts; prints `REVERB_APP_ID`, `REVERB_APP_KEY`, `REVERB_APP_SECRET` (new for a new app, the same while it has one), `REVERB_HOST`, `REVERB_PORT` and `REVERB_SCHEME` |
| `reverb-app-remove <N>` | the environment's app; its sockets already open stay until they close |
| `memory` | the box's memory, in MB: `total_mb`, `available_mb` and `swap_free_mb` from `/proc/meminfo`, and `reserve_mb`, what the box keeps for all but QA (`MROOM_QA_RESERVE_MB`, 4096 unless set); qa-up sizes its slots from them |

The `browser` role reads and changes nothing:

| Operation | What it does |
|---|---|
| `db-read <N> <table> <column>... [<column>=<value>...] [asc:\|desc:<column>] [limit:<n>]` | at most 100 rows (`limit:` fewer) of one table in the environment's database, as JSON, read as the environment's read-only role; every column it names, filters on (at most 5, each an exact match on the column's text) or orders by must be in `MROOM_QA_DB_READ` |
| `signin-code`, `mail-read`, `env-sha` | as above |

The `template` role has one:

| Operation | What it does |
|---|---|
| `template-load` | the QA template, rebuilt from a `pg_dump -Fc` archive on stdin (at most 4 GiB), then swapped in for the old one whole; environments made before keep their own database, and the next clone gets the new template |

The client sends only N, and the few words some operations also take, each of a fixed form. The
database, role and Redis user are `<MROOM_APP_NAME>_qa_<N>`, and the database is cloned from
`MROOM_QA_TEMPLATE`, both set by a person in `box.env`. A bucket is `<MROOM_APP_NAME>-qa-<N>-<disk>`, each
`_` of the name a `-`, for the disk name `bucket-create` takes: `[a-z][a-z0-9]{0,15}`, with no `-` in it, so
no disk's bucket is another environment's or another disk's. Its Reverb app's id and key are both
`<MROOM_APP_NAME>-qa-<N>`: public, so the frontend builds without a secret, and the PR's alone, so no other
PR is ever given an id whose sockets may still be open. A password reaches
Postgres only as a SCRAM verifier, through stdin, and Redis only as its SHA-256. Each request and refusal
is logged, never a secret, to `~/.local/state/mroom/gate.log` and to syslog.

**The template database** (design 9) is what every environment's database is cloned from, so a deploy
migrates only what its pull request adds, and seeds nothing. A job where pull requests' code never runs builds
it: by default it migrates and seeds a database of its own with the default branch's code
(`qa.parity.database = "seeded"`), or it takes the masked snapshot (`"snapshot"`, opt-in), and sends
`pg_dump -Fc` of it to `template-load`:

- **As the objects role.** The archive is restored into `<template>_next`, a new database built from
  `template0`, by `pg_restore --no-owner --no-privileges --single-transaction --exit-on-error`, signed in as
  `<app>_qa_objects` with a password made for that restore and a login that lapses after two hours, which the
  gate takes back as soon as the restore ends. So whatever the archive holds runs with that role's rights, never
  the gate's, and `pg_hba.conf` lets that role reach `<template>_next` alone. The template's objects belong to
  it, as D18 needs.
- **A swap.** Then, while no clone runs (`db-create` waits for it, and it for them), the old template is set
  aside as `<template>_old`, the new one takes its name, and the old one is dropped. A step that fails puts the
  old one back, a restore that fails leaves the template as it was, and a load that was killed halfway is put
  right by the next one. `pg_restore` reads archives of its own Postgres version or older, so dump with a
  `pg_dump` no newer than the box's Postgres.
- **What the caller sees.** Only the gate's lines, and on a failed restore `pg_restore`'s first error, which
  may quote a row of the caller's own archive: it never reaches the gate's log.

**Read-only database access for browser QA** (design 8.6). Each environment also gets a read-only Postgres
role, `<app>_qa_<N>_read`, made by `db-create` and dropped by `db-drop`. No app is given its password: the gate
keeps it and signs in with it for `db-read` alone, never as itself, since the pull request's code owns the
database and a view or function it planted runs as whoever reads it. The role holds `SELECT` on the tables in
`public` (the template's, and every table the environment's role makes there later), `CONNECT` on its own
environment's database alone, and no other privilege; its sessions are read-only with a 30 s statement timeout,
and `pg_hba.conf` lets it reach environments' databases only. `db-read` builds the one `SELECT` itself from names
it quotes and values psql quotes, with the catalog first on the search path, in a read-only transaction that is
rolled back. What it may read is what `MROOM_QA_DB_READ` lists, the `table.column` entries a person sets on the
box to match `qa.db_read_allowlist`: a check can name no other column, filter on none, and order by none, since
a filter would tell its values apart too. An error names its SQLSTATE, never Postgres's message, which can quote
a value. The pull request's code still decides what its own tables hold, so the list says what a check may ask
for, not what the data is. An environment made before this release has no read-only role: tear it down and
bring it up again.

The gate makes an environment's passwords, its bucket keys and its app key once, and keeps them in
`~/.local/state/mroom/qa/<app>_qa_<N>.secrets` (mode 600, beside the commit `code-put` records), so every
later request gives the same ones and a deploy changes nothing under the running app: its users stay signed
in, its connections stay up, and its workers and the file URLs it gave out keep working. `--rotate` makes a
new one, and the old one stops working. `db-drop`, `redis-user-remove`, `mail-user-remove` and `bucket-drop`
delete those of their own service, and `user-clean` the app key.

A Redis user gets Redis's own data types and the functions an app needs (`@keyspace`, `@string`, `@hash`,
`@list`, `@set`, `@sortedset`, `@stream`, `@bitmap`, `@hyperloglog`, `@geo`, `@pubsub`, `@scripting`,
`@transaction` and `@connection`), never `@all`, for keys and channels under its prefix only. It loses the
commands among them that flush, watch, list, count or debug the whole server or reset its scripts (design
8.9). It gets no module command: Redis checks a command's keys from what the command declares, and a
module's commands may not declare them all (`JSON.MGET` declares only its first), so the gate refuses to
run if a loaded module puts a command in one of those categories. Each change closes the user's old
connections and is saved to Redis's `aclfile`, so it survives a restart. `redis-clear` deletes inside
Redis, a slice of the keyspace at a time, so no key name is read back, where a newline in one could make
it two.

So an environment's app can't use what acts on a whole database, such as `Cache::flush()` (FLUSHDB) or
anything that scans, such as `cache:prune-stale-tags` (SCAN); `redis-clear` empties an environment instead.
A pattern subscription must be exactly `<prefix>*`. And one Redis keeps environments' data apart, not their
load: a long script or a large write from one PR slows every environment and the dev site.

An environment's two sites, `api.<N>.<MROOM_QA_ZONE>` for the Laravel app and `<N>.<MROOM_QA_ZONE>` for a
frontend of its own, are Forge isolated sites in the home of one user of their own, `<MROOM_APP_NAME>_qa_<N>`
(D17); qa-up creates them. The gate works in them only through `site-op`, run as that user with `sudo`, so it
never unpacks a tarball, follows a PR's link or runs its code as the box user. `site-op` runs only as a QA
site's user, and only on that environment's own two sites:

- **Unpacking** uses Python's safe tarfile filter: no absolute path, no `..`, no link that leaves the
  tree, no device file, no setuid bit, and no oversized header. A code tree must be GitHub's one folder
  named after the commit, a cut-off upload fails on gzip's checksum, and the tree replaces the site's whole
  tree except the backend's `.env` and `storage/`. Any `.env` in the tarball is skipped, a link at `.env`,
  `storage` or `bootstrap/cache` refuses the tarball, and the gate writes `version.json`
  (`{"release": null, "commit": "<sha>"}`) into the backend, since a tarball has no git history, in place of
  any the tree holds. The app's `app.version_path` endpoint reports it; checks ask the gate instead
  (`env-sha`), since the PR's code could write the file afterwards. `lib/core/version.sh` is the one reader they share.
- **The swap** builds the new tree beside the live one, then exchanges the two entry by entry, each in one
  atomic step (`renameat2`), so the site never lacks an entry, even while its own code writes. A failed step
  undoes the steps done. A killed put's kept items go back live with the next put; if the site made its own
  meanwhile, that copy is set aside as `.mroom-kept-*` for a person, as is a scratch tree whose put is not
  known. Kept items are never deleted, and each put reports how many set-aside copies wait. A log the app
  writes during the swap itself may be lost. Changing `MROOM_QA_BACKEND_DIR` while an environment exists
  leaves its `.env` and `storage/` at the old place, where the next put replaces them: recreate the
  environment instead.
- **`.env`** is written by `env-put`, as the site user, so neither Forge nor the gate writes through a link
  the PR's code left there. `env-sha` checks that write; the PR's code can change the file afterwards.
- **The commit** that `env-sha` reports is the one the gate recorded, as the box user, outside the site.
  `code-put` clears it first, so a failed put leaves `none`.
- **`signin-code`** asks the app only for addresses ending in `MROOM_QA_PERSONA_DOMAIN` (`.test`); what the
  app prints is the PR's own code's answer.
- **`user-clean`** runs as the site user too: a user may stop its own processes and delete its own files,
  so no rule lets the box user run anything as root. PHP-FPM's master replaces a killed pool worker at
  once, so pool workers are stopped once, which ends any request in flight, and their fresh replacements
  stop when Forge deletes the site. A request that arrives in between could still leave a file, so qa-down
  deletes the site right after. Anything else that keeps coming back, such as a daemon not yet deleted,
  fails the clean, though the files go first.

The sudoers line lets the box user, and so every agent on the box, run `site-op` as any QA site user:
put any code into a QA site and run its sign-in command. QA sites hold only QA data, and the box user can
already read every isolated site's files on Forge.

Mail goes to the box's Mailpit, which keeps it (D19). Each environment sends with its own SMTP login, and
a login sets the mail's `Username` field and its only tag, since the tags an `X-Tags` header or a plus
address would add are turned off.

- **No port to take.** Mailpit listens only on Unix sockets in a folder that only the box user can open,
  so no site user can reach its API or stand in for it. Apps send to `127.0.0.1:1025`, where mroom's mail
  relay (`lib/mail-relay`) pipes each connection to Mailpit's SMTP socket. Anyone on the box may take a free
  TCP port, and with it the logins apps send, so systemd holds this one: `mroom-mail-relay.socket` listens
  on it from boot, as root, and hands it to the relay. The port stays held while the relay restarts, after
  an update, a crash or a reboot, and a connection that comes meanwhile waits for it. While it is held,
  nothing else can listen where apps' mail arrives. `mail-user-add` gives no login unless what listens on
  `127.0.0.1` at the port is that socket, active as systemd reports it, or the relay itself; another root
  program there, such as a mail catcher in a container, is refused.
- **Restarts.** Mailpit reads its logins only when it starts, so `mail-user-add` and `mail-user-remove` stop
  it, systemd starts it again (`mroom-mailpit.service`, however often), and the gate waits until it answers
  on HTTP and SMTP: a moment without SMTP, which a queued mail with more than one try survives. Each Mailpit
  runs a second before the next stop, so no caller can keep it down; one run by a supervisor instead, such
  as a Forge daemon, runs 3, since a supervisor gives up after three stops within its Start Seconds. A
  restart also moves Mailpit onto the build `mroom baseline mailpit` installed last.
- **The relay** ends a session when Mailpit's side does, or the client's fails, and after at most
  `MAIL_RELAY_MAX_SECONDS` (1800). It runs at most `MAIL_RELAY_MAX_CONNECTIONS` (256) at once, and at most
  `MAIL_RELAY_MAX_PER_USER` (32) from one Linux user, so no QA site can take every place.
- **Confined.** Mailpit reads mail from untrusted apps, so its unit lets it see only its build, its data,
  its sockets and the two login files, with no network; the relay sees only its script and Mailpit's
  sockets. Neither can read the box user's other secrets.
- **The login file** is never left empty, which Mailpit would take as "no login needed": it keeps a login
  no one knows, and a write that fails leaves the file as it was.
- **Reading and deleting.** Only the gate holds the API login. `mail-read` and `mail-clear` act only on mail
  whose `Username` is the environment's login, and `mail-read` only on mail to persona addresses alone.
  Mailpit deletes every mail when asked to delete an empty list, so `mail-clear` sends only plain,
  non-empty lists of IDs.

Files go to the box's Garage (D14), a bucket for each environment and file disk, `<app>-qa-<N>-<disk>`:

- **A key per bucket.** `bucket-create` gives the bucket a new key, allowed to read and write it alone, and
  deletes the old ones, so a key left in an old `.env` reaches nothing. The gate prints neutral settings;
  qa-up writes them to the names the app's disks read.
- **Two hosts.** Apps and browsers reach Garage through nginx: `s3.<zone>` for the S3 API, path-style, so
  every bucket is under one host and its certificate, and `files.<zone>/<bucket>/<path>` for a public
  disk's files, which Garage serves from a bucket only when its website access is on. Garage has no
  per-file permissions, so a disk with both kinds of file is two disks here.
- **No port to take.** Garage's S3, web and admin endpoints listen only on Unix sockets in a folder only the
  box user can open, and its own RPC stays in a network of its own (`PrivateNetwork`), where no site user can
  reach it. Only the gate holds the admin token. Garage, confined like Mailpit, sees only its build, config,
  data and secrets.
- **Dropping.** `bucket-drop` finds the environment's buckets and keys by name, so a disk the app no longer
  has leaves nothing behind. Garage deletes only an empty bucket and empties none itself, so the drop
  deletes the environment's keys first, then each bucket's objects through the S3 API, with a key made for
  that bucket's drop alone, and only then the bucket. The drop key goes when the drop ends, whether it
  worked or not; one a killed gate left goes with the next drop of that environment.

WebSockets go to mroom's Reverb host (D16), one Reverb for every environment, each with an app of its own:

- **No restart.** The host reads its apps from a file on every lookup, so `reverb-app-add` and
  `reverb-app-remove` need none, and no environment's sockets drop when another's app comes or goes. The
  gate replaces the file whole, by renaming, so the host reads the old apps or the new ones, never half.
- **An app per environment.** Its id and key come from the PR. Its secret is new when the app is, and only
  the gate, the host and the environment's `.env` hold it. A later `reverb-app-add` keeps it, since Reverb
  keeps the app each socket opened with: a new secret would fail the private channels of every socket already
  open. To change it, remove the app, then add it.
- **Its limits.** A browser may open its sockets only from the environment's two hosts, `api.<N>.<zone>` and
  `<N>.<zone>`, at most 100 subscribed at once, and only a socket subscribed to a channel may send client events
  on it. The host closes a socket it refuses; Reverb itself only sends the error. It also gives each client event
  to its own app: Reverb 1.12.0 looks the channel up in whichever app it served last, so with more than one app a
  valid one is refused at random (fixed upstream after 1.12.0).
- **One host.** Browsers and apps reach it through nginx on `ws.<zone>`: the frontend opens its sockets
  there, and the backend sends its events there, signed with its secret.
- **No port to take.** It listens only on a Unix socket in a folder only the box user can open, so no site
  user can take its place, not even while it restarts. Confined like Garage, it sees only its build and its
  apps folder, and has no network of its own.
- **Removing.** A removed app's open sockets stay until they close: the host looks an app up only when a
  socket opens or an event arrives, and no longer pings them, so nginx closes a dead one after its 180 s read
  timeout. A new socket with its key is refused.

**Set up once,** for an app named `shop`, on Postgres 16 or later and Redis 7 or later. Before Postgres 16,
a role that may create roles may also grant itself the administrator ones, so the gate refuses older
versions. CI runs these steps against a real Postgres, a real Redis 7 and 8, real site users and sudo, and
the real Mailpit, Garage and Reverb host under systemd (`tests/pg/`, `tests/redis/`, `tests/site/`,
`tests/mail/`, `tests/files/` and `tests/reverb/`).

Steps marked *as root* change what the box user cannot, so they must not trust anything the box user, or a
program running as it, could have changed. Run them from a session those programs cannot change, a Forge
recipe run as root (Server > Recipes), never by typing `sudo` in the box user's shell, whose `PATH`,
aliases and functions they can change. They read no file the box user can write.

**The root recipe** (design D21). What mroom installs as root, `site-op` with its sudoers line and the QA
services' systemd units, comes from a release, never from the box. Save this as a recipe in Forge, run as
`root` and shared only with the team that holds the box, and run it whenever these steps or
`mroom baseline` say so. It downloads `lib/root-setup` from the release tag `v`, checks it against `sum`,
and runs it, which installs the `parts` named:

- Take `v` and `sum` from this README at the latest release on GitHub (its Releases page), never from the
  box, and upgrade the box to that release first. `v` is a tag, never a commit: GitHub serves a fork's commits
  under this repository's address too. Tag and `sum` together pin the exact file.
- What root trusts is this repository's tags and README, so nothing on the box may write to it: the box's
  one GitHub credential, the agents' account (design D22), may write the app's repository, never this one.
- `parts`: `site-op` always, `mailpit` when `qa.parity.mail` is `catcher`, `garage` when `qa.parity.files`
  is `same`, `reverb` when `qa.parity.broadcast` is `same`. `smtp_port` is `box.env`'s
  `MROOM_QA_SMTP_PORT`, 1025 unless set.
- `root-setup` reads no file the box user can write: it writes each unit from its own text, checks `site-op`
  against the SHA-256 it holds, and runs again without harm, rewriting and restarting only what changed, or
  what a run that stopped halfway left.
- The services live in `/var/lib/mroom/services`, not in the box user's home. systemd, as root, resolves each
  folder a unit binds, links and all, each time a service starts, so `root-setup` makes that path root's:
  `/var/lib/mroom/services` and a folder for each service in it belong to root, mode 755, and only the
  folders the units bind, one level down, belong to the box user, mode 700. The box user can change what is
  in those folders, never the path to them. `root-setup` stops before it writes a unit if any part of that
  path is a link, a file, or a folder someone other than root may change, or if a folder it would give the
  box user belongs to someone else (design D21, open question 8). Each service sees only its own folders.
- Never give a token on the box a `recipe:*` scope: even `recipe:view` runs any saved recipe.

<!-- root-recipe: tests/root-test.sh checks sum against lib/root-setup, and runs this block -->
```bash
set -euo pipefail
v=v0.5.0
sum=8c56e94b5501601b4e8ae2175308eededaca97bda19ae7b0149bc8495881ca7c
user=forge
parts=(site-op mailpit garage reverb)
smtp_port=1025
[[ "$v" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "v must be a release tag, such as v0.4.0" >&2; exit 1; }
f="$(mktemp)"
trap 'rm -f "$f"' EXIT
curl -q -fsSL --proto '=https' --proto-redir '=https' --max-time 60 -o "$f" \
  "https://raw.githubusercontent.com/milroyfraser/mroom/refs/tags/$v/lib/root-setup"
echo "$sum  $f" | sha256sum --check --quiet
bash "$f" --user "$user" --smtp-port "$smtp_port" --release "$v" "${parts[@]}"
```

1. In the box user's `~/.ssh/authorized_keys`, by hand (Forge's SSH key screen stores a bare key, without
   options), a key for each role, each its own:

   ```
   restrict,command="/home/forge/.local/bin/mroom gate provision" ssh-ed25519 AAAA… mroom-qa-up
   restrict,command="/home/forge/.local/bin/mroom gate browser" ssh-ed25519 AAAA… mroom-qa-browser
   restrict,command="/home/forge/.local/bin/mroom gate template" ssh-ed25519 AAAA… mroom-qa-template
   ```

   The `template` key belongs to the job that builds the template (step 3), and the `browser` key to browser
   QA (phase 2b); add each when its job exists.

2. As a Postgres superuser (`sudo -u postgres psql`). `\password` asks for each password, so none ends up
   in a history file or the server's log:

   ```sql
   CREATE ROLE shop_qa_gate LOGIN CREATEDB CREATEROLE;
   \password shop_qa_gate
   CREATE ROLE shop_qa_objects NOLOGIN;      -- owns the template's objects; never a database or tablespace
   GRANT shop_qa_objects TO shop_qa_gate WITH ADMIN OPTION;  -- template-load gives it a login for a restore
   CREATE ROLE shop_qa_envs NOLOGIN;         -- every environment's role joins it; never grant it anything
   GRANT shop_qa_envs TO shop_qa_gate WITH ADMIN OPTION;
   CREATE ROLE shop_qa_readers NOLOGIN;      -- every read-only role joins it; never grant it anything
   GRANT shop_qa_readers TO shop_qa_gate WITH ADMIN OPTION;
   ```

3. The template, through the gate: migrate and seed a database of its own where pull requests' code never runs
   (a runner with the default branch's code, or a scratch database), then send its archive with the
   `template` key. `template-load` makes the template on the first load and replaces it on every later one:

   ```sh
   pg_dump -Fc --no-owner --no-privileges -d shop_seed | ssh -i mroom-qa-template forge@<box> template-load
   ```

   Its objects belong to `shop_qa_objects`, which must never own a database or a tablespace. Each new
   environment takes over what that role owns, and the gate refuses to run while it owns one.

4. Every new database lets any role connect, so take that back on each of the app's databases, the dev
   site's for one (not `postgres`, which the gate connects to):

   ```sql
   REVOKE CONNECT ON DATABASE shop_dev FROM PUBLIC;
   ```

5. At the very top of `pg_hba.conf`, above every `local` and `host` line, then reload Postgres. The first
   matching line wins. The gate's own line comes first, since the gate belongs to `shop_qa_envs` and
   `shop_qa_readers`, and the lines below would match it too. Each environment's role then reaches only the
   database named after it, each read-only role only environments' databases (and of those only its own, the
   one that grants it `CONNECT`), and the objects role only the database `template-load` builds the template in.
   Postgres 16 reads a database that starts with `/` as a regular expression:

   ```
   host   all                     shop_qa_gate      127.0.0.1/32  scram-sha-256
   host   all                     shop_qa_gate      ::1/128       scram-sha-256
   host   sameuser                +shop_qa_envs     127.0.0.1/32  scram-sha-256
   host   sameuser                +shop_qa_envs     ::1/128       scram-sha-256
   host   all                     +shop_qa_envs     all           reject
   local  all                     +shop_qa_envs                   reject
   host   /^shop_qa_[0-9]+$       +shop_qa_readers  127.0.0.1/32  scram-sha-256
   host   /^shop_qa_[0-9]+$       +shop_qa_readers  ::1/128       scram-sha-256
   host   all                     +shop_qa_readers  all           reject
   local  all                     +shop_qa_readers                reject
   host   shop_qa_template_next   shop_qa_objects   127.0.0.1/32  scram-sha-256
   host   shop_qa_template_next   shop_qa_objects   ::1/128       scram-sha-256
   host   all                     shop_qa_objects   all           reject
   local  all                     shop_qa_objects                 reject
   ```

6. The gate's connection, in `~/.config/mroom/secrets/pg_service.conf`, mode 600:

   ```
   [mroom-gate]
   host=127.0.0.1
   port=5432
   dbname=postgres
   user=shop_qa_gate
   password=<the gate's password>
   ```

7. The gate's Redis login. This makes a long random password, writes it to
   `~/.config/mroom/secrets/redis-gate.env` (mode 600) and prints the SHA-256 that step 8 needs, without
   the password reaching a command line or your shell's history:

   ```sh
   (
     umask 077
     p="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
     printf 'REDIS_GATE_USER=mroom-gate\nREDIS_GATE_PASSWORD=%s\n' "$p" >~/.config/mroom/secrets/redis-gate.env
     printf '%s' "$p" | sha256sum | cut -d' ' -f1
   )
   ```

   `REDIS_GATE_HOST` and `REDIS_GATE_PORT` default to `127.0.0.1` and `6379`.

8. Redis's users in an `aclfile`. Redis rewrites it on `ACL SAVE`, so put it in a folder Redis's own user
   may write to, such as `/etc/redis`. The file holds two lines. The first is the gate's own user, with
   the hash from step 7. The second is the `user default …` line that `redis-cli ACL LIST` prints now,
   copied unchanged (add `--askpass` if Redis has a password). With that line the default user keeps
   exactly the access it has today, so the restart opens nothing and every client keeps working. Without
   it, Redis starts with the default user open to anyone, whatever password it had:

   ```
   user mroom-gate on #<the hash> ~* &* +@all
   user default <the rest of the line ACL LIST printed>
   ```

   In `redis.conf`, add `aclfile /etc/redis/users.acl` and remove any `requirepass` line, whose hash the
   default user's line now carries. Then restart Redis.

9. Give every other client of Redis, such as the dev site, its workers and each worktree, a user of its
   own (D15). Then turn the default user off and close the connections still signed in as it.
   `--askpass` asks for the gate's password:

   ```
   $ redis-cli --user mroom-gate --askpass
   127.0.0.1:6379> ACL SETUSER default off
   127.0.0.1:6379> ACL SAVE
   127.0.0.1:6379> CLIENT KILL USER default
   ```

   Until then Redis is exactly as open as it was. The gate refuses Redis requests while the default user
   is on, since with it any process on the box reaches every key.

10. *As root:* the root recipe with `site-op` in its parts. It installs `site-op`, owned by root so the box
    user cannot change the helper itself, at `/usr/local/libexec/mroom/site-op`, from the release and
    checked against the SHA-256 `lib/root-setup` holds. With it comes the one sudoers line that lets the box
    user run it as any of Forge's isolated users, never as root, written, checked with `visudo` when the box
    has it, and only then put in place as `/etc/sudoers.d/mroom-gate`:
    `forge ALL=(%isolated) NOPASSWD: /usr/local/libexec/mroom/site-op`. Run the recipe again after each
    mroom upgrade: the gate refuses a copy that is not its release's own.

    A QA site's user never needs to log in, but its PR's code could add its own SSH key: add
    `DenyGroups isolated` to `/etc/ssh/sshd_config` and reload sshd, which also turns off Forge's SFTP for
    isolated users. Add `AllowAgentForwarding no` with it: a developer who connects with `ssh -A` would
    otherwise lend their own keys to every session on the box (design D22).

11. In `box.env`: `MROOM_APP_NAME=shop`, `MROOM_QA_TEMPLATE=shop_qa_template` (58 characters at most, which
    leaves room for `_next`), `MROOM_QA_ZONE=qa.example.dev`, for browser QA `MROOM_QA_DB_READ` (the
    `table.column` entries `db-read` may read, space-separated, the same as `qa.db_read_allowlist`, such as
    `MROOM_QA_DB_READ="users.id users.email bookmarks.user_id"`), and when they differ from the defaults,
    `MROOM_QA_BACKEND_DIR` (the Laravel app's folder in the repository, `.`), `MROOM_QA_PHP` (`php`),
    `MROOM_QA_PERSONA_DOMAIN` (`.test`) and `MROOM_QA_RESERVE_MB` (`4096`: the memory, in MB, the box keeps for
    the dev site, sessions and builds, which no QA environment may count on). A site user's name is at most 32
    characters, so an app name of 19 characters or fewer always fits.

12. The mail catcher, when `qa.parity.mail` is `catcher` (the default): *as root*, the root recipe with
    `mailpit` in its parts, then `mroom baseline mailpit`. The recipe makes the services' folders and
    installs three systemd units and starts them: the socket on `127.0.0.1:1025` (`MROOM_QA_SMTP_PORT` in
    `box.env`, and the recipe's `smtp_port`, to change it), the relay and Mailpit, both run as the box user.
    Until baseline has run, the relay and Mailpit have nothing to run, and systemd keeps trying. Baseline
    downloads Mailpit at the build `lib/core/pins.txt` names, refuses it unless the archive and the binary
    match their SHA-256 pins, puts mroom's mail relay beside it and makes their logins (mode 600, in
    `/var/lib/mroom/services/mailpit/etc`; the gate's API login in `~/.config/mroom/secrets`). Before the
    recipe has made the folders, it installs nothing and says so. Baseline can run again: what is in place
    is kept, it restarts the relay or Mailpit itself when their files changed (systemd holds the port
    meanwhile), and it says when the installed units are not this release's, which the recipe then
    rewrites. Nothing else may listen on the port: on a box that ran an earlier mail catcher there, stop
    that first.

13. The file store, when `qa.parity.files` is `same` (the default): *as root*, the root recipe with `garage`
    in its parts, which makes its folders and installs Garage's systemd unit, then `mroom baseline garage`,
    which gives Garage its one-node layout once it answers (run it again if it says Garage does not yet).
    Baseline downloads Garage at the build `lib/core/pins.txt` names and refuses any other, and makes its RPC
    secret and admin and metrics tokens (mode 600, in `/var/lib/mroom/services/garage/etc`). With
    `MROOM_QA_ZONE` set, it prints the nginx configs of Garage's two hosts: create `s3.<zone>` and
    `files.<zone>` as sites in Forge, each with its certificate, and put the printed blocks in place of their
    `location` blocks. Forge's nginx runs as the box user, who alone can open Garage's sockets. The S3 host
    streams each body to Garage, so an unsigned upload is refused before nginx stores any of it.

14. WebSockets, when `qa.parity.broadcast` is `same` (the default): *as root*, the root recipe with `reverb`
    in its parts, which makes its folders and installs the Reverb host's systemd unit, then
    `mroom baseline reverb`, which says whether it answers. Baseline installs this release's
    `reverb-host` with the packages its `composer.lock` pins, which takes Composer and PHP 8.3 or later at
    `/usr/bin/php`, and an empty apps file (mode 600, in `/var/lib/mroom/services/reverb/apps`). With
    `MROOM_QA_ZONE` set, it prints the nginx config of the host: create `ws.<zone>` as a site in Forge, with
    its certificate, and put the printed block in place of its `location` blocks.

**A box whose services ran before 0.5.0** keeps them in `~/.local/share/mroom-services`, and their logins
and Garage's secrets in `~/.config/mroom/secrets`. Move them in one sitting, with no QA environment coming up
or going down meanwhile: from step 1 to step 3 the gate looks for the services' files in their new folders,
so it refuses mail logins, buckets and Reverb apps, and a teardown in that time would leave them behind. Do
this for each part the box runs:

1. Upgrade the box to the release.
2. *As root*, the root recipe with the same parts. It makes the folders in `/var/lib/mroom/services` and
   installs the new units, and restarts each service, which then has nothing to run until step 3: QA mail,
   files and WebSockets are down from here to there.
3. `mroom baseline <part>`. It checks that the units are this release's and that nothing runs from the old
   folder any more, then moves the data into the new folders before it installs a build, so the service
   cannot start while its data moves: Mailpit's mail and SMTP logins, Garage's metadata, data and secrets
   (its node, layout, buckets and keys stay), and the Reverb host's apps. Then it installs the builds again.
   It checks every move of a part before it makes any: a name in both places that is not the same file
   stops it, with nothing moved. When `/home` and `/var` are separate filesystems, each move is a copy,
   which needs room for the data twice over. Each move goes under a hidden `.<name>.moving` first: the next
   run finishes one cut short once the old copy is gone, and stops while both are there, for a person to
   keep the complete one. Run again, it moves nothing.
4. Put the nginx blocks baseline prints in place of the old ones on `s3.<zone>`, `files.<zone>` and
   `ws.<zone>`: the sockets moved.
5. Remove `~/.local/share/mroom-services`, which holds only old builds and sockets now.

## QA environments

Each pull request can have a QA environment of its own on the box: `api.<N>.<zone>` for the Laravel app and,
for a frontend of its own, `<N>.<zone>`, with the services the QA gate gives it (design 8.2). Reusable
workflows run it; the app calls each from a workflow of its own, pinned to the mroom release the box runs
(`v0.5.0` below is the next release tag, the first with these host names; 0.4.0's workflows name the sites
differently):

| Workflow | Runs on | What it does |
|---|---|---|
| `qa-plan.yml` | a push to a pull request, or by hand | sorts the changed paths (could a user notice the change?), then builds the frontend from the pull request's code with public values only; it holds no secret |
| `qa-up.yml` | the QA plan run completing, or the plan's hand-over | brings the environment up or refreshes it, when a user could notice the change, the environment exists, the `qa` label is on, or a person started the plan |
| `qa-down.yml` | the pull request closing, its `qa` label coming off, the reaper, or by hand | tears the environment down: its daemons, its site user's processes and files, its sites, then its database, Redis user and keys, mail, buckets and Reverb app, through the gate |
| `qa-reap.yml` | a schedule, or by hand | starts a teardown for every environment older than `qa.ttl_days` (5) |

- **Who holds what.** Only jobs in the GitHub environment `qa` hold the Forge token and the box's SSH key,
  which reach root (design D20). `qa` admits the default branch alone, and those jobs check out only the
  default branch's `mroom.toml`, and mroom at the commit of the workflow file, so a pull request is only a
  number to them. Its code runs only in `qa-plan`, with no secret, and on the box, in its own isolated sites.
- **Forge is the source of truth.** An environment exists while Forge has one of its sites, a site being removed
  not counting. The zone is QA's alone: a site of it named `<N>.<zone>` or `api.<N>.<zone>` is environment N's. A
  Forge read that fails is retried and then fails the run, so it never reads as "no environment". Forge can
  accept a delete and never run it, so a site still removing after 30 minutes gets the delete again, and the
  reaper warns about it: the same one two nights running needs a person in Forge.
- **Environments of mroom before 0.5.0** have their sites at `api-<N>.<zone>` and `go-<N>.<zone>`, with their
  cookies set for the whole zone. They are found, counted, reaped and torn down like any, but not refreshed under
  the new names beside the old: a deploy to one stops before it changes anything and says to tear it down (`gh
  workflow run qa-down.yml -f pr_number=<N>`), and the next deploy brings it up under the new names. Moving to
  0.5.0, the box and the app's workflow pins move together, since the two releases name the sites differently,
  and the root recipe runs again as soon as 0.5.0 is installed: until the box has 0.5.0's `site-op`, the gate
  refuses work in a site, a teardown's included. With `MROOM_QA_CERTIFICATE` set, each API site now asks Let's
  Encrypt for its own. A browser that used an environment of before 0.5.0 keeps its cookies, set for the whole
  zone, until they expire. The new cookie names keep them from being read in place of the new ones, but Laravel's
  remember-me cookie keeps one name, so clear the zone's cookies once. Going back to 0.4.0 needs every
  environment torn down first: 0.4.0 neither sees nor deletes sites of the new names. 0.5.0 also wires
  `qa.parity.broadcast = "same"`, which 0.4.0 refused: an app that set `"log"` for that alone can drop it once
  the box has the Reverb host and its frontend maps what Laravel Echo reads (sockets in the frontend, below).
- **A teardown.** qa-down's first job only reads Forge, so a pull request that never had an environment gets no
  teardown; one started by hand or by the reaper skips it. The second job runs every step, each skipping what is
  already gone, whether or not Forge still has a site: daemons first, since supervisor starts again what is
  stopped, then `user-clean`, then the sites right after (design 8.9), then the box's side. A `user-clean` that
  fails keeps the sites. Once the sites are gone, the environment no longer takes a slot, so its
  slot is given on then, whatever the box's side comes to. When a step fails, the comment names it, and "Re-run
  failed jobs" or "Re-run all jobs" on that run finishes the teardown: the comment's hidden line keeps the state
  the teardown started from, which the check takes when Forge has no site left, as a teardown by hand or by the
  reaper does. Teardowns, their checks and deploys of one pull request take turns, first in first out, so none
  runs beside another and none waiting is dropped: a pull request closed during its first deploy is checked once
  that deploy has made its sites.
- **The reaper** starts the app's qa-down workflow for each environment past its time (reason `ttl`) rather
  than tearing it down itself, so each teardown takes its pull request's turn, frees its slot and can be
  re-run on its own; the reaper holds the Forge token and no SSH key.
- **The comment.** A pull request with an environment has one `### QA environment` comment, edited in place,
  that says whether it is ready, waits for a slot, failed, is being removed or was removed, and why. It is for
  people; its hidden line also tells which pull request gets a freed slot: the one that has waited longest, by
  the time it started waiting, which the comment keeps however often it is rewritten. A teardown that freed a
  slot ends with qa-down's wake job, of which one runs at a time for the repository, so two teardowns close
  together wake two pull requests, not one twice. The wake marks the pull request woken before it starts its
  QA plan again, so the next wake picks another; a woken one waits again after 30 minutes, and one whose plan
  could not be started at once. It reads the 100 newest open pull requests and their comments, one listing
  each, 100 a page, and no more. The wake's dispatch, made with the job token, does start the plan, but nothing
  after it starts by itself: a run the job token started starts no `workflow_run` when it ends, and neither
  does a run that one starts in turn. So each link of the chain starts the next itself: the plan hands itself
  to qa-up (its `hand-over` job, which needs `actions: write`), and qa-up, started that way, starts what
  follows it. The hand-over goes by the plan run's actor, so a person's re-run of a woken plan hands over too.
  When the label comes off a pull request with no environment, its comment stops saying it waits.
- **Caches.** qa-plan's build job runs the pull request's code, and a run started by hand or by a wake runs
  under the default branch, so it only reads caches (`cache-mode: read`): otherwise the pull request's code
  could save a poisoned cache that the default branch's own builds restore. Any workflow of the app's that
  runs a pull request's code under a trusted trigger (`workflow_dispatch`, `push`, `schedule` and the like)
  should do the same.
- **Which run deploys.** qa-up takes only the plan run's id from the event that started it, and everything
  else from GitHub's record of that run: a run of the app's plan workflow; for one started on `pull_request`,
  the one open pull request of the repository at its commit; for one started by hand or by a wake, the
  default branch's run named `PR #<N>`, at the commit its build job is named after. It deploys only the pull
  request's head: a run that waited its turn behind a newer push stops, and that push's own run deploys it.
- **What qa-up makes.** A Forge isolated site, and a second for a frontend of its own, in the home of one user of
  the environment's own, `<app>_qa_<N>` (design D17), each with a certificate (one that fails is deleted, waited
  for until Forge has it gone, and asked for again, once; failing again, it needs a person; one Forge installed
  but did not enable is enabled), and nginx set to follow a link only when the link and its target have one
  owner: `disable_symlinks if_not_owner` at the top of the site's config, the fragment each of its domains
  includes in each of its server blocks. Forge applies a new config later, so qa-up reads it back until it has
  the guard, and lets no code in before. Then the proof that it works on the box, before any code too: the gate's
  `probe-link` links the box's `site-op`, a root-owned file, into each site's web root, and the run stops if
  asking for that link still brings back that file, by the SHA-256 the gate gives, after as many tries as `/up`
  gets (nginx takes a config Forge has just written a moment later). The body is compared, not the status: with
  the guard, the request goes on to the app or the single-page fallback, which may well answer 200. A site's PHP
  version is set when it is made: a site that runs another than `app.php` is refused, with how to make it again.
  Any daemon or scheduled job of the environment that runs as another user is deleted before any code goes in,
  since it would run the pull request's code as that user: one that runs from one of the environment's folders,
  or whose command names one by its path (the site user's home and anything in it, or a path with one of the
  sites' domains as a whole part; a URL is no path, so a job that only asks a site for a page stays), and any
  scheduled job of the sites' own, which goes through its site's path. Then the code, as data: GitHub's tarball
  of the commit through the gate's `code-put`, with Vite's build put into it when Vite runs inside the Laravel
  app, and a frontend of its own through `dist-put`. Then the environment's services through the gate, as
  `[qa.parity]` says, its `.env` through `env-put`, and Forge's deploy, whose script runs as the site user or not
  at all, pulls nothing, then runs the tree's `.mroom/hooks/qa-deploy` (or composer install, `migrate --force`
  and `app.build.after_deploy`), then `.mroom/hooks/qa-fixtures` (or `php artisan mroom:qa-fixtures` when the app
  has it), then `queue:restart`. Then one queue worker for `app.build.queues`, which also runs as the site user
  or not at all, kept only when Forge's record of it names the site user, and made again when its command changed
  (other queues, another PHP). Then `/up`, asked up to 6 times 5 seconds apart, since a new site, or any site
  while PHP-FPM or nginx reloads, answers 502 for a moment; only once it answers 200 is the commit said to be
  deployed. Each step checks its own resource, so the next run repairs one that stopped halfway.
- **Slots.** The box holds as many environments as its memory does: its RAM, less `MROOM_QA_RESERVE_MB` (4096),
  in environments of `qa.env_memory_mb` (1024) each, and never more than `qa.max_envs` (5). qa-up asks the gate
  (`memory`) for a new environment, and the run's log says how many fit. Once they are all in use, a new one
  waits for a slot. While the box has less RAM available and free swap than one environment needs, it waits for
  the memory, and is tried again when an environment goes down or on a later push; the comment says which. A box
  whose memory holds none fails the deploy, saying so. Linux reports a little less RAM than the box was sold
  with, so an 8 GB box holds 3 environments by default, not `qa.max_envs` (5), and a 4 GB one none: on a small
  box, lower `MROOM_QA_RESERVE_MB` or `qa.env_memory_mb`. Upgrade the box before the app's workflow pins, since
  a gate older than qa-up has no `memory` and every new environment fails until it does. One whose code went
  in, by the gate's record (`env-sha`), is always refreshed. Two first deploys at once each count the others
  inside their own pull request's turn, so a new environment counts again once its site is made, by the order
  Forge made the environments' first sites in, and one past the slots gives way: its sites are deleted once
  Forge has made them, waited for until Forge has them gone, and deleted again once if they stay, since Forge
  can refuse a delete, or take one and never run it. One that will not go fails the run, and the next gives way
  again, since the environment's code never went in.
- **No required checks.** None of the QA workflows' checks can be a required one: the plan's build job is
  named after the commit it builds (`QA build <sha>`), so its name changes with every push, and a required
  check is matched by its name. The QA environment comment says how each deploy went; require the app's own
  CI.
- **When it says no.** A pull request that is closed, has moved on, or whose change no user could notice gets
  no environment. A build that failed, and a pull request whose `mroom.toml` puts the frontend elsewhere than
  the default branch's (qa-up deploys a build by the default branch's), each get a comment that says so, and
  the run stays green. The comment comes from the action's last step, which runs whatever happened before it,
  so a step that failed before it could say why is said too.
- **The `.env`.** `MROOM_QA_ENV_TEMPLATE` (third-party test-mode keys only: no app key, no credential for the
  box), less every entry whose key mroom sets (read entry by entry, so a quoted value of several lines stays
  whole), then mroom's: the `APP_KEY` the gate keeps for the environment, `APP_ENV=qa` (which Laravel counts as
  not production: a known gap, design 9), `APP_DEBUG=false`, `SESSION_SECURE_COOKIE=true` (the hosts answer over
  https alone, so the cookies never go over http), the public values below, the database, Redis user, host, port
  and prefixes the gate gives, and as `[qa.parity]` says: the mail login with plain SMTP to the box
  (`MAIL_SCHEME=smtp`, `MAIL_ENCRYPTION=null`, whatever the template says) for `catcher`, or `MAIL_MAILER=log`;
  for each disk of `qa.disks`, a bucket and a key of its own under Laravel's s3 env names with the disk's prefix
  in place of `AWS_` (`files = "AWS_"` gives `AWS_BUCKET`, `AWS_ACCESS_KEY_ID` and the rest; a disk in
  `qa.public_disks` also gets `<prefix>URL`), or `FILESYSTEM_DISK=local`; and `BROADCAST_CONNECTION=log`,
  unless `broadcast = "same"`. With `same`, the environment has an app of its own on the box's Reverb host, and
  the file gets `BROADCAST_CONNECTION=reverb` (and `BROADCAST_DRIVER`, its name before Laravel 11), the app's
  public values (below) and the secret the gate gives. An app with a frontend also gets `VITE_REVERB_APP_KEY`,
  `VITE_REVERB_HOST`, `VITE_REVERB_PORT` and `VITE_REVERB_SCHEME`, the build values Reverb's installer puts in a
  Laravel app's `.env`, set as a frontend that maps them (below) is built. qa-up stops before the `.env` when the
  gate's id, key, host, port or scheme is not the public one, since the frontend would open its sockets for another
  app or on another host. The file goes through the gate's `env-put` alone, never through Forge's API for a site's
  environment. The passwords and secret keys the gate gives, the Reverb app's secret among them, and the app key,
  are masked in the run's log, and a line of the gate's answer that could hold a value is never shown. The gate
  keeps the passwords, the bucket keys, the Reverb app's secret and the app key (QA gate, above), so every deploy
  gets the same ones: the environment's users stay signed in, and its open sockets keep their private channels.
- **What the plan builds.** `app.frontend_dir` is a folder for a frontend of its own (it gets the site
  `<N>.<zone>`), `.` for Vite inside the Laravel app, or empty for no frontend; `app.build.frontend` is the
  command, and without one nothing is built; `app.build.frontend_dist` is where it writes (`dist`, or
  `public/build` for Vite inside Laravel). In `app.build.frontend_env`, `env:<KEY>` is the environment's own
  value of a key it does not keep secret (`APP_URL`, `CLIENT_URL`, `SESSION_DOMAIN`, `SESSION_COOKIE`,
  `XSRF_COOKIE_NAME`, for a frontend of its own `CORS_ALLOWED_ORIGINS` and `SANCTUM_STATEFUL_DOMAINS`, and with
  `broadcast = "same"` the Reverb ones below), and any other `env:<KEY>` is empty, since the build runs the pull
  request's code. A frontend of its own reads the session and XSRF cookies the Laravel app sets, so they are set
  for `.<N>.<zone>`: no other environment's host is under it, and neither are the zone's shared hosts, Garage's
  and the Reverb host's. An app with no frontend of its own keeps them on its one host. Their names are the
  environment's own too, `<app>_qa_<N>_sid` and `<app>_qa_<N>_csrf`, and not those of before 0.5.0: a browser
  may hold cookies of those for the whole zone until they expire, and would send them first.
- **Sockets in the frontend.** With `qa.parity.broadcast = "same"`, the default, the plan's public values hold
  the environment's Reverb app too: `REVERB_APP_ID` and `REVERB_APP_KEY`, both `<app>-qa-<N>` from the pull
  request's number, as the gate makes them, and the box's Reverb host, `REVERB_HOST` (`ws.<zone>`),
  `REVERB_PORT` (443) and `REVERB_SCHEME` (https). The app's secret is never one of them. A frontend that opens
  its sockets with Laravel Echo maps what Echo reads:

  ```toml
  [app.build.frontend_env]
  VITE_REVERB_APP_KEY = "env:REVERB_APP_KEY"
  VITE_REVERB_HOST = "env:REVERB_HOST"
  VITE_REVERB_PORT = "env:REVERB_PORT"
  VITE_REVERB_SCHEME = "env:REVERB_SCHEME"
  ```

  The plan builds by the pull request's `mroom.toml`, and qa-up wires the environment by the default branch's.
  So a pull request whose `qa.parity.broadcast` is not the default branch's, one branched before the default
  branch changed it among them, gets a frontend built for its own setting until the two agree. The box needs the
  Reverb host first (QA gate, step 14). Without it, the gate gives no app: a deploy fails at that step, after its
  sites and code are in, and a teardown's Reverb step fails too.
- **The path rules.** The plan is `none` when every changed path is one no user can see: tests, docs, CI,
  agent and developer tooling; any other path, a path outside the app's folders included, makes it `maybe`.
  A renamed file counts with both its names, and a name that holds a control character, a newline among them,
  makes it `maybe` too.
  `qa.hidden_paths` adds paths no user can see (such as the app's console commands) and `qa.visible_paths`
  paths a user can, whatever the rules say (Markdown a page shows); each is a list of shell patterns in which
  `*` also matches `/`, and the visible ones are checked first.

**Set up once**, in the app's repository, besides the QA gate above:

1. A GitHub environment `qa`, deploying from the default branch only, with the secrets `MROOM_FORGE_TOKEN`,
   `MROOM_QA_SSH_KEY` (the private half of the key the box forces to `mroom gate provision`) and
   `MROOM_QA_ENV_TEMPLATE`. The variables `MROOM_FORGE_ORG`, `MROOM_FORGE_SERVER`, `MROOM_QA_SSH_HOST`,
   `MROOM_QA_SSH_KNOWN_HOSTS` (the box's host key line, as `ssh-keyscan -t ed25519 <host>` prints it, checked
   against the box's own `/etc/ssh/ssh_host_ed25519_key.pub`) and, when they apply, `MROOM_QA_SSH_USER` (when the
   box user is not `forge`), `MROOM_QA_CERTIFICATE` (a certificate in Forge to clone onto a frontend's site, such
   as one for `*.<zone>`; the API's site, `api.<N>.<zone>`, is a level below what that names, so it asks Let's
   Encrypt, as every site does without it, which checks the site over http: the box answers on port 80 for the
   zone's names) and `MROOM_QA_NGINX_TEMPLATE` (an nginx template for new sites) go in the repository's
   variables, not the `qa` environment's: none is secret, and every job of the called workflows reads the
   repository's, while GitHub's docs never say an environment's own reach a called workflow's job that sets
   `deployment: false`. Until `MROOM_FORGE_SERVER` is set, the workflows tear down and reap nothing, with a
   warning. The Forge token comes from an account whose only team holds the box, with exactly the scopes these
   calls need: `server:view`, `site:create`, `site:delete`, `site:meta`, `site:manage-ssl`, `site:manage-nginx`,
   `site:manage-deploys`, `server:create-daemons` and `server:delete-daemons`. Creating daemons reaches root
   (design D20), which is why only `qa` holds it. Every name and host the workflows build comes from the default
   branch's `mroom.toml` (`app.name`, `qa.zone`, the app's folders), and must match the box's `box.env`.
2. The label: `gh label create qa --description "Forces a QA environment on; taking it off tears it down"`.
3. The app's own workflows, which name a plan run started by hand or by a wake `PR #<N>`, so that qa-up can
   tell which pull request it was for:

```yaml
# .github/workflows/qa-plan.yml
name: QA plan
run-name: "${{ github.event_name == 'workflow_dispatch' && format('PR #{0}', inputs.pr_number) || format('QA plan · PR #{0}', github.event.pull_request.number) }}"
on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review, labeled]
  workflow_dispatch:
    inputs:
      pr_number: { description: The pull request to plan, required: true, type: string }
permissions:
  contents: read
jobs:
  qa:
    # No fork's and no Dependabot's pull request, and no label but qa.
    if: >-
      github.event_name == 'workflow_dispatch' || (github.event.pull_request.head.repo.full_name == github.repository &&
      github.event.pull_request.user.login != 'dependabot[bot]' && (github.event.action != 'labeled' || github.event.label.name == 'qa'))
    permissions:
      actions: write # the hand-over, for a plan the wake started; the build job itself only reads
      contents: read
      pull-requests: read
    uses: milroyfraser/mroom/.github/workflows/qa-plan.yml@v0.5.0
    with:
      pr: ${{ inputs.pr_number || github.event.pull_request.number }}
```

```yaml
# .github/workflows/qa-up.yml
name: QA environment up
run-name: "QA environment · ${{ github.event_name == 'workflow_dispatch' && format('PR #{0}', inputs.pr) || (github.event.workflow_run.pull_requests[0] && format('PR #{0}', github.event.workflow_run.pull_requests[0].number) || github.event.workflow_run.display_title) }}"
on:
  workflow_run:
    workflows: [QA plan]
    types: [completed]
  # The plan's hand-over, for a plan the job token started, which ends with no workflow_run.
  workflow_dispatch:
    inputs:
      pr: { description: The pull request, required: true, type: string }
      plan_run_id: { description: The QA plan run whose build to deploy, required: true, type: string }
permissions:
  contents: read
jobs:
  qa:
    permissions:
      actions: write # read the plan's run, and start next-workflows after a hand-over
      contents: read
      pull-requests: write
    uses: milroyfraser/mroom/.github/workflows/qa-up.yml@v0.5.0
    # with:
    #   next-workflows: qa-browser.yml # what follows qa-up on workflow_run, started by dispatch after a hand-over
    secrets:
      MROOM_FORGE_TOKEN: ${{ secrets.MROOM_FORGE_TOKEN }}
      MROOM_QA_SSH_KEY: ${{ secrets.MROOM_QA_SSH_KEY }}
      MROOM_QA_ENV_TEMPLATE: ${{ secrets.MROOM_QA_ENV_TEMPLATE }}
```

```yaml
# .github/workflows/qa-down.yml
name: QA environment down
on:
  pull_request_target:
    types: [closed, unlabeled]
  workflow_dispatch:
    inputs:
      pr_number: { description: The pull request whose environment to tear down, required: true, type: string }
      reason: { description: Why it goes, required: true, type: choice, options: [hand, ttl], default: hand }
permissions:
  contents: read
jobs:
  qa:
    if: github.event_name == 'workflow_dispatch' || github.event.action == 'closed' || github.event.label.name == 'qa'
    permissions:
      actions: write
      contents: read
      pull-requests: write
    uses: milroyfraser/mroom/.github/workflows/qa-down.yml@v0.5.0
    with:
      pr: ${{ inputs.pr_number || github.event.pull_request.number }}
      reason: ${{ inputs.reason || 'hand' }}
    secrets:
      MROOM_FORGE_TOKEN: ${{ secrets.MROOM_FORGE_TOKEN }}
      MROOM_QA_SSH_KEY: ${{ secrets.MROOM_QA_SSH_KEY }}
```

```yaml
# .github/workflows/qa-reap.yml
name: QA environment reap
on:
  schedule:
    - cron: "0 3 * * *"
  workflow_dispatch:
permissions:
  contents: read
jobs:
  qa:
    permissions:
      actions: write # to start a teardown for each environment past its time
      contents: read
    uses: milroyfraser/mroom/.github/workflows/qa-reap.yml@v0.5.0
    secrets:
      MROOM_FORGE_TOKEN: ${{ secrets.MROOM_FORGE_TOKEN }}
```

A caller passes the secrets by name, since `secrets: inherit` reaches only a workflow of the same
organisation, and the secrets resolve from the `qa` environment that the called job names. Since 8 December
2025, `pull_request_target` runs the default branch's workflow whatever a pull request's base, so a pull request
based on another branch tears down like any other. The workflow files' names above are the defaults the reusable
workflows start each other by (`plan-workflow`, `up-workflow`, `down-workflow` inputs); an app that names its own
otherwise passes them. A teardown by hand: `gh workflow run qa-down.yml -f pr_number=<N>`.

**A workflow that follows qa-up**, such as a browser check on `workflow_run` of the app's QA environment up
workflow, never starts after a qa-up run the job token started, since that run ends with no `workflow_run`
either. Name it in qa-up's `next-workflows`, and give it `workflow_dispatch` with the inputs `pr` and
`up_run_id`: qa-up starts it once its deploy ran, whether the environment came up or not, as the
`workflow_run` would have. It takes the rest from GitHub, how the deploy went included, from the run
`up_run_id` names, as qa-up does from its plan's run, and finds the runs it looks for by workflow and name,
never by the usual event alone, since a dispatched run is as much a run of its workflow as one `workflow_run`
started. It trusts only a run of the default branch's copy of the workflow, on `workflow_run` or dispatched on
the default branch, the one that started it included: a pull request's own copy of the workflow's file, or a
branch's, runs on events of its own and names its runs and jobs as it likes, and its runs start a
`workflow_run` too. qa-up goes by the run's first starter here too, so a person's re-run of a dispatched qa-up
starts it again; should that re-run also end with a `workflow_run`, it runs twice for one commit.

## CI templates

`templates/github/` holds CI workflows with the measured defaults of
[section 10 of the design](docs/design.md#10-cicd-defaults-measured). `mroom init` (phase 1, still to come)
copies them once into an app's `.github/`, and the app owns them from then on. Until then, copy them by hand
and fill the placeholders below.

| File | What it does |
|---|---|
| `workflows/ci-backend.yml` | static checks, the test shards, the `test` check, and a measuring mode |
| `workflows/ci-frontend.yml` | `lint`, the unit-test shards and the `unit-tests` check |
| `workflows/ci-e2e.yml` | the `e2e` check: browser tests against the served app |
| `workflows/ci-cache-warm.yml` | saves the dependency caches on the default branch |
| `workflows/ci-e2e-build-warm.yml` | saves the e2e frontend build on the default branch |
| `actions/changed-areas/` | which parts a pull request changes, so a job can skip its work and still report |
| `actions/setup-frontend/` | Node, pnpm (for pnpm), the package store (restore only) and the frontend's install |
| `actions/e2e-frontend-build/` | the e2e build: restored when its inputs are unchanged, built otherwise |
| `scripts/vitest-file-times.mjs` | a vitest reporter that records each test file's time |
| `workflows/deploy-production.yml` | the production deploy: the `release` branch at the tag, then `deploy-verify` ([below](#the-production-deploy)) |
| `scripts/release-branch.sh` | points the `release` branch at a release tag's commit, for the deploy |

What they do, in short:

- **Caches are saved only on the default branch** (by the two warm workflows) and only restored in pull
  requests. No template uses `actions/cache` (which saves from any branch) or setup-node's own cache.
- **apt's downloads are cached**, keyed on the lockfile that pins Playwright plus the ISO week, and the weekly
  save runs `apt-get autoclean` first.
- **The installed `vendor/` is cached** with a fallback key, so a changed lock starts from the last one.
- **Backend shards are split by measured time**, and the last shard, `rest`, excludes the named suites, so a
  new suite runs. Run the measuring mode (Actions, CI backend, Run workflow, tick `measure`) to get each
  suite's time and a suggested split. The frontend shards split by count; each uploads its files' times.
- **Required checks keep their names:** `test`, `lint`, `unit-tests` and `e2e`. Put these in the ruleset and
  in `pr.required_checks`, never a shard's name, so changing a shard count needs no ruleset change.
- **The e2e build is reused** when the frontend is unchanged, and built without source maps but minified.

After the templates merge, run each warm workflow once (`gh workflow run ci-cache-warm.yml`, and
`ci-e2e-build-warm.yml`), so the first pull request finds warm caches. `tools/ci-first-push.sh` measures what
a pull request's first push waits for; its defaults match the templates' job and step names.

Things to know:

- With pnpm, the frontend's `package.json` needs a `packageManager` field: `pnpm/action-setup` reads the
  pnpm version from it.
- The workflows have no `merge_group` trigger. With a merge queue, add `merge_group:` beside `pull_request:`,
  or the queue waits forever on the required checks.
- Actions are pinned by version tag, as GitHub's own docs show. The warm workflows run third-party actions
  (`shivammathur/setup-php`, `pnpm/action-setup`) on the default branch, where caches are written; pin
  them to a commit if that matters more to you than easy updates.
- The vitest reporter needs vitest 3 or later.
- `ci-e2e.yml` waits for Laravel's `/up` route (Laravel 11 and later), and expects Playwright in the backend
  folder's Node lockfile, as Pest's browser plugin has it: the backend folder needs a `package.json`.
- In a public repository, GitHub turns off a scheduled workflow after 60 days with no activity. Turn the weekly
  cache warm back on in the Actions tab if that happens.

**Placeholders.** A `<<key>>` is filled from `mroom.toml` or the repository; a `<<fill:name>>` is a value
config cannot know, and a person fills it. When a folder is `.` and a `/` follows the placeholder, both go:
`<<app.backend_dir>>/vendor` becomes `vendor`. An app with no frontend (`app.frontend_dir = ""`) is not
supported yet: the Node steps would build their paths from the repository's root.

| Placeholder | Filled with |
|---|---|
| `<<app.backend_dir>>` | `app.backend_dir` |
| `<<app.frontend_dir>>` | `app.frontend_dir` |
| `<<app.php>>` | `app.php`, such as `8.4` |
| `<<app.package_manager>>` | `app.package_manager`: `npm` or `pnpm` |
| `<<app.build.frontend_dist>>` | `app.build.frontend_dist`; by default `dist`, or `public/build` when `app.frontend_dir` is `.` |
| `<<tests.command>>` | `tests.command`; a shard adds its `--testsuite` options |
| `<<tests.database>>` | `tests.database_pattern` with `{app}` as `app.name` and `{slug}` as `ci` |
| `<<default_branch>>` | the repository's default branch, such as `main` |
| `<<pm.lockfile>>` | `package-lock.json` (npm) or `pnpm-lock.yaml` (pnpm) |
| `<<pm.install>>` | `npm ci` or `pnpm install --frozen-lockfile` |
| `<<pm.exec>>` | `npx` or `pnpm exec` |
| `<<pm.store_path>>` | `npm config get cache` or `pnpm store path --silent` |
| `<<fill:node_version>>` | the Node version for CI, such as `22` |
| `<<fill:backend_static_checks>>` | the backend checks that need no database, such as `vendor/bin/pint --test` |
| `<<fill:slowest_suite>>` | a phpunit suite that needs a shard of its own; the measuring mode shows which (add more shards like it) |
| `<<fill:e2e_suite>>` | the phpunit suite of the browser tests, which the backend shards leave out |
| `<<fill:measured_times>>` | each suite's measured time and the date, as a comment for the next rebalance |
| `<<fill:frontend_lint>>` | the frontend's lint, format and type checks, such as `pnpm lint && pnpm exec tsc --noEmit` |
| `<<fill:frontend_src>>` | the frontend's source folder inside its own: `src` for a separate SPA, `resources` for Vite inside Laravel (then add the other folders Tailwind scans to the build's key) |
| `<<fill:e2e_build>>` | the build without source maps but minified, with the env it needs, such as `VITE_API_URL=http://127.0.0.1:8000 pnpm exec vite build --sourcemap false` |
| `<<fill:e2e_command>>` | the browser tests, failing when none are found, such as `php artisan test --testsuite=Browser --fail-on-empty-test-suite` |
| `<<mroom_version>>` | the mroom release whose actions the deploy uses, such as `v0.6.0` (the one `mroom init` runs as) |
| `<<fill:backend_origin>>` | the Laravel app's production origin, such as `https://api.shop.example.dev` |
| `<<fill:frontend_origin>>` | a separate SPA's production origin, whose `/version.json` the deploy also waits on; empty for none |
| `<<fill:tag_pattern>>` | the release tags, as a bash regular expression, such as `^v[0-9]+\.[0-9]+\.[0-9]+$` |

### The production deploy

`workflows/deploy-production.yml` ships a release tag, never a branch tip, and waits until production runs it
([design section 10](docs/design.md#10-cicd-defaults-measured), patterns 8 to 10). Publishing a GitHub release
starts it; a person deploys another tag, a rollback included, with
`gh workflow run deploy-production.yml --ref <tag>`. The run takes no input: the tag is the ref it runs for.

- **`release`**, in the GitHub environment `production`: checks out the tag with the deploy key, and
  `scripts/release-branch.sh` points the `release` branch at the tag's commit. It refuses a run that is not from a
  tag matching `<<fill:tag_pattern>>`, a release whose tag is not the run's, and a tag whose commit is not on the
  default branch. The branch moves forward for a release, back for a rollback (with a warning), or stays for a
  re-run; when someone else moved it (to a commit off the default branch, or neither before nor after the tag),
  the job stops for a person. Then, when `MROOM_DEPLOY_HOOK` is set, it calls the host's deploy hook. This job
  builds and installs nothing, and runs no action but `actions/checkout`, since it holds the key.
- **`verify`**, with no environment and no secret: `deploy-verify` asks `app.version_path` (and a separate
  SPA's `/version.json`) with a query no cache has seen, every 10 seconds, until each reports the tag's commit
  three times in a row with `/up` answering 200, and fails after 10 minutes. A fixed sleep and a health ping
  pass when the host's deploy failed, since the old release answers too; the commit cannot. When the app names
  another release for the right commit (two tags on one commit, or no tag found), it warns and still passes.
- **One deploy at a time:** the whole run takes the group `deploy-production` and never cancels one in
  progress, so a second deploy waits until the first is verified.

What the app sets up once:

1. **The version endpoint** (design section 9): `app.version_path` answers `{"release": "<tag>", "commit":
   "<sha>"}` with `Cache-Control: no-store`, from a file the host's deploy script writes from the code it
   checked out (`git describe --tags --exact-match`, `git rev-parse HEAD`), never from config set separately.
   A separate SPA's build writes the same to `version.json`.
2. **The host deploys `release`:** the Forge site's branch is `release`, with Quick Deploy on, or Quick Deploy off
   and the site's deploy hook URL in the `production` secret `MROOM_DEPLOY_HOOK` (one or the other: with both, it
   deploys twice). A separate SPA's host deploys the same branch, or the app adds a job of its own between
   `release` and `verify` that builds the tag. The deploy script restarts the workers and clears caches, so a
   rollback runs the old code.
3. **A deploy key** with write access (`ssh-keygen -t ed25519 -N '' -f release-key`; Settings, Deploy keys, Allow
   write access), its private half in the `production` secret `MROOM_RELEASE_KEY`, and no other deploy key with
   write access.
4. **The GitHub environment `production`:** deployment branches and tags limited to tags matching the release
   tags (such as `v*`), required reviewers who are people, and "Prevent self-review", so each deploy is approved
   by a person other than the one who started it (design 8.8, D22).
5. **A ruleset on `release`** (target `refs/heads/release`): restrict creations, updates and deletions, and block
   force pushes, with deploy keys as the only bypass. Without it, any account with Write, the agents' included,
   could push the branch production deploys.
6. **Who may create release tags:** a tag ruleset, so that only people can make one. The environment admits any
   tag that matches, and the workflow file at that tag is the one that runs with the deploy key.

A re-run of the same tag leaves the branch where it is: Quick Deploy then deploys nothing and `verify` passes at
once, while a deploy hook deploys again.

`actions/deploy-verify` can also be used on its own, from any job after a deploy: its inputs are `origin`,
`frontend-origin`, `commit` (the full SHA), `tag`, `health-path` (`/up`; empty for none), `timeout` (`10m`),
`interval` (`10s`) and `config` (the app's `mroom.toml`, for `app.version_path`).

## Regression label

A pull request that fixes a problem a release caused in production carries the `regression` label and
names that release in its body. The label is the record behind two measures of the design (section 1.2):
production problems per release, and the time from a release to the first report of a problem.

```text
Breaks: v1.2.3
Reported: 2026-10-20T09:15Z    optional: when the problem was first reported (a date, or a UTC time)
```

Without a `Reported` line, the time the pull request was opened counts as the first report. Lines inside
HTML comments and fenced code blocks do not count, nor does a line with no value, so a pull request
template can carry the line for the author to fill in:

```markdown
## Regression

Breaks: <!-- the release that shipped the problem this PR fixes, such as v1.2.3; leave empty if none -->
```

Filled in, the line marks the pull request as a regression fix, and the check then asks for the label too.
Set it up once in the app's repository:

```bash
gh label create regression --color B60205 --description "Fixes a production problem a release caused"
```

and add the check to its workflows:

```yaml
on:
  pull_request:
    types: [opened, edited, synchronize, reopened, labeled, unlabeled]
permissions:
  contents: read
  pull-requests: read
jobs:
  regression-label:
    runs-on: ubuntu-latest
    timeout-minutes: 2
    steps:
      - uses: milroyfraser/mroom/actions/regression-label@v0.4.0
```

The check fails when the label and the `Breaks` line do not come together, when the release does not exist
or is a draft, or when `Reported` is malformed, earlier than the release, or in the future. It reads the
pull request from the event file and prints only values it has checked, so text in a PR body cannot send
a workflow command.

Count both measures from a checkout of mroom, on any machine with `gh` signed in:

```bash
tools/regressions.sh example/shop 2026-07-01
# Releases published since 2026-07-01: 85; with a reported problem: 5
# Production problems per release: 0.07 (6 over 85)
# Time from a release to the first report of a problem: median 21h, longest 6d 2h (6 problems)
```

## Claude review

A reusable workflow gives each pull request one full Claude review, then follow-ups. The full review marks
each finding 🔴 blocking, 🟡 optional or 🟣 pre-existing, with at most 5 optional ones. A later push gets a
follow-up that only re-checks the earlier blocking findings (✅ fixed, ❌ still open, or 💬 settled by a
reply) and looks for new blocking ones in what changed since. It raises no new nits. Each review ends with
a hidden line naming the commit it reviewed, and the earlier reviews are folded as outdated.

The app calls it on `pull_request`, pinned to a mroom release (`v0.5.0` below stands for the first release
that has it), and passes its Claude Code OAuth token or Anthropic API key under the name the workflow
expects:

```yaml
# .github/workflows/claude-review.yml
name: Claude review
on:
  pull_request:
    types: [opened, synchronize]
permissions:
  contents: read
jobs:
  claude:
    permissions:
      contents: read
      pull-requests: write # to post the review and fold the earlier ones
      issues: read
      id-token: write # the Claude GitHub app's token
    uses: milroyfraser/mroom/.github/workflows/claude-review.yml@v0.5.0
    with:
      paths: |                      # review only a change that touches these (empty: every change)
        backend/**
        frontend/**
      review-guide: .claude/commands/review.md   # the app's review standard (empty: none)
      review-guide-paths: |         # the code the guide covers (empty: every reviewed path)
        backend/app/**
        backend/tests/**
      # reviewer: claude[bot]                        the login that posts the review, the default
      # allowed-bots: claude[bot],github-actions[bot]  bots whose pull requests are reviewed too
    secrets:
      CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }} # or ANTHROPIC_API_KEY
```

Patterns match as a workflow's own `paths` do: `*` and `?` stay inside one folder, `**` crosses folders. A
rename counts by both names. The review guide is any Markdown file on the default branch: a review command,
a style guide or a checklist. In a full review that touches the guide's paths, Claude checks the changed code
against it. A rule the guide marks blocking is 🔴 only at a line the pull request adds or changes.

How it keeps the secret away from pull request code (design 8.1 and 8.5):

- A `scope` job, with no secret, reads the event and the changed files and decides whether to review.
- The `review` job holds the secret. It checks out the app's default branch, for its `CLAUDE.md`, the
  review guide and the code around the change, and mroom at the commit of the called workflow. It never
  checks out the pull request. Claude reads the diff and the conversation through `gh`, as data.
- A fork's pull request and Dependabot's get no review, whatever the caller's trigger. Nor does one based on
  another branch than the default: the action restores `.claude/`, `CLAUDE.md` and `.mcp.json` from the base
  branch, and their hooks would run next to the secret.
- The pinned `anthropics/claude-code-action` and its tool allowlist live in one composite action
  (`actions/claude-review`). Claude may read files, read issues and pull requests, and comment on this pull
  request; nothing else. Deny rules keep its reading tools out of the checkout's `.git` (where the action
  puts its token), the runner's temp folder, `~/.claude`, `/proc` and `/sys`.
- One review per pull request runs at a time: a newer push cancels the older review.

The Claude GitHub app must be installed on the repository (`/install-github-app` in Claude Code sets it up and
stores the token). The runner sandbox comes in phase 2b; until then the allowlist and the default-branch
checkout are the box. Text in the diff and the comments can still try to steer Claude. The deny rules on
`gh pr comment` (no `--body-file`, no `-F`) match a command's start only, so they are best effort: an
injected prompt that gets `gh` to read a file could still post it. The sandbox's clean environment closes
that.

## Review findings

A check run on the pull request's head commit, `Review findings`, that is red while the latest Claude review
has an open 🔴 blocking finding. It also reads a table the author's session may post, headed
**Review findings and how each was resolved**: a row with neither ✅ nor ➖ in any cell keeps it red. Only a
table by the pull request's author or the repository's owners, members and collaborators counts. With
no review and no table it is neutral, "Not reviewed yet". A review whose format it cannot read is neutral too,
unless the table is red.

```yaml
# .github/workflows/review-findings.yml
name: Review findings
on:
  pull_request_target:
    types: [opened, synchronize, reopened, ready_for_review, edited]
  issue_comment:
    types: [created, edited, deleted]
  workflow_run:
    workflows: [Claude review] # the review workflow's name
    types: [completed]
permissions:
  contents: read
jobs:
  findings:
    permissions:
      contents: read
      pull-requests: read
      issues: read
      checks: write # to post the check run
    uses: milroyfraser/mroom/.github/workflows/review-findings.yml@v0.5.0
    # with:
    #   reviewer: claude[bot]          # the login that posts the review, the default
    #   check-name: Review findings    # the default
```

Every run rereads the pull request's comments, so any of these events gives the same answer. Only a pull
request's comments that are, or were, a review or a findings table wake it. `workflow_run` is a backstop for
a review comment whose own event started nothing. The triggers all run the default branch's copy of this
workflow, so a pull request cannot change what checks it. It reads the pull request through the API, checks
out only mroom and holds no secret. Text from a comment in the summary is escaped: no mentions, no HTML, no
links.

The check is a signal for the person who reviews, not a gate. GitHub counts a neutral check as passing, and
any workflow with `checks: write`, one a pull request adds among them, can post a check run of the same name.
The gate is a person's approval of the latest push, which shows such a change.

## PR status

The persona keeps one status note on each pull request, edited in place, and pings the author in chat
only when they must act. The note has a line each for the QA environment, CI, the Claude review, the
review findings check and browser QA, and each line names the commit it refers to and links what it
rests on:

```
✅ **Agent's notes** · ready for review

- **Environment:** ✅ [app](https://42.qa.example.dev) · [API](https://api.42.qa.example.dev) · [comment](…) · `aaaaaaa`
- **CI:** ✅ 4/4 required pass · [checks](…) · `aaaaaaa`
- **Claude review:** ✅ [no blocking findings](…) · `aaaaaaa`
- **Review findings:** ✅ [No open findings](…) · `aaaaaaa`
- **Browser QA:** not set up
```

What was not checked says "not run" or "unknown", never a pass, and an unknown or pending line keeps
the pull request from ready. When two lines disagree (CI green but browser QA failed, an environment
serving an older commit than the head), the note asks an **Open question** with the next thing to
check. It is a reusable workflow, `.github/workflows/pr-status.yml`, with the composite action
`actions/pr-status`, which the app calls from a workflow of its own:

```yaml
# .github/workflows/pr-status.yml
name: PR status
on:
  pull_request_target:
    types: [opened, synchronize, reopened, ready_for_review, converted_to_draft, closed]
  workflow_run:
    # Each workflow's name: what the note reads, so it updates when one completes.
    workflows: [CI, Claude review, QA plan, QA environment up]
    types: [completed]
  # By hand; by the called workflow itself (relay, retry-closed); and by qa-up, when it is in its
  # next-workflows, which passes up_run_id too.
  workflow_dispatch:
    inputs:
      pr: { description: The pull request to update, required: true, type: string }
      up_run_id: { description: The qa-up run that started this one, if any, required: false, type: string }
permissions:
  contents: read
jobs:
  status:
    permissions:
      actions: write # to start this workflow again for a qa-up run's or a closed pull request's update
      checks: read
      contents: read
      issues: write
      pull-requests: write # to write the note
    uses: milroyfraser/mroom/.github/workflows/pr-status.yml@v0.5.0 # the first release with PR status
    with:
      pr: ${{ inputs.pr }}
      # review-check: claude / review   # the Claude review's check run: <your caller job> / review
      # findings-check: Review findings # empty when the app has no review findings check
      # browser-check: ""               # the browser QA check run, once the app has one (phase 2b)
      # qa-workflow: qa-up.yml          # your qa-up workflow's file, and qa-up-name its name
      # qa-up-name: QA environment up
    secrets:
      MROOM_CHAT_TOKEN: ${{ secrets.MROOM_CHAT_TOKEN }}
```

The review findings check runs on events of its own (README, Review findings), and a check the job token
posts starts no workflow, so the app's review findings workflow runs the note after its check, as a second
job:

```yaml
# .github/workflows/review-findings.yml, after its findings job
  status:
    needs: findings
    if: always() && needs.findings.result != 'skipped' && (github.event_name != 'issue_comment' || github.event.issue.pull_request)
    permissions: { actions: write, checks: read, contents: read, issues: write, pull-requests: write }
    uses: milroyfraser/mroom/.github/workflows/pr-status.yml@v0.5.0
    with:
      pr: ${{ github.event.pull_request.number || github.event.issue.number || github.event.workflow_run.pull_requests[0].number }}
    secrets:
      MROOM_CHAT_TOKEN: ${{ secrets.MROOM_CHAT_TOKEN }}
```

And a qa-up run that the job token started ends with no `workflow_run` (README, QA environments), so name
`pr-status.yml` in qa-up's `next-workflows`.

```toml
[persona]
name = "Agent"                          # the name on every note and ping
channel = "C0123456789"                 # the chat channel pings go to (a Slack channel id)
chat_users = ".github/chat-users.json"  # the chat user map, the default

[github]
agent_login = "shop-agents"             # the box's agents' GitHub account (design D22)

[issues]                                # optional: pings link the pull request's issue
id_pattern = "SHOP-[0-9]+"
url = "https://tracker.example.dev/issue/{id}"
```

- **Pings.** One goes out when CI turns red, the review has blocking findings, the deploy fails, or
  browser QA fails or cannot verify, and once per pull request when it is ready for review. Each says
  what happened, links the evidence, the pull request and its issue, and ends with the question for the
  author. None for a draft or a closed pull request, and none for one by anyone but the repository's
  owner, members and collaborators, or from a fork: on a public repository anyone can open one. Those
  get the note alone.
- **Whom a ping mentions.** The chat user map, a JSON object in the app's repository read from the default
  branch, maps a GitHub login or a commit email to a Slack user id (`{"dev1": "U0123456789"}`); an entry
  whose value is not a user id is dropped. The author of a pull request is mentioned through it, or
  named when it has no entry. An agent's pull request (opened as `github.agent_login`) mentions the
  author of its first commit, since a profile commits under its developer's name: by GitHub account,
  else by email. Later commits never count. A first commit the map knows by neither, such as the
  agents' own, mentions the developer the map names for `github.agent_login`.
- **One note, one ping per change.** The note ends with a hidden line, `<!-- mroom-pr-status pr=42
  final=0 sent=… -->`, holding the pings already sent, each keyed by commit, kind and outcome. A ping is
  recorded in the note before it goes out: when the note cannot be written, none goes; when a ping fails
  after that, it is missed, not sent again. Should a person's edit lose the hidden line, the note is found
  by its footer and edited in place, and since what was sent is lost with it, that run's pings and the
  ready ping are recorded without being sent; only a failure that goes away and comes back on the same
  commit could ping twice then. Should there be two notes (a post whose answer was lost, then another),
  the oldest is kept current, the pings any of them recorded count, and the others are edited once to say
  they are copies. Deleting the note resets its pings.
- **Closed pull requests.** A closed pull request's note shows the final state and is left alone until it
  reopens. It is marked final only once GitHub took that edit, and every `workflow_run` also retries the
  pull requests closed in the last day whose note is not final yet.
- **Which events.** Every run rebuilds the note from GitHub (the pull request; the required checks of the
  rulesets and the branch protection on its base branch, or `pr.required_checks` when those name none; the
  check runs on its head; its comments; and the app's latest qa-up run with its deploy job), so it does
  not matter which event woke it. A qa-up run links no pull request, so the called workflow's `relay` job
  starts the app's workflow by dispatch for the number its run-name ends in. That name can come from a
  fork's own QA plan, so a run counts only when its deploy job, which qa-up names after the pull request
  it resolved itself (`QA deploy · PR #42`), names this one, and only a run of the default branch's copy
  of the workflow (on `workflow_run`, or dispatched on the default branch): a pull request's own copy of
  its file, or a branch's, names its runs and jobs as it likes. One update per pull request runs at a time.
  A pull request based on another branch than the default gets no note.
- **Secrets.** Only the chat bot's token (`chat:write`, invited to the channel), in the `persona`
  environment (design 8.8; default branch only), never a repository or organisation secret. Without it
  the note is still kept, and no pings go out until it is set. The note is written with the job token.
  No trigger runs a pull request's own copy of the app's workflow (`pull_request_target` runs its base
  branch's, the others the default branch's), the update runs only for a pull request based on the
  default branch, the jobs check out only the default branch's `mroom.toml` and mroom at the commit of
  the workflow, and the pull request is read as data, through the API. Text in the note that does not
  come from mroom, such as a check's name or title, is escaped, with no mentions and no links, and so is
  the title in a ping.
- **A dry run.** `actions/pr-status/pr-status.sh <pr>`, run anywhere without `MROOM_PR_STATUS_LIVE=1`,
  prints the note, what it would do with it, and the pings, and changes nothing.

For now the note lives on the pull request, as the design's tracker `none` has it, even when the app has
a tracker; keeping it on the tracker's issue instead comes with the tracker adapter. The note is a signal,
not a gate. A pull request's own workflow can post a check run of any name, such as a required check's
or `Review findings`, and can post as `github-actions[bot]`, so it could make its own note show a pass
or forge its hidden line. The gate is a person's review of the latest push, and the required checks
GitHub itself enforces.

## Development

```bash
tests/run.sh               # every test: offline, each in a temp HOME
tests/run.sh config box    # only tests/config-test.sh and tests/box-test.sh
tests/run.sh --skip qa-up  # all but tests/qa-up-test.sh, which CI runs in a job of its own
```

The tests need what the box needs (bash 5, python3 3.11+); on a host without them the TOML and install
tests skip locally, and CI on `ubuntu-latest` runs them all, plus shellcheck on every shell script and an
install on a bare `ubuntu:24.04` container. Releases are cut by hand: [docs/releasing.md](docs/releasing.md).

## Licence

MIT, see [LICENSE](LICENSE). Third-party material is listed in [NOTICE](NOTICE).
