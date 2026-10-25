#!/usr/bin/env bash
# ci-first-push.sh <owner/repo> <since ISO-8601> — how long a pull request's FIRST push waits on CI.
#
# For every PR opened since <since>, it takes the first run (attempt 1) of the backend and e2e
# workflows on that PR's first head commit, skips runs that did no work (changed-areas skipped the
# tests), and prints per-PR rows plus a summary: the slowest backend test job, the e2e job, its apt
# step and whether the dependency caches were restored. A PR's first push is the case cache warming
# is for: re-runs of one PR are always warm and say nothing about it.
#
#   tools/ci-first-push.sh example/shop 2026-10-23T22:52:17Z
#
# Env: BACKEND_WORKFLOW (ci-backend.yml), E2E_WORKFLOW (ci-e2e.yml), BACKEND_JOB_PREFIX
# ("Backend tests"), E2E_JOB (e2e), APT_STEP ("Install Playwright system deps"), MIN_WORK_SECONDS
# (90: a job shorter than this skipped its work). Needs gh (signed in) and jq.
set -euo pipefail

REPO="${1:?usage: ci-first-push.sh <owner/repo> <since ISO-8601>}"
SINCE="${2:?usage: ci-first-push.sh <owner/repo> <since ISO-8601>}"
BACKEND_WORKFLOW="${BACKEND_WORKFLOW:-ci-backend.yml}"
E2E_WORKFLOW="${E2E_WORKFLOW:-ci-e2e.yml}"
BACKEND_JOB_PREFIX="${BACKEND_JOB_PREFIX:-Backend tests}"
E2E_JOB="${E2E_JOB:-e2e}"
APT_STEP="${APT_STEP:-Install Playwright system deps}"
MIN_WORK_SECONDS="${MIN_WORK_SECONDS:-90}"

# first_run <workflow> <pr number>: the id of the earliest run of <workflow> for the PR's first commit.
first_run() {
  local first_sha
  first_sha="$(gh api "repos/$REPO/pulls/$2/commits?per_page=1" --jq '.[0].sha')"
  gh api "repos/$REPO/actions/workflows/$1/runs?head_sha=$first_sha&per_page=20" \
    --jq '[.workflow_runs[] | select(.event == "pull_request")] | sort_by(.created_at) | .[0].id // empty'
}

# attempt 1 only: a re-run is warm by construction.
jobs_of() { gh api "repos/$REPO/actions/runs/$1/attempts/1/jobs?per_page=100"; }

secs='((.completed_at|fromdate) - (.started_at|fromdate))'

printf '%-6s %-9s %-9s %-7s %s\n' PR backend e2e apt caches
rows=""
for pr in $(gh pr list --repo "$REPO" --state all --search "created:>=${SINCE%%T*}" --limit 200 \
    --json number,createdAt --jq ".[] | select(.createdAt >= \"$SINCE\") | .number"); do
  b="-" e="-" apt="-" caches="-"
  if run="$(first_run "$BACKEND_WORKFLOW" "$pr")" && [ -n "$run" ]; then
    b="$(jobs_of "$run" | jq -r --arg p "$BACKEND_JOB_PREFIX" --argjson min "$MIN_WORK_SECONDS" \
      "[.jobs[] | select(.name | startswith(\$p)) | select(.started_at and .completed_at) | $secs] | max // 0 | if . < \$min then \"-\" else tostring end")"
  fi
  if run="$(first_run "$E2E_WORKFLOW" "$pr")" && [ -n "$run" ]; then
    j="$(jobs_of "$run" | jq -c --arg n "$E2E_JOB" '[.jobs[] | select(.name == $n)][0] // empty')"
    if [ -n "$j" ]; then
      d="$(jq -r "$secs" <<<"$j")"
      if [ "$d" -ge "$MIN_WORK_SECONDS" ]; then
        e="$d"
        apt="$(jq -r --arg s "$APT_STEP" "[.steps[] | select(.name == \$s and .started_at and .completed_at) | $secs][0] // \"-\"" <<<"$j")"
        # The restore step logs whether it hit; the job log is the only place that says so.
        hits="$(gh api "repos/$REPO/actions/jobs/$(jq -r .id <<<"$j")/logs" 2>/dev/null | grep -c 'Cache restored from key' || true)"
        caches="${hits} restored"
      fi
    fi
  fi
  printf '%-6s %-9s %-9s %-7s %s\n' "#$pr" "$b" "$e" "$apt" "$caches"
  rows+="$b $e $apt"$'\n'
done

summary() { # summary <column> <label>; plain awk and sort, so it runs on macOS too
  awk -v c="$1" '$c ~ /^[0-9]+$/ {print $c}' | sort -n | awk -v l="$2" '{a[++n]=$1; s+=$1} END {
    if (!n) { printf "%-22s no runs with work yet\n", l; exit }
    p50 = int(n*0.5+0.5); p90 = int(n*0.9+0.5); if (p50 < 1) p50 = 1; if (p90 < 1) p90 = 1
    printf "%-22s n=%d mean=%ds p50=%ds p90=%ds max=%ds\n", l, n, s/n, a[p50], a[p90], a[n] }'
}
echo
summary 1 "slowest backend shard" <<<"$rows"
summary 2 "e2e job" <<<"$rows"
summary 3 "apt step" <<<"$rows"
