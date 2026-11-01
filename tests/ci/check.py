#!/usr/bin/env python3
"""check.py <check> <repository root> - one shape check over the CI templates (templates/github).

Used by tests/ci-templates-test.sh and tests/deploy-test.sh, one check per test case. Reads the templates
as YAML (PyYAML), with their placeholders unfilled: every placeholder sits inside a scalar, so the raw
files parse. The CI checks leave out the production deploy (workflows/deploy-production.yml), which runs
on a tag and holds a secret by design; the deploy-* checks read it alone. Prints what is wrong and exits
1, or exits 0.
"""

import os
import re
import sys

import yaml

DEFAULT = "github.ref == 'refs/heads/<<default_branch>>'"
VENDOR = {
    "path": "<<app.backend_dir>>/vendor",
    "key": "${{ runner.os }}-vendor-php<<app.php>>-${{ hashFiles('<<app.backend_dir>>/composer.lock') }}",
    "restore-keys": "${{ runner.os }}-vendor-php<<app.php>>-",
}
PLAYWRIGHT_LOCK = "${{ hashFiles('<<app.backend_dir>>/<<pm.lockfile>>') }}"
DEBS = {
    "path": "/var/cache/ci-apt",
    "key": "${{ runner.os }}-playwright-debs-" + PLAYWRIGHT_LOCK + "-${{ steps.apt-cache.outputs.week }}",
    "restore-keys": "${{ runner.os }}-playwright-debs-" + PLAYWRIGHT_LOCK + "-",
}
# The jobs a ruleset requires, by workflow: each must report on every pull request.
REQUIRED = {"ci-backend.yml": ["test"], "ci-frontend.yml": ["lint", "unit-tests"], "ci-e2e.yml": ["e2e"]}

problems = []


def problem(text):
    problems.append(text)


def load(root, deploy=False):
    """The CI templates, or with deploy=True also the production deploy's."""
    base = os.path.join(root, "templates", "github")
    files = {}
    for sub in ("workflows", "actions"):
        for dirpath, _, names in os.walk(os.path.join(base, sub)):
            for name in names:
                # By its exact name: any other workflow, one named deploy-* included, meets every CI check.
                if os.path.join(sub, name) == DEPLOY and not deploy:
                    continue
                if name.endswith((".yml", ".yaml")):
                    path = os.path.join(dirpath, name)
                    with open(path, encoding="utf-8") as fh:
                        text = fh.read()
                    files[os.path.relpath(path, base)] = (yaml.safe_load(text), text)
    return files


def on(doc):
    # PyYAML reads the bare key `on` as True.
    return doc.get("on", doc.get(True)) or {}


def jobs_and_steps(files):
    """(file, job id or None, step) for every step of every workflow job and composite action."""
    for rel, (doc, _) in files.items():
        if rel.startswith("workflows/"):
            for job_id, job in (doc.get("jobs") or {}).items():
                for step in job.get("steps") or []:
                    yield rel, job_id, step
        else:
            for step in (doc.get("runs") or {}).get("steps") or []:
                yield rel, None, step


def uses(step, action):
    return str(step.get("uses", "")).split("@")[0] == action


def family(key):
    match = re.match(r"\$\{\{ runner\.os \}\}-([a-z0-9-]+?)-(\$\{\{|php|node)", key or "")
    return match.group(1) if match else key


def where(rel, job, step):
    return f"{rel}{':' + job if job else ''}: {step.get('name', step.get('uses'))}"


def check_no_save_on_post(files):
    for rel, job, step in jobs_and_steps(files):
        if uses(step, "actions/cache"):
            problem(f"{where(rel, job, step)} uses actions/cache, which saves from any branch in its post step")


def check_save_on_default_branch(files):
    saves = 0
    for rel, job, step in jobs_and_steps(files):
        if uses(step, "actions/cache/save"):
            saves += 1
            cond = str(step.get("if", ""))
            if DEFAULT not in cond or "||" in cond:
                problem(f"{where(rel, job, step)} saves without requiring the default branch: if: {cond!r}")
    if saves < 5:
        problem(f"only {saves} cache saves; the warm workflows save vendor, the store, Playwright, its apt packages and the build")


def check_no_setup_node_cache(files):
    for rel, job, step in jobs_and_steps(files):
        if uses(step, "actions/setup-node"):
            given = step.get("with") or {}
            if "cache" in given or given.get("package-manager-cache") is not False:
                problem(f"{where(rel, job, step)} lets setup-node save its own cache from pull requests")


def check_keys_match(files):
    restores = {}
    for rel, job, step in jobs_and_steps(files):
        given = step.get("with") or {}
        if uses(step, "actions/cache/restore"):
            name = family(given.get("key"))
            triple = (given.get("path"), given.get("key"), given.get("restore-keys"))
            restores.setdefault(name, set()).add(triple)
        if uses(step, "actions/cache/save"):
            key = str(given.get("key", ""))
            match = re.fullmatch(r"\$\{\{ steps\.([a-z-]+)\.outputs\.cache-primary-key \}\}", key)
            if not match:
                problem(f"{where(rel, job, step)} saves under its own key, not its restore step's")
                continue
            peers = [s for r, j, s in jobs_and_steps(files) if r == rel and j == job and s.get("id") == match.group(1)]
            if len(peers) != 1 or not uses(peers[0], "actions/cache/restore") or \
                    (peers[0].get("with") or {}).get("path") != given.get("path"):
                problem(f"{where(rel, job, step)} saves a path its restore step {match.group(1)} does not restore")
    for name, triples in sorted(restores.items()):
        if len(triples) != 1:
            problem(f"cache {name} is restored with {len(triples)} different paths or keys: {sorted(map(str, triples))}")
    for name in ("vendor", "node-store", "playwright", "playwright-debs", "e2e-dist"):
        if name not in restores:
            problem(f"no cache {name}")


def restore_steps(files, name):
    return [(rel, job, step) for rel, job, step in jobs_and_steps(files)
            if uses(step, "actions/cache/restore") and family((step.get("with") or {}).get("key")) == name]


def check_vendor(files):
    found = {rel for rel, _, _ in restore_steps(files, "vendor")}
    for rel in ("workflows/ci-backend.yml", "workflows/ci-e2e.yml", "workflows/ci-cache-warm.yml"):
        if rel not in found:
            problem(f"{rel} does not restore vendor/")
    for rel, job, step in restore_steps(files, "vendor"):
        given = step.get("with") or {}
        for field, want in VENDOR.items():
            if given.get(field) != want:
                problem(f"{where(rel, job, step)}: {field} is {given.get(field)!r}, not {want!r}")


def check_apt(files):
    steps = restore_steps(files, "playwright-debs")
    if {rel for rel, _, _ in steps} != {"workflows/ci-e2e.yml", "workflows/ci-cache-warm.yml"}:
        problem("the apt packages are not restored by exactly ci-e2e.yml and ci-cache-warm.yml")
    for rel, job, step in steps:
        given = step.get("with") or {}
        for field, want in DEBS.items():
            if given.get(field) != want:
                problem(f"{where(rel, job, step)}: {field} is {given.get(field)!r}, not {want!r}")
    for rel in ("workflows/ci-e2e.yml", "workflows/ci-cache-warm.yml"):
        doc, text = files[rel]
        if 'Dir::Cache::Archives "/var/cache/ci-apt"' not in text:
            problem(f"{rel} does not point apt's downloads at /var/cache/ci-apt")
        if 'echo "week=$(date -u +%G-%V)"' not in text:
            problem(f"{rel} does not key the apt packages on the ISO week")
    # The weekly save drops the versions apt no longer offers first, so the cache does not grow.
    names = [s.get("name", "") for _, j, s in jobs_and_steps(files) if j == "warm"]
    runs = [str(s.get("run", "")) for _, j, s in jobs_and_steps(files) if j == "warm"]
    clean = [i for i, run in enumerate(runs) if "apt-get autoclean" in run]
    save = [i for i, name in enumerate(names) if name == "Save Playwright system packages"]
    if not clean or not save or clean[0] > save[0]:
        problem("ci-cache-warm.yml does not run apt-get autoclean before it saves the apt packages")


def check_catch_all(files):
    doc, _ = files["workflows/ci-backend.yml"]
    shards = doc["jobs"]["tests"]["strategy"]["matrix"]["shard"]
    if not shards or shards[-1].get("name") != "rest":
        problem("the last backend shard is not the catch-all `rest`")
        return
    named = set()
    for shard in shards[:-1]:
        suites = str(shard.get("suites", ""))
        if not suites.startswith("--testsuite="):
            problem(f"shard {shard.get('name')} does not name its suites with --testsuite=")
        named |= set(suites.removeprefix("--testsuite=").split(","))
    rest = str(shards[-1].get("suites", ""))
    if not rest.startswith("--exclude-testsuite="):
        problem("the `rest` shard does not exclude the named suites")
        return
    missing = (named | {"<<fill:e2e_suite>>"}) - set(rest.removeprefix("--exclude-testsuite=").split(","))
    if missing:
        problem(f"the `rest` shard runs suites another shard (or e2e) runs: {sorted(missing)}")
    if doc["jobs"]["tests"]["strategy"].get("fail-fast") is not False:
        problem("a failed backend shard cancels the others")


def check_gate(files, rel, gate, needs):
    doc, _ = files[rel]
    job = doc["jobs"].get(gate)
    if not job:
        problem(f"{rel} has no aggregate job {gate}")
        return
    if job.get("name", gate) != gate:
        problem(f"{rel}: the aggregate job reports as {job.get('name')!r}, not {gate!r}")
    if not str(job.get("if", "")).startswith("always()"):
        problem(f"{rel}: {gate} does not run when a shard failed (if: always())")
    if sorted(job.get("needs") or []) != sorted(needs):
        problem(f"{rel}: {gate} needs {job.get('needs')}, not {needs}")
    text = yaml.safe_dump(job["steps"])
    for need in needs:
        if f"needs.{need}.result" not in text:
            problem(f"{rel}: {gate} does not read {need}'s result")
    if text.count("= success") < len(needs):
        problem(f"{rel}: {gate} does not require success of every job it needs")


def check_aggregate(files):
    check_gate(files, "workflows/ci-backend.yml", "test", ["static", "tests"])
    check_gate(files, "workflows/ci-frontend.yml", "unit-tests", ["unit"])
    unit = files["workflows/ci-frontend.yml"][0]["jobs"]["unit"]
    if "strategy.job-total" not in unit.get("name", "") or \
            "strategy.job-total" not in yaml.safe_dump(unit["steps"]):
        problem("the unit shards do not take their count from strategy.job-total, in the name and --shard")


def check_measure(files):
    doc, text = files["workflows/ci-backend.yml"]
    inputs = (on(doc).get("workflow_dispatch") or {}).get("inputs") or {}
    if (inputs.get("measure") or {}).get("type") != "boolean":
        problem("ci-backend.yml has no measure input")
    jobs = doc["jobs"]
    if "inputs.measure" not in str((jobs.get("suites") or {}).get("if", "")):
        problem("the suites job does not run only in measuring mode")
    measure = jobs.get("measure") or {}
    if measure.get("needs") != "suites" or \
            measure.get("strategy", {}).get("matrix", {}).get("suite") != "${{ fromJSON(needs.suites.outputs.list) }}":
        problem("the measure job does not run one job per suite")
    if "measure-report" not in jobs:
        problem("no measure-report job")
    _, frontend = files["workflows/ci-frontend.yml"]
    if "vitest-file-times.mjs" not in frontend:
        problem("the frontend shards do not record their per-file times")


def check_no_secrets(files):
    for rel, (doc, text) in files.items():
        for bad in ("secrets.", "secrets[", "pull_request_target", "workflow_run", "id-token"):
            if bad in text:
                problem(f"{rel} contains {bad!r}")
        if re.search(r":\s*write\b", text):
            problem(f"{rel} grants a write permission")
        if not rel.startswith("workflows/"):
            continue
        if doc.get("permissions") != {"contents": "read"}:
            problem(f"{rel}: permissions are {doc.get('permissions')!r}, not contents: read")
        for job_id, job in doc["jobs"].items():
            if "permissions" in job or "environment" in job or "secrets" in job:
                problem(f"{rel}:{job_id} changes its permissions or names an environment or secrets")


def check_required_checks_report(files):
    for name, gates in REQUIRED.items():
        doc, _ = files[f"workflows/{name}"]
        pr = on(doc).get("pull_request", "absent")
        if pr == "absent" or (isinstance(pr, dict) and ("paths" in pr or "paths-ignore" in pr)):
            problem(f"{name} has a paths filter on pull_request, or no pull_request: a required check could never arrive")
        for gate in gates:
            cond = str(doc["jobs"][gate].get("if", ""))
            if cond and not cond.startswith("always()"):
                problem(f"{name}:{gate} can be skipped as a whole: if: {cond!r}")


def check_concurrency(files):
    # By pull request number: two forks' branches of the same name must not cancel each other's runs.
    for name in [rel.split("/", 1)[1] for rel in files if rel.startswith("workflows/")]:
        group = str((files[f"workflows/{name}"][0].get("concurrency") or {}).get("group", ""))
        if group != "${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}":
            problem(f"{name}: the concurrency group {group!r} is not per pull request")


def check_first_push_names(files):
    # tools/ci-first-push.sh's defaults: BACKEND_JOB_PREFIX, E2E_JOB and APT_STEP.
    backend = files["workflows/ci-backend.yml"][0]["jobs"]["tests"]["name"]
    if not backend.startswith("Backend tests"):
        problem(f"the backend shards are named {backend!r}, not 'Backend tests ...'")
    e2e = files["workflows/ci-e2e.yml"][0]["jobs"]["e2e"]
    if e2e.get("name") != "e2e":
        problem("the e2e job is not named e2e")
    if "Install Playwright system deps" not in [s.get("name") for s in e2e["steps"]]:
        problem("the e2e job has no 'Install Playwright system deps' step")


def check_e2e_build(files):
    doc, _ = files["actions/e2e-frontend-build/action.yml"]
    steps = doc["runs"]["steps"]
    restore = next((s for s in steps if uses(s, "actions/cache/restore")), {})
    key = str((restore.get("with") or {}).get("key", ""))
    for part in ("'.github/actions/e2e-frontend-build/action.yml'", "node${{ steps.node.outputs.version }}",
                 "'<<app.frontend_dir>>/<<pm.lockfile>>'", "'<<app.backend_dir>>/composer.lock'", "'!<<app.frontend_dir>>/<<fill:frontend_src>>/**/*.test.*'"):
        if part not in key:
            problem(f"the e2e build's key lacks {part}")
    build = next((s for s in steps if s.get("name") == "Build the frontend"), {})
    if build.get("if") != "steps.restore.outputs.cache-hit != 'true'":
        problem("the e2e build is not skipped when it was restored")
    warm, _ = files["workflows/ci-e2e-build-warm.yml"]
    paths = (on(warm).get("push") or {}).get("paths") or []
    for part in ("<<app.frontend_dir>>/**", "<<app.backend_dir>>/composer.lock", ".github/actions/e2e-frontend-build/**"):
        if part not in paths:
            problem(f"ci-e2e-build-warm.yml does not warm again when {part} changes, though it is in the build's key")
    step = warm["jobs"]["build"]["steps"][-1]
    if not uses(step, "./.github/actions/e2e-frontend-build") or (step.get("with") or {}).get("save") != "${{ " + DEFAULT + " }}":
        problem("ci-e2e-build-warm.yml does not save the build, on the default branch only")
    e2e, _ = files["workflows/ci-e2e.yml"]
    used = [s for s in e2e["jobs"]["e2e"]["steps"] if uses(s, "./.github/actions/e2e-frontend-build")]
    if len(used) != 1 or "save" in (used[0].get("with") or {}):
        problem("ci-e2e.yml does not restore-or-build through the action, without saving")


DEPLOY = "workflows/deploy-production.yml"


def check_deploy_triggers(files):
    doc, _ = files[DEPLOY]
    triggers = on(doc)
    if sorted(triggers) != ["release", "workflow_dispatch"]:
        problem(f"the deploy runs on {sorted(triggers)}, not only a published release and a person's dispatch")
    if (triggers.get("release") or {}).get("types") != ["published"]:
        problem("the deploy runs on a release event other than published")
    if triggers.get("workflow_dispatch"):
        problem("the deploy's dispatch takes inputs: the tag must be the run's ref, so nothing typed reaches a script")


def check_deploy_secrets(files):
    """Only the job of the production environment holds a secret, and it runs no third-party code."""
    doc, text = files[DEPLOY]
    if doc.get("permissions") != {"contents": "read"}:
        problem(f"the deploy's permissions are {doc.get('permissions')!r}, not contents: read")
    if re.search(r":\s*write\b", text) or "id-token" in text:
        problem("the deploy grants a write permission or an OIDC token")
    for bad in ("pull_request", "workflow_run", "secrets: inherit"):
        if bad in text:
            problem(f"the deploy contains {bad!r}")
    for job_id, job in doc["jobs"].items():
        dumped = yaml.safe_dump(job)
        holds = "secrets." in dumped
        env = job.get("environment")
        name = env.get("name") if isinstance(env, dict) else env
        if "permissions" in job:
            problem(f"deploy:{job_id} changes its permissions")
        if holds and name != "production":
            problem(f"deploy:{job_id} reads a secret outside the production environment")
        if name == "production" and job_id != "release":
            problem(f"deploy:{job_id} is in the production environment; only the release job is")
        if holds:
            for step in job.get("steps") or []:
                action = str(step.get("uses", "")).split("@")[0]
                if action and action != "actions/checkout":
                    problem(f"deploy:{job_id} runs {action} beside the deploy key")
                if "run" in step and "secrets." in str(step.get("run")):
                    problem(f"deploy:{job_id}: a secret is written into a script, not passed through env")
    release = doc["jobs"].get("release") or {}
    checkout = next((s for s in release.get("steps") or [] if uses(s, "actions/checkout")), {})
    given = checkout.get("with") or {}
    if given.get("ref") != "${{ github.ref }}" or given.get("ssh-key") != "${{ secrets.MROOM_RELEASE_KEY }}":
        problem("the release job does not check out the run's own tag with the release key")
    if given.get("fetch-depth") != 0:
        problem("the release job's checkout has no history, so it cannot tell whether the tag is on the default branch")


def check_deploy_release(files):
    doc, _ = files[DEPLOY]
    group = doc.get("concurrency") or {}
    if group.get("group") != "deploy-production" or group.get("cancel-in-progress") is not False:
        problem(f"the deploy's concurrency {group!r} is not one fixed group that never cancels a deploy")
    steps = (doc["jobs"].get("release") or {}).get("steps") or []
    names = [s.get("id") for s in steps]
    if "release" not in names:
        problem("the release job has no step with id release")
        return
    step = steps[names.index("release")]
    if ".github/scripts/release-branch.sh" not in str(step.get("run", "")):
        problem("the release step does not run release-branch.sh")
    env = step.get("env") or {}
    for key, want in (("REF_TYPE", "${{ github.ref_type }}"), ("REF_NAME", "${{ github.ref_name }}"),
                      ("RELEASE_TAG", "${{ github.event.release.tag_name }}"), ("DEFAULT_BRANCH", "<<default_branch>>"),
                      ("TAG_PATTERN", "<<fill:tag_pattern>>")):
        if env.get(key) != want:
            problem(f"the release step's {key} is {env.get(key)!r}, not {want!r}")
    hook = steps[names.index("release") + 1:] if names.index("release") + 1 < len(steps) else []
    if not hook or "secrets.MROOM_DEPLOY_HOOK" not in str((hook[0].get("env") or {}).get("DEPLOY_HOOK")):
        problem("the host's deploy hook does not come after the release branch moved, from the environment")


def check_deploy_verify(files):
    doc, _ = files[DEPLOY]
    job = doc["jobs"].get("verify") or {}
    if job.get("needs") != "release":
        problem("the verify job does not wait for the release job")
    if "environment" in job:
        problem("the verify job names an environment; it needs no secret")
    steps = job.get("steps") or []
    verify = [s for s in steps if str(s.get("uses", "")).split("@")[0] == "milroyfraser/mroom/actions/deploy-verify"]
    if len(verify) != 1:
        problem("the verify job does not run mroom's deploy-verify once")
        return
    if str(verify[0].get("uses")).split("@")[1] != "<<mroom_version>>":
        problem("deploy-verify is not pinned to the mroom release")
    given = verify[0].get("with") or {}
    if given.get("commit") != "${{ needs.release.outputs.commit }}":
        problem("deploy-verify does not wait for the commit the release job pushed")
    if given.get("tag") != "${{ needs.release.outputs.tag }}":
        problem("deploy-verify is not told the tag")
    checkout = next((s for s in steps if uses(s, "actions/checkout")), {})
    if (checkout.get("with") or {}).get("ref") != "${{ needs.release.outputs.commit }}":
        problem("the verify job does not read the tag's own mroom.toml")
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    with open(os.path.join(root, "actions", "deploy-verify", "action.yml"), encoding="utf-8") as fh:
        action = yaml.safe_load(fh)
    known = set((action.get("inputs") or {}))
    for name in given:
        if name not in known:
            problem(f"deploy-verify has no input {name}")


def readme_section(root):
    with open(os.path.join(root, "README.md"), encoding="utf-8") as fh:
        text = fh.read()
    match = re.search(r"^## CI templates\n(.*?)(?=^## )", text, re.S | re.M)
    return match.group(1) if match else ""


def check_placeholders(files, root):
    used = set()
    for _, (_, text) in files.items():
        used |= set(re.findall(r"<<([^<>\s]+)>>", text))
    with open(os.path.join(root, "templates", "github", "scripts", "vitest-file-times.mjs"), encoding="utf-8") as fh:
        used |= set(re.findall(r"<<([^<>\s]+)>>", fh.read()))
    section = readme_section(root)
    if not section:
        problem("README.md has no '## CI templates' section")
        return
    documented = set(re.findall(r"^\| `<<([^<>\s]+)>>` \|", section, re.M))
    for name in sorted(used - documented):
        problem(f"<<{name}>> is used in a template but has no row in the README's CI templates table")
    for name in sorted(documented - used):
        problem(f"<<{name}>> is documented but no template uses it")
    for name in sorted(used):
        if not re.fullmatch(r"(fill:[a-z0-9_]+|default_branch|mroom_version|pm\.[a-z_]+|tests\.database|"
                            r"app\.[a-z_.]+|tests\.[a-z_]+)", name):
            problem(f"<<{name}>> is not a known kind of placeholder")


CHECKS = {
    "no-save-on-post": check_no_save_on_post,
    "save-on-default-branch": check_save_on_default_branch,
    "no-setup-node-cache": check_no_setup_node_cache,
    "keys-match": check_keys_match,
    "vendor": check_vendor,
    "apt": check_apt,
    "catch-all": check_catch_all,
    "aggregate": check_aggregate,
    "measure": check_measure,
    "no-secrets": check_no_secrets,
    "required-checks-report": check_required_checks_report,
    "concurrency": check_concurrency,
    "first-push-names": check_first_push_names,
    "e2e-build": check_e2e_build,
}
DEPLOY_CHECKS = {
    "deploy-triggers": check_deploy_triggers,
    "deploy-secrets": check_deploy_secrets,
    "deploy-release": check_deploy_release,
    "deploy-verify": check_deploy_verify,
}


def main():
    name, root = sys.argv[1], sys.argv[2]
    files = load(root, deploy=name in DEPLOY_CHECKS or name == "placeholders")
    if name == "placeholders":
        check_placeholders(files, root)
    elif name in DEPLOY_CHECKS:
        DEPLOY_CHECKS[name](files)
    else:
        CHECKS[name](files)
    for text in problems:
        print(text)
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
