---
name: forge
description: Call the Laravel Forge API for this box's server (sites, background processes, nginx, certificates, deployments) through mroom's `forge-api`. Use whenever a task needs Forge. Never read the token or call Forge directly.
---

# The Forge API on this box

Use **`forge-api`** to read or change this box's infrastructure in Forge: sites, background
processes, nginx, certificates, deployments. It reads the token itself, so you never see it, and it
pins every call to this box's server (`MROOM_FORGE_ORG` and `MROOM_FORGE_SERVER`, which
`mroom config box` shows). Reads run without asking (`forge-api GET` is allowed in mroom's
settings); writes ask.

```
forge-api GET sites
forge-api GET sites/<site id>/nginx
forge-api PUT sites/<site id>/nginx --write --data '{"config":"..."}'
```

The box's token should hold only the scopes to read and to change site settings (nginx,
certificates). Creating or deleting background processes, scheduled jobs and sites is a person's
job in Forge, since a token that can do it reaches root: tell them exactly what to create.

## Rules

- Never merge, approve, deploy or release on your own. A person does each of these.
- Tracker writes: only the state of the issue being worked, and comments on it.
- Ask the person before you create an issue or a label.
- Never touch production. Never read secrets, tokens or credential files.
- Never read the Forge token, put it in a command, or call Forge with curl or a script. Always go
  through `forge-api`.
- Paths are relative to the pinned server (`sites/...`, `background-processes/...`). The wrapper
  refuses `orgs`, `servers`, `..`, URLs and encoded slashes. Do not try to get around it. If a task
  needs another server, stop and tell the person.
- Reads (GET) are free. **Any write (POST, PUT, PATCH, DELETE) needs `--write` and the person's
  confirmation first**, saying exactly what will change.
- Never touch a production server or its database, even if asked in passing. Tell the person to
  do it.
- Paths that return secrets (a site's env, a deploy hook or webhook URL, a command's output) need
  `forge-api --secret GET …`, which always asks. Use it only when the task needs one value, and
  never print the answer: sum it up instead.

## Finding things

Look ids up each time; never rely on one from memory: `forge-api GET sites` for sites and their
domains, `forge-api GET background-processes` for daemons. Per-PR QA sites are `api-<PR>.<zone>`
and `go-<PR>.<zone>` (`qa.zone`), each with a `queue:work` process.

## Gotchas

- The v2 API is scoped to an organisation; the wrapper adds that part of the path.
- The nginx update field is `config` (`PUT sites/<site id>/nginx`).
- **Issue certificates one at a time, with nginx clean.** One failed certificate leaves nginx in an
  emergency state, every later reload is refused, and files are never written.
- Run Reverb as a plain background process (`php artisan reverb:start --host=0.0.0.0 --port=8080`),
  not through Forge's Reverb integration, which misreads a custom host and rewrites `REVERB_*` in
  the env.
- The Forge CLI is denied in mroom's settings (it bundles deploys, env pulls and tinker); use the
  API.
- Forge answers an odd 502 now and then; the wrapper retries it.
