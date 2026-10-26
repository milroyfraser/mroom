#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2016  # t_* run through test_case; a $ in single quotes is for eval, later
# The gate against a real Redis (the image in MROOM_TEST_REDIS_IMAGE, redis:8 by default), set up as the
# README's "QA gate" section says: what a fake redis-cli cannot show. Each environment's user reaches only
# its own prefix, may run no module command and none of the commands that act on the whole server, yet may
# run what a Laravel app sends; a new password replaces the old one and closes old connections; users
# survive a restart; redis-clear deletes exactly the prefix's keys, even one whose name holds a newline.
# CI only: it needs Docker, so tests/run.sh does not pick it up.
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
# denied <user> <password> <redis-cli args...>: the command is refused for want of permission (NOPERM, or
# from inside a script, an ACL failure).
denied() {
  local o
  if o="$(as "$@" 2>&1)"; then return 1; fi
  case "$o" in *NOPERM* | *"ACL failure in script: No permissions"*) return 0 ;; esac
  echo "    refused, but not for permission: $o" >&2
  return 1
}
# may <user> <command...>: ACL DRYRUN says the user may run it, without running it.
may() {
  local user="$1" o
  shift
  o="$(as mroom-gate "$GATE_PW" ACL DRYRUN "$user" "$@" 2>&1)" || true
  [ "$o" = OK ] && return 0
  echo "    $o" >&2
  return 1
}
gate() { run env SSH_ORIGINAL_COMMAND="$1" "$MROOM" gate provision; }
# take_password: the REDIS_PASSWORD the gate just printed, which then leaves $out, so a failure's report in
# CI's public log never shows it.
take_password() { password="$(sed -n 's/^REDIS_PASSWORD=//p' <<<"$out")"; out="(credentials)"; }
acl_file() { docker exec "$NAME" cat /acl/users.acl; }

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
# on ACL SAVE, so the folder is open to it. The image's umask makes the rewritten file 600, so it is read
# through the container.
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

# module_sweep <user>: every command of every loaded module, put to ACL DRYRUN for that user with as many
# arguments as its arity asks, inside the container so two hundred checks take a second. A container such
# as FT.CONFIG is skipped, since its subcommands are listed and checked. Prints "denied", or
# "allowed <command>" or "unchecked <command>" (a reply that is neither) for each.
module_sweep() {
  local script
  script="$(cat <<'SWEEP'
user="$1"
r() { redis-cli --no-auth-warning --user mroom-gate "$@"; }
list="$(r MODULE LIST | awk 'prev == "name" { print } { prev = $0 }' | while read -r m; do
  r COMMAND LIST FILTERBY MODULE "$m"
done | sort -u)"
echo "$list" | while read -r c; do
  [ -n "$c" ] || continue
  if echo "$list" | awk -v p="$c|" 'index($0, p) == 1 { found = 1 } END { exit !found }'; then continue; fi
  arity="$(r COMMAND INFO "$c" | sed -n 2p)"
  arity="${arity#-}"
  set -- $(echo "$c" | tr '|' ' ')
  while [ "$#" -lt "${arity:-1}" ]; do set -- "$@" shop:qa12:a; done
  case "$(r ACL DRYRUN "$user" "$@" 2>&1)" in
    OK) echo "allowed $c" ;;
    *"no permissions to run"*) echo denied ;;
    *) echo "unchecked $c" ;;
  esac
done
SWEEP
)"
  REDISCLI_AUTH="$GATE_PW" docker exec -e REDISCLI_AUTH "$NAME" sh -c "$script" sweep "$1" </dev/null
}

t_the_gate_on_a_real_redis() {
  start_redis
  mkdir -p "$HOME/.config/mroom/secrets"
  printf 'MROOM_APP_NAME=shop\n' >"$HOME/.config/mroom/box.env"
  printf 'REDIS_GATE_USER=mroom-gate\nREDIS_GATE_PASSWORD=%s\n' "$GATE_PW" >"$HOME/.config/mroom/secrets/redis-gate.env"
  chmod 600 "$HOME/.config/mroom/secrets/redis-gate.env"
  local modules password pw12 pw13 old sub c args sweep acl clients
  modules="$(as mroom-gate "$GATE_PW" MODULE LIST | tr -d '\r' | awk 'prev == "name" { print } { prev = $0 }' | tr '\n' ' ')"
  echo "  $IMAGE: $(as mroom-gate "$GATE_PW" INFO server | tr -d '\r' | grep '^redis_version:'), modules: ${modules:-none}"
  if [[ "$IMAGE" == redis:8* ]]; then
    expect_true "this Redis 8 has no modules, so their commands go unchecked" [ -n "$modules" ]
  fi
  expect_true "the default user signed in" eval '! redis-cli -e PING >/dev/null 2>&1'

  gate "redis-user-add 12"; expect_rc 0
  take_password; pw12="$password"
  expect_true "env 12 cannot write its own key" can shop_qa_12 "$pw12" SET shop:qa12:a 1
  expect_true "env 12 cannot use its prefix in another database" can shop_qa_12 "$pw12" -n 1 SET shop:qa12:b 1
  expect_true "env 12 cannot publish on its own channel" can shop_qa_12 "$pw12" PUBLISH shop:qa12:events x
  expect_true "env 12 read env 13's key" denied shop_qa_12 "$pw12" GET shop:qa13:a
  expect_true "env 12 wrote outside its prefix" denied shop_qa_12 "$pw12" SET cache:a 1
  expect_true "env 12 published on env 13's channel" denied shop_qa_12 "$pw12" PUBLISH shop:qa13:events x
  expect_true "env 12 reached env 13's key from a script" denied shop_qa_12 "$pw12" EVAL "return redis.call('GET', 'shop:qa13:a')" 0
  for c in "KEYS *" "SCAN 0" RANDOMKEY DBSIZE FLUSHALL FLUSHDB "SWAPDB 0 1" INFO TIME "MEMORY STATS" \
    "CONFIG GET maxmemory" "CLIENT LIST" "ACL LIST" "PUBSUB CHANNELS" "PUBSUB SHARDCHANNELS" "PUBSUB NUMSUB x" \
    "PUBSUB SHARDNUMSUB x" "PUBSUB NUMPAT" "FUNCTION LIST" "SCRIPT FLUSH" "SCRIPT DEBUG YES" "CLIENT TRACKING on"; do
    read -r -a args <<<"$c"
    expect_true "env 12 may run $c" denied shop_qa_12 "$pw12" "${args[@]}"
  done

  # No module command at all: a module's key specs decide what its commands reach, and some name only
  # their first key. JSON.MGET read other environments' documents before this rule.
  if [ -n "$modules" ]; then
    expect_true "env 12 read another environment's JSON" denied shop_qa_12 "$pw12" JSON.MGET shop:qa12:x shop:qa13:a '$'
    expect_true "env 12 merged another environment's sketch" denied shop_qa_12 "$pw12" CMS.MERGE shop:qa12:c 1 shop:qa13:c
    expect_true "env 12 listed every index" denied shop_qa_12 "$pw12" FT._LIST
    expect_true "env 12 queried every time series" denied shop_qa_12 "$pw12" TS.QUERYINDEX a=b
    sweep="$(module_sweep shop_qa_12)"
    echo "  module commands denied: $(grep -c -x denied <<<"$sweep" || true)"
    expect_true "env 12 may run module commands: $(grep -v -x denied <<<"$sweep" | tr '\n' ' ')" \
      eval '! grep -q -v -x denied <<<"$sweep"'
  fi

  # What a Laravel app and Horizon send: the cache, locks, queues, sessions, tags, broadcasting, Pulse.
  while read -r -a args; do
    expect_true "env 12 may not run ${args[*]}, which an app needs" may shop_qa_12 "${args[@]}" </dev/null
  done <<'NEEDED'
GET shop:qa12:k
SET shop:qa12:k v EX 60 NX
SETEX shop:qa12:k 60 v
MGET shop:qa12:a shop:qa12:b
INCRBY shop:qa12:k 1
DEL shop:qa12:k
UNLINK shop:qa12:a shop:qa12:b
EXISTS shop:qa12:k
EXPIRE shop:qa12:k 60
TTL shop:qa12:k
TYPE shop:qa12:k
HSET shop:qa12:h f v
HGETALL shop:qa12:h
HINCRBY shop:qa12:h f 1
RPUSH shop:qa12:queues:default job
LPOP shop:qa12:queues:default
BLPOP shop:qa12:queues:default 1
LLEN shop:qa12:queues:default
ZADD shop:qa12:queues:default:delayed 1 job
ZRANGEBYSCORE shop:qa12:queues:default:delayed -inf +inf
ZREMRANGEBYSCORE shop:qa12:queues:default:delayed -inf +inf
ZCARD shop:qa12:queues:default:delayed
ZSCAN shop:qa12:tag:entries 0
SADD shop:qa12:s m
SMEMBERS shop:qa12:s
EVAL return(1) 0
EVALSHA e0e1f9fabfc9d4800c877a703b823ac0578ff8db 0
SCRIPT LOAD return(1)
MULTI
EXEC
WATCH shop:qa12:k
PING
SELECT 1
CLIENT SETNAME app
PUBLISH shop:qa12:events x
SUBSCRIBE shop:qa12:events
PSUBSCRIBE shop:qa12:*
XADD shop:qa12:pulse * k v
XRANGE shop:qa12:pulse - +
NEEDED

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
  take_password; pw12="$password"
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
  take_password; pw13="$password"
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
  acl="$(acl_file)" || acl=""
  expect_true "the aclfile could not be read" [ -n "$acl" ]
  expect_true "the aclfile still holds env 12's user" eval '! grep -q "^user shop_qa_12 " <<<"$acl"'
  expect_true "the aclfile lost env 13's user" grep -q "^user shop_qa_13 " <<<"$acl"

  # With the default user on, any process on the box reaches every key: the gate refuses to go on.
  expect_true "the default user could not be turned on" can mroom-gate "$GATE_PW" ACL SETUSER default on
  gate "redis-user-add 14"; expect_rc 1; expect_err_has "Redis's default user is on"
  run as mroom-gate "$GATE_PW" ACL USERS
  expect_true "env 14's user was made anyway" eval '! grep -qx shop_qa_14 <<<"$out"'
}

test_case real-redis t_the_gate_on_a_real_redis
finish
