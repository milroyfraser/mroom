#!/usr/bin/env python3
"""A stand-in for Laravel Forge's v2 API, for the QA action tests (tests/qa-*-test.sh). It plays curl:

    curl <arguments>     as lib/core/forge.sh calls it: --request, --header @- (the token, on stdin), --data-binary
                         @<file>, --dump-header <file>, --output <file>, --write-out '%{http_code}', and the URL

It answers from one server's state, the JSON file $FORGE_STATE, which a test seeds and reads back: "sites" and
"processes" (background processes), each a list of plain objects with an "id". Only the bearer token
fake-forge-token reaches the organisation acme's server 42. Each call is logged to $FORGE_LOG as one line,
"<METHOD> <path and query>", with " <body>" after it for a write, and as "forge <METHOD> <path>" to $ORDER_LOG,
when it is set, which the gate's stand-in (tests/fakes/ssh) writes too.

As Forge does, it answers JSON:API resources, and lists at most 30 items at a time, whatever page[size] asks, with
a cursor to the next page ("page_size" in the state lowers the most). A site it deletes turns removing, with updated_at
now (MROOM_NOW, when set), and goes after "remove_reads" (1) more reads of the site list; -1 keeps it removing. A
process it deletes goes at once, or turns removing and goes after "process_remove_reads" reads of the list. "fail":
{"<METHOD> <path>": code} answers that code to every such call, and {"code": code, "times": n} to the next n only.

What qa-up makes, it makes as Forge does, slowly: a site stays installing for "install_reads" (1) reads of the list,
with an nginx config of Forge's shape; a certificate is inactive for "cert_reads" (1) reads; a deployment is deploying
for "deploy_reads" (1) reads, then ends "deploy_result" (finished) with "deploy_log" as its output; and a background
process runs as the user asked for, or as "process_user" when the state names one, as a Forge that ignores the user
would. Any other host plays the environment's /up: it answers the next code of $FORGE_UP (one a line, the last one
repeating), 000 being no answer, and logs each to $FORGE_UP.log.
"""

import datetime
import json
import os
import sys
import urllib.parse

TOKEN = "fake-forge-token"
BASE = "/api/orgs/acme/servers/42"
STATE, LOG = os.environ["FORGE_STATE"], os.environ["FORGE_LOG"]


def now() -> str:
    """The test's clock (MROOM_NOW, epoch seconds) when it has one."""
    when = datetime.datetime.now(datetime.timezone.utc)
    if os.environ.get("MROOM_NOW"):
        when = datetime.datetime.fromtimestamp(int(os.environ["MROOM_NOW"]), datetime.timezone.utc)
    return when.strftime("%Y-%m-%dT%H:%M:%SZ")


def resource(kind: str, item: dict) -> dict:
    hidden = ("id", "remove_reads", "install_reads", "reads", "nginx", "script", "certificates", "deployments")
    return {"id": str(item["id"]), "type": kind, "attributes": {k: v for k, v in item.items() if k not in hidden}}


def up_probe(out: str | None, write_out: str) -> int:
    """The environment's /up: the next code of $FORGE_UP, the last one repeating."""
    path = os.environ.get("FORGE_UP", "")
    codes = open(path).read().split() if path and os.path.exists(path) else ["200"]
    code = codes[0]
    if len(codes) > 1:
        with open(path, "w") as f:
            f.write("\n".join(codes[1:]) + "\n")
    with open(path + ".log", "a") as f:
        f.write(f"{code}\n")
    if out and out != "/dev/null":
        open(out, "w").close()
    if "%{http_code}" in write_out:
        sys.stdout.write(code)
    return 7 if code == "000" else 0


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
        if item.get("status") == "removing" and isinstance(left, int) and left >= 0:
            if left == 0:
                continue
            item[field] = left - 1
        kept.append(item)
    return kept


NGINX = """# FORGE CONFIG (DO NOT REMOVE!)
include forge-conf/{name}/before/*;

server {{
    listen 80;
    server_name {name};
    root /home/{user}/{name}{web};

    index index.html index.php;

    location / {{
        try_files $uri $uri/ {fallback};
    }}
}}
"""


def site_of(state: dict, site_id: str) -> dict | None:
    return next((s for s in state.get("sites", []) if str(s["id"]) == site_id), None)


def new_id(state: dict) -> int:
    state["next_id"] = state.get("next_id", 100) + 1
    return state["next_id"]


def make_site(state: dict, body: dict) -> dict:
    web = (body.get("web_directory") or "/").rstrip("/")
    site = {"id": new_id(state), "name": body["name"], "status": "installing", "user": body.get("isolated_user", "forge"),
            "isolated": bool(body.get("is_isolated")), "created_at": now(), "type": body.get("type"),
            "php_version": body.get("php_version"), "web_directory": body.get("web_directory"),
            "install_reads": state.get("install_reads", 1)}
    site["nginx"] = NGINX.format(name=site["name"], user=site["user"], web=web,
                                 fallback="/index.php?$query_string" if body.get("type") == "php" else "=404")
    state.setdefault("sites", []).append(site)
    return site


def site_route(state: dict, method: str, site: dict, rest: list, query: dict, body: dict | None) -> tuple[int, object]:
    if rest == ["nginx"] and method == "GET":
        return 200, {"data": {"id": str(site["id"]), "type": "nginxConfigs", "attributes": {"content": site.get("nginx")}}}
    if rest == ["nginx"] and method == "PUT":
        site["nginx"] = body["config"]
        return 200, None
    if rest == ["certificates"] and method == "GET":
        for cert in site.get("certificates", []):
            if not cert["active"]:
                cert["reads"] -= 1
                if cert["reads"] < 0:
                    cert.update(active=True, request_status="created")
        return 200, {"data": [resource("certificates", c) for c in site.get("certificates", [])]}
    if rest == ["domains"] and method == "GET":
        return 200, {"data": [{"id": str(site["id"] * 10), "type": "domains", "attributes": {"name": site["name"], "type": "primary"}}]}
    if len(rest) == 3 and rest[0] == "domains" and rest[2] == "certificates" and method == "POST":
        if rest[1] != str(site["id"] * 10):
            return 404, {"message": "Not Found."}
        cert = {"id": new_id(state), "type": body["type"], "active": False, "request_status": "creating",
                "reads": state.get("cert_reads", 1)}
        site.setdefault("certificates", []).append(cert)
        return 202, {"data": resource("certificates", cert)}
    if rest == ["deployments", "script"] and method == "PUT":
        site["script"] = body["content"]
        return 200, None
    if rest == ["deployments"] and method == "POST":
        deployment = {"id": new_id(state), "status": "deploying", "reads": state.get("deploy_reads", 1)}
        site.setdefault("deployments", []).append(deployment)
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
    return 404, {"message": f"the fake has no {method} for a site's {'/'.join(rest)}"}


def route(state: dict, method: str, path: str, query: dict, body: dict | None) -> tuple[int, object]:
    parts = path.strip("/").split("/")
    if parts == ["sites"] and method == "POST":
        return 202, {"data": resource("sites", make_site(state, body))}
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
        return site_route(state, method, site, parts[2:], query, body)
    if len(parts) == 2 and parts[0] == "sites" and method == "DELETE":
        for site in state.get("sites", []):
            if str(site["id"]) == parts[1]:
                site.update(status="removing", updated_at=now(), remove_reads=state.get("remove_reads", 1))
                return 202, None
        return 404, {"message": "Not Found."}
    if parts == ["background-processes"] and method == "GET":
        state["processes"] = settle(state.get("processes", []), "remove_reads")
        return 200, page(state, state["processes"], "backgroundProcesses", query)
    if parts == ["background-processes"] and method == "POST":
        process = {"id": new_id(state), "user": state.get("process_user", body["user"]), "directory": body.get("directory"),
                   "command": body["command"], "processes": body["processes"], "status": "installing",
                   "site_id": body.get("site_id"), "name": body["name"]}
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
        return up_probe(out, write_out)
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
