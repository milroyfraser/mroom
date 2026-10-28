# shellcheck shell=bash
# version.sh — asks what an app runs (design 9, 10). Sourced, never run on its own: by deploy-verify and /release,
# which ask the app's app.version_path, and by browser QA, which asks the gate, since in a QA environment the pull
# request's own code would answer the app's path. The caller sets MROOM_ROOT and, for qa_version, has called
# qa_gate_init (lib/core/qa.sh).

# version_url <origin>: the address to ask for the running release, <origin><app.version_path>, with a query no
# cache has seen (?mroom=<time>-<random>). <origin> is https://<host>, or http:// for a test, with an optional port
# and no path.
version_url() {
  local path
  [[ "$1" =~ ^https?://[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?(:[0-9]{1,5})?$ ]] \
    || { echo "version_url: $1 is not an origin such as https://shop.example.dev" >&2; return 2; }
  path="$(python3 "$MROOM_ROOT/lib/core/config.py" get app.version_path)" || return 1
  printf '%s%s?mroom=%s-%s\n' "$1" "$path" "$(mroom_now)" "$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')"
}

# version_parse: reads the version endpoint's answer, {"release": "<tag>" or null, "commit": "<sha>"}, on stdin and
# prints release=<tag, or none> and commit=<sha>. Returns 1 for anything else: an answer that is not JSON, a commit
# that is not a full SHA, or a tag that is not plain (letters, digits and . _ + -, at most 100).
version_parse() {
  local answer
  answer="$(head -c 65536 | jq -er 'if type == "object" and (.commit | type) == "string"
      and (.commit | test("\\A[0-9a-f]{40}\\z"))
      and (.release == null or ((.release | type) == "string" and (.release | test("\\A[A-Za-z0-9._+-]{1,100}\\z"))))
    then "release=\(.release // "none")\ncommit=\(.commit)" else error("no") end' 2>/dev/null)" || return 1
  printf '%s\n' "$answer"
}

# qa_version <N>: what QA environment N runs, as version_parse prints it: release=none, since a tarball has no tag,
# and the commit the gate recorded when it unpacked the tree (env-sha), never what the environment's code says.
# Returns 1 while no code went in.
qa_version() {
  local out commit
  out="$(qa_gate env-sha "$1")" || return 1
  commit="$(sed -n 's/^commit=//p' <<<"$out" | head -n1)"
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf 'release=none\ncommit=%s\n' "$commit"
}
