#!/usr/bin/env bash
# run.sh — runs every tests/*-test.sh and exits 1 if any fails. Offline; each test uses a temp HOME.
#   tests/run.sh                 all of them
#   tests/run.sh config box      only config-test.sh and box-test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failed=()

if [ "$#" -gt 0 ]; then
  files=()
  for name in "$@"; do files+=("$HERE/$name-test.sh"); done
else
  files=("$HERE"/*-test.sh)
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
