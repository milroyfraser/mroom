"""A Pusher-protocol client for tests/reverb/gate-real-test.sh, from Python's standard library alone.

  client.py open   <where> <key> <origin>                        prints the first message the host sends, then
                                                                 "closed" if the host closes the socket within
                                                                 two seconds, or "open"
  client.py listen <where> <key> <origin> <channel> <seconds>    subscribes, prints "ready", then the first event
                                                                 that arrives, as "event <name> <data>"
  client.py whisper <where> <key> <origin> <channel> <event> <data> [<go file>]
                                                                 subscribes, then sends a client event; prints
                                                                 "sent", or the error the host answers with.
                                                                 With a go file, it prints "ready" once
                                                                 subscribed, and sends once the file exists
  client.py send   <where> <app id> <key> <secret> <channel> <event> <data>
                                                                 sends the event through Reverb's HTTP API,
                                                                 signed with the secret; prints the HTTP status

<where> is unix:<path> for the host's own socket, or <host>:<port> for nginx in front of it.
"""
import base64
import hashlib
import hmac
import http.client
import json
import os
import socket
import struct
import sys
import time

HOST = "ws.qa.example.test"


def connect(where):
    if where.startswith("unix:"):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(where[len("unix:"):])
    else:
        host, port = where.rsplit(":", 1)
        sock = socket.create_connection((host, int(port)))
    sock.settimeout(10)
    return sock


def read_exactly(sock, n):
    data = b""
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            raise EOFError("the host closed the socket")
        data += chunk
    return data


def handshake(sock, key, origin):
    nonce = base64.b64encode(os.urandom(16)).decode()
    sock.sendall((f"GET /app/{key}?protocol=7&client=mroom-test&version=1.0 HTTP/1.1\r\n"
                  f"Host: {HOST}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                  f"Sec-WebSocket-Key: {nonce}\r\nSec-WebSocket-Version: 13\r\nOrigin: {origin}\r\n\r\n").encode())
    head = b""
    while b"\r\n\r\n" not in head:
        chunk = sock.recv(1)
        if not chunk:
            raise EOFError("the host closed the socket before the handshake ended")
        head += chunk
    status = head.split(b"\r\n", 1)[0].decode()
    if " 101 " not in status:
        raise RuntimeError(f"no WebSocket: {status}")


def send_text(sock, text):
    payload, mask = text.encode(), os.urandom(4)
    if len(payload) < 126:
        header = struct.pack("!BB", 0x81, 0x80 | len(payload))
    else:
        header = struct.pack("!BBH", 0x81, 0x80 | 126, len(payload))
    sock.sendall(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))


def recv_text(sock):
    """The next text message, answering pings on the way; None once the host closes the socket."""
    while True:
        first, second = read_exactly(sock, 2)
        opcode, length = first & 0x0F, second & 0x7F
        if length == 126:
            length = struct.unpack("!H", read_exactly(sock, 2))[0]
        elif length == 127:
            length = struct.unpack("!Q", read_exactly(sock, 8))[0]
        payload = read_exactly(sock, length)
        if opcode == 0x8:
            return None
        if opcode == 0x9:
            mask = os.urandom(4)
            sock.sendall(struct.pack("!BB", 0x8A, 0x80 | len(payload)) + mask
                         + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))
            continue
        if opcode == 0x1:
            return payload.decode()


def cmd_open(where, key, origin):
    sock = connect(where)
    handshake(sock, key, origin)
    print(recv_text(sock))
    # Whether the host keeps the socket: it closes one it refuses at once.
    sock.settimeout(2)
    try:
        while recv_text(sock) is not None:
            pass
        print("closed")
    except (EOFError, ConnectionError):
        print("closed")
    except socket.timeout:
        print("open")


def subscribed(sock, key, origin, channel):
    """Connects and subscribes; None once subscribed, else the message the host answered with."""
    handshake(sock, key, origin)
    first = json.loads(recv_text(sock) or "{}")
    if first.get("event") != "pusher:connection_established":
        return first
    send_text(sock, json.dumps({"event": "pusher:subscribe", "data": {"channel": channel}}))
    while True:
        message = json.loads(recv_text(sock) or '{"event": "closed"}')
        if message.get("event") == "pusher_internal:subscription_succeeded":
            return None
        if message.get("event") in ("pusher:error", "closed"):
            return message


def cmd_whisper(where, key, origin, channel, event, data, go=None):
    sock = connect(where)
    refused = subscribed(sock, key, origin, channel)
    if refused is not None:
        print(json.dumps(refused))
        return 1
    if go:
        # The test serves another app here, between this socket's subscribe and its event.
        print("ready", flush=True)
        deadline = time.monotonic() + 15
        while not os.path.exists(go):
            if time.monotonic() > deadline:
                print("no go")
                return 1
            time.sleep(0.05)
    send_text(sock, json.dumps({"event": event, "channel": channel, "data": json.loads(data)}))
    # A refusal comes back at once; silence means the host took the event.
    sock.settimeout(2)
    try:
        text = recv_text(sock)
        print(text if text is not None else "closed")
        return 1
    except socket.timeout:
        print("sent")
        return 0


def cmd_listen(where, key, origin, channel, seconds):
    sock = connect(where)
    handshake(sock, key, origin)
    first = json.loads(recv_text(sock) or "{}")
    if first.get("event") != "pusher:connection_established":
        print(json.dumps(first))
        return 1
    send_text(sock, json.dumps({"event": "pusher:subscribe", "data": {"channel": channel}}))
    deadline = time.monotonic() + float(seconds)
    while time.monotonic() < deadline:
        text = recv_text(sock)
        if text is None:
            print("closed")
            return 1
        message = json.loads(text)
        name = message.get("event", "")
        if name == "pusher_internal:subscription_succeeded":
            print("ready", flush=True)
        elif name == "pusher:ping":
            send_text(sock, json.dumps({"event": "pusher:pong", "data": {}}))
        elif not name.startswith("pusher"):
            # A server's event carries its data as a string, a client's as an object.
            data = message.get("data")
            text = data if isinstance(data, str) else json.dumps(data, separators=(",", ":"))
            print(f"event {name} {text}", flush=True)
            return 0
    print("no event")
    return 1


class UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__("localhost", timeout=10)
        self.unix_path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(10)
        self.sock.connect(self.unix_path)


def cmd_send(where, app_id, key, secret, channel, event, data):
    body = json.dumps({"name": event, "channels": [channel], "data": data}).encode()
    path = f"/apps/{app_id}/events"
    params = {"auth_key": key, "auth_timestamp": str(int(time.time())), "auth_version": "1.0",
              "body_md5": hashlib.md5(body).hexdigest()}
    query = "&".join(f"{k}={params[k]}" for k in sorted(params))
    signature = hmac.new(secret.encode(), f"POST\n{path}\n{query}".encode(), hashlib.sha256).hexdigest()
    if where.startswith("unix:"):
        conn = UnixHTTPConnection(where[len("unix:"):])
    else:
        host, port = where.rsplit(":", 1)
        conn = http.client.HTTPConnection(host, int(port), timeout=10)
    conn.request("POST", f"{path}?{query}&auth_signature={signature}", body=body,
                 headers={"Host": HOST, "Content-Type": "application/json"})
    print(conn.getresponse().status)


def main(argv):
    command, args = argv[1], argv[2:]
    if command == "open" and len(args) == 3:
        return cmd_open(*args) or 0
    if command == "listen" and len(args) == 5:
        return cmd_listen(*args)
    if command == "send" and len(args) == 7:
        return cmd_send(*args) or 0
    if command == "whisper" and len(args) in (6, 7):
        return cmd_whisper(*args)
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
