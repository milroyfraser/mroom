#!/usr/bin/env python3
"""skills-check.py: the checks of tests/skills-test.sh, which runs this with SKILLS_DIR, COMMANDS_DIR and
MROOM_ROOT_DIR set. Prints one line per check, "ok <what>" or "FAIL <what>". Python 3.9 or newer, standard
library only."""
import json, os, re, subprocess, sys

root = os.environ["MROOM_ROOT_DIR"]
skills_dir = os.environ["SKILLS_DIR"]
commands_dir = os.environ["COMMANDS_DIR"]

SKILLS = ["correct", "deliver", "forge", "implement", "refine", "release"]
COMMANDS = ["clean-review", "crap"]
SKILL_KEYS = {"name", "description", "disable-model-invocation", "argument-hint", "allowed-tools", "model"}
COMMAND_KEYS = {"description", "argument-hint", "allowed-tools", "model"}
RULES = [
    "- Never merge, approve, deploy or release on your own. A person does each of these.",
    "- Tracker writes: only the state of the issue being worked, and comments on it.",
    "- Ask the person before you create an issue or a label.",
    "- Never touch production. Never read secrets, tokens or credential files.",
]
COMMAND_RULES = [
    "- Never commit, push, merge or approve. The developer reviews and commits.",
    "- Never read secrets, tokens or credential files, and never touch production.",
]

def say(ok, what):
    print(("ok " if ok else "FAIL ") + what)

def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()

def frontmatter(text):
    """(dict, body) from a --- block of `key: value` lines; None when there is no valid block."""
    if not text.startswith("---\n"):
        return None, text
    end = text.find("\n---\n", 4)
    if end < 0:
        return None, text
    data = {}
    for line in text[4:end].split("\n"):
        m = re.fullmatch(r"([a-z][a-z-]*): (.+)", line)
        if not m or m.group(1) in data:
            return None, text
        value = m.group(2).strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        elif value[0] in "\"'[{>|&*!%@`#" or ": " in value or " #" in value:
            return None, text  # not a plain YAML scalar
        data[m.group(1)] = value
    return data, text[end + 5:]

def code(text):
    """Every inline code span and fenced block, as strings."""
    blocks = re.findall(r"^ *```[a-z]*\n(.*?)^ *```$", text, flags=re.S | re.M)
    rest = re.sub(r"^ *```[a-z]*\n.*?^ *```$", "", text, flags=re.S | re.M)
    return blocks + re.findall(r"`([^`\n]+)`", rest)

RELEASE_CREATE = r"(?:^|[\s{=])gh\s+release\s+create\s+\S"
RELEASE_EDIT = r"(?:^|[\s{=])gh\s+release\s+edit\s+\S"

def split_commands(spans):
    """Every command in the spans: line continuations joined, then split at newlines, ;, &&, || and |,
    and at $( and backticks' openings, each stripped, so a command in the middle of a span is seen too."""
    out = []
    for span in spans:
        joined = re.sub(r"\\\n\s*", " ", span)
        for part in re.split(r"\n|;|&&|\|\||\||\$\(|\(", joined):
            part = part.strip()
            if part:
                out.append(part)
    return out

# --- What mroom has: commands, their subcommands, config keys ---------------------------------------------
front = read(os.path.join(root, "bin/mroom"))
case = front[front.index('case "$cmd" in'):]
not_yet = set(re.search(r"^\s*([a-z| ]+)\)\n\s*not_yet", case, flags=re.M).group(1).replace(" ", "").split("|"))
labels = set()
for m in re.finditer(r"^\s{2}([a-z][a-z| -]*)\)", case, flags=re.M):
    labels |= set(m.group(1).replace(" ", "").split("|"))
commands = labels - not_yet - {"help", "-h", "--help", "--version"}
usage_text = front.split("\nset -euo")[0]
for name in sorted(commands):
    lib = os.path.join(root, "lib", name)
    if os.path.isfile(lib):
        usage_text += "\n" + read(lib).split("\nset -")[0]
usage_text += "\n" + read(os.path.join(root, "lib/core/config.py")).split('"""')[1]
subs = {}
for m in re.finditer(r"mroom ([a-z]+) ([a-z][a-z|-]*)", usage_text):
    subs.setdefault(m.group(1), set()).update(m.group(2).split("|"))
keys = set(re.findall(r"^\s*\"([a-z_]+(?:\.[a-z_]+)+)\":", read(os.path.join(root, "lib/core/config.py")), flags=re.M))
say("tracker" in commands and {"get", "list", "comment", "state"} <= subs.get("tracker", set()),
    "the checks find mroom's commands and subcommands")
say("issues.state_review" in keys and "release.production_url" in keys, "the checks find mroom.toml's keys")

# --- Each skill and command -------------------------------------------------------------------------------
docs = {}
for kind, folder, expected, allowed in (("skill", skills_dir, SKILLS, SKILL_KEYS),
                                         ("command", commands_dir, COMMANDS, COMMAND_KEYS)):
    found = sorted(os.listdir(folder)) if os.path.isdir(folder) else []
    names = found if kind == "skill" else sorted(f[:-3] for f in found if f.endswith(".md"))
    say(names == expected, f"plugin {kind}s are exactly {expected} (found {names})")
    for name in names:
        path = os.path.join(folder, name, "SKILL.md") if kind == "skill" else os.path.join(folder, name + ".md")
        if not os.path.isfile(path):
            say(False, f"{kind} {name} has no file at {path}")
            continue
        text = read(path)
        meta, body = frontmatter(text)
        label = f"{kind} {name}"
        say(meta is not None, f"{label} has valid frontmatter")
        meta = meta or {}
        say(set(meta) <= allowed, f"{label} uses only known frontmatter keys (has {sorted(meta)})")
        say(10 <= len(meta.get("description", "")) <= 1024, f"{label} has a description of 10 to 1024 characters")
        if kind == "skill":
            say(meta.get("name") == name, f"{label}: its name matches its folder (name: {meta.get('name')})")
        if "disable-model-invocation" in meta:
            say(meta["disable-model-invocation"] in ("true", "false"), f"{label}: disable-model-invocation is true or false")
        docs[label] = (name, kind, meta, body, text)
skill_names = [d[0] for d in docs.values() if d[1] == "skill"]
say(len(skill_names) == len(set(skill_names)), "every skill's name is unique")
known_slash = set(SKILLS) | set(COMMANDS)

# Strict on purpose: a skill names a tracker's MCP server or a secret file only in its rules' own words
# ("Never read secrets, tokens or credential files"), never in prose such as "copy it to .env".
FORBIDDEN = [
    (r"gh\s+pr\s+merge", "a merge"), (r"gh\s+pr\s+review", "a PR review (an approval)"), (r"--approve", "an approval"),
    (r"gh\s+release\s+delete", "a release delete"), (r"--draft=false|draft=false", "publishing a draft"),
    (r"gh\s+workflow\s+run", "starting a workflow (a deploy)"), (r"gh\s+secret", "a secret"),
    (r"gh\s+auth\s+(token|git-credential)", "a token read"), (r"git\s+tag\b", "a tag"),
    (r"git\s+push\b[^`\n]*(--force|\s-f\b|--tags|--follow-tags|--mirror|\s\+)", "a force or tag push"),
    (r"gh\s+issue\s+(create|comment|edit|close)", "a GitHub issue write (the tracker is mroom tracker)"),
    (r"gh\s+api\b[^`\n]*(-X|--method)\s*(POST|PUT|PATCH|DELETE)", "a gh api write"),
    (r"\bmutation\s*[({]", "a GraphQL mutation"),
    (r"(?i)\b(linear|sentry|forge)\b[^.\n]{0,30}\bMCP\b|\bMCP\b[^.\n]{0,30}\b(linear|sentry|forge)\b",
     "a tracker, error-tracker or Forge MCP server"),
    (r"api\.linear\.app|linear\.app/|sentry\.io|forge\.laravel\.com", "a tracker, error-tracker or Forge host"),
    (r"\bmcp__|\b(list_issues|get_issue|save_comment|save_issue|list_issue_labels|list_issue_statuses|update_issue)\b",
     "a tracker or error-tracker MCP tool"),
    # Any command that names a secret file: cat, grep, sed, jq, source, an editor ...
    (r"\b[a-z][a-z0-9_-]*\s+[^`\n]*?(?<![\w-])(\.env\b(?!\.example)|forge-token\b|\.ssh/|\.credentials|secrets/)",
     "a secret read"),
    (r"\bforge\s+(deploy|env|tinker|ssh)", "the Forge CLI"),
    (r"--dangerously|bypassPermissions|--no-verify", "skipping a permission or a hook"),
]

for label, (name, kind, meta, body, text) in sorted(docs.items()):
    spans = code(body)
    joined = "\n".join(spans)
    # Safety rules.
    for rule in (RULES if kind == "skill" else COMMAND_RULES):
        say(rule in body, f"{label} keeps the rule: {rule[2:60]}")
    if kind == "skill":
        rules = re.search(r"^## Rules\n(.*?)(?=^## |\Z)", body, flags=re.S | re.M)
        say(bool(rules) and all(r in rules.group(1) for r in RULES), f"{label} has the rules under ## Rules")
    for pattern, what in FORBIDDEN:
        hits = [m.group(0) for m in re.finditer(pattern, text)]
        say(not hits, f"{label} runs no {what} ({hits[:3]})")
    cmds = split_commands(spans)
    bad_edits = [c for c in cmds if re.search(RELEASE_EDIT, c)
                 and re.search(r"--(draft|latest|prerelease|tag|target)\b", c)]
    say(not bad_edits, f"{label}: gh release edit changes only the notes ({bad_edits[:2]})")
    undrafted = [c for c in cmds if re.search(RELEASE_CREATE, c) and not re.search(r"\s--draft\b(?!=)", c)]
    say(not undrafted, f"{label}: every gh release create has --draft ({undrafted[:2]})")
    # gh api: a field makes it a POST unless this command says GET; graphql writes by a mutation, or a query
    # read from a file, which the test cannot see.
    api_writes = [c for c in cmds if re.match(r"gh\s+api\b", c) and (
        (not re.match(r"gh\s+api\s+graphql\b", c) and re.search(r"\s(-f|-F|--field|--raw-field|--input)\b", c)
         and not re.search(r"(-X\s*|--method[\s=])GET\b", c))
        or (re.match(r"gh\s+api\s+graphql\b", c) and re.search(r"mutation|query=@|--input\b", c)))]
    say(not api_writes, f"{label} runs no gh api write ({api_writes[:2]})")
    curls = [s for s in spans if re.search(r"\b(curl|wget|http)\b", s) and not s.startswith("http")]
    curl_ok = all(re.fullmatch(r"curl -s <production_url><version_path>", s) for s in curls)
    say(curl_ok and (not curls or name == "release"),
        f"{label} calls no URL itself, but the release's read of the version path ({curls[:3]})")
    # Commands, skills and keys it names.
    for m in re.finditer(r"(?:^|[\s\"'(|;&$])mroom ([a-z][a-z-]*)(?: ([a-z][a-z-]*))?", joined):
        cmd, sub = m.group(1), m.group(2)
        say(cmd in commands, f"{label}: `mroom {cmd}` is a command mroom has")
        if cmd in subs and sub:
            say(sub in subs[cmd], f"{label}: `mroom {cmd} {sub}` is a subcommand mroom has")
    for m in re.finditer(r"/mroom:([a-z][a-z-]*)", text):
        say(m.group(1) in known_slash, f"{label}: /mroom:{m.group(1)} is a skill or command of the plugin")
    for span in spans:
        for key in re.findall(r"\b((?:app|tests|issues|errors|pr|qa|persona|release|github)\.[a-z_]+(?:\.[a-z_]+)*)\b", span):
            say(key in keys, f"{label}: `{key}` is a key mroom.toml has")
    # No tracker: exit 3.
    for adapter in ("tracker", "errors"):
        if re.search(rf"mroom {adapter}\b", joined):
            say(re.search(rf"`mroom {adapter}` exits 3|mroom {adapter}` call exits 3", body) is not None,
                f"{label} says what to do when `mroom {adapter}` exits 3")
    # Privacy.
    private = [
        (r"\b(?!0\.0\.0\.0\b|127\.0\.0\.1\b)(?:\d{1,3}\.){3}\d{1,3}\b", "IP address"),
        (r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[a-z]{2,}", "email address"),
        (r"\b(?!SHOP-)[A-Z][A-Z0-9]{1,9}-[0-9]+\b", "issue id but the SHOP- example"),
        (r"(?<![\w/])#[0-9]{2,}\b", "PR or issue number"),
        (r"(?<![\w.-])[0-9]{5,}(?![\w-])", "long number (a server, site or project id)"),
        (r"/Users/|/home/|~[a-z]", "home folder"),
    ]
    for pattern, what in private:
        hits = re.findall(pattern, text)
        say(not hits, f"{label} names no {what} ({hits[:3]})")
    hosts = re.findall(r"https?://([^/\s)`\"'>]+)", text)
    # Bare host names too, with no scheme (go.shop-corp.io).
    hosts += re.findall(r"(?<![\w./@-])((?:[a-z0-9-]+\.)+(?:dev|io|com|net|org|co|ai|cloud))\b(?!\.[a-z])", text)
    say(all(h.rstrip(".") == "github.com" or h.rstrip(".").endswith("example.dev") or h == "<production_url>"
            for h in hosts),
        f"{label} links only github.com or an example host ({hosts})")
    words = os.environ.get("MROOM_PRIVATE_WORDS")
    if words:
        for word in [w.strip() for w in read(words).split("\n") if w.strip()]:
            say(re.search(word, text, flags=re.I) is None, f"{label} names none of the private words (one of them)")

# --- The release skill ------------------------------------------------------------------------------------
release = docs.get("skill release")
if release:
    _, _, meta, body, _ = release
    say(meta.get("disable-model-invocation") == "true", "release runs only when a person asks (disable-model-invocation)")
    cmds = split_commands(code(body))
    creates = [c for c in cmds if re.search(RELEASE_CREATE, c)]
    edits = [c for c in cmds if re.search(RELEASE_EDIT, c)]
    say(bool(creates) and all(re.search(r"\s--draft\b(?!=)", c) for c in creates),
        f"release always creates the release with --draft ({[c for c in creates if '--draft' not in c][:2]})")
    say(all(re.search(r"--(draft|latest|prerelease|tag|target)\b", c) is None for c in edits),
        "release's gh release edit changes only the notes")
    # A step before the one that drafts asks the person, not only the rules.
    sections = re.split(r"^## ", body, flags=re.M)
    draft_at = next((i for i, sec in enumerate(sections)
                     if any(re.search(RELEASE_CREATE, c) for c in split_commands(code(sec)))), -1)
    asked = [sec for sec in sections[:max(draft_at, 0)] if not sec.startswith("Rules")
             and re.search(r"AskUserQuestion`?:?\s*\*\*release now\*\*", sec)]
    say(draft_at > 0 and bool(asked), "release asks the person (AskUserQuestion: release now) in a step before it drafts")
    say("If either is declined, stop" in body, "release stops when the prompt is declined")
    say("Never publish, delete or edit a published release" in body, "release never publishes a release itself")
corr = docs.get("skill correct")
say(bool(corr) and corr[2].get("disable-model-invocation") == "true", "correct runs only when a person asks")
say(os.path.isfile(os.path.join(skills_dir, "correct", "LICENSE")), "correct keeps its upstream MIT LICENSE")

# --- The settings fragments still ask on a release --------------------------------------------------------
frag = {}
for f in sorted(os.listdir(os.path.join(root, "settings"))):
    perms = json.loads(read(os.path.join(root, "settings", f)))["permissions"]
    for kind in ("allow", "ask", "deny"):
        frag.setdefault(kind, []).extend(perms.get(kind, []))
for rule in ("Bash(gh release create:*)", "Bash(gh release edit:*)"):
    say(rule in frag["ask"], f"the settings ask before {rule}")
say(not any(r.startswith("Bash(gh release") and r != "Bash(gh release list:*)" and r != "Bash(gh release view:*)"
            for r in frag["allow"]), "no settings fragment allows a release write")
say("Bash(gh release delete:*)" in frag["deny"] and "Bash(gh pr merge:*)" in frag["deny"],
    "the settings deny a release delete and a merge")
