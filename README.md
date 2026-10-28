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
[guard, the plugin's skeleton and the settings fragments](#guard-and-settings). Every other command prints
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
`mroom config keys` lists every key, its type, and whether it is required.

```bash
mroom config get app.name                  # shop
mroom config get app.build.daemons         # one item per line
mroom config get app.build.daemons --json  # ["horizon", "reverb"]
mroom config get app.build --json          # a whole table, as JSON
mroom config get app.php --default 8.4     # a fallback when the key is not set
mroom config validate                      # check the whole file
mroom config path                          # which mroom.toml was found
mroom config keys                          # every key the schema knows
```

Strings print raw, lists one item per line, tables of strings as `KEY=value` lines, and `--json` prints
JSON. `--default` takes the key's type: a number for a number, JSON for a list or table
(`--default '[]'`). A missing required key fails with its name and an example line; a wrong type fails
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
  credentials, through any reader, interpreter or redirection; `gh auth token`.

```bash
mroom guard check 'true && git push --force origin feat/x'   # exit 2, and why
mroom guard check 'git push -u origin feat/x'                # allowed
```

**It is a speed bump, not a boundary.** A command built from variables (`$CMD`) or from another
command's output (`cat $(echo x)`), a script file (`bash x.sh`), an alias already in a config file
or `ssh host 'cmd'` gets past it. Without jq or
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
| `base.json` | every app: git and gh reads, pushes and releases ask, merges, approvals, force-pushes and secret reads denied |
| `laravel-vite.json` | Laravel and Vite: tests, linters and builds allowed; migrations, seeds and tinker ask |
| `forge.json` | Forge: `forge-api GET` allowed; the Forge CLI and its tokens denied |
| `tracker-linear.json` | a Linear tracker: GitHub issue writes denied |

The merge joins every list. Claude Code checks deny first, then ask, then allow, so an `allow` rule
never overrides an `ask` or a `deny`. `tests/settings-test.sh` checks each fragment and what the
merged set decides for common commands.

## QA gate

CI never gets a shell on the box (design 8.2). The QA runner's SSH key is forced to `mroom gate`, which
runs only the operations of its role and builds every name itself, so a request can reach nothing but its
own environment. Phase 2a adds operations one PR at a time; today the `provision` role has:

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

The client sends only N, and the few words some operations also take, each of a fixed form. The
database, role and Redis user are `<MROOM_APP_NAME>_qa_<N>`, and the database is cloned from
`MROOM_QA_TEMPLATE`, both set by a person in `box.env`. A bucket is `<MROOM_APP_NAME>-qa-<N>-<disk>`, each
`_` of the name a `-`, for the disk name `bucket-create` takes: `[a-z][a-z0-9]{0,15}`, with no `-` in it, so
no disk's bucket is another environment's or another disk's. Its Reverb app's id and key are both
`<MROOM_APP_NAME>-qa-<N>`: public, so the frontend builds without a secret, and the PR's alone, so no other
PR is ever given an id whose sockets may still be open. A password reaches
Postgres only as a SCRAM verifier, through stdin, and Redis only as its SHA-256. Each request and refusal
is logged, never a secret, to `~/.local/state/mroom/gate.log` and to syslog.

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

An environment's two sites, `api-<N>.<MROOM_QA_ZONE>` and `go-<N>.<MROOM_QA_ZONE>`, are Forge isolated
sites in the home of one user of their own, `<MROOM_APP_NAME>_qa_<N>` (D17); qa-up creates them. The
gate works in them only through `site-op`, run as that user with `sudo`, so it never unpacks a tarball,
follows a PR's link or runs its code as the box user. `site-op` runs only as a QA site's user, and only on
that environment's own `api-<N>` and `go-<N>` sites:

- **Unpacking** uses Python's safe tarfile filter: no absolute path, no `..`, no link that leaves the
  tree, no device file, no setuid bit, and no oversized header. A code tree must be GitHub's one folder
  named after the commit, a cut-off upload fails on gzip's checksum, and the tree replaces the site's whole
  tree except the backend's `.env` and `storage/`. Any `.env` in the tarball is skipped, a link at `.env`,
  `storage` or `bootstrap/cache` refuses the tarball, and the gate writes `version.json`
  (`{"release": null, "commit": "<sha>"}`) into the backend, since a tarball has no git history.
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
- **Its limits.** A browser may open its sockets only from the environment's two sites, at most 100
  subscribed at once, and only a socket subscribed to a channel may send client events on it. The host closes
  a socket it refuses; Reverb itself only sends the error. It also gives each client event to its own app:
  Reverb 1.12.0 looks the channel up in whichever app it served last, so with more than one app a valid one
  is refused at random (fixed upstream after 1.12.0).
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
  what a run that stopped halfway left. systemd itself, as root, still resolves the units' bind paths in the
  box user's home each time a service starts (design D21 notes this limit).
- Never give a token on the box a `recipe:*` scope: even `recipe:view` runs any saved recipe.

<!-- root-recipe: tests/root-test.sh checks sum against lib/root-setup, and runs this block -->
```bash
set -euo pipefail
v=v0.4.0
sum=7a50f8014b0b6582f922efa6f7224f1f1d8d9bfd10caa82d32a95712906e6c9c
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
   options):

   ```
   restrict,command="/home/forge/.local/bin/mroom gate provision" ssh-ed25519 AAAA… mroom-qa-up
   ```

2. As a Postgres superuser (`sudo -u postgres psql`). `\password` asks for each password, so none ends up
   in a history file or the server's log:

   ```sql
   CREATE ROLE shop_qa_gate LOGIN CREATEDB CREATEROLE;
   \password shop_qa_gate
   CREATE ROLE shop_qa_objects NOLOGIN;      -- owns the template's objects; never a database or tablespace
   GRANT shop_qa_objects TO shop_qa_gate;
   CREATE ROLE shop_qa_envs NOLOGIN;         -- every environment's role joins it; never grant it anything
   GRANT shop_qa_envs TO shop_qa_gate WITH ADMIN OPTION;
   CREATE DATABASE shop_qa_template OWNER shop_qa_gate;
   GRANT CONNECT ON DATABASE shop_qa_template TO shop_qa_objects;
   \c shop_qa_template
   GRANT CREATE ON SCHEMA public TO shop_qa_objects;
   ```

3. Build the template as `shop_qa_objects`, so its objects belong to that role. Give it a login for now
   (`ALTER ROLE shop_qa_objects LOGIN;` and `\password shop_qa_objects`), run the app's migrations and
   seeders against `shop_qa_template` as that role, then take the login away:

   ```sql
   ALTER ROLE shop_qa_objects NOLOGIN PASSWORD NULL;
   REVOKE CONNECT ON DATABASE shop_qa_template FROM PUBLIC, shop_qa_objects;
   ```

   `shop_qa_objects` must never own a database or a tablespace. Each new environment takes over what that
   role owns, and the gate refuses to run while it owns one.

4. Every new database lets any role connect, so take that back on each of the app's databases, the dev
   site's for one (not `postgres`, which the gate connects to):

   ```sql
   REVOKE CONNECT ON DATABASE shop_dev FROM PUBLIC;
   ```

5. At the very top of `pg_hba.conf`, above every `local` and `host` line, then reload Postgres. The first
   matching line wins. The gate's own line comes first, since the gate belongs to `shop_qa_envs` and the
   reject lines would match it too. Each environment's role then reaches only the database named after it:

   ```
   host   all       shop_qa_gate   127.0.0.1/32  scram-sha-256
   host   all       shop_qa_gate   ::1/128       scram-sha-256
   host   sameuser  +shop_qa_envs  127.0.0.1/32  scram-sha-256
   host   sameuser  +shop_qa_envs  ::1/128       scram-sha-256
   host   all       +shop_qa_envs  all           reject
   local  all       +shop_qa_envs                reject
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

11. In `box.env`: `MROOM_APP_NAME=shop`, `MROOM_QA_TEMPLATE=shop_qa_template` and
    `MROOM_QA_ZONE=qa.example.dev`, and when they differ from the defaults, `MROOM_QA_BACKEND_DIR` (the
    Laravel app's folder in the repository, `.`), `MROOM_QA_PHP` (`php`) and `MROOM_QA_PERSONA_DOMAIN`
    (`.test`). A site user's name is at most 32 characters, so an app name of 19 characters or fewer always
    fits.

12. The mail catcher, when `qa.parity.mail` is `catcher` (the default): `mroom baseline mailpit`, then,
    *as root*, the root recipe with `mailpit` in its parts, then `mroom baseline mailpit` again. Baseline
    downloads Mailpit at the build `lib/core/pins.txt` names, refuses it unless the archive and the binary
    match their SHA-256 pins, puts mroom's mail relay beside it and makes their logins (mode 600, in
    `~/.config/mroom/secrets`). The recipe installs three systemd units and starts them: the socket on
    `127.0.0.1:1025` (`MROOM_QA_SMTP_PORT` in `box.env`, and the recipe's `smtp_port`, to change it), the
    relay and Mailpit, both run as the box user. Baseline can run again: what is in place is kept, it
    restarts the relay or Mailpit itself when their files changed (systemd holds the port meanwhile), and it
    says when the installed units are not this release's, which the recipe then rewrites. Nothing else may
    listen on the port: on a box that ran an earlier mail catcher there, stop that first.

13. The file store, when `qa.parity.files` is `same` (the default): `mroom baseline garage`, then, *as
    root*, the root recipe with `garage` in its parts, which installs Garage's systemd unit, then
    `mroom baseline garage` again, which gives Garage its one-node layout. Baseline downloads Garage at the
    build `lib/core/pins.txt` names and refuses any other, and makes its RPC secret and admin and metrics
    tokens (mode 600, in `~/.config/mroom/secrets`). With `MROOM_QA_ZONE` set, it prints the nginx configs
    of Garage's two hosts: create `s3.<zone>` and `files.<zone>` as sites in Forge, each with its
    certificate, and put the printed blocks in place of their `location` blocks. Forge's nginx runs as the
    box user, who alone can open Garage's sockets. The S3 host streams each body to Garage, so an unsigned
    upload is refused before nginx stores any of it.

14. WebSockets, when `qa.parity.broadcast` is `same` (the default): `mroom baseline reverb`, then, *as root*,
    the root recipe with `reverb` in its parts, which installs the Reverb host's systemd unit, then
    `mroom baseline reverb` again, which says whether it answers. Baseline installs this release's
    `reverb-host` with the packages its `composer.lock` pins, which takes Composer and PHP 8.3 or later at
    `/usr/bin/php`, and makes its folders and an empty apps file (mode 600, in a folder of its own). With
    `MROOM_QA_ZONE` set, it prints the nginx config of the host: create `ws.<zone>` as a site in Forge, with
    its certificate, and put the printed block in place of its `location` blocks.

## QA environments

Each pull request can have a QA environment of its own on the box: `api-<N>.<zone>` for the Laravel app and,
for a frontend of its own, `go-<N>.<zone>`, with the services the QA gate gives it (design 8.2). Reusable
workflows run it; the app calls each from a workflow of its own, pinned to the mroom release the box runs
(`v0.4.0` below is the first release with these workflows):

| Workflow | Runs on | What it does |
|---|---|---|
| `qa-plan.yml` | a push to a pull request, or by hand | sorts the changed paths (could a user notice the change?), then builds the frontend from the pull request's code with public values only; it holds no secret |
| `qa-up.yml` | the QA plan run completing, or the plan's hand-over | brings the environment up or refreshes it, when a user could notice the change, the environment exists, the `qa` label is on, or a person started the plan |
| `qa-down.yml` | the pull request closing, its `qa` label coming off, the reaper, or by hand | tears the environment down: its daemons, its site user's processes and files, its sites, then its database, Redis user and keys, mail and buckets, through the gate |
| `qa-reap.yml` | a schedule, or by hand | starts a teardown for every environment older than `qa.ttl_days` (5) |

- **Who holds what.** Only jobs in the GitHub environment `qa` hold the Forge token and the box's SSH key,
  which reach root (design D20). `qa` admits the default branch alone, and those jobs check out only the
  default branch's `mroom.toml`, and mroom at the commit of the workflow file, so a pull request is only a
  number to them. Its code runs only in `qa-plan`, with no secret, and on the box, in its own isolated sites.
- **Forge is the source of truth.** An environment exists while Forge has its `api-<N>` or `go-<N>` site, a
  site being removed not counting. A Forge read that fails is retried and then fails the run, so it never
  reads as "no environment". Forge can accept a delete and never run it, so a site still removing after 30
  minutes gets the delete again, and the reaper warns about it: the same one two nights running needs a
  person in Forge.
- **A teardown.** qa-down's first job only reads Forge, so a pull request that never had an environment gets no
  teardown; one started by hand or by the reaper skips it. The second job runs every step, each skipping what is
  already gone, whether or not Forge still has a site: daemons first, since supervisor starts again what is
  stopped, then `user-clean`, then the sites right after (design 8.9), then the box's side. A `user-clean` that
  fails keeps the sites. Once the sites are gone, the environment no longer counts against `qa.max_envs`, so its
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
  deployed. Each step checks its own resource, so the next run repairs one that stopped halfway. From
  `qa.max_envs` (5) environments on, a new one waits for a slot; one whose code went in, by the gate's record
  (`env-sha`), is always refreshed. Two first deploys at once each count the others inside their own pull
  request's turn, so a new environment counts again once its site is made, by the order Forge made the
  environments' first sites in, and one past `qa.max_envs` gives way: its sites are deleted once Forge has made
  them, waited for until Forge has them gone, and deleted again once if they stay, since Forge can refuse a
  delete, or take one and never run it. One that will not go fails the run, and the next gives way again, since
  the environment's code never went in.
- **No required checks.** None of the QA workflows' checks can be a required one: the plan's build job is
  named after the commit it builds (`QA build <sha>`), so its name changes with every push, and a required
  check is matched by its name. The QA environment comment says how each deploy went; require the app's own
  CI.
- **When it says no.** A pull request that is closed, has moved on, or whose change no user could notice gets
  no environment. A build that failed, `qa.parity.broadcast = "same"` (the default: mroom's Reverb host exists,
  but qa-up does not wire environments into it yet, so set `broadcast = "log"` meanwhile), and a pull request
  whose `mroom.toml` puts the frontend elsewhere than the default branch's (qa-up deploys a build by the
  default branch's) each get a comment that says so, and the run stays green. The comment comes from the
  action's last step, which runs whatever happened before it, so a step that failed before it could say why
  is said too.
- **The `.env`.** `MROOM_QA_ENV_TEMPLATE` (third-party test-mode keys only: no app key, no credential for the
  box), less every entry whose key mroom sets (read entry by entry, so a quoted value of several lines stays
  whole), then mroom's: the `APP_KEY` the gate keeps for the environment, `APP_ENV=qa` (which Laravel counts as
  not production: a known gap, design 9), `APP_DEBUG=false`, `SESSION_SECURE_COOKIE=true` (the hosts answer over
  https alone), the public values below, the database, Redis user, host, port and prefixes the gate gives, and as
  `[qa.parity]` says: the mail login with plain SMTP to the box (`MAIL_SCHEME=smtp`, `MAIL_ENCRYPTION=null`,
  whatever the template says) for `catcher`, or `MAIL_MAILER=log`; for each disk of `qa.disks`, a bucket and a
  key of its own under Laravel's s3 env names with the disk's prefix in place of `AWS_` (`files = "AWS_"` gives
  `AWS_BUCKET`, `AWS_ACCESS_KEY_ID` and the rest; a disk in `qa.public_disks` also gets `<prefix>URL`), or
  `FILESYSTEM_DISK=local`; and `BROADCAST_CONNECTION=log`. The passwords and secret keys the gate gives, and the
  app key, are masked in the run's log, and a line of the gate's answer that could hold a value is never shown.
  The gate keeps the passwords, the bucket keys and the app key (QA gate, above), so every deploy gets the same
  ones, and the environment's users stay signed in.
- **What the plan builds.** `app.frontend_dir` is a folder for a frontend of its own (it gets the go site),
  `.` for Vite inside the Laravel app, or empty for no frontend; `app.build.frontend` is the command, and
  without one nothing is built; `app.build.frontend_dist` is where it writes (`dist`, or `public/build` for
  Vite inside Laravel). In `app.build.frontend_env`, `env:<KEY>` is the environment's own value of a key it
  does not keep secret (`APP_URL`, `CLIENT_URL`, `SESSION_DOMAIN`, `SESSION_COOKIE`, `XSRF_COOKIE_NAME`, and
  for a frontend of its own `CORS_ALLOWED_ORIGINS` and `SANCTUM_STATEFUL_DOMAINS`), and any other `env:<KEY>`
  is empty, since the build runs the pull request's code. Each environment's cookies have names of their
  own, `<app>_qa_<N>_session` and `<app>_qa_<N>_xsrf`, since every environment shares the zone.
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
   against the box's own `/etc/ssh/ssh_host_ed25519_key.pub`) and, when they apply, `MROOM_QA_SSH_USER` (when
   the box user is not `forge`), `MROOM_QA_CERTIFICATE` (a wildcard certificate in Forge to clone onto each
   site; without it each site asks Let's Encrypt) and `MROOM_QA_NGINX_TEMPLATE` (an nginx template for new
   sites) go in the repository's variables, not the `qa` environment's: none is secret, and every job of the
   called workflows reads the repository's, while GitHub's docs never say an environment's own reach a called
   workflow's job that sets `deployment: false`. Until `MROOM_FORGE_SERVER` is set, the workflows tear down and
   reap nothing, with a warning. The Forge token comes from an account whose only team holds the box, with
   exactly the scopes these calls need: `server:view`, `site:create`, `site:delete`, `site:meta`,
   `site:manage-ssl`, `site:manage-nginx`, `site:manage-deploys`, `server:create-daemons` and
   `server:delete-daemons`. Creating daemons reaches root (design D20), which is why only `qa` holds it. Every
   name and host the workflows build comes from the default branch's `mroom.toml` (`app.name`, `qa.zone`, the
   app's folders), and must match the box's `box.env`.
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
    uses: milroyfraser/mroom/.github/workflows/qa-plan.yml@v0.4.0
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
    uses: milroyfraser/mroom/.github/workflows/qa-up.yml@v0.4.0
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
    uses: milroyfraser/mroom/.github/workflows/qa-down.yml@v0.4.0
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
    uses: milroyfraser/mroom/.github/workflows/qa-reap.yml@v0.4.0
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
never by event, since a dispatched run is as much a run of its workflow as one `workflow_run` started. qa-up
goes by the run's first starter here too, so a person's re-run of a dispatched qa-up starts it again; should
that re-run also end with a `workflow_run`, it runs twice for one commit.

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
