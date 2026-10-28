#!/usr/bin/env python3
"""text.py: what the persona does to text before it leaves (alert triage, lib/persona). stdin to stdout.

    text.py redact          anything shaped like a token or key becomes [redacted token]; an email
                            address, a phone number or an IBAN becomes [redacted]. Ids, keys, dates,
                            versions and links stay readable.
    text.py no-token        exits 1, printing nothing, when the text holds something shaped like a token
                            or key; 0 when it does not
    text.py defang <host>...
                            each link to a host that is not one of these, or a subdomain of one, becomes
                            hxxps://host[.]example, so text an alert carried cannot become a live link

Alert text is untrusted (design 8.4): an error's message, a URL or a user's name can carry a token or a
person's data, and a link the reader would follow. Run with python3 -I. Reads at most 1 MiB.
"""

import re
import sys

MAX = 1 << 20

# The shape of a token or key: a tracker's, a chat bot's, Claude's, GitHub's, an error tracker's, a private
# key, a cloud key, a payment provider's live or webhook key, a JSON web token.
TOKEN = re.compile(
    r"lin_(?:api|oauth)_[A-Za-z0-9]{16,}"
    r"|xox[abposre]-[A-Za-z0-9-]{8,}"
    r"|sk-ant-[A-Za-z0-9_-]{8,}"
    r"|gh[pousr]_[A-Za-z0-9]{20,}"
    r"|github_pat_[A-Za-z0-9_]{20,}"
    r"|sntry[su]?_[A-Za-z0-9+/=_-]{20,}"
    r"|-----BEGIN [A-Z ]*PRIVATE KEY"
    r"|AKIA[0-9A-Z]{16}"
    r"|(?:sk|rk)_live_[A-Za-z0-9]{8,}"
    r"|whsec_[A-Za-z0-9]{8,}"
    r"|eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}"
)
IBAN = re.compile(r"\b[A-Z]{2}[0-9]{2}(?:[ ]?[A-Z0-9]{4}){2,7}(?:[ ]?[A-Z0-9]{1,3})?\b")
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}")
# A phone number starts with + (international) or 0 (national), so run ids, error ids, dates and times stay.
PHONE_INTL = re.compile(r"(?<![\w+])\+[1-9][0-9]{0,2}(?:[ .-]?\(?[0-9]{1,4}\)?){2,5}[0-9]\b")
PHONE_NATIONAL = re.compile(r"(?<![\w.:/-])0[1-9][0-9]?(?:[ -]?[0-9]){7,8}\b")
LINK = re.compile(r"\b(https?)://([^/\s<>()|`\"'\]\[]+)")
HOST = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+")


def redact(text: str) -> str:
    text = TOKEN.sub("[redacted token]", text)
    text = IBAN.sub("[redacted]", text)
    text = EMAIL.sub("[redacted]", text)
    text = PHONE_INTL.sub("[redacted]", text)
    return PHONE_NATIONAL.sub("[redacted]", text)


def defang(text: str, hosts: list[str]) -> str:
    def allowed(host: str) -> bool:
        bare = host.lower().rsplit("@", 1)[-1]
        bare = re.sub(r":[0-9]+$", "", bare)
        return any(bare == h or bare.endswith("." + h) for h in hosts)

    def one(match: re.Match) -> str:
        scheme, host = match.group(1), match.group(2)
        if allowed(host):
            return match.group(0)
        return scheme.replace("t", "x") + "://" + host.replace(".", "[.]")

    return LINK.sub(one, text)


def main(argv: list[str]) -> int:
    if not argv or argv[0] not in ("redact", "no-token", "defang"):
        print("usage: text.py redact | no-token | defang <host>...", file=sys.stderr)
        return 2
    data = sys.stdin.buffer.read(MAX + 1)
    if len(data) > MAX:
        print("text.py: the text is longer than 1 MiB", file=sys.stderr)
        return 2
    text = data.decode("utf-8", errors="replace")
    if argv[0] == "no-token":
        return 1 if TOKEN.search(text) else 0
    if argv[0] == "redact":
        sys.stdout.write(redact(text))
        return 0
    hosts = [h.lower() for h in argv[1:]]
    for h in hosts:
        if not HOST.fullmatch(h):
            print(f"text.py: not a host name: {h[:80]}", file=sys.stderr)
            return 2
    sys.stdout.write(defang(text, hosts))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
