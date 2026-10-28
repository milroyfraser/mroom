#!/usr/bin/env bash
# run.sh — runs every tests/*-test.sh and exits 1 if any fails. Offline; each test uses a temp HOME.
#   tests/run.sh                 all of them
#   tests/run.sh config box      only config-test.sh and box-test.sh
#   tests/run.sh --skip qa-up    all of them but qa-up-test.sh, which CI runs in a job of its own
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failed=()
names=() skip=" "

while [ "$#" -gt 0 ]; do
  case "$1" in
    --skip)
      [ -n "${2:-}" ] || { echo "run.sh: --skip takes a test name" >&2; exit 2; }
      [ -f "$HERE/$2-test.sh" ] || { echo "run.sh: no such test file: $HERE/$2-test.sh" >&2; exit 2; }
      skip+="$2 "
      shift 2
      ;;
    *) names+=("$1"); shift ;;
  esac
done

files=()
if [ "${#names[@]}" -gt 0 ]; then
  for name in "${names[@]}"; do files+=("$HERE/$name-test.sh"); done
else
  for file in "$HERE"/*-test.sh; do
    name="$(basename "$file" -test.sh)"
    [[ "$skip" == *" $name "* ]] || files+=("$file")
  done
fi

for file in "${files[@]}"; do
  [ -f "$file" ] || { echo "run.sh: no such test file: $file" >&2; exit 2; }
  echo "== $(basename "$file")"
  if ! bash "$file"; then failed+=("$(basename "$file")"); fi
done

if [ "${#failed[@]}" -gt 0 ]; then
  echo "FAILED: ${failed[*]}"
  exit 1
fi
echo "all passed"
