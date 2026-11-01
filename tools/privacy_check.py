#!/usr/bin/env python3
"""privacy_check.py: checks a change for the owner's private words (names of people, projects, hosts and ids
that must never reach this public repository).

    tools/privacy_check.py [--base <ref>] [--head <ref>]

It runs in a git repository (a bare one too) and reads, for <base>...<head>:
  - every path the change adds or changes (empty files too; a deleted path is not the change's text);
  - every line the change adds, as text whatever the repository's attributes say, NUL bytes dropped;
  - each commit in <base>..<head>: its author and committer ("name <email>") and its message;
  - $PR_TITLE, $PR_BODY and $PR_HEAD_REF when set (else the checked-out branch's name).
--base defaults to origin/main and --head to HEAD. A hit names the place (file and line, a commit's author,
committer or message line, the title, a body line, the branch name) and the entry's number, never the word,
the line or a path that matches. With GITHUB_ACTIONS=true it is an ::error annotation, every entry is masked
(::add-mask::) before anything else is printed, and the log never says how many entries there are.

The list is one case-insensitive regular expression per line; blank lines are skipped and the entries are
numbered from 1 among the rest. It comes from:
  - $MROOM_PRIVATE_WORDS, the list itself (a one-line value holding a / is refused: it reads like a path);
  - else $MROOM_PRIVATE_WORDS_FILE, the path of a file holding it;
  - else, outside GitHub Actions, .private-words at the top of the working tree (gitignored; never a link).
With no list the check passes with a notice. tests/skills-check.py reads the list through private_words() too.

Exit codes: 0 no hit or no list, 1 a hit or an entry that is not a valid regular expression, 2 a usage or git
error. Python 3.9 or newer, standard library only."""
import argparse, os, re, shutil, subprocess, sys

LIST_FILE = ".private-words"
GIT = shutil.which("git")


class ListError(Exception):
    """The list cannot be read as given. Its message never holds an entry."""


def _entries(text):
    return [w.strip() for w in text.split("\n") if w.strip()] or None


def private_words(root=None, actions=None):
    """The entries of the private list, or None when there is none. Never prints them. root is the working tree
    whose .private-words is the last resort, which GitHub Actions never reads (a pull request could carry one)."""
    if actions is None:
        actions = os.environ.get("GITHUB_ACTIONS") == "true"
    value = os.environ.get("MROOM_PRIVATE_WORDS", "")
    if value.strip():
        if "\n" not in value.strip() and "/" in value:
            raise ListError("MROOM_PRIVATE_WORDS holds one line with a /, which reads like a path: put the list "
                            "itself there, or name its file in MROOM_PRIVATE_WORDS_FILE")
        return _entries(value)
    path = os.environ.get("MROOM_PRIVATE_WORDS_FILE", "")
    if path:
        if not os.path.isfile(path):
            raise ListError("MROOM_PRIVATE_WORDS_FILE names no file")
        with open(path, encoding="utf-8") as fh:
            return _entries(fh.read())
    if actions or not root:
        return None
    path = os.path.join(root, LIST_FILE)
    if os.path.islink(path):
        raise ListError(f"{LIST_FILE} is a link; make it a plain file")
    if not os.path.isfile(path):
        return None
    with open(path, encoding="utf-8") as fh:
        return _entries(fh.read())


def git(*args, ok=(0,)):
    """git's stdout as bytes. The child gets no list in its environment."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("MROOM_PRIVATE_WORDS")}
    proc = subprocess.run([GIT, "-c", "core.quotePath=false", *args], stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, env=env)
    if proc.returncode not in ok:
        # git's own message names refs and paths of this repository, never a list entry.
        sys.stderr.write(proc.stderr.decode("utf-8", "replace"))
        print(f"privacy: git {args[0]} failed", file=sys.stderr)
        sys.exit(2)
    return proc.stdout


def text(raw):
    return raw.replace(b"\0", b"").decode("utf-8", "replace")


DIFF = ["--no-renames", "--no-ext-diff", "--no-textconv", "--text", "--ignore-submodules=none", "--no-relative"]


def changed_paths(base, head):
    """Every path the change adds or changes, as git's own bytes."""
    names = git("diff", "--name-only", "-z", "--diff-filter=d", *DIFF, f"{base}...{head}")
    return [p for p in names.split(b"\0") if p]


def added_lines(base, head, path):
    """(line number, text) for every line the change adds to path."""
    raw = git("diff", "--no-color", "-U0", "--src-prefix=a/", "--dst-prefix=b/", *DIFF, f"{base}...{head}",
              "--", b":(top,literal)" + path)
    out, in_hunk, line = [], False, 0
    for row in raw.split(b"\n"):
        if row.startswith(b"diff --git "):
            in_hunk = False
        elif row.startswith(b"@@"):
            m = re.match(rb"@@ -\S+ \+(\d+)", row)
            line, in_hunk = (int(m.group(1)) if m else 0), True
        elif in_hunk and row.startswith(b"+"):
            out.append((line, text(row[1:])))
            line += 1
    return out


def commits(base, head):
    """(short id, author, committer, message) for every commit in base..head."""
    out = []
    for sha in git("rev-list", f"{base}..{head}").split():
        raw = git("show", "-s", "--no-show-signature", "--no-mailmap", "--no-notes",
                  "--format=%h%x00%an <%ae>%x00%cn <%ce>%x00%B", sha.decode())
        short, author, committer, message = raw.split(b"\0", 3)
        out.append((text(short), text(author), text(committer), text(message)))
    return out


def escape_data(s):
    return s.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def escape_property(s):
    return escape_data(s).replace(":", "%3A").replace(",", "%2C")


def main():
    parser = argparse.ArgumentParser(description="Check a change for the private words.")
    parser.add_argument("--base", default="origin/main")
    parser.add_argument("--head", default="HEAD")
    opts = parser.parse_args()
    actions = os.environ.get("GITHUB_ACTIONS") == "true"
    if not GIT:
        print("privacy: no git on PATH", file=sys.stderr)
        return 2

    root = None
    if not actions:
        root = text(git("rev-parse", "--show-toplevel", ok=(0, 128))).strip() or None
    try:
        words = private_words(root, actions)
    except ListError as e:
        print(f"privacy: {e}", file=sys.stderr)
        return 2
    if words is None:
        msg = "no private words, so the privacy check is skipped"
        print(f"::notice::{msg}" if actions else f"privacy: {msg}")
        return 0
    if actions:
        for word in words:
            print(f"::add-mask::{escape_data(word)}")

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

    def check(s, where, file=None, line=None):
        for n, pattern in patterns:
            if pattern.search(s):
                hits.append((where, file, line, n))

    paths = changed_paths(opts.base, opts.head)
    added = 0
    for k, raw in enumerate(paths, 1):
        path = text(raw)
        before = len(hits)
        check(path, f"the path of changed file {k}")
        # A path that matches is never printed: it is named by its place among the change's files.
        shown = path if len(hits) == before else f"changed file {k}"
        for line, s in added_lines(opts.base, opts.head, raw):
            added += 1
            check(s, f"{shown}:{line}", file=shown if shown == path else None, line=line)
    for short, author, committer, message in commits(opts.base, opts.head):
        check(author, f"commit {short} author")
        check(committer, f"commit {short} committer")
        for i, s in enumerate(message.split("\n"), 1):
            check(s, f"commit {short} message line {i}")
    for name, var in (("PR title", "PR_TITLE"), ("PR body", "PR_BODY")):
        for i, s in enumerate(os.environ.get(var, "").split("\n"), 1):
            check(s, f"{name} line {i}" if name == "PR body" else name)
    branch = os.environ.get("PR_HEAD_REF")
    if branch is None and not actions:
        branch = text(git("symbolic-ref", "--short", "-q", "HEAD", ok=(0, 1))).strip()
    check(branch or "", "the branch name")

    for where, file, line, n in hits:
        msg = f"{where}: matches entry {n} of the private list"
        if actions and file:
            print(f"::error file={escape_property(file)},line={line}::{escape_data(msg)}")
        elif actions:
            print(f"::error::{escape_data(msg)}")
        else:
            print(f"privacy: {msg}")
    if hits:
        print(f"privacy: {len(hits)} hit(s); remove each before the change is pushed or merged")
        return 1
    if actions:
        print("privacy: no hits")
    else:
        print(f"privacy: no hits ({len(patterns)} entries, {added} added lines, {len(paths)} files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
