#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2016  # t_* run through test_case; a $ in single quotes is for eval, later
# Tests for the gate's Garage operations (bucket-create, bucket-drop): a bucket per environment and file disk,
# a key that reaches it alone and is new on every create, website access only for a public disk, and a drop
# that finds every bucket and key of the environment by name and empties each bucket with a key of its own,
# which goes when the drop ends. Offline:
# tests/fakes/garage.py plays Garage's admin and S3 APIs on Unix sockets, and the gate's real curl and
# lib/s3-empty talk to it. tests/files/gate-real-test.sh runs the real Garage in CI.
set -euo pipefail
SUITE=garage
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
stop_all() {
  local f
  for f in "$TOP"/*/garage.pid; do if [ -s "$f" ]; then kill "$(cat "$f")" 2>/dev/null || true; fi; done
  rm -rf "$TOP"
}
trap stop_all EXIT
skip_unless has_box_tools "this host lacks bash 5, flock or GNU date, which box commands need"

TOKEN=0123456789abcdef0123456789abcdef0123456789abcdef
REAL_CURL="$(command -v curl)"

world() {
  local run="$HOME/.local/share/mroom-services/garage/run" secrets="$HOME/.config/mroom/secrets"
  mkdir -p "$run" "$secrets" "$T/bin"
  chmod 700 "$run"
  printf 'MROOM_APP_NAME=shop\nMROOM_QA_ZONE=qa.example.dev\n' >"$HOME/.config/mroom/box.env"
  printf '%s\n' "$TOKEN" >"$secrets/garage-admin-token"
  chmod 600 "$secrets/garage-admin-token"
  # curl is the real one, behind a shim that logs every command line.
  printf '#!/bin/sh\necho "$*" >>"$T/curl.argv"\nexec "%s" "$@"\n' "$REAL_CURL" >"$T/bin/curl"
  printf '#!/bin/sh\necho "$*" >>"$T/syslog"\n' >"$T/bin/logger"
  chmod +x "$T/bin/curl" "$T/bin/logger"
  export T PATH="$T/bin:$PATH"
  garage_up
}

garage_up() {
  local run="$HOME/.local/share/mroom-services/garage/run"
  python3 -I "$ROOT/tests/fakes/garage.py" "$run/admin.sock" "$run/s3.sock" "$HOME/.config/mroom/secrets/garage-admin-token" \
    "$T/garage.log" >"$T/garage.out" 2>&1 &
  echo $! >"$T/garage.pid"
  for _ in $(seq 1 50); do grep -q up "$T/garage.out" 2>/dev/null && return 0; sleep 0.1; done
  cat "$T/garage.out" >&2
  return 1
}
garage_down() { kill "$(cat "$T/garage.pid")" 2>/dev/null || true; sleep 0.2; }

gate() { run env SSH_ORIGINAL_COMMAND="$1" "$MROOM" gate provision; }
# admin <path> [<json>]: the test's own call to the stand-in's admin API.
admin() {
  local args=(-q -s --unix-socket "$HOME/.local/share/mroom-services/garage/run/admin.sock" --header @-)
  if [ -n "${2-}" ]; then args+=(--request POST --data-binary "$2"); fi
  printf 'Authorization: Bearer %s\n' "$TOKEN" | "$REAL_CURL" "${args[@]}" "http://localhost$1"
}
state() { admin /test/state; }
seed() { admin /test/seed "$(jq -nc --arg b "$1" '{bucket: $b, keys: $ARGS.positional}' --args "${@:2}")" >/dev/null; }
field() { sed -n "s/^$1=//p" <<<"$2"; }
gate_log_text() { cat "$HOME/.local/state/mroom/gate.log" 2>/dev/null || true; }
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
lacks() { ! has "$@"; }

t_bucket_create_makes_a_bucket_and_a_key_for_it_alone() {
  world
  gate "bucket-create 12 files"
  expect_rc 0
  expect_out_has $'BUCKET=shop-qa-12-files\nACCESS_KEY_ID=GK'
  expect_out_has $'REGION=garage\nENDPOINT=https://s3.qa.example.dev\nPATH_STYLE=true'
  expect_true "a private disk got a public URL" lacks "$out" "URL="
  local key secret first
  key="$(field ACCESS_KEY_ID "$out")" secret="$(field SECRET_ACCESS_KEY "$out")"
  expect_true "the key id is not Garage's" eval '[[ "$key" =~ ^GK[0-9a-f]{24}$ ]]'
  expect_true "the secret is not Garage's" eval '[[ "$secret" =~ ^[0-9a-f]{64}$ ]]'
  run state
  run jq -c --arg k "$key" '.keys[$k]' <<<"$out"
  expect_out '{"name":"shop-qa-12-files","buckets":{"shop-qa-12-files":{"read":true,"write":true,"owner":false}}}'
  run state; run jq -c '.buckets' <<<"$out"; expect_out '{"shop-qa-12-files":{"website":false,"objects":[]}}'
  expect_true "the admin token reached a command line" lacks "$(cat "$T/curl.argv")" "$TOKEN"
  expect_true "the secret reached the gate log" lacks "$(gate_log_text)" "$secret"
  # Again: a new key, the old one gone, the bucket and its files kept.
  first="$key"
  seed shop-qa-12-files keep.txt
  gate "bucket-create 12 files"; expect_rc 0
  key="$(field ACCESS_KEY_ID "$out")"
  expect_true "the key was not replaced" [ "$key" != "$first" ]
  run state
  run jq -r '[.keys[] | select(.name == "shop-qa-12-files")] | length' <<<"$out"; expect_out 1
  run state; run jq -c '.buckets["shop-qa-12-files"].objects' <<<"$out"; expect_out '["keep.txt"]'
}

t_a_public_disk_gets_website_access_and_a_url() {
  world
  gate "bucket-create 12 media public"
  expect_rc 0
  expect_out_has "URL=https://files.qa.example.dev/shop-qa-12-media"
  run state; run jq -c '.buckets["shop-qa-12-media"].website' <<<"$out"; expect_out true
  # Made private again, it is no longer served.
  gate "bucket-create 12 media"; expect_rc 0
  run state; run jq -c '.buckets["shop-qa-12-media"].website' <<<"$out"; expect_out false
}

t_bucket_drop_empties_and_deletes_every_bucket_and_key_of_the_environment() {
  world
  local disk
  for disk in "12 files" "12 media public" "13 files" "1 files"; do gate "bucket-create $disk"; expect_rc 0; done
  # A key of a disk the app no longer has, and the key of a drop a killed gate left.
  admin /v2/CreateKey '{"name": "shop-qa-12-old"}' >/dev/null
  admin /v2/CreateKey '{"name": "mroom-drop-shop-qa-12-files"}' >/dev/null
  local names=() i
  for i in $(seq 1 1200); do names+=("n/$i.txt"); done
  # Garage reads a key's leading slashes in a path as none, so these are deleted only if sent encoded; a
  # DELETE of "/" sent as is would be one of the bucket.
  seed shop-qa-12-files "a.txt" "dir/b c.pdf" "ü/ñ#?&=.png" "+plus+" "50%25" "/lead" "//two" "/" "${names[@]}"
  seed shop-qa-12-media "pic.png"
  seed shop-qa-13-files "theirs.txt"
  seed shop-qa-1-files "ones.txt"
  gate "bucket-drop 12"
  expect_rc 0
  expect_out $'bucket shop-qa-12-files: dropped, 1208 objects deleted\nbucket shop-qa-12-media: dropped, 1 objects deleted'
  run state
  run jq -c '.buckets | keys' <<<"$out"; expect_out '["shop-qa-1-files","shop-qa-13-files"]'
  run state
  run jq -r '[.keys[].name] | sort | join(" ")' <<<"$out"; expect_out "shop-qa-1-files shop-qa-13-files"
  run state; run jq -c '[.buckets["shop-qa-13-files"].objects, .buckets["shop-qa-1-files"].objects]' <<<"$out"
  expect_out '[["theirs.txt"],["ones.txt"]]'
  # Its S3 requests were signed, and good.
  expect_true "an S3 request was refused" lacks "$(cat "$T/garage.log")" "login=bad"
  run grep -c '^s3 DELETE /shop-qa-12-.* login=good$' "$T/garage.log"; expect_out 1209
  expect_true "a key's slash went unencoded" grep -qxF 's3 DELETE /shop-qa-12-files/%2F%2Ftwo login=good' "$T/garage.log"
  gate "bucket-drop 12"; expect_rc 0; expect_out "environment 12 has no buckets, so nothing to drop"
  gate "bucket-drop 1"; expect_rc 0; expect_out "bucket shop-qa-1-files: dropped, 1 objects deleted"
  run state; run jq -c '.buckets | keys' <<<"$out"; expect_out '["shop-qa-13-files"]'
}

t_a_failed_drop_leaves_no_key_of_its_own() {
  world
  gate "bucket-create 12 files"; expect_rc 0
  seed shop-qa-12-files one.txt two.txt
  admin /test/fail '{"s3_delete": true}' >/dev/null
  gate "bucket-drop 12"
  expect_rc 1; expect_err_has "bucket-drop 12: s3-empty: deleting an object of shop-qa-12-files: HTTP 500 InternalError"
  run state
  run jq -r '[.keys[].name] | length' <<<"$out"; expect_out 0
  run state; run jq -c '.buckets["shop-qa-12-files"].objects' <<<"$out"; expect_out '["one.txt","two.txt"]'
}

t_what_the_gate_refuses() {
  world
  local words
  for words in "bucket-create 12 Files" "bucket-create 12 1files" "bucket-create 12 averyveryverylongdisk" \
    "bucket-create 12 files private" "bucket-create 12 files public more" "bucket-create 0 files" \
    "bucket-drop 12 files" "bucket-drop x" "bucket-drop"; do
    gate "$words"; expect_rc 1; expect_err_has "refused"
  done
  run state; run jq -c '.buckets' <<<"$out"; expect_out '{}'
  local secrets="$HOME/.config/mroom/secrets"
  chmod 644 "$secrets/garage-admin-token"
  gate "bucket-create 12 files"; expect_rc 1; expect_err_has "garage-admin-token must be yours and mode 600"
  chmod 600 "$secrets/garage-admin-token"
  printf 'MROOM_APP_NAME=shop\n' >"$HOME/.config/mroom/box.env"
  gate "bucket-create 12 files"; expect_rc 1; expect_err_has "MROOM_QA_ZONE is not set in box.env"
  printf 'MROOM_APP_NAME=shop\nMROOM_QA_ZONE=qa.example.dev\n' >"$HOME/.config/mroom/box.env"
  garage_down
  gate "bucket-create 12 files"; expect_rc 1; expect_err_has "bucket-create 12: curl: (7)"
  rm "$secrets/garage-admin-token"
  gate "bucket-create 12 files"; expect_rc 1; expect_err_has "garage-admin-token is missing; run mroom baseline garage"
}

test_case bucket-create t_bucket_create_makes_a_bucket_and_a_key_for_it_alone
test_case public t_a_public_disk_gets_website_access_and_a_url
test_case bucket-drop t_bucket_drop_empties_and_deletes_every_bucket_and_key_of_the_environment
test_case failed-drop t_a_failed_drop_leaves_no_key_of_its_own
test_case refusals t_what_the_gate_refuses
finish
