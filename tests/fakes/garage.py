#!/usr/bin/env python3
"""A stand-in for Garage's admin and S3 APIs, for the offline tests (tests/garage-test.sh, baseline-test.sh).

    garage.py <admin socket> <s3 socket> <admin token file> <log>

Serves both APIs on Unix sockets, as mroom's Garage does, from one in-memory state: buckets, keys and their
permissions, website access, objects and a one-node layout. The admin API wants the token as a Bearer
login; the S3 API wants a valid Signature Version 4 from a key allowed on the bucket. As Garage does, it
reads the key from the path after dropping the slashes it starts with, takes a DELETE of no key for one of
the bucket (which only an owner may do), and checks a signature against the path decoded and encoded again
with each / kept. Every request is logged (method, path, and whether its login was good), never a token or
a secret.

Test controls, on the admin socket with the token: POST /test/seed {"bucket", "keys": [...]} puts objects;
GET /test/state prints the state, secrets left out; POST /test/fail {"s3_delete": true} makes S3 deletes fail.
"""

import datetime
import hashlib
import hmac
import json
import os
import secrets
import socket
import socketserver
import sys
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler

ADMIN_SOCK, S3_SOCK, TOKEN_FILE, LOG = sys.argv[1:5]
lock = threading.Lock()
state = {"buckets": {}, "keys": {}, "layout": {"version": 0, "roles": []}, "staged": [], "fail": {}}
NODE = "a1" * 32


def log(line):
    with open(LOG, "a") as f:
        f.write(line + "\n")


def token():
    with open(TOKEN_FILE) as f:
        return f.read().strip()


def bucket_info(bid):
    b = state["buckets"][bid]
    return {"id": bid, "globalAliases": [b["alias"]], "websiteAccess": b["website"], "objects": len(b["objects"])}


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def address_string(self):
        return "unix"

    def reply(self, status, body=b"", content_type="application/json"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""


class Admin(Handler):
    def handle_any(self):
        good = self.headers.get("Authorization", "") == f"Bearer {token()}"
        url = urllib.parse.urlsplit(self.path)
        query = dict(urllib.parse.parse_qsl(url.query))
        log(f"admin {self.command} {url.path} login={'good' if good else 'bad'}")
        if not good:
            return self.reply(403, {"code": "Forbidden", "message": "Forbidden"})
        raw = self.body()
        data = json.loads(raw) if raw else {}
        with lock:
            return self.route(url.path, query, data)

    do_GET = do_POST = handle_any

    def route(self, path, query, data):
        buckets, keys = state["buckets"], state["keys"]
        if path == "/v2/GetBucketInfo":
            for bid, b in buckets.items():
                if b["alias"] == query.get("globalAlias") or bid == query.get("id"):
                    return self.reply(200, bucket_info(bid))
            return self.reply(404, {"code": "NoSuchBucket", "message": "Bucket not found"})
        if path == "/v2/CreateBucket":
            alias = data["globalAlias"]
            if any(b["alias"] == alias for b in buckets.values()):
                return self.reply(409, {"code": "BucketAlreadyExists", "message": "Bucket already exists"})
            bid = secrets.token_hex(32)
            buckets[bid] = {"alias": alias, "website": False, "objects": {}}
            return self.reply(200, bucket_info(bid))
        if path == "/v2/ListBuckets":
            return self.reply(200, [{"id": bid, "created": "2026-10-26T00:00:00Z", "globalAliases": [b["alias"]],
                                     "localAliases": []} for bid, b in buckets.items()])
        if path == "/v2/ListKeys":
            return self.reply(200, [{"id": k, "name": v["name"], "expired": False} for k, v in keys.items()])
        if path == "/v2/CreateKey":
            kid = "GK" + secrets.token_hex(12)
            keys[kid] = {"name": data.get("name", ""), "secret": secrets.token_hex(32), "perms": {}}
            return self.reply(200, {"accessKeyId": kid, "secretAccessKey": keys[kid]["secret"], "name": keys[kid]["name"]})
        if path == "/v2/AllowBucketKey":
            if data["accessKeyId"] not in keys or data["bucketId"] not in buckets:
                return self.reply(404, {"code": "NoSuchKey", "message": "no such key or bucket"})
            keys[data["accessKeyId"]]["perms"][data["bucketId"]] = data["permissions"]
            return self.reply(200, bucket_info(data["bucketId"]))
        if path == "/v2/DeleteKey":
            if keys.pop(query.get("id", ""), None) is None:
                return self.reply(404, {"code": "NoSuchKey", "message": "Key not found"})
            return self.reply(200, b"")
        if path == "/v2/UpdateBucket":
            if query.get("id") not in buckets:
                return self.reply(404, {"code": "NoSuchBucket", "message": "Bucket not found"})
            buckets[query["id"]]["website"] = bool(data["websiteAccess"]["enabled"])
            return self.reply(200, bucket_info(query["id"]))
        if path == "/v2/CleanupIncompleteUploads":
            return self.reply(200, {"uploadsDeleted": 0})
        if path == "/v2/DeleteBucket":
            b = buckets.get(query.get("id", ""))
            if b is None:
                return self.reply(404, {"code": "NoSuchBucket", "message": "Bucket not found"})
            if b["objects"]:
                return self.reply(409, {"code": "BucketNotEmpty", "message": "Bucket is not empty"})
            del buckets[query["id"]]
            for k in keys.values():
                k["perms"].pop(query["id"], None)
            return self.reply(200, b"")
        if path == "/v2/GetClusterStatus":
            return self.reply(200, {"layoutVersion": state["layout"]["version"], "nodes": [{"id": NODE, "isUp": True}]})
        if path == "/v2/GetClusterLayout":
            return self.reply(200, {**state["layout"], "stagedRoleChanges": state["staged"]})
        if path == "/v2/UpdateClusterLayout":
            state["staged"] = data.get("roles", [])
            return self.reply(200, {**state["layout"], "stagedRoleChanges": state["staged"]})
        if path == "/v2/ApplyClusterLayout":
            if data.get("version") != state["layout"]["version"] + 1:
                return self.reply(400, {"code": "InvalidRequest", "message": "wrong layout version"})
            state["layout"] = {"version": data["version"], "roles": state["staged"]}
            state["staged"] = []
            return self.reply(200, {"message": ["applied"]})
        if path == "/test/seed":
            bid = next(i for i, b in buckets.items() if b["alias"] == data["bucket"])
            for key in data["keys"]:
                buckets[bid]["objects"][key] = b"x"
            return self.reply(200, b"")
        if path == "/test/state":
            return self.reply(200, {
                "buckets": {b["alias"]: {"website": b["website"], "objects": sorted(b["objects"])} for b in buckets.values()},
                "keys": {k: {"name": v["name"], "buckets": {buckets[b]["alias"]: p for b, p in v["perms"].items() if b in buckets}}
                         for k, v in keys.items()},
                "layout": state["layout"]})
        if path == "/test/fail":
            state["fail"] = data
            return self.reply(200, b"")
        return self.reply(404, {"code": "NotFound", "message": f"no endpoint {path}"})


def signature_ok(handler, url, secret):
    """Checks a Signature Version 4 header the way Garage reads one: over the request as it came."""
    auth = handler.headers.get("Authorization", "")
    try:
        cred = auth.split("Credential=")[1].split(",")[0]
        signed = auth.split("SignedHeaders=")[1].split(",")[0].strip()
        given = auth.split("Signature=")[1].strip()
        _, day, region, service, _ = cred.split("/")
    except (IndexError, ValueError):
        return False
    headers = "".join(f"{h}:{handler.headers.get(h, '').strip()}\n" for h in signed.split(";"))
    query = "&".join(f"{urllib.parse.quote(k, safe='-_.~')}={urllib.parse.quote(v, safe='-_.~')}"
                     for k, v in sorted(urllib.parse.parse_qsl(url.query, keep_blank_values=True)))
    path = urllib.parse.quote(urllib.parse.unquote(url.path), safe="-_.~/")
    canonical = "\n".join([handler.command, path, query, headers, signed,
                           handler.headers.get("x-amz-content-sha256", "")])
    to_sign = "\n".join(["AWS4-HMAC-SHA256", handler.headers.get("x-amz-date", ""),
                         f"{day}/{region}/{service}/aws4_request", hashlib.sha256(canonical.encode()).hexdigest()])
    key = ("AWS4" + secret).encode()
    for part in (day, region, service, "aws4_request"):
        key = hmac.new(key, part.encode(), hashlib.sha256).digest()
    return hmac.compare_digest(hmac.new(key, to_sign.encode(), hashlib.sha256).hexdigest(), given)


class S3(Handler):
    def handle_any(self):
        url = urllib.parse.urlsplit(self.path)
        auth = self.headers.get("Authorization", "")
        kid = auth.split("Credential=")[1].split("/")[0] if "Credential=" in auth else ""
        with lock:
            key = state["keys"].get(kid)
            good = key is not None and signature_ok(self, url, key["secret"])
            log(f"s3 {self.command} {url.path} login={'good' if good else 'bad'}")
            if not good:
                return self.reply(403, b"<Error><Code>AccessDenied</Code></Error>", "application/xml")
            name, _, raw_key = url.path.lstrip("/").partition("/")
            key_name = urllib.parse.unquote(raw_key.lstrip("/"))
            bid = next((i for i, b in state["buckets"].items() if b["alias"] == name), None)
            perm = key["perms"].get(bid, {})
            if bid is None:
                return self.reply(404, b"<Error><Code>NoSuchBucket</Code></Error>", "application/xml")
            objects = state["buckets"][bid]["objects"]
            if self.command == "GET" and not key_name:
                if not perm.get("read"):
                    return self.reply(403, b"<Error><Code>AccessDenied</Code></Error>", "application/xml")
                q = dict(urllib.parse.parse_qsl(url.query))
                names = sorted(objects)[: int(q.get("max-keys", "1000"))]
                enc = (lambda k: urllib.parse.quote(k, safe="")) if q.get("encoding-type") == "url" else (lambda k: k)
                contents = "".join(f"<Contents><Key>{enc(k)}</Key></Contents>" for k in names)
                xml = ('<?xml version="1.0" encoding="UTF-8"?><ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
                       f"<Name>{name}</Name>{contents}<IsTruncated>{'true' if len(objects) > len(names) else 'false'}</IsTruncated>"
                       "</ListBucketResult>")
                return self.reply(200, xml.encode(), "application/xml")
            if self.command == "DELETE" and not key_name:
                # DeleteBucket, which only an owner may do.
                return self.reply(403, b"<Error><Code>AccessDenied</Code></Error>", "application/xml")
            if self.command == "DELETE":
                if not perm.get("write") or state["fail"].get("s3_delete"):
                    return self.reply(403 if not perm.get("write") else 500,
                                      b"<Error><Code>InternalError</Code></Error>", "application/xml")
                objects.pop(key_name, None)
                return self.reply(204, b"")
            return self.reply(400, b"<Error><Code>InvalidRequest</Code></Error>", "application/xml")

    do_GET = do_DELETE = do_PUT = handle_any


def serve(path, handler):
    if os.path.exists(path):
        os.unlink(path)
    server = Server(path, handler)
    os.chmod(path, 0o600)
    threading.Thread(target=server.serve_forever, daemon=True).start()


serve(ADMIN_SOCK, Admin)
serve(S3_SOCK, S3)
print("up", flush=True)
threading.Event().wait()
