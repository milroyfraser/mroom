#!/usr/bin/env python3
"""A stand-in for GitHub (as the gh CLI) and chat (Slack, as curl), for the PR status tests
(tests/pr-status-test.sh). It never touches the network. The first argument says which it plays: `gh` or
`curl`; the rest are that tool's arguments, as actions/pr-status/pr-status.sh passes them.

It answers from one world's state, the JSON file $PRS_STATE, which a test seeds and reads back, and keeps what
the calls change there, so a second run sees the note the first one wrote:

  repo            "owner/name"; default_branch
  pulls           {<N>: {number, title, body, html_url, user: {login}, draft, state, merged, closed_at, updated_at,
                         head: {sha, ref}, base: {ref}, labels: [{name}]}}
  commits         {<N>: [{author: {login} | null, commit: {author: {email}}}]}, oldest first
  users           {<login>: {name}}, for users/<login>
  rules           {<branch>: [<rule>]}, as GitHub's rules/branches/<branch> lists them
  check_runs      {<sha>: [{id, name, status, conclusion, html_url, external_id, output: {title}}]}
  comments        {<N>: [{id, user: {login}, body, html_url, created_at}]}, oldest first
  runs            {<workflow file>: [{id, status, conclusion, html_url, display_title, created_at,
                                      pull_requests: [{number}]}]}
  jobs            {<run id>: [{name, status, conclusion, html_url}]}
  contents        {<path>: <text>}, the default branch's files
  next_id         the id the next comment gets
  slack_error     an error Slack answers every post with (channel_not_found, say)
  fail            ["<METHOD> <path regex>" ...]: those calls fail as GitHub answering 502, and change nothing
  lose_response   ["<METHOD> <path regex>" ...]: those calls take effect, then fail as a timeout would
  down            ["github" | "slack"]: every call to it fails, as no connection

Each call is logged to $PRS_LOG as one JSON line: {service: "github", method, path} or {service: "slack",
auth, body}. A call's argv is appended to $PRS_ARGV, so a test can check no token was on a command line.
"""

import json
import os
import re
import subprocess
import sys

STATE, LOG = os.environ["PRS_STATE"], os.environ["PRS_LOG"]
NOW = "2026-10-28T12:00:00Z"


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


def jq(data, program):
    """Prints data through the jq program as gh --jq does: strings raw, everything else as JSON."""
    out = subprocess.run(["jq", "-r", program], input=json.dumps(data), capture_output=True, text=True)
    if out.returncode != 0:
        sys.stderr.write(out.stderr)
        sys.exit(1)
    sys.stdout.write(out.stdout)


def matches(rules, method, path):
    return any(re.search(r.split(" ", 1)[1], path) and r.split(" ", 1)[0] == method for r in rules)


def not_found():
    sys.stderr.write("gh: Not Found (HTTP 404)\n")
    sys.exit(1)


def gh(argv):
    state = load()
    if "github" in state.get("down", []):
        sys.stderr.write("error connecting to api.github.com\n")
        sys.exit(1)
    if not argv or argv[0] != "api":
        sys.stderr.write(f"fake gh: not faked: {' '.join(argv[:2])}\n")
        sys.exit(1)
    method, program, path, fields, body, raw = "GET", None, None, {}, None, False
    i = 1
    while i < len(argv):
        a = argv[i]
        if a == "-X":
            method = argv[i + 1]; i += 2
        elif a == "--jq":
            program = argv[i + 1]; i += 2
        elif a == "--input":
            body = json.loads(sys.stdin.read() or "null") if argv[i + 1] == "-" else None; i += 2
        elif a in ("-F", "-f"):
            k, v = argv[i + 1].split("=", 1); fields[k] = v; i += 2
        elif a == "-H":
            raw = raw or "raw" in argv[i + 1]; i += 2
        elif a == "--paginate":
            i += 1
        elif path is None:
            path = a; i += 1
        else:
            sys.stderr.write(f"fake gh: unexpected argument {a}\n")
            sys.exit(2)
    log({"service": "github", "method": method, "path": path})
    if matches(state.get("fail", []), method, path):
        sys.stderr.write("gh: Server Error (HTTP 502)\n")
        sys.exit(1)
    lose = matches(state.get("lose_response", []), method, path)
    repo = state["repo"]
    bare, _, query = path.partition("?")
    p = bare.split("/")
    if p[0] == "users" and len(p) == 2:
        jq(state.get("users", {}).get(p[1]) or not_found(), program or ".")
        return
    if p[:3] != ["repos", *repo.split("/")]:
        not_found()
    rest = p[3:]
    data = None
    if rest == []:
        data = {"default_branch": state.get("default_branch", "main"), "full_name": repo}
    elif rest[:1] == ["pulls"] and len(rest) == 1:
        pulls = [v for v in state["pulls"].values() if "state=closed" not in query or v["state"] == "closed"]
        data = sorted(pulls, key=lambda v: v.get("updated_at", ""), reverse=True)[:20]
    elif rest[:1] == ["pulls"] and len(rest) == 2:
        data = state["pulls"].get(rest[1]) or not_found()
    elif rest[:1] == ["pulls"] and rest[2:] == ["commits"]:
        data = state.get("commits", {}).get(rest[1], [])[:1 if "per_page=1" in query else 100]
    elif rest[:2] == ["rules", "branches"]:
        data = state.get("rules", {}).get("/".join(rest[2:]), [])
    elif rest[:1] == ["commits"] and rest[2:] == ["check-runs"]:
        runs = state.get("check_runs", {}).get(rest[1], [])
        data = {"total_count": len(runs), "check_runs": runs}
    elif rest[:1] == ["issues"] and rest[2:] == ["comments"]:
        n = rest[1]
        comments = state.setdefault("comments", {}).setdefault(n, [])
        if method == "POST":
            if not isinstance(body, dict) or not isinstance(body.get("body"), str):
                sys.stderr.write("gh: Invalid request (HTTP 422)\n"); sys.exit(1)
            cid = state.get("next_id", 900)
            state["next_id"] = cid + 1
            data = {"id": cid, "user": {"login": "github-actions[bot]"}, "body": body["body"],
                    "html_url": f"https://github.com/{repo}/pull/{n}#issuecomment-{cid}", "created_at": NOW}
            comments.append(data)
            save(state)
        else:
            data = comments
    elif rest[:2] == ["issues", "comments"] and len(rest) == 3 and method == "PATCH":
        cid = int(rest[2])
        found = [c for cs in state.get("comments", {}).values() for c in cs if c["id"] == cid]
        if not found:
            not_found()
        if not isinstance(body, dict) or not isinstance(body.get("body"), str):
            sys.stderr.write("gh: Invalid request (HTTP 422)\n"); sys.exit(1)
        found[0]["body"] = body["body"]
        save(state)
        data = found[0]
    elif rest[:2] == ["actions", "workflows"] and rest[3:] == ["runs"]:
        wf = rest[2]
        if wf not in state.get("runs", {}):
            not_found()
        runs = sorted(state["runs"][wf], key=lambda r: r["created_at"], reverse=True)
        data = {"total_count": len(runs), "workflow_runs": runs[:int(fields.get("per_page", 30))]}
    elif rest[:2] == ["actions", "runs"] and rest[3:] == ["jobs"]:
        data = {"jobs": state.get("jobs", {}).get(rest[2], [])}
    elif rest[:1] == ["contents"]:
        name = "/".join(rest[1:])
        if name not in state.get("contents", {}):
            not_found()
        if not raw:
            sys.stderr.write("fake gh: contents without the raw media type\n"); sys.exit(2)
        if lose:
            sys.exit(1)
        sys.stdout.write(state["contents"][name])
        return
    else:
        sys.stderr.write(f"fake gh: not faked: {method} {path}\n")
        sys.exit(1)
    if lose:
        sys.stderr.write("gh: context deadline exceeded\n")
        sys.exit(1)
    if program is not None:
        jq(data, program)
    else:
        sys.stdout.write(json.dumps(data) + "\n")


def curl(argv):
    state = load()
    url, data, auth, config = None, None, "", None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("-K", "--config"):
            config = argv[i + 1]; i += 2
        elif a == "--data-binary":
            data = sys.stdin.read() if argv[i + 1] == "@-" else argv[i + 1]; i += 2
        elif a in ("--max-time", "-X", "--request"):
            i += 2
        elif a.startswith("-"):
            i += 1
        else:
            url = a; i += 1
    if config:
        with open(config) as f:
            for line in f:
                m = re.match(r'^header = "Authorization: (.*)"$', line.strip())
                if m:
                    auth = m.group(1)
    if "slack" in state.get("down", []):
        sys.stderr.write("curl: (7) Failed to connect\n")
        sys.exit(7)
    if url != "https://slack.com/api/chat.postMessage":
        sys.stderr.write(f"fake curl: not faked: {url}\n")
        sys.exit(1)
    try:
        body = json.loads(data or "")
    except ValueError:
        body = data
    log({"service": "slack", "auth": auth, "body": body})
    if state.get("slack_error"):
        sys.stdout.write(json.dumps({"ok": False, "error": state["slack_error"]}))
    else:
        sys.stdout.write(json.dumps({"ok": True, "ts": "1.0"}))


def main():
    with open(os.environ["PRS_ARGV"], "a") as f:
        f.write(json.dumps(sys.argv[1:]) + "\n")
    tool, argv = sys.argv[1], sys.argv[2:]
    if tool == "gh":
        gh(argv)
    elif tool == "curl":
        curl(argv)
    else:
        sys.exit(f"fake: unknown tool {tool}")


if __name__ == "__main__":
    main()
