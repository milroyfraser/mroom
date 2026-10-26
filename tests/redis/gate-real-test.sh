#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2016  # t_* run through test_case; a $ in single quotes is for eval, later
# The gate against a real Redis (the image in MROOM_TEST_REDIS_IMAGE, redis:8 by default), set up as the
# README's "QA gate" section says: what a fake redis-cli cannot show. Each environment's user reaches only
# its own prefix and none of the commands that act on the whole server; a new password replaces the old one
# and closes old connections; users survive a restart; redis-clear deletes exactly the prefix's keys, even
# one whose name holds a newline. CI only: it needs Docker, so tests/run.sh does not pick it up.
set -euo pipefail
SUITE=gate-redis-real
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

IMAGE="${MROOM_TEST_REDIS_IMAGE:-redis:8}"
NAME="mroom-gate-redis-$$"
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -rf "$TOP"' EXIT

# as <user> <password> <redis-cli args...>: one command as that user.
as() { local user="$1" pw="$2"; shift 2; REDISCLI_AUTH="$pw" redis-cli --no-auth-warning -e --user "$user" "$@"; }
can() { as "$@" >/dev/null 2>&1; }
cannot() { ! can "$@"; }
# denied <user> <password> <redis-cli args...>: the command is refused for want of permission.
denied() {
  local o
  if o="$(as "$@" 2>&1)"; then return 1; fi
  case "$o" in *NOPERM*) return 0 ;; esac
  echo "    refused, but not for permission: $o" >&2
  return 1
}
gate() { run env SSH_ORIGINAL_COMMAND="$1" "$MROOM" gate provision; }
password_of() { sed -n 's/^REDIS_PASSWORD=//p' <<<"$1"; }

wait_for_redis() {
  local _
  for _ in $(seq 1 30); do
    if can mroom-gate "$GATE_PW" PING; then return 0; fi
    sleep 1
  done
  docker logs "$NAME" >&2 || true
  echo "Redis did not start" >&2
  exit 1
}

# start_redis: the README's setup: users in an aclfile, the gate's own user, the default user off. The
# folder is not /data, which the image's entrypoint would hand to its redis user; Redis rewrites the file
# on ACL SAVE, so the folder is open to it.
start_redis() {
  ACL_DIR="$T/acl"
  mkdir -p "$ACL_DIR" "$T/bin"
  chmod 777 "$ACL_DIR"
  GATE_PW="gate-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
  printf 'user mroom-gate on #%s ~* &* +@all\nuser default off\n' \
    "$(printf '%s' "$GATE_PW" | sha256sum | cut -d' ' -f1)" >"$ACL_DIR/users.acl"
  chmod 666 "$ACL_DIR/users.acl"
  docker run -d --name "$NAME" -v "$ACL_DIR:/acl" "$IMAGE" \
    redis-server --aclfile /acl/users.acl --save '' --appendonly no >/dev/null
  # redis-cli, for the gate and the checks, is the image's own, run in the container. A password goes in
  # through the environment, never a command line.
  printf '#!/bin/sh\nexec docker exec -e REDISCLI_AUTH %s redis-cli "$@"\n' "$NAME" >"$T/bin/redis-cli"
  chmod +x "$T/bin/redis-cli"
  export PATH="$T/bin:$PATH"
  wait_for_redis
}

t_the_gate_on_a_real_redis() {
  start_redis
  mkdir -p "$HOME/.config/mroom/secrets"
  printf 'MROOM_APP_NAME=shop\n' >"$HOME/.config/mroom/box.env"
  printf 'REDIS_GATE_USER=mroom-gate\nREDIS_GATE_PASSWORD=%s\n' "$GATE_PW" >"$HOME/.config/mroom/secrets/redis-gate.env"
  chmod 600 "$HOME/.config/mroom/secrets/redis-gate.env"
  local cats pw12 pw13 old sub c clients
  cats="$(as mroom-gate "$GATE_PW" ACL CAT | tr -d '\r')"
  echo "  $IMAGE: $(as mroom-gate "$GATE_PW" INFO server | tr -d '\r' | grep '^redis_version:'), keyless categories: $(grep -x -E 'search|timeseries' <<<"$cats" | tr '\n' ' ')"
  if [[ "$IMAGE" == redis:8* ]]; then
    expect_true "this Redis 8 has no @search, so the rule for it goes untested" grep -qx search <<<"$cats"
  fi
  expect_true "the default user signed in" eval '! redis-cli -e PING >/dev/null 2>&1'

  gate "redis-user-add 12"; expect_rc 0
  pw12="$(password_of "$out")"
  expect_true "env 12 cannot write its own key" can shop_qa_12 "$pw12" SET shop:qa12:a 1
  expect_true "env 12 cannot use its prefix in another database" can shop_qa_12 "$pw12" -n 1 SET shop:qa12:b 1
  expect_true "env 12 cannot publish on its own channel" can shop_qa_12 "$pw12" PUBLISH shop:qa12:events x
  expect_true "env 12 read env 13's key" denied shop_qa_12 "$pw12" GET shop:qa13:a
  expect_true "env 12 wrote outside its prefix" denied shop_qa_12 "$pw12" SET cache:a 1
  expect_true "env 12 published on env 13's channel" denied shop_qa_12 "$pw12" PUBLISH shop:qa13:events x
  for c in "KEYS *" "SCAN 0" RANDOMKEY FLUSHALL FLUSHDB "SWAPDB 0 1" INFO "CONFIG GET maxmemory" "CLIENT LIST" \
    "ACL LIST" "PUBSUB CHANNELS" "PUBSUB SHARDCHANNELS" "PUBSUB NUMSUB x" "PUBSUB SHARDNUMSUB x" "FUNCTION LIST" \
    "SCRIPT FLUSH" "CLIENT TRACKING on"; do
    # shellcheck disable=SC2086  # each command is plain words
    expect_true "env 12 may run $c" denied shop_qa_12 "$pw12" $c
  done
  if grep -qx search <<<"$cats"; then expect_true "env 12 listed every index" denied shop_qa_12 "$pw12" FT._LIST; fi
  if grep -qx timeseries <<<"$cats"; then
    expect_true "env 12 queried every time series" denied shop_qa_12 "$pw12" TS.QUERYINDEX a=b
  fi

  # A second request: a new password, the old one refused, and its open connections closed.
  as shop_qa_12 "$pw12" SUBSCRIBE shop:qa12:events >/dev/null 2>&1 &
  sub=$!
  for _ in $(seq 1 20); do
    clients="$(as mroom-gate "$GATE_PW" CLIENT LIST)"
    if grep -q 'user=shop_qa_12' <<<"$clients"; then break; fi
    sleep 0.5
  done
  old="$pw12"
  gate "redis-user-add 12"; expect_rc 0
  pw12="$(password_of "$out")"
  expect_true "the old password still signs in" cannot shop_qa_12 "$old" PING
  expect_true "the new password does not sign in" can shop_qa_12 "$pw12" PING
  for _ in $(seq 1 20); do
    if ! kill -0 "$sub" 2>/dev/null; then break; fi
    sleep 0.5
  done
  expect_true "a connection signed in with the old password stayed open" eval '! kill -0 "$sub" 2>/dev/null'
  kill "$sub" 2>/dev/null || true
  wait "$sub" 2>/dev/null || true

  # ACL SAVE wrote the user to the aclfile, so it survives a restart.
  docker restart "$NAME" >/dev/null
  wait_for_redis
  expect_true "env 12's user did not survive a restart" can shop_qa_12 "$pw12" PING

  gate "redis-user-add 13"; expect_rc 0
  pw13="$(password_of "$out")"
  expect_true "env 13 cannot write its key" can shop_qa_13 "$pw13" SET shop:qa13:keep 1
  expect_true "env 12 cannot write" can shop_qa_12 "$pw12" SET shop:qa12:a 1
  expect_true "env 12 cannot write in database 1" can shop_qa_12 "$pw12" -n 1 SET shop:qa12:b 1
  # A name holding a newline: read back line by line, its second line would name env 13's key.
  expect_true "env 12 cannot write a key with a newline" can shop_qa_12 "$pw12" SET $'shop:qa12:x\nshop:qa13:keep' 1
  # Enough keys, among others, that the scan takes many steps and the deletes many batches.
  expect_true "the bulk keys were not written" can mroom-gate "$GATE_PW" EVAL \
    "for i = 1, 2500 do redis.call('SET', 'shop:qa12:bulk:' .. i, i) redis.call('SET', 'other:' .. i, i) end" 0
  gate "redis-clear 12"; expect_rc 0; expect_out "redis shop:qa12:: 2503 keys deleted"
  run as mroom-gate "$GATE_PW" EXISTS shop:qa13:keep; expect_out 1
  run as mroom-gate "$GATE_PW" EXISTS shop:qa12:a $'shop:qa12:x\nshop:qa13:keep' shop:qa12:bulk:1; expect_out 0
  run as mroom-gate "$GATE_PW" -n 1 EXISTS shop:qa12:b; expect_out 0
  run as mroom-gate "$GATE_PW" DBSIZE; expect_out 2501

  gate "redis-user-remove 12"; expect_rc 0
  expect_true "env 12's user still signs in" cannot shop_qa_12 "$pw12" PING
  expect_true "the aclfile still holds env 12's user" eval '! grep -q "^user shop_qa_12 " "$ACL_DIR/users.acl"'
  expect_true "the aclfile lost env 13's user" grep -q "^user shop_qa_13 " "$ACL_DIR/users.acl"

  # With the default user on, any process on the box reaches every key: the gate refuses to go on.
  expect_true "the default user could not be turned on" can mroom-gate "$GATE_PW" ACL SETUSER default on
  gate "redis-user-add 14"; expect_rc 1; expect_err_has "Redis's default user is on"
  run as mroom-gate "$GATE_PW" ACL USERS
  expect_true "env 14's user was made anyway" eval '! grep -qx shop_qa_14 <<<"$out"'
}

test_case real-redis t_the_gate_on_a_real_redis
finish
