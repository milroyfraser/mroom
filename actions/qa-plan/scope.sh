#!/usr/bin/env bash
# scope.sh — the path rules of the QA plan (actions/qa-plan; design 8.2): could a user notice this change? The
# cheap, certain half of the plan, which needs no model.
#
#   scope.sh < paths          one changed path per line, as plan.sh lists a pull request's files
#
# Prints two lines, for GITHUB_OUTPUT:
#   scope=none|maybe
#   reason=<each area and how many of the paths are in it, the areas a user could see first>
#
# none when every path is in an area no user can see: tests, docs, CI, agent and developer tooling. maybe when
# any path could reach the app. A path outside the app's folders that no rule names is a maybe too, since a new
# top-level folder should be looked at, not waved through; so is an empty list, which means it could not be
# read, one of 3000 paths or more, the most GitHub lists, and a name that holds a control character. Otherwise the
# first rule that matches a path decides it:
#   1. qa.visible_paths in mroom.toml: paths a user can see, whatever the rules below say
#   2. qa.hidden_paths: paths no user can see, such as the app's console commands
#   3. mroom's own rules, below, for where a Laravel + Vite app keeps what (app.backend_dir, app.frontend_dir)
# A pattern is a shell pattern in which * also matches /, so docs/* is everything under docs/. Needs
# MROOM_ROOT's config reader and the app's mroom.toml (MROOM_CONFIG, or found from here).
set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
CONFIG="$(cd "$(dirname "$SELF")/../.." && pwd)/lib/core/config.py"
MAX_PATHS=3000

get() { python3 "$CONFIG" get "$1" --default "$2"; }
visible=() hidden=()
text="$(get qa.visible_paths '[]')"
[ -z "$text" ] || mapfile -t visible <<<"$text"
text="$(get qa.hidden_paths '[]')"
[ -z "$text" ] || mapfile -t hidden <<<"$text"
backend="$(get app.backend_dir .)"
frontend="$(get app.frontend_dir .)"
# A folder's paths start with <folder>/; the repository's root, ".", is every path.
b="" f=""
[ "$backend" = . ] || b="$backend/"
case "$frontend" in
  . | "") f="$b" ;;
  *) f="$frontend/" ;;
esac

# area <path>: sets kind (visible or hidden) and name (the area) for the path.
app_area=backend
[ "$f" != "$b" ] || app_area=app
area() {
  local p="$1" pattern
  kind=visible
  # A name no rule can be trusted to read: GitHub's list shows a name with a newline as two lines, which plan.sh
  # passes on as one line holding a control character instead.
  if [[ "$p" == *[[:cntrl:]]* ]]; then name="a name with a control character"; return; fi
  for pattern in "${visible[@]}"; do
    # shellcheck disable=SC2053  # the pattern is meant to match as a pattern
    if [[ -n "$pattern" && "$p" == $pattern ]]; then name=qa.visible_paths; return; fi
  done
  kind=hidden
  for pattern in "${hidden[@]}"; do
    # shellcheck disable=SC2053
    if [[ -n "$pattern" && "$p" == $pattern ]]; then name=qa.hidden_paths; return; fi
  done
  case "$p" in
    "${b}tests/"* | "${b}phpunit.xml" | "${b}phpunit.xml.dist" | "${b}phpunit.dist.xml" | __tests__/* | */__tests__/* \
      | *.test.[jt]s | *.test.[jt]sx | *.spec.[jt]s | *.spec.[jt]sx) name=tests ;;

    # Views and mail templates, which can be Markdown, reach users.
    "${b}resources/"*) kind=visible name="$app_area" ;;

    *.md | docs/* | LICENSE | LICENSE.* | */LICENSE) name=docs ;;

    .github/*) name="CI (.github)" ;;
    .claude/* | .cursor/* | .mcp.json | .mcp.json.*) name="agent tooling" ;;
    .mroom/* | mroom.toml | .husky/* | .editorconfig | .gitignore | */.gitignore | .gitattributes | */.gitattributes \
      | .prettierrc* | */.prettierrc* | .prettierignore | */.prettierignore | eslint.config.* | */eslint.config.* \
      | .eslintrc* | */.eslintrc* | "${b}pint.json" | "${b}phpstan.neon"* | "${b}phpstan.dist.neon" | "${b}rector.php" \
      | docker-compose.yml | compose.yaml) name="dev tooling" ;;

    # Everything else in the app's folders is the app: its code, config, migrations, routes, locales and assets.
    "$f"*) kind=visible name="$app_area"; if [ "$f" != "$b" ]; then name=frontend; fi ;;
    "$b"*) kind=visible name=backend ;;
    *) kind=visible name="other (not classified)" ;;
  esac
}

declare -A counts=()
visible_n=0 total=0
while IFS= read -r path || [ -n "$path" ]; do
  [ -n "$path" ] || continue
  area "$path"
  counts["$kind $name"]=$((${counts["$kind $name"]:-0} + 1))
  total=$((total + 1))
  [ "$kind" = hidden ] || visible_n=$((visible_n + 1))
done

if ((total == 0)); then
  printf 'scope=maybe\nreason=no changed paths could be read\n'
  exit 0
fi

# "1 backend, 1 frontend, 2 docs": the areas a user could see first, then by name.
summary="$(for key in "${!counts[@]}"; do
  printf '%s\t%s\t%s\n' "${key%% *}" "${key#* }" "${counts[$key]}"
done | LC_ALL=C sort -t $'\t' -k1,1r -k2,2 | awk -F '\t' '{ printf "%s%s %s", (NR > 1 ? ", " : ""), $3, $2 }')"

if ((total >= MAX_PATHS)); then
  printf 'scope=maybe\nreason=%s paths, the most GitHub lists, so some were not seen: %s\n' "$total" "$summary"
elif ((visible_n > 0)); then
  printf 'scope=maybe\nreason=%s of %s paths could reach the app: %s\n' "$visible_n" "$total" "$summary"
else
  printf 'scope=none\nreason=only paths no user can see changed: %s\n' "$summary"
fi
