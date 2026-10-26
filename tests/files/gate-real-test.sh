#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2016  # t_* run through test_case; a $ in single quotes is for eval, later
# The gate's Garage operations against the real Garage, run the way a box runs it: what a fake cannot show.
# mroom baseline garage downloads the pinned build and checks its SHA-256, its unit is installed by running,
# as root, the very script it prints, from a home under /home as on a box, and baseline sets up its layout.
# The test then checks:
# - each environment's key reaches its own bucket and no other;
# - a public disk's files are served on its website endpoint, a private one's are not;
# - through an nginx made from the configs baseline prints, S3 signatures still hold and the files host
#   finds the bucket in the path;
# - Forge's own location blocks take no path from them, a Host signed with its port holds, an unsigned
#   upload is refused before nginx keeps any of it, and a website redirect keeps its bucket;
# - a new key replaces the old one, and the files stay;
# - bucket-drop empties and deletes every bucket and key of the environment, keys that start with a slash
#   too, and no other environment's;
# - Garage keeps its data when systemd starts it again.
# CI only: it downloads Garage and installs a systemd unit as root, replacing a box's own, so it refuses to
# run anywhere but GitHub Actions, and tests/run.sh does not pick it up.
set -euo pipefail
if [ "${GITHUB_ACTIONS:-}" != true ]; then
  echo "tests/files/gate-real-test.sh: CI only; it would replace this machine's mroom systemd units" >&2
  exit 2
fi
SUITE=files-real
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

CI_HOME=""
cleanup() {
  local f
  for f in "$TOP"/*/nginx/nginx.pid; do if [ -s "$f" ]; then kill "$(cat "$f")" 2>/dev/null || true; fi; done
  sudo systemctl disable --now mroom-garage.service >/dev/null 2>&1 || true
  sudo rm -f /etc/systemd/system/mroom-garage.service
  sudo systemctl daemon-reload || true
  [ -z "$CI_HOME" ] || rm -rf "$CI_HOME"
  rm -rf "$TOP"
}
trap cleanup EXIT

gate() { run env SSH_ORIGINAL_COMMAND="$1" "$MROOM" gate provision; }
field() { sed -n "s/^$1=//p" <<<"$2"; }
root_script_of() { sed -n '/^----- run as root -----$/,/^----- end -----$/p' <<<"$1" | sed '1d;$d'; }
garage_run() { echo "$HOME/.local/share/mroom-services/garage/run"; }

# s3 <key output> <unix|host:port> <Host> <method> <path> [<body>]: one signed S3 request, with the key
# bucket-create printed; prints the HTTP status, then the body. The path is sent as given and signed as
# Garage checks it: decoded, then encoded again with each / kept.
s3() {
  S3_KEY="$(field ACCESS_KEY_ID "$1")" S3_SECRET="$(field SECRET_ACCESS_KEY "$1")" python3 -I - "${@:2}" <<'PY'
import datetime, hashlib, hmac, http.client, os, socket, sys, urllib.parse
where, host, method, target = sys.argv[1:5]
body = sys.argv[5].encode() if len(sys.argv) > 5 else b""
key_id, secret = os.environ["S3_KEY"], os.environ["S3_SECRET"]
path, _, query = target.partition("?")
pairs = sorted(urllib.parse.parse_qsl(query, keep_blank_values=True))
q = lambda s: urllib.parse.quote(s, safe="-_.~")
canonical_query = "&".join(f"{q(k)}={q(v)}" for k, v in pairs)
now = datetime.datetime.now(datetime.timezone.utc)
stamp, day = now.strftime("%Y%m%dT%H%M%SZ"), now.strftime("%Y%m%d")
digest = hashlib.sha256(body).hexdigest()
headers = {"host": host, "x-amz-content-sha256": digest, "x-amz-date": stamp}
signed = ";".join(sorted(headers))
canonical = "\n".join([method, urllib.parse.quote(urllib.parse.unquote(path), safe="-_.~/"), canonical_query, "".join(f"{k}:{headers[k]}\n" for k in sorted(headers)), signed, digest])
scope = f"{day}/garage/s3/aws4_request"
to_sign = "\n".join(["AWS4-HMAC-SHA256", stamp, scope, hashlib.sha256(canonical.encode()).hexdigest()])
k = ("AWS4" + secret).encode()
for part in (day, "garage", "s3", "aws4_request"):
    k = hmac.new(k, part.encode(), hashlib.sha256).digest()
headers["authorization"] = (f"AWS4-HMAC-SHA256 Credential={key_id}/{scope}, SignedHeaders={signed}, "
                            f"Signature={hmac.new(k, to_sign.encode(), hashlib.sha256).hexdigest()}")
if where.startswith("/"):
    class Unix(http.client.HTTPConnection):
        def connect(self):
            self.sock = socket.socket(socket.AF_UNIX)
            self.sock.connect(where)
    conn = Unix("localhost", timeout=30)
else:
    h, p = where.rsplit(":", 1)
    conn = http.client.HTTPConnection(h, int(p), timeout=30)
conn.request(method, path + (f"?{canonical_query}" if canonical_query else ""), body=body, headers=headers)
r = conn.getresponse()
print(r.status)
sys.stdout.write(r.read().decode(errors="replace"))
PY
}
status_of() { head -n1 <<<"$1"; }
body_of() { tail -n +2 <<<"$1"; }
# web <socket|host:port> <Host> <path>: a plain GET; prints the HTTP status, then the body.
web() {
  local code
  if [[ "$1" == /* ]]; then
    code="$(curl -q -s --max-time 10 --unix-socket "$1" -H "Host: $2" -o "$T/web.body" -w '%{http_code}' "http://localhost$3")"
  else
    code="$(curl -q -s --max-time 10 -H "Host: $2" -o "$T/web.body" -w '%{http_code}' "http://$1$3")"
  fi
  printf '%s\n%s' "$code" "$(cat "$T/web.body")"
}

wait_ready() {
  for _ in $(seq 1 80); do
    if [ "$(systemctl is-active mroom-garage.service 2>/dev/null)" = active ] && [ -S "$(garage_run)/admin.sock" ] \
      && curl -q -s --max-time 2 --unix-socket "$(garage_run)/admin.sock" -o /dev/null http://localhost/health; then
      return 0
    fi
    sleep 0.25
  done
  systemctl status --no-pager mroom-garage.service >&2 || true
  sudo journalctl -u mroom-garage.service -n 30 --no-pager >&2 || true
  echo "Garage did not start" >&2
  exit 1
}

t_the_bucket_operations_against_the_real_garage() {
  CI_HOME="$(mktemp -d "/home/$(id -un)/mroom-ci.XXXXXX")"
  export HOME="$CI_HOME"
  mkdir -p "$HOME/.config/mroom"
  printf 'MROOM_APP_NAME=shop\nMROOM_QA_ZONE=qa.example.test\n' >"$HOME/.config/mroom/box.env"
  run "$MROOM" baseline garage
  expect_rc 0; expect_out_has "garage v2.5.0: installed, SHA-256"
  local script
  script="$(root_script_of "$out")"
  expect_true "baseline printed no script to run as root" [ -n "$script" ]
  sudo bash -c "$script"
  wait_ready
  run "$MROOM" baseline garage
  expect_rc 0; expect_out_has "Garage answers; its layout now holds this node."
  expect_out_has "systemd units: installed as this mroom writes them (mroom-garage.service active)."
  local baseline_out="$out" files12 media12 files13 old r
  run "$MROOM" baseline garage; expect_out_has "Garage answers; its layout holds one node."
  run stat -c %a "$(garage_run)"; expect_out 700

  gate "bucket-create 12 files"; expect_rc 0; files12="$out"
  gate "bucket-create 12 media public"; expect_rc 0; media12="$out"
  expect_true "the public disk has no URL" eval '[ "$(field URL "$media12")" = https://files.qa.example.test/shop-qa-12-media ]'
  gate "bucket-create 13 files"; expect_rc 0; files13="$out"

  # Each key reaches its own bucket, and no other.
  r="$(s3 "$files12" "$(garage_run)/s3.sock" garage.invalid PUT /shop-qa-12-files/a.txt hello12)"
  expect_true "environment 12 could not write its bucket: $r" [ "$(status_of "$r")" = 200 ]
  r="$(s3 "$files12" "$(garage_run)/s3.sock" garage.invalid GET /shop-qa-12-files/a.txt)"
  expect_true "environment 12 could not read its bucket: $r" [ "$(body_of "$r")" = hello12 ]
  r="$(s3 "$files13" "$(garage_run)/s3.sock" garage.invalid GET /shop-qa-12-files/a.txt)"
  expect_true "environment 13 read environment 12's bucket: $r" [ "$(status_of "$r")" = 403 ]
  r="$(s3 "$files13" "$(garage_run)/s3.sock" garage.invalid PUT /shop-qa-12-files/b.txt from13)"
  expect_true "environment 13 wrote environment 12's bucket: $r" [ "$(status_of "$r")" = 403 ]
  r="$(s3 "$media12" "$(garage_run)/s3.sock" garage.invalid GET /shop-qa-12-files/a.txt)"
  expect_true "one disk's key read another disk's bucket: $r" [ "$(status_of "$r")" = 403 ]
  # Keys that start with a slash, which Garage reads only from a path with the slash encoded: the drop must
  # delete them too.
  local key
  for key in %2Flead %2F%2Ftwo %2F; do
    r="$(s3 "$files12" "$(garage_run)/s3.sock" garage.invalid PUT "/shop-qa-12-files/$key" slash12)"
    expect_true "the key $key could not be written: $r" [ "$(status_of "$r")" = 200 ]
  done

  # Website access: the public disk's files are served, the private one's are not.
  r="$(s3 "$media12" "$(garage_run)/s3.sock" garage.invalid PUT /shop-qa-12-media/hello.txt public12)"
  expect_true "the public disk's key could not write: $r" [ "$(status_of "$r")" = 200 ]
  r="$(web "$(garage_run)/web.sock" shop-qa-12-media.web.mroom.invalid /hello.txt)"
  expect_true "a public file is not served: $r" [ "$(status_of "$r")" = 200 ]
  expect_true "a public file is not served whole: $r" [ "$(body_of "$r")" = public12 ]
  r="$(web "$(garage_run)/web.sock" shop-qa-12-files.web.mroom.invalid /a.txt)"
  expect_true "a private file is served: $r" [ "$(status_of "$r")" = 404 ]

  # Through an nginx made from the configs baseline printed: signatures hold, and the files host finds the
  # bucket in the path.
  mkdir -p "$T/nginx"
  {
    echo "worker_processes 1; pid $T/nginx/nginx.pid; error_log $T/nginx/error.log warn; events {}"
    echo "http { access_log $T/nginx/access.log; client_body_temp_path $T/nginx/body; proxy_temp_path $T/nginx/proxy;"
    echo "fastcgi_temp_path $T/nginx/fcgi; uwsgi_temp_path $T/nginx/uwsgi; scgi_temp_path $T/nginx/scgi;"
    # Forge's own blocks of a PHP site, left in place: the printed ones must still take every path.
    forge='location ~ \.php$ { return 418; } location ~ /\.(?!well-known).* { deny all; }'
    echo "server { listen 127.0.0.1:8081; server_name s3.qa.example.test; $forge"
    # The printed config lines alone, which are indented; the text around them is not.
    sed -n '/^s3.qa.example.test, the S3 API/,/^files.qa.example.test, public files/p' <<<"$baseline_out" | grep '^    '
    echo "} server { listen 127.0.0.1:8081; server_name files.qa.example.test; $forge"
    sed -n '/^files.qa.example.test, public files/,$p' <<<"$baseline_out" | grep '^    '
    echo "} }"
  } >"$T/nginx/nginx.conf"
  nginx -p "$T/nginx" -c "$T/nginx/nginx.conf" 2>"$T/nginx/start.err" || { cat "$T/nginx/nginx.conf" "$T/nginx/start.err" >&2; exit 1; }
  sleep 0.5
  r="$(s3 "$files12" 127.0.0.1:8081 s3.qa.example.test GET /shop-qa-12-files/a.txt)"
  expect_true "a signed request through nginx failed: $r" [ "$(body_of "$r")" = hello12 ]
  r="$(s3 "$files12" 127.0.0.1:8081 s3.qa.example.test GET "/shop-qa-12-files?list-type=2")"
  expect_true "a signed listing through nginx failed: $r" eval '[[ "$r" == 200*"<Key>a.txt</Key>"* ]]'
  r="$(web 127.0.0.1:8081 files.qa.example.test /shop-qa-12-media/hello.txt)"
  expect_true "the files host does not serve a public file: $r" [ "$(body_of "$r")" = public12 ]
  r="$(web 127.0.0.1:8081 files.qa.example.test /shop-qa-12-files/a.txt)"
  expect_true "the files host serves a private file: $r" [ "$(status_of "$r")" = 404 ]
  # Forge's blocks take no path from the printed ones.
  r="$(s3 "$files12" 127.0.0.1:8081 s3.qa.example.test PUT /shop-qa-12-files/x.php php12)"
  expect_true "a .php key did not reach Garage: $r" [ "$(status_of "$r")" = 200 ]
  r="$(s3 "$files12" 127.0.0.1:8081 s3.qa.example.test PUT /shop-qa-12-files/dir/.keep keep12)"
  expect_true "a dot folder's key did not reach Garage: $r" [ "$(status_of "$r")" = 200 ]
  r="$(s3 "$media12" "$(garage_run)/s3.sock" garage.invalid PUT /shop-qa-12-media/x.php php12)"
  r="$(web 127.0.0.1:8081 files.qa.example.test /shop-qa-12-media/x.php)"
  expect_true "the files host did not serve a .php file from Garage: $r" [ "$(body_of "$r")" = php12 ]
  # The Host a client signed reaches Garage as it sent it, port and all.
  r="$(s3 "$files12" 127.0.0.1:8081 s3.qa.example.test:8081 GET /shop-qa-12-files/a.txt)"
  expect_true "a request signed with a port failed: $r" [ "$(body_of "$r")" = hello12 ]
  # An unsigned upload is refused before nginx keeps any of it: 100 MB at 2 MB/s would take 50 seconds.
  local start code took location
  start="$(date +%s)"
  code="$(head -c 104857600 /dev/zero | curl -q -s -o /dev/null -w '%{http_code}' --max-time 20 --limit-rate 2M \
    -H 'Host: s3.qa.example.test' -H 'Expect:' -T - http://127.0.0.1:8081/shop-qa-12-files/big)" || true
  took=$(($(date +%s) - start))
  expect_true "an unsigned upload was not refused at once (HTTP $code after ${took}s)" \
    eval '[[ "$code" =~ ^[45][0-9][0-9]$ ]] && [ "$took" -lt 10 ]'
  expect_true "nginx kept an upload's body in a file" eval '! grep -q "buffered to a temporary file" "$T/nginx/error.log"'
  # A website redirect keeps the bucket in the path.
  r="$(s3 "$media12" "$(garage_run)/s3.sock" garage.invalid PUT /shop-qa-12-media/docs/index.html docs12)"
  location="$(curl -q -s --max-time 10 -H 'Host: files.qa.example.test' -o /dev/null -D - \
    http://127.0.0.1:8081/shop-qa-12-media/docs | tr -d '\r' | sed -n 's/^[Ll]ocation: //p')"
  expect_true "a website redirect lost its bucket: '$location'" [ "$location" = /shop-qa-12-media/docs/ ]
  r="$(web 127.0.0.1:8081 files.qa.example.test /shop-qa-12-media/docs/)"
  expect_true "a folder's index is not served: $r" [ "$(body_of "$r")" = docs12 ]

  # A new key replaces the old one, and the files stay.
  old="$files12"
  gate "bucket-create 12 files"; expect_rc 0; files12="$out"
  r="$(s3 "$old" "$(garage_run)/s3.sock" garage.invalid GET /shop-qa-12-files/a.txt)"
  expect_true "an old key still works: $r" [ "$(status_of "$r")" = 403 ]
  r="$(s3 "$files12" "$(garage_run)/s3.sock" garage.invalid GET /shop-qa-12-files/a.txt)"
  expect_true "the new key cannot read, or the file went: $r" [ "$(body_of "$r")" = hello12 ]

  # Garage keeps its data when systemd starts it again.
  sudo systemctl kill --signal=SIGKILL mroom-garage.service
  sleep 2
  wait_ready
  r="$(s3 "$files12" "$(garage_run)/s3.sock" garage.invalid GET /shop-qa-12-files/a.txt)"
  expect_true "a file went with a restart: $r" [ "$(body_of "$r")" = hello12 ]

  # bucket-drop empties and deletes every bucket and key of the environment; other environments' stay.
  gate "bucket-create 1 files"; expect_rc 0
  gate "bucket-drop 12"; expect_rc 0
  expect_out_has "bucket shop-qa-12-files: dropped, 6 objects deleted"
  expect_out_has "bucket shop-qa-12-media: dropped, 3 objects deleted"
  r="$(s3 "$files12" "$(garage_run)/s3.sock" garage.invalid GET /shop-qa-12-files/a.txt)"
  expect_true "a dropped bucket's key still works: $r" [ "$(status_of "$r")" = 403 ]
  gate "bucket-drop 12"; expect_out "environment 12 has no buckets, so nothing to drop"
  r="$(s3 "$files13" "$(garage_run)/s3.sock" garage.invalid PUT /shop-qa-13-files/c.txt hello13)"
  expect_true "another environment's bucket went: $r" [ "$(status_of "$r")" = 200 ]
  run bash -c 'printf "Authorization: Bearer %s\n" "$(cat "$1")" | curl -q -s --unix-socket "$2" --header @- http://localhost/v2/ListKeys' _ \
    "$HOME/.config/mroom/secrets/garage-admin-token" "$(garage_run)/admin.sock"
  run jq -r '[.[].name] | sort | join(" ")' <<<"$out"; expect_out "shop-qa-1-files shop-qa-13-files"
  gate "bucket-drop 1"; expect_rc 0; expect_out "bucket shop-qa-1-files: dropped, 0 objects deleted"
}

test_case real-garage t_the_bucket_operations_against_the_real_garage
finish
