#!/usr/bin/env python3
"""A stand-in for the tracker (Linear), the error tracker (Sentry) and chat (Slack), for the persona's tests
(tests/persona-test.sh, tests/triage-test.sh). It plays curl, as lib/core/api.sh calls it: --request, --header @-
(the Authorization line, on stdin), --data-binary @<file>, --dump-header <file>, --output <file>, --write-out
'%{http_code}', and the URL. It never touches the network.

It answers from one world's state, the JSON file $PERSONA_STATE, which a test seeds and reads back, and keeps what
the calls change there, so a second run sees what the first one filed:

  viewer          the id of the token's user (the persona)
  team            {id, key}; states [{id, name, type}]; labels [{id, name}]
  issues          [{id, identifier, title, description, url, createdAt, creator, assignee, state, labels,
                    comments: [{body, createdAt, user}]}], creator being a user's id
  strip_markers   true: the tracker drops HTML comments from the descriptions it stores, as a tracker might
  unescape_entities  true: it turns &lt; and the like back into characters, as a rich-text store might
  sentry          {projects, new, regressed, escalating: [<Sentry issue>], events: {<id>: <event>}}
  slack_error     an error Slack answers every post with (channel_not_found, say)
  down            ["linear" | "sentry" | "slack"]: that service answers 503
  down_after_create  true: the tracker goes down right after the next create

Each call is logged to $PERSONA_LOG as one JSON line: {service, op, vars} for Linear (op being the GraphQL
operation's first field), {service, method, path} for Sentry and {service, body} for Slack, with "auth", the
Authorization value it got.
"""

import html
import json
import os
import re
import sys
import urllib.parse

STATE, LOG = os.environ["PERSONA_STATE"], os.environ["PERSONA_LOG"]


def load():
    with open(STATE) as f:
        return json.load(f)


def save(state):
    with open(STATE + ".new", "w") as f:
        json.dump(state, f)
    os.replace(STATE + ".new", STATE)


def log(entry):
    with open(LOG, "a") as f:
        f.write(json.dumps(entry) + "\n")


def args():
    a, out = sys.argv[1:], {"method": "GET", "data": None, "url": None, "output": None, "headers": None}
    i = 0
    while i < len(a):
        x = a[i]
        if x == "--request":
            out["method"] = a[i + 1]; i += 2
        elif x == "--data-binary":
            with open(a[i + 1].lstrip("@")) as f:
                out["data"] = f.read()
            i += 2
        elif x == "--output":
            out["output"] = a[i + 1]; i += 2
        elif x == "--dump-header":
            out["headers"] = a[i + 1]; i += 2
        elif x in ("--header", "--write-out", "--max-time"):
            i += 2
        elif x.startswith("-"):
            i += 1
        else:
            out["url"] = x; i += 1
    return out


def answer(req, code, body):
    with open(req["headers"], "w") as f:
        f.write(f"HTTP/2 {code}\r\n")
    with open(req["output"], "w") as f:
        f.write(json.dumps(body))
    sys.stdout.write(str(code))
    return 0


def state_of(state, sid):
    return next((s for s in state["states"] if s["id"] == sid), state["states"][0])


def issue_node(state, issue, viewer):
    s = state_of(state, issue.get("state"))
    labels = [{"name": l["name"]} for l in state["labels"] if l["id"] in issue.get("labels", [])]
    creator = issue.get("creator")
    assignee = issue.get("assignee")
    return {
        "id": issue["id"], "identifier": issue["identifier"], "title": issue["title"],
        "description": issue.get("description"), "url": issue["url"], "branchName": "b/" + issue["identifier"],
        "priority": 0, "priorityLabel": "No priority", "createdAt": issue["createdAt"],
        "updatedAt": issue["createdAt"], "state": s, "team": state["team"],
        "creator": {"id": creator, "name": "Persona" if creator == viewer else "Someone"} if creator else None,
        "assignee": {"name": assignee, "isMe": False} if assignee else None,
        "labels": {"nodes": labels},
    }


def find_issue(state, key):
    return next((i for i in state["issues"] if key in (i["id"], i["identifier"])), None)


def linear(req, auth):
    state = load()
    if "linear" in state.get("down", []):
        return answer(req, 503, {"errors": [{"message": "down"}]})
    body = json.loads(req["data"])
    q, v = body["query"], body.get("variables") or {}
    op = re.search(r"\{\s*(\w+)", q).group(1)
    log({"service": "linear", "op": op, "vars": v, "auth": auth})
    viewer = state["viewer"]
    if op == "viewer":
        issue = find_issue(state, v["id"])
        return answer(req, 200, {"data": {"viewer": {"id": viewer}, "issue": None if issue is None else {
            "identifier": issue["identifier"], "creator": {"id": issue.get("creator")} if issue.get("creator") else None}}})
    if op == "issue":
        issue = find_issue(state, v["id"])
        if issue is None:
            return answer(req, 200, {"data": {"issue": None}})
        if "comments(" in q:
            nodes = [{"body": c["body"], "createdAt": c["createdAt"], "user": {"name": c.get("user", "Someone")}}
                     for c in issue.get("comments", [])]
            return answer(req, 200, {"data": {"issue": {"comments": {"nodes": nodes, "pageInfo": {"hasNextPage": False}}}}})
        return answer(req, 200, {"data": {"issue": issue_node(state, issue, viewer)}})
    if op == "issues":
        f = v.get("f") or {}
        want = (f.get("description") or {}).get("contains", "")
        team = ((f.get("team") or {}).get("key") or {}).get("eq")
        nodes = [issue_node(state, i, viewer) for i in state["issues"]
                 if want in (i.get("description") or "") and (team is None or team == state["team"]["key"])]
        return answer(req, 200, {"data": {"issues": {"nodes": nodes, "pageInfo": {"hasNextPage": False}}}})
    if op == "teams":
        key = v["k"]
        nodes = [{"id": state["team"]["id"], "key": key}] if key == state["team"]["key"] else []
        return answer(req, 200, {"data": {"teams": {"nodes": nodes}}})
    if op == "team":
        return answer(req, 200, {"data": {"team": {"states": {"nodes": state["states"], "pageInfo": {"hasNextPage": False}}}}})
    if op == "issueLabels":
        nodes = [{"id": l["id"], "name": l["name"], "team": None} for l in state["labels"] if l["name"] in v["n"]]
        return answer(req, 200, {"data": {"issueLabels": {"nodes": nodes}}})
    if op == "issueCreate":
        i = v["i"]
        n = state.get("next", 1)
        state["next"] = n + 1
        ident = f"{state['team']['key']}-{n}"
        desc = i.get("description", "")
        if state.get("strip_markers"):
            desc = re.sub(r"<!--.*?-->", "", desc, flags=re.S)
        if state.get("unescape_entities"):
            desc = html.unescape(desc)
        state["issues"].append({
            "id": f"uuid-{n}", "identifier": ident, "title": i["title"], "description": desc,
            "url": f"https://tracker.example.dev/issue/{ident}", "createdAt": f"2026-10-28T10:{n:02d}:00Z",
            "creator": viewer, "assignee": i.get("assigneeId"), "state": i.get("stateId"),
            "labels": i.get("labelIds", []), "comments": []})
        if state.get("down_after_create"):
            state.setdefault("down", []).append("linear")
        save(state)
        return answer(req, 200, {"data": {"issueCreate": {"success": True, "issue": {
            "identifier": ident, "url": f"https://tracker.example.dev/issue/{ident}"}}}})
    if op == "commentCreate":
        issue = find_issue(state, v["i"])
        if issue is None:
            return answer(req, 200, {"data": None, "errors": [{"message": "Entity not found"}]})
        issue.setdefault("comments", []).append({"body": v["b"], "createdAt": "2026-10-28T11:00:00Z", "user": "Persona"})
        save(state)
        return answer(req, 200, {"data": {"commentCreate": {"success": True, "comment": {"url": issue["url"] + "#c"}}}})
    return answer(req, 200, {"data": None, "errors": [{"message": f"the fake does not know {op}"}]})


def sentry(req, auth):
    state = load()
    url = urllib.parse.urlsplit(req["url"])
    path = url.path.split("/organizations/", 1)[-1]
    path = path.split("/", 1)[1] if "/" in path else path
    log({"service": "sentry", "method": req["method"], "path": "/" + path + ("?" + url.query if url.query else ""), "auth": auth})
    if "sentry" in state.get("down", []):
        return answer(req, 503, {"detail": "down"})
    s = state["sentry"]
    if path.startswith("projects/"):
        return answer(req, 200, s.get("projects", [{"slug": "web"}]))
    if path == "issues/":
        query = urllib.parse.parse_qs(url.query).get("query", [""])[0]
        if "is:regressed" in query:
            return answer(req, 200, s.get("regressed", []))
        if "is:escalating" in query:
            return answer(req, 200, s.get("escalating", []))
        if "firstSeen" in query:
            return answer(req, 200, s.get("new", []))
        return answer(req, 200, [])
    m = re.fullmatch(r"issues/([0-9]+)/(events/latest/)?", path)
    if m:
        every = s.get("new", []) + s.get("regressed", []) + s.get("escalating", [])
        issue = next((i for i in every if i["id"] == m.group(1)), None)
        if issue is None:
            return answer(req, 404, {"detail": "The requested resource does not exist"})
        if m.group(2):
            event = s.get("events", {}).get(m.group(1))
            return answer(req, 200, event) if event else answer(req, 404, {"detail": "no event"})
        return answer(req, 200, issue)
    return answer(req, 404, {"detail": "the fake does not know " + path})


def slack(req, auth):
    state = load()
    log({"service": "slack", "body": json.loads(req["data"]), "auth": auth})
    if "slack" in state.get("down", []):
        return answer(req, 503, {"ok": False, "error": "down"})
    if state.get("slack_error"):
        return answer(req, 200, {"ok": False, "error": state["slack_error"]})
    return answer(req, 200, {"ok": True, "ts": "1.2"})


def main():
    req = args()
    auth = ""
    for line in sys.stdin.read().splitlines():
        if line.startswith("Authorization: "):
            auth = line[len("Authorization: "):]
    host = urllib.parse.urlsplit(req["url"]).hostname
    if host == "api.linear.app":
        return linear(req, auth)
    if host in ("us.sentry.io", "de.sentry.io"):
        return sentry(req, auth)
    if host == "slack.com":
        return slack(req, auth)
    print(f"curl: (6) Could not resolve host: {host}", file=sys.stderr)
    return 6


if __name__ == "__main__":
    sys.exit(main())
