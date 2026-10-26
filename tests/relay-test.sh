#!/usr/bin/env bash
# shellcheck disable=SC2317  # t_* run through test_case
# Tests for lib/mail-relay, which pipes QA apps' mail to Mailpit (D19): bytes go both ways unchanged, the end
# of one direction reaches the other side, a connection that comes while Mailpit is down is closed and the
# relay stays up, many connections run at once, and it takes the port from systemd, which holds it while
# the relay restarts; each session ends with Mailpit's side, within its time, and only so many run at once. Offline: a Python server on a Unix socket plays
# Mailpit's SMTP side. tests/mail/gate-real-test.sh runs the relay in front of the real Mailpit in CI.
set -euo pipefail
SUITE=relay
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

t_the_relay_pipes_each_connection_to_mailpit() {
  run python3 -I - "$ROOT/lib/mail-relay" "$T/smtp.sock" <<'PY'
import os, socket, subprocess, sys, threading, time

relay_path, sock_path = sys.argv[1], sys.argv[2]


class Mailpit:
    """Plays Mailpit's SMTP side: greets, sends back each chunk in capitals, and says BYE at the end of input."""

    def __init__(self):
        if os.path.exists(sock_path):
            os.unlink(sock_path)
        self.server = socket.socket(socket.AF_UNIX)
        self.server.bind(sock_path)
        self.server.listen(64)
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        while True:
            try:
                conn, _ = self.server.accept()
            except OSError:
                return
            threading.Thread(target=self.talk, args=(conn,), daemon=True).start()

    def talk(self, conn):
        with conn:
            conn.sendall(b"220 hello\r\n")
            while data := conn.recv(65536):
                conn.sendall(data.upper())
            conn.sendall(b"BYE\r\n")

    def stop(self):
        self.server.close()
        os.unlink(sock_path)


def connect(port, attempts=50):
    for _ in range(attempts):
        try:
            return socket.create_connection(("127.0.0.1", port), timeout=5)
        except OSError:
            time.sleep(0.1)
    raise SystemExit("the relay never listened")


def read_all(conn, into):
    while data := conn.recv(65536):
        into.append(data)


probe = socket.socket()
probe.bind(("127.0.0.1", 0))
port = probe.getsockname()[1]
probe.close()
mailpit = Mailpit()
relay = subprocess.Popen([sys.executable, "-I", relay_path, "127.0.0.1", str(port), sock_path])
try:
    conn = connect(port)
    print("greeting:", "ok" if conn.recv(100) == b"220 hello\r\n" else "wrong")
    conn.sendall(b"ehlo qa\r\n")
    print("echo:", "ok" if conn.recv(100) == b"EHLO QA\r\n" else "wrong")
    # A mebibyte each way, read while it is sent, then the end of input passed on to Mailpit.
    got = []
    reader = threading.Thread(target=read_all, args=(conn, got))
    reader.start()
    conn.sendall(b"a" * 1048576)
    conn.shutdown(socket.SHUT_WR)
    reader.join(20)
    print("large and half-close:", "ok" if b"".join(got) == b"A" * 1048576 + b"BYE\r\n" else "wrong")
    conn.close()

    # Mailpit down: the relay closes the connection and stays up; with Mailpit back, it works again.
    mailpit.stop()
    conn = connect(port)
    conn.settimeout(5)
    print("closed while Mailpit is down:", "ok" if conn.recv(100) == b"" else "wrong")
    conn.close()
    print("relay still up:", "ok" if relay.poll() is None else "exited")
    mailpit = Mailpit()
    conn = connect(port)
    print("back with Mailpit:", "ok" if conn.recv(100) == b"220 hello\r\n" else "wrong")
    conn.close()

    # Twenty connections at once, each with its own words.
    results = {}

    def one(n):
        with connect(port) as c:
            c.recv(100)
            c.sendall(b"rcpt %d\r\n" % n)
            results[n] = c.recv(100) == b"RCPT %d\r\n" % n

    threads = [threading.Thread(target=one, args=(n,)) for n in range(20)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(20)
    print("twenty at once:", "ok" if len(results) == 20 and all(results.values()) else "wrong")
finally:
    relay.terminate()
    relay.wait(10)
PY
  expect_rc 0
  local check
  for check in greeting echo "large and half-close" "closed while Mailpit is down" "relay still up" \
    "back with Mailpit" "twenty at once"; do
    expect_out_has "$check: ok"
  done
}

t_the_relay_takes_systemds_socket_and_bounds_each_connection() {
  run python3 -I - "$ROOT/lib/mail-relay" "$T/smtp.sock" <<'PY'
import errno, os, socket, subprocess, sys, threading, time

relay_path, sock_path = sys.argv[1], sys.argv[2]
mode = {"close": False}


class Mailpit:
    """Greets, then sends back what it reads, or closes at once while mode["close"] is set."""

    def __init__(self):
        if os.path.exists(sock_path):
            os.unlink(sock_path)
        self.server = socket.socket(socket.AF_UNIX)
        self.server.bind(sock_path)
        self.server.listen(64)
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        while True:
            try:
                conn, _ = self.server.accept()
            except OSError:
                return
            threading.Thread(target=self.talk, args=(conn,), daemon=True).start()

    def talk(self, conn):
        with conn:
            conn.sendall(b"220 hello\r\n")
            if mode["close"]:
                return
            while data := conn.recv(65536):
                conn.sendall(data)


def free_port():
    probe = socket.socket()
    probe.bind(("127.0.0.1", 0))
    port = probe.getsockname()[1]
    probe.close()
    return port


def handed_over(listener, port, env=None):
    """The relay started the way systemd starts it: the listening socket as fd 3, LISTEN_PID its own pid."""
    script = 'exec 3<&0 0</dev/null; LISTEN_PID=$$ LISTEN_FDS=1 exec "$0" -I "$1" 127.0.0.1 "$2" "$3"'
    return subprocess.Popen(["sh", "-c", script, sys.executable, relay_path, str(port), sock_path],
                            stdin=listener.fileno(), stderr=subprocess.PIPE, env={**os.environ, **(env or {})})


def greeting(port, timeout=5):
    with socket.create_connection(("127.0.0.1", port), timeout=timeout) as c:
        return c.recv(100)


def taken(port):
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("127.0.0.1", port))
        return False
    except OSError as e:
        return e.errno == errno.EADDRINUSE
    finally:
        s.close()


def wait_closed(conn, seconds):
    conn.settimeout(seconds)
    try:
        return conn.recv(100) == b""
    except socket.timeout:
        return False


Mailpit()
port = free_port()
listener = socket.create_server(("127.0.0.1", port))
relay = handed_over(listener, port)
time.sleep(0.5)
print("systemd's socket:", "ok" if greeting(port) == b"220 hello\r\n" else "wrong")
# The relay restarts while systemd holds the port: no one else can take it, and a connection that comes
# meanwhile waits and is served by the next relay.
relay.terminate()
relay.wait(10)
print("held while the relay is down:", "ok" if taken(port) else "free")
waiting = socket.create_connection(("127.0.0.1", port), timeout=5)
relay = handed_over(listener, port)
print("served by the next relay:", "ok" if waiting.recv(100) == b"220 hello\r\n" else "wrong")
waiting.close()
relay.terminate()
relay.wait(10)

# A socket on another port than the relay was told: refused.
other = socket.create_server(("127.0.0.1", free_port()))
wrong = handed_over(other, port)
_, err = wrong.communicate(timeout=10)
print("a socket on another port:", "ok" if wrong.returncode != 0 and b"not listening on 127.0.0.1:" in err else f"wrong ({wrong.returncode}, {err!r})")
other.close()

# Without systemd, a taken port stops the relay instead of leaving it waiting.
busy = subprocess.run([sys.executable, "-I", relay_path, "127.0.0.1", str(port), sock_path],
                      capture_output=True, timeout=10)
print("a taken port:", "ok" if busy.returncode != 0 and b"cannot listen on 127.0.0.1:" in busy.stderr else f"wrong ({busy.returncode})")

# At most two at once (the third is closed before any greeting), and a session ends when Mailpit's side
# does, which frees its place even though the client never closes.
relay = handed_over(listener, port, {"MAIL_RELAY_MAX_CONNECTIONS": "2", "MAIL_RELAY_MAX_SECONDS": "3"})
time.sleep(0.5)
a = socket.create_connection(("127.0.0.1", port), timeout=5)
b = socket.create_connection(("127.0.0.1", port), timeout=5)
a.recv(100)
b.recv(100)
third = socket.create_connection(("127.0.0.1", port), timeout=5)
print("a third at once is closed:", "ok" if wait_closed(third, 3) else "served")
third.close()
a.close()
b.close()
time.sleep(0.3)
mode["close"] = True
held = [socket.create_connection(("127.0.0.1", port), timeout=5) for _ in range(2)]
for h in held:
    h.recv(100)
time.sleep(0.5)
print("ended with Mailpit's side:", "ok" if greeting(port) == b"220 hello\r\n" else "still held")
mode["close"] = False
long = socket.create_connection(("127.0.0.1", port), timeout=5)
long.recv(100)
print("closed after its time:", "ok" if wait_closed(long, 6) else "still open")
relay.terminate()
relay.wait(10)
PY
  expect_rc 0
  local check
  for check in "systemd's socket" "held while the relay is down" "served by the next relay" \
    "a socket on another port" "a taken port" "a third at once is closed" "ended with Mailpit's side" \
    "closed after its time"; do
    expect_out_has "$check: ok"
  done
}

t_the_relay_takes_three_arguments() {
  run python3 -I "$ROOT/lib/mail-relay"
  expect_rc 2; expect_err_has "usage: mail-relay <host> <port> <socket>"
  run python3 -I "$ROOT/lib/mail-relay" 127.0.0.1 smtp "$T/smtp.sock"
  expect_rc 2; expect_err_has "usage: mail-relay"
}

test_case pipes t_the_relay_pipes_each_connection_to_mailpit
test_case systemd t_the_relay_takes_systemds_socket_and_bounds_each_connection
test_case usage t_the_relay_takes_three_arguments
finish
