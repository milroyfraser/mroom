#!/usr/bin/env bash
# build.sh settings|run <N> <app> — the frontend of QA environment N, built from the pull request's own checkout
# in <app> with public values only (.github/workflows/qa-plan.yml; design 8.2). What it runs is the pull request's
# code, so it runs in a job that holds no secret, and after the path rules.
#
#   build.sh settings <N> <app>   prints dir= (the folder to build in), node_file= (an .nvmrc or .node-version
#                                 there or at the root, for setup-node) and dist= (the folder the build writes),
#                                 each relative to <app>, for GITHUB_OUTPUT; dist= is empty with nothing to build
#   build.sh run <N> <app>        installs the packages and runs the build
#
# The pull request's mroom.toml says what to build: app.frontend_dir (a folder of its own; . for Vite inside the
# Laravel app, which builds in app.backend_dir; empty for no frontend), app.package_manager (npm, or pnpm),
# app.build.frontend (the command; unset, nothing is built) and app.build.frontend_dist (where the build writes,
# inside that folder: dist for a frontend of its own, public/build for Vite inside Laravel, by default).
# app.build.frontend_env sets the build's environment: env:<KEY> is the environment's own value of KEY that is
# not secret, the one qa-up writes into its .env (lib/core/qa.sh, qa_public_env: APP_URL, CLIENT_URL, the cookies'
# names and domain, and, when the environment broadcasts with Reverb, its Reverb app's id and key and the Reverb
# host's name, port and scheme); any other env:<KEY> is empty, since a build that runs a pull request's code holds
# nothing secret; and a plain value is used as it is, so it is public too.
set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
MROOM_ROOT="$(cd "$(dirname "$SELF")/../.." && pwd)"
export MROOM_ROOT
# shellcheck source=lib/core/util.sh
. "$MROOM_ROOT/lib/core/util.sh"
# shellcheck source=lib/core/forge.sh
. "$MROOM_ROOT/lib/core/forge.sh"
# shellcheck source=lib/core/qa.sh
. "$MROOM_ROOT/lib/core/qa.sh"
QA_NAME="mroom qa-plan"

mode="${1:-}" n="${2:-}" app="${3:-}"
case "$mode" in settings | run) ;; *) echo "usage: build.sh settings|run <N> <app folder>" >&2; exit 2 ;; esac
qa_number "$n" || { qa_say "the pull request's number is not a number"; exit 2; }
[ -d "$app" ] || { qa_say "there is no app folder $app"; exit 2; }
export MROOM_CONFIG="$app/mroom.toml"
qa_names "$n"

command="$(qa_config app.build.frontend "")"
case "$QA_FRONTEND" in
  "") dir="" ;;
  .) dir="$QA_BACKEND" default_dist=public/build ;;
  *) dir="$QA_FRONTEND" default_dist=dist ;;
esac
dist=""
if [ -n "$dir" ] && [ -n "$command" ]; then dist="$(qa_config app.build.frontend_dist "$default_dist")"; fi

if [ "$mode" = settings ]; then
  node_file=""
  for file in "$dir/.nvmrc" "$dir/.node-version" .nvmrc .node-version; do
    if [ -n "$dist" ] && [ -f "$app/$file" ]; then node_file="${file#./}"; break; fi
  done
  printf 'dir=%s\nnode_file=%s\ndist=%s\n' "$dir" "$node_file" "${dist:+$dir/$dist}"
  exit 0
fi

if [ -z "$dist" ]; then echo "nothing to build: no app.build.frontend, or app.frontend_dir is empty"; exit 0; fi

# The build's environment: the public values of this environment, and the plain values mroom.toml gives.
values="$(qa_public_env)" || { qa_say "mroom.toml could not say how the environment broadcasts (qa.parity.broadcast)"; exit 1; }
declare -A public=()
while IFS='=' read -r key value; do public["$key"]="$value"; done <<<"$values"
vars=()
while IFS= read -r line; do
  [ -n "$line" ] || continue
  name="${line%%=*}" value="${line#*=}"
  [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { qa_say "app.build.frontend_env has a name that is not one: ${name:0:40}"; exit 1; }
  if [[ "$value" == env:* ]]; then
    key="${value#env:}"
    if [ -n "${public[$key]+set}" ]; then
      value="${public[$key]}"
    else
      echo "$name reads $key, which is not one of a QA environment's public values, so it is empty in this build"
      value=""
    fi
  fi
  vars+=("$name=$value")
done < <(qa_config app.build.frontend_env '{}')

cd "$app/$dir"
case "$(qa_config app.package_manager npm)" in
  pnpm)
    if ! command -v pnpm >/dev/null 2>&1; then
      # The version package.json pins, else the current major one.
      version="$(jq -r '.packageManager // "" | capture("^pnpm@(?<v>[0-9]+\\.[0-9]+\\.[0-9]+)").v // "10"' package.json 2>/dev/null || echo 10)"
      npm install --global "pnpm@$version"
    fi
    pnpm install --frozen-lockfile
    ;;
  *) npm ci ;;
esac
echo "building: $command"
env "${vars[@]}" bash -c "$command"
if [ ! -d "$dist" ] || [ -z "$(ls -A "$dist")" ]; then
  qa_say "the build wrote nothing to $dir/$dist (app.build.frontend_dist)"
  exit 1
fi
echo "built $dir/$dist"
