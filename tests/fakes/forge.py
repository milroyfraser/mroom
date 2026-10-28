#!/usr/bin/env python3
"""A stand-in for Laravel Forge's v2 API, for the QA action tests (tests/qa-*-test.sh). It plays curl:

    curl <arguments>     as lib/core/forge.sh calls it: --request, --header @- (the token, on stdin), --data-binary
                         @<file>, --dump-header <file>, --output <file>, --write-out '%{http_code}', and the URL

It answers from one server's state, the JSON file $FORGE_STATE, which a test seeds and reads back: "sites",
"processes" (background processes) and "jobs" (the server's scheduled jobs; a site's own are its "jobs"), each a
list of plain objects with an "id". Only the bearer token fake-forge-token reaches the organisation acme's server 42.
Each call is logged to $FORGE_LOG as one line, "<METHOD> <path and query>", with " <body>" after it for a write, and
as "forge <METHOD> <path>" to $ORDER_LOG, when it is set, which the gate's stand-in (tests/fakes/ssh) writes too.

As Forge does, it answers JSON:API resources, and lists at most 30 items at a time, whatever page[size] asks, with
a cursor to the next page ("page_size" in the state lowers the most). A site it deletes turns removing, with
updated_at now (MROOM_NOW, when set), and goes after "remove_reads" (1) more reads of the site list; -1 keeps it
removing. As Forge can, it accepts the next "site_deletes_dropped" (0) site deletes and never runs them, the site
removing for good until a later delete, and with "installing_delete_dropped" one sent while a site is installing. A process it deletes goes at once, or turns removing and goes after "process_remove_reads" reads of the
list; a scheduled job goes at once, or turns deleting for "job_remove_reads" reads (-1 keeps it). With
"server_lists_site_jobs", the server's list of scheduled jobs holds the sites' own too, which only their site's path
deletes. "fail":
{"<METHOD> <path>": code} answers that code to every such call, and {"code": code, "times": n} to the next n only.

What qa-up makes, it makes as Forge does, as Forge's own answers show it:
- a site stays installing for "install_reads" (1) reads of the list. Forge gives its web_directory as an absolute
  path and its php_version as "PHP 8.4". Its nginx config (GET sites/<id>/nginx) is the site.conf fragment alone,
  with no server block and no root; each of its domains has the server block that includes it (GET
  sites/<id>/domains/<id>/nginx). A PUT of the fragment is applied later, after "nginx_reads" (1) reads, or never
  with "nginx_put_ignored". "sites_made_first" and "sites_made_after" are other runs' sites, made just before and
  just after the next one asked for, as when two runs make sites at once;
- a certificate, on the site's one domain, is installing for "cert_reads" (1) reads; then it is installed and
  active, or, for the next "cert_fail" (0) asked for, of the status "cert_fail_status" (failed; Forge also has
  failed-unknown and failed-runner), its request_status never failed. A cloned one is active only when it was sent
  with "enable": true and "clone_enable_ignored" is not set; one that is not is enabled through its actions
  ({"action": "enable"}), enabling for a read, unless "enable_ignored". One it deletes stays listed as it was for
  "cert_remove_reads" (1) more reads, as Forge deletes later;
- a deployment is deploying for "deploy_reads" (1) reads, then ends "deploy_result" (finished), with "deploy_log" as
  its output; "deploy_adds_process" is a background process that turns up once a deployment is asked for;
- a background process may run as root, as forge, or as the isolated user of one of the server's sites; any other
  user is refused (422). It runs as the user asked for, or as "process_user" when the state names one, as a Forge
  that ignores the user would.
Any other host plays the environment itself: /up answers the next code of $FORGE_UP (one a line, the last one
repeating), 000 being no answer, and logs each to $FORGE_UP.log. /mroom-symlink-probe is the link the gate's
probe-link puts at the web root (tests/fakes/ssh), to the root-owned file $SITE_OP_INSTALLED. nginx serves that
file, 200, when the site's nginx config lacks disable_symlinks if_not_owner at its top level, with "probe_follows"
(true, or one site's name), as a box whose own config overrides the site's would, and for the next
"probe_follows_for" answers, as nginx does until it has reloaded a config Forge just wrote. Guarded, try_files
hands the path on: a site with the single-page fallback answers 200 with its index.html, an app with "catch_all"
200 with its own page, and any other 404. "probe_code" answers that code instead, 000 being no answer. Each code
goes to $FORGE_UP.probe. "server_extra" adds a line to each domain's server block.
"""

import datetime
import json
import os
import sys
import urllib.parse

TOKEN = "fake-forge-token"
BASE = "/api/orgs/acme/servers/42"
STATE, LOG = os.environ["FORGE_STATE"], os.environ["FORGE_LOG"]
HIDDEN = ("id", "remove_reads", "install_reads", "reads", "nginx", "pending_nginx", "nginx_reads", "script",
          "certificates", "deployments", "fail", "enable", "jobs")


def now() -> str:
    """The test's clock (MROOM_NOW, epoch seconds) when it has one."""
    when = datetime.datetime.now(datetime.timezone.utc)
    if os.environ.get("MROOM_NOW"):
        when = datetime.datetime.fromtimestamp(int(os.environ["MROOM_NOW"]), datetime.timezone.utc)
    return when.strftime("%Y-%m-%dT%H:%M:%SZ")


def resource(kind: str, item: dict) -> dict:
    return {"id": str(item["id"]), "type": kind, "attributes": {k: v for k, v in item.items() if k not in HIDDEN}}


def page(state: dict, items: list, kind: str, query: dict) -> dict:
    size = min(int(query.get("page[size]", ["100"])[0]), state.get("page_size", 30))
    start = int(query.get("page[cursor]", ["0"])[0])
    rest = items[start + size:]
    return {"data": [resource(kind, i) for i in items[start:start + size]],
            "meta": {"next_cursor": str(start + size) if rest else None}}


def settle(items: list, field: str) -> list:
    """One more read of a list: what is removing counts down, and goes at 0."""
    kept = []
    for item in items:
        left = item.get(field)
        if item.get("status") in ("removing", "deleting") and isinstance(left, int) and left >= 0:
            if left == 0:
                continue
            item[field] = left - 1
        kept.append(item)
    return kept


# A site's nginx config as Forge gives it: the site.conf fragment, which each of its domains includes inside its own
# server block, below.
SITE_CONF = """ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers off;

add_header X-Frame-Options "SAMEORIGIN";
add_header X-Content-Type-Options "nosniff";

index index.html index.htm{index};

charset utf-8;

# FORGE CONFIG (DO NOT REMOVE!)
include forge-conf/{id}/server/*;

location / {{
    try_files $uri $uri/ {fallback};
}}

location = /favicon.ico {{ access_log off; log_not_found off; }}
location = /robots.txt  {{ access_log off; log_not_found off; }}

access_log off;
error_log  /var/log/nginx/{id}-error.log error;
{php}
location ~ /\\.(?!well-known).* {{
    deny all;
}}
"""
PHP_BLOCK = """
error_page 404 /index.php;

location ~ \\.php$ {{
    fastcgi_split_path_info ^(.+\\.php)(/.+)$;
    fastcgi_pass unix:/var/run/php/{fpm}-fpm-{user}.sock;
    fastcgi_index index.php;
    include fastcgi_params;
    include forge_fastcgi_defaults;
}}
"""
DOMAIN_CONF = """# FORGE CONFIG (DO NOT REMOVE!)
include forge-conf/{id}/before/*;

server {{
    http2 on;
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name {name};
    server_tokens off;
    root {web};
{extra}
    # FORGE SSL (DO NOT REMOVE!)
    ssl_certificate /etc/nginx/ssl/domains/{domain}/server.crt;
    ssl_certificate_key /etc/nginx/ssl/domains/{domain}/server.key;

    include forge-conf/{id}/site.conf;
}}

# FORGE CONFIG (DO NOT REMOVE!)
include forge-conf/{id}/after/*;
"""


def site_conf(site: dict) -> str:
    php = site.get("php_version")
    fpm = "php" + php.removeprefix("PHP ").replace(".", "") if php else ""
    return SITE_CONF.format(id=site["id"], index=" index.php" if php else "",
                            fallback="/index.php?$query_string" if php else "=404",
                            php=PHP_BLOCK.format(fpm=fpm, user=site.get("user", "forge")) if php else "")


def guarded(conf: str) -> bool:
    """Whether nginx would refuse a link to another owner's file: disable_symlinks if_not_owner at the fragment's top
    level, outside comments and blocks. Its own reading, line by line, apart from the one qa-up uses."""
    depth = 0
    for line in conf.splitlines():
        line = line.split("#", 1)[0]
        if depth == 0 and line.strip() == "disable_symlinks if_not_owner;":
            return True
        depth += line.count("{") - line.count("}")
    return False


def site_of(state: dict, site_id: str) -> dict | None:
    return next((s for s in state.get("sites", []) if str(s["id"]) == site_id), None)


def new_id(state: dict) -> int:
    state["next_id"] = state.get("next_id", 100) + 1
    return state["next_id"]


def make_site(state: dict, body: dict) -> dict:
    user = body.get("isolated_user", "forge") if body.get("is_isolated") else "forge"
    root = f"/home/{user}/{body['name']}"
    web = (body.get("web_directory") or "/").rstrip("/")
    php = body.get("php_version")
    site = {"id": new_id(state), "name": body["name"], "status": "installing", "user": user,
            "isolated": bool(body.get("is_isolated")), "created_at": now(), "type": body.get("type"),
            "php_version": f"PHP {php[3]}.{php[4:]}" if php and len(php) >= 5 else None,
            "root_directory": root, "web_directory": root + web, "install_reads": state.get("install_reads", 1)}
    state.setdefault("sites", []).append(site)
    return site


def certificates(state: dict, site: dict) -> list:
    """One more read of the domain's certificates: what Forge is still working on moves along."""
    kept = []
    for cert in site.get("certificates", []):
        if "gone_in" in cert:
            if cert["gone_in"] <= 0:
                continue
            cert["gone_in"] -= 1
        kept.append(cert)
    site["certificates"] = kept
    for cert in site["certificates"]:
        if cert["status"] in ("installing", "enabling"):
            cert["reads"] -= 1
            if cert["reads"] < 0:
                if cert["status"] == "enabling":
                    cert.update(status="installed", active=True)
                elif cert["fail"]:
                    cert.update(request_status="verifying", status=state.get("cert_fail_status", "failed"))
                elif cert["type"] == "clone" and (not cert["enable"] or state.get("clone_enable_ignored")):
                    cert.update(request_status="created", status="installed")
                else:
                    cert.update(request_status="created", status="installed", active=True)
    return site["certificates"]


def site_route(state: dict, method: str, site: dict, rest: list, query: dict, body: dict | None) -> tuple[int, object]:
    domain = str(site["id"] * 10)
    if rest == ["nginx"] and method == "GET":
        if "pending_nginx" in site and not state.get("nginx_put_ignored"):
            site["nginx_reads"] -= 1
            if site["nginx_reads"] < 0:
                site["nginx"] = site.pop("pending_nginx")
        site.setdefault("nginx", site_conf(site))
        return 200, {"data": {"id": str(site["id"]), "type": "nginxConfigs", "attributes": {"content": site["nginx"]}}}
    if rest == ["nginx"] and method == "PUT":
        site.update(pending_nginx=body["config"], nginx_reads=state.get("nginx_reads", 1))
        return 202, None
    if rest == ["domains"] and method == "GET":
        return 200, {"data": [{"id": domain, "type": "domainRecords",
                               "attributes": {"name": site["name"], "type": "primary", "status": "enabled"}}]}
    if rest[:2] != ["domains", domain]:
        return 404, {"message": f"the fake has no {method} for a site's {'/'.join(rest)}"}
    rest = rest[2:]
    if rest == ["nginx"] and method == "GET":
        web = site.get("web_directory") or f"/home/{site.get('user', 'forge')}/{site['name']}"
        extra = state.get("server_extra", "")
        conf = DOMAIN_CONF.format(id=site["id"], name=site["name"], web=web, domain=domain, extra=extra + "\n" if extra else "")
        return 200, {"data": {"id": domain, "type": "nginxConfigs", "attributes": {"content": conf}}}
    if rest == ["certificates"] and method == "GET":
        return 200, {"data": [resource("certificates", c) for c in certificates(state, site)]}
    if rest == ["certificates"] and method == "POST":
        fail = state.get("cert_fail", 0) > 0
        if fail:
            state["cert_fail"] -= 1
        cert = {"id": new_id(state), "type": body["type"], "enable": bool(body.get("enable")), "active": False,
                "request_status": "creating", "status": "installing", "reads": state.get("cert_reads", 1), "fail": fail}
        site.setdefault("certificates", []).append(cert)
        return 202, {"data": resource("certificates", cert)}
    if len(rest) == 2 and rest[0] == "certificates" and method == "DELETE":
        cert = next((c for c in site.get("certificates", []) if str(c["id"]) == rest[1]), None)
        if cert is None:
            return 404, {"message": "Not Found."}
        cert.setdefault("gone_in", state.get("cert_remove_reads", 1))
        return 202, None
    if len(rest) == 3 and rest[0] == "certificates" and rest[2] == "actions" and method == "POST":
        cert = next((c for c in site.get("certificates", []) if str(c["id"]) == rest[1]), None)
        if cert is None:
            return 404, {"message": "Not Found."}
        if (body or {}).get("action") not in ("enable", "disable"):
            return 422, {"message": "The selected action is invalid."}
        if body["action"] == "enable" and not cert["active"] and not state.get("enable_ignored"):
            cert.update(status="enabling", reads=0)
        return 202, None
    return 404, {"message": f"the fake has no {method} for a domain's {'/'.join(rest)}"}


def deployment_route(state: dict, method: str, site: dict, rest: list, query: dict, body: dict | None):
    if rest == ["deployments", "script"] and method == "PUT":
        site["script"] = body["content"]
        return 200, None
    if rest == ["deployments"] and method == "POST":
        deployment = {"id": new_id(state), "status": "deploying", "reads": state.get("deploy_reads", 1)}
        site.setdefault("deployments", []).append(deployment)
        if state.get("deploy_adds_process"):
            state.setdefault("processes", []).append(dict(state.pop("deploy_adds_process"), id=new_id(state)))
        return 202, None
    if rest == ["deployments"] and method == "GET":
        newest = list(reversed(site.get("deployments", [])))[: int(query.get("page[size]", ["100"])[0])]
        return 200, {"data": [resource("deployments", d) for d in newest], "meta": {"next_cursor": None}}
    if len(rest) in (2, 3) and rest[0] == "deployments" and method == "GET":
        deployment = next((d for d in site.get("deployments", []) if str(d["id"]) == rest[1]), None)
        if deployment is None:
            return 404, {"message": "Not Found."}
        if len(rest) == 3 and rest[2] == "log":
            return 200, {"data": {"type": "deploymentOutputs", "attributes": {"output": state.get("deploy_log", "")}}}
        if deployment["status"] == "deploying":
            deployment["reads"] -= 1
            if deployment["reads"] < 0:
                deployment["status"] = state.get("deploy_result", "finished")
        return 200, {"data": resource("deployments", deployment)}
    return None


def jobs_route(state: dict, method: str, owner: dict, rest: list, query: dict) -> tuple[int, object] | None:
    """The scheduled jobs of the server (owner is the state) or of one site."""
    if rest == ["scheduled-jobs"] and method == "GET":
        owner["jobs"] = settle(owner.get("jobs", []), "remove_reads")
        listed = owner["jobs"]
        if owner is state and state.get("server_lists_site_jobs"):
            listed = listed + [job for site in state.get("sites", []) for job in site.get("jobs", [])]
        return 200, page(state, listed, "scheduledJobs", query)
    if len(rest) == 2 and rest[0] == "scheduled-jobs" and method == "DELETE":
        for job in owner.get("jobs", []):
            if str(job["id"]) == rest[1]:
                reads = state.get("job_remove_reads", 0)
                if reads:
                    job.update(status="deleting", remove_reads=reads)
                else:
                    owner["jobs"].remove(job)
                return 202, None
        return 404, {"message": "Not Found."}
    return None


def route(state: dict, method: str, path: str, query: dict, body: dict | None) -> tuple[int, object]:
    parts = path.strip("/").split("/")
    if parts[0] == "scheduled-jobs":
        return jobs_route(state, method, state, parts, query) or (404, {"message": f"the fake has no {method} {path}"})
    if parts == ["sites"] and method == "POST":
        for other in state.pop("sites_made_first", []):
            make_site(state, other)
        site = make_site(state, body)
        for other in state.pop("sites_made_after", []):
            make_site(state, other)
        return 202, {"data": resource("sites", site)}
    if parts == ["sites"] and method == "GET":
        for site in state.get("sites", []):
            if site.get("status") == "installing" and site.get("install_reads", 0) >= 0:
                site["install_reads"] -= 1
                if site["install_reads"] < 0:
                    site["status"] = "installed"
        state["sites"] = settle(state.get("sites", []), "remove_reads")
        sites = state["sites"]
        if "filter[name]" in query:
            sites = [s for s in sites if s["name"] == query["filter[name]"][0]]
        return 200, page(state, sites, "sites", query)
    if len(parts) > 2 and parts[0] == "sites":
        site = site_of(state, parts[1])
        if site is None:
            return 404, {"message": "Not Found."}
        return deployment_route(state, method, site, parts[2:], query, body) \
            or jobs_route(state, method, site, parts[2:], query) \
            or site_route(state, method, site, parts[2:], query, body)
    if len(parts) == 2 and parts[0] == "sites" and method == "DELETE":
        for site in state.get("sites", []):
            if str(site["id"]) == parts[1]:
                if site.get("status") == "installing" and state.get("installing_delete_dropped"):
                    return 202, None
                if state.get("site_deletes_dropped", 0) > 0:
                    state["site_deletes_dropped"] -= 1
                    site.update(status="removing", updated_at=now(), remove_reads=-1)
                    return 202, None
                site.update(status="removing", updated_at=now(), remove_reads=state.get("remove_reads", 1))
                return 202, None
        return 404, {"message": "Not Found."}
    if parts == ["background-processes"] and method == "GET":
        state["processes"] = settle(state.get("processes", []), "remove_reads")
        return 200, page(state, state["processes"], "backgroundProcesses", query)
    if parts == ["background-processes"] and method == "POST":
        users = {"root", "forge"} | {s.get("user") for s in state.get("sites", []) if s.get("isolated")}
        if body.get("user") not in users:
            return 422, {"message": "The selected user is invalid.", "errors": {"user": ["The selected user is invalid."]}}
        process = {"id": new_id(state), "command": body["command"], "user": state.get("process_user", body["user"]),
                   "directory": body.get("directory"), "processes": body["processes"], "status": "installing",
                   "created_at": now()}
        state.setdefault("processes", []).append(process)
        return 202, {"data": resource("backgroundProcesses", process)}
    if len(parts) == 2 and parts[0] == "background-processes" and method == "GET":
        process = next((p for p in state.get("processes", []) if str(p["id"]) == parts[1]), None)
        return (200, {"data": resource("backgroundProcesses", process)}) if process else (404, {"message": "Not Found."})
    if len(parts) == 2 and parts[0] == "background-processes" and method == "DELETE":
        for process in state.get("processes", []):
            if str(process["id"]) == parts[1]:
                reads = state.get("process_remove_reads", 0)
                if reads:
                    process.update(status="removing", remove_reads=reads)
                else:
                    state["processes"].remove(process)
                return 202, None
        return 404, {"message": "Not Found."}
    return 404, {"message": f"the fake has no {method} {path}"}


def probe(state: dict, host: str) -> tuple[str, str]:
    """What the link to a root-owned file answers, as nginx would serve it: its code and body."""
    site = next((s for s in state.get("sites", []) if s.get("name") == host), None)
    conf = "" if site is None else site.get("nginx") or site_conf(site)
    if site is None:
        code, body = "000", ""
    elif state.get("probe_follows") in (True, host) or state.get("probe_follows_for", 0) > 0 or not guarded(conf):
        if state.get("probe_follows_for", 0) > 0:
            state["probe_follows_for"] -= 1
        with open(os.environ["SITE_OP_INSTALLED"]) as f:
            code, body = "200", f.read()
    elif "/index.html;" in conf:
        code, body = "200", "<html>app</html>\n"
    elif state.get("catch_all"):
        code, body = "200", "<!doctype html><title>Shop</title>\n"
    else:
        code, body = "404", "Not Found\n"
    code = state.get("probe_code", code)
    return code, "" if code == "000" else body


def environment(host: str, path: str, out: str | None, write_out: str) -> int:
    """The environment's own answers: /up from $FORGE_UP, and the link nginx must refuse from the site's config."""
    up = os.environ.get("FORGE_UP", "")
    body = ""
    if path == "/mroom-symlink-probe":
        with open(STATE) as f:
            state = json.load(f)
        code, body = probe(state, host)
        with open(STATE, "w") as f:
            json.dump(state, f, indent=1)
        with open(up + ".probe", "a") as f:
            f.write(f"{code}\n")
    else:
        codes = open(up).read().split() if up and os.path.exists(up) else ["200"]
        code = codes[0]
        if len(codes) > 1:
            with open(up, "w") as f:
                f.write("\n".join(codes[1:]) + "\n")
        with open(up + ".log", "a") as f:
            f.write(f"{code}\n")
    if out and out != "/dev/null" and code != "000":
        with open(out, "w") as f:
            f.write(body)
    if "%{http_code}" in write_out:
        sys.stdout.write(code)
    return 7 if code == "000" else 0


def main(argv: list[str]) -> int:
    method, url, data, out, headers, write_out, auth = "GET", "", None, None, None, "", False
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg in ("--request", "-X"):
            method = argv[i + 1]
        elif arg in ("--header", "-H"):
            if argv[i + 1] == "@-":
                auth = sys.stdin.read().strip() == f"Authorization: Bearer {TOKEN}"
        elif arg == "--data-binary":
            value = argv[i + 1]
            data = open(value[1:]).read() if value.startswith("@") else value
        elif arg in ("--output", "-o"):
            out = argv[i + 1]
        elif arg == "--dump-header":
            headers = argv[i + 1]
        elif arg in ("--write-out", "-w"):
            write_out = argv[i + 1]
        elif arg in ("--max-time", "-m"):
            pass
        elif arg.startswith("-"):
            i += 1
            continue
        else:
            url = arg
            i += 1
            continue
        i += 2

    parsed = urllib.parse.urlsplit(url)
    path, query = parsed.path, urllib.parse.parse_qs(parsed.query)
    if parsed.netloc != "forge.laravel.com":
        return environment(parsed.netloc, path, out, write_out)
    with open(STATE) as f:
        state = json.load(f)
    with open(LOG, "a") as f:
        f.write(f"{method} {path.removeprefix(BASE)}{'?' + parsed.query if parsed.query else ''}"
                + (f" {data}" if data else "") + "\n")
    if os.environ.get("ORDER_LOG"):
        with open(os.environ["ORDER_LOG"], "a") as f:
            f.write(f"forge {method} {path.removeprefix(BASE)}\n")

    key = f"{method} {path.removeprefix(BASE)}"
    failing = state.get("fail", {}).get(key)
    if not path.startswith(BASE + "/") or not auth:
        code, answer = 401, {"message": "Unauthenticated."}
    elif isinstance(failing, int):
        code, answer = failing, {"message": "failing, as the test asked"}
    elif isinstance(failing, dict) and failing.get("times", 0) > 0:
        failing["times"] -= 1
        code, answer = failing["code"], {"message": "failing, as the test asked"}
    else:
        code, answer = route(state, method, path.removeprefix(BASE), query, json.loads(data) if data else None)

    with open(STATE, "w") as f:
        json.dump(state, f, indent=1)
    if headers:
        with open(headers, "w") as f:
            f.write(f"HTTP/2 {code}\r\ncontent-type: application/json\r\n\r\n")
    text = "" if answer is None else json.dumps(answer)
    if out:
        with open(out, "w") as f:
            f.write(text)
    else:
        sys.stdout.write(text)
    if "%{http_code}" in write_out:
        sys.stdout.write(str(code))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
