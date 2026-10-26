"""scram.py: prints a Postgres SCRAM-SHA-256 verifier for the password on stdin.

The gate sets each QA role's password as a verifier (D18), so the password itself never reaches the
server, its logs or a command line. The format is Postgres's own: SCRAM-SHA-256$<iterations>:<salt>$<stored
key>:<server key>, each part base64 (RFC 5802, RFC 7677). MROOM_SCRAM_SALT (base64) fixes the salt for tests;
a real run always takes 16 random bytes.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import os
import sys

ITERATIONS = 4096


def verifier(password: str, salt: bytes, iterations: int = ITERATIONS) -> str:
    salted = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iterations)
    client_key = hmac.new(salted, b"Client Key", hashlib.sha256).digest()
    stored_key = hashlib.sha256(client_key).digest()
    server_key = hmac.new(salted, b"Server Key", hashlib.sha256).digest()

    def b64(raw: bytes) -> str:
        return base64.b64encode(raw).decode("ascii")

    return f"SCRAM-SHA-256${iterations}:{b64(salt)}${b64(stored_key)}:{b64(server_key)}"


def main() -> int:
    password = sys.stdin.read()
    if not password or "\n" in password or "\r" in password:
        print("scram.py: give exactly one password on stdin, with no newline", file=sys.stderr)
        return 2
    # Postgres runs a password through SASLprep first, which this does not: for printable ASCII the two
    # agree, so anything else is refused rather than stored as a verifier no sign-in would match.
    if not all(" " < c <= "~" for c in password):
        print("scram.py: the password must be printable ASCII", file=sys.stderr)
        return 2
    fixed = os.environ.get("MROOM_SCRAM_SALT")
    salt = base64.b64decode(fixed, validate=True) if fixed else os.urandom(16)
    print(verifier(password, salt))
    return 0


if __name__ == "__main__":
    sys.exit(main())
