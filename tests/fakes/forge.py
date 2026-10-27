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
a cursor to the next page ("page_size" in the state lowers the most). A site it deletes turns removing, with updated_at now (MROOM_NOW, when set), and
goes after "remove_reads" (1) more reads of the site list; -1 keeps it removing. A process it deletes goes at
once, or turns removing and goes after "process_remove_reads" reads of the list. "fail": {"<METHOD> <path>": code}
answers that code to every such call, and {"code": code, "times": n} to the next n only.
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
    return {"id": str(item["id"]), "type": kind,
            "attributes": {k: v for k, v in item.items() if k not in ("id", "remove_reads")}}


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


def route(state: dict, method: str, path: str, query: dict, body: dict | None) -> tuple[int, object]:
    parts = path.strip("/").split("/")
    if parts == ["sites"] and method == "GET":
        state["sites"] = settle(state.get("sites", []), "remove_reads")
        sites = state["sites"]
        if "filter[name]" in query:
            sites = [s for s in sites if s["name"] == query["filter[name]"][0]]
        return 200, page(state, sites, "sites", query)
    if len(parts) == 2 and parts[0] == "sites" and method == "DELETE":
        for site in state.get("sites", []):
            if str(site["id"]) == parts[1]:
                site.update(status="removing", updated_at=now(), remove_reads=state.get("remove_reads", 1))
                return 202, None
        return 404, {"message": "Not Found."}
    if parts == ["background-processes"] and method == "GET":
        state["processes"] = settle(state.get("processes", []), "remove_reads")
        return 200, page(state, state["processes"], "backgroundProcesses", query)
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
    if parsed.netloc != "forge.laravel.com" or not path.startswith(BASE + "/") or not auth:
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
