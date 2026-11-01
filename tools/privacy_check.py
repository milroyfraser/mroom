#!/usr/bin/env python3
"""privacy_check.py: checks a change for the owner's private words (names of people, projects, hosts and ids
that must never reach this public repository).

    tools/privacy_check.py [--base <ref>] [--head <ref>]

It reads the lines the change adds (git diff <base>...<head>), the paths it touches, the messages of the
commits in <base>..<head>, and $PR_TITLE and $PR_BODY when they are set. --base defaults to origin/main and
--head to HEAD. A hit names the place (file and line, commit, title or body line) and the entry's number,
never the word, the line or a path that matches; with GITHUB_ACTIONS set it is an ::error annotation.

The list is one case-insensitive regular expression per line; blank lines are skipped and the entries are
numbered from 1 among the rest. It comes from $MROOM_PRIVATE_WORDS, the path of a file or the list itself, or
else from .private-words at the top of the repository (gitignored). With no list the check passes with a
notice. tests/skills-check.py reads the list through private_words() too.

Exit codes: 0 no hit or no list, 1 a hit or an entry that is not a valid regular expression, 2 a git error.
Python 3.9 or newer, standard library only."""
import argparse, os, re, subprocess, sys

LIST_FILE = ".private-words"


def private_words(root):
    """The entries of the private list, or None when there is none. Never prints them."""
    value = os.environ.get("MROOM_PRIVATE_WORDS", "")
    if value.strip():
        if "\n" not in value and os.path.isfile(value):
            with open(value, encoding="utf-8") as fh:
                value = fh.read()
    else:
        path = os.path.join(root, LIST_FILE)
        if not os.path.isfile(path):
            return None
        with open(path, encoding="utf-8") as fh:
            value = fh.read()
    words = [w.strip() for w in value.split("\n") if w.strip()]
    return words or None


def git(*args):
    proc = subprocess.run(["git", "-c", "core.quotePath=false", *args], stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE)
    if proc.returncode != 0:
        # git's own message names refs and paths of this repository, never a list entry.
        sys.stderr.write(proc.stderr.decode("utf-8", "replace"))
        print(f"privacy: git {args[0]} failed", file=sys.stderr)
        sys.exit(2)
    return proc.stdout.decode("utf-8", "replace")


def added_lines(base, head):
    """(path, line number, text) for every line the change adds, and the set of paths it touches."""
    out, paths, path, line = [], [], None, 0
    diff = git("diff", "--no-color", "--no-ext-diff", "--no-renames", "-U0", f"{base}...{head}")
    for row in diff.split("\n"):
        if row.startswith("diff --git "):
            path = None
        elif row.startswith("+++ "):
            path = row[6:] if row.startswith("+++ b/") else None
            if path is not None:
                paths.append(path)
        elif row.startswith("--- a/") and path is None:
            # A deleted file: its path is still the change's.
            paths.append(row[6:])
        elif row.startswith("@@"):
            m = re.match(r"@@ -\S+ \+(\d+)", row)
            line = int(m.group(1)) if m else 0
        elif row.startswith("+") and path is not None:
            out.append((path, line, row[1:]))
            line += 1
    return out, list(dict.fromkeys(paths))


def commit_messages(base, head):
    """(short id, message) for every commit in base..head."""
    log = git("log", "--format=%x1e%h%x1f%B", f"{base}..{head}")
    return [tuple(c.split("\x1f", 1)) for c in log.split("\x1e") if "\x1f" in c]


def main():
    parser = argparse.ArgumentParser(description="Check a change for the private words.")
    parser.add_argument("--base", default="origin/main")
    parser.add_argument("--head", default="HEAD")
    opts = parser.parse_args()
    actions = os.environ.get("GITHUB_ACTIONS") == "true"

    root = git("rev-parse", "--show-toplevel").strip()
    words = private_words(root)
    if words is None:
        msg = "no private words (MROOM_PRIVATE_WORDS or .private-words), so the privacy check is skipped"
        print(f"::notice::{msg}" if actions else f"privacy: {msg}")
        return 0

    patterns, bad = [], False
    for n, word in enumerate(words, 1):
        try:
            patterns.append((n, re.compile(word, re.I)))
        except re.error:
            print(f"privacy: entry {n} of the list is not a valid regular expression")
            bad = True
    if bad:
        return 1

    hits = []

    def check(text, where, file=None, line=None):
        for n, pattern in patterns:
            if pattern.search(text):
                hits.append((where, file, line, n))

    lines, paths = added_lines(opts.base, opts.head)
    # A path that matches is never printed: it is named by its place among the change's files.
    shown = {}
    for k, path in enumerate(paths, 1):
        before = len(hits)
        check(path, f"the path of changed file {k}")
        shown[path] = path if len(hits) == before else f"changed file {k}"
    for path, line, text in lines:
        check(text, f"{shown[path]}:{line}", file=shown[path] if shown[path] == path else None, line=line)
    for sha, message in commit_messages(opts.base, opts.head):
        for i, text in enumerate(message.split("\n"), 1):
            check(text, f"commit {sha} message line {i}")
    for name, var in (("PR title", "PR_TITLE"), ("PR body", "PR_BODY")):
        for i, text in enumerate(os.environ.get(var, "").split("\n"), 1):
            check(text, f"{name} line {i}" if name == "PR body" else name)

    for where, file, line, n in hits:
        msg = f"{where}: matches entry {n} of the private list"
        if actions and file:
            print(f"::error file={file},line={line}::{msg}")
        elif actions:
            print(f"::error::{msg}")
        else:
            print(f"privacy: {msg}")
    if hits:
        print(f"privacy: {len(hits)} hit(s); remove each before the change is pushed or merged")
        return 1
    print(f"privacy: no hits ({len(patterns)} entries, {len(lines)} added lines, {len(paths)} files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
