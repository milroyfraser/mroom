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
part of phase 1: the [box watchdog](#box-watchdog) with its job records, and the
[regression label](#regression-label) check with its measures. Every other command prints
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
./install.sh --version v0.3.1
```

Either way mroom lands in `~/.local/share/mroom/<version>/` and `~/.local/bin/mroom` links to it. Make
sure `~/.local/bin` is on your `PATH`. Running `install.sh` again replaces that version in place.
`--prefix <dir>` installs under another folder, `--force` replaces a `~/.local/bin/mroom` that some other
tool put there, and `./install.sh --uninstall` removes every installed version and the link (it keeps
`~/.config/mroom`). `--version` downloads with `gh` when it is signed in, and with `curl` otherwise.

```bash
mroom version            # 0.3.1
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

## QA gate

CI never gets a shell on the box (design 8.2). The QA runner's SSH key is forced to `mroom gate`, which
runs only the operations of its role and builds every name itself, so a request can reach nothing but its
own environment. Phase 2a adds operations one PR at a time; today the `provision` role has:

| Operation | What it does |
|---|---|
| `db-create <N>` | a Postgres role and a database of their own for QA environment N, cloned from the template (D18); prints `DB_DATABASE`, `DB_USERNAME` and a new `DB_PASSWORD` for the environment's `.env` |
| `db-drop <N>` | the environment's database and role |
| `redis-user-add <N>` | a Redis user of its own, limited to its prefix `<app>:qa<N>:` (D15); prints `REDIS_USERNAME`, a new `REDIS_PASSWORD`, `REDIS_PREFIX` and `HORIZON_PREFIX` |
| `redis-user-remove <N>` | the environment's Redis user, which also closes its connections |
| `redis-clear <N>` | every key under the environment's prefix, in every Redis database |

The client sends only N. The database, role and Redis user are `<MROOM_APP_NAME>_qa_<N>`, and the
database is cloned from `MROOM_QA_TEMPLATE`, both set by a person in `box.env`. A password reaches
Postgres only as a SCRAM verifier, through stdin, and Redis only as its SHA-256. Each request and refusal
is logged, never a secret, to `~/.local/state/mroom/gate.log` and to syslog.

A Redis user reaches only keys and channels under its prefix, and none of the commands that flush,
watch or list the whole server or reset its scripts (design 8.9). On Redis 8 it also loses `@search`
and `@timeseries`, whose commands take no keys. Each change closes the user's old connections and is
saved to Redis's `aclfile`, so it survives a restart. `redis-clear` deletes inside Redis, a slice of the
keyspace at a time, so no key name is read back, where a newline in one could make it two.

**Set up once,** for an app named `shop`, on Postgres 16 or later and Redis 7 or later. Before Postgres 16,
a role that may create roles may also grant itself the administrator ones, so the gate refuses older
versions. CI runs these steps against a real Postgres and a real Redis 7 and 8 (`tests/pg/` and
`tests/redis/`).

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

8. Redis's users in an `aclfile`, which Redis rewrites on `ACL SAVE`: in `redis.conf`,
   `aclfile /etc/redis/users.acl`, with any `requirepass` line removed, since the file replaces it. In that
   file, the gate's own user, with the hash from step 7, then restart Redis:

   ```
   user mroom-gate on #<the hash> ~* &* +@all
   ```

9. Give every other client of Redis, such as the dev site, its workers and each worktree, a user of its
   own (D15). Then turn the default user off and close the connections still signed in as it.
   `--askpass` asks for the gate's password:

   ```
   $ redis-cli --user mroom-gate --askpass
   127.0.0.1:6379> ACL SETUSER default off
   127.0.0.1:6379> ACL SAVE
   127.0.0.1:6379> CLIENT KILL USER default
   ```

   The gate refuses Redis requests while the default user is on, since with it any process on the box
   reaches every key.

10. In `box.env`: `MROOM_APP_NAME=shop` and `MROOM_QA_TEMPLATE=shop_qa_template`.

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
      - uses: milroyfraser/mroom/actions/regression-label@v0.3.1
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
tests/run.sh             # every test: offline, each in a temp HOME
tests/run.sh config box  # only tests/config-test.sh and tests/box-test.sh
```

The tests need what the box needs (bash 5, python3 3.11+); on a host without them the TOML and install
tests skip locally, and CI on `ubuntu-latest` runs them all, plus shellcheck on every shell script and an
install on a bare `ubuntu:24.04` container. Releases are cut by hand: [docs/releasing.md](docs/releasing.md).

## Licence

MIT, see [LICENSE](LICENSE). Third-party material is listed in [NOTICE](NOTICE).
