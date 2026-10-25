# shellcheck shell=bash
# jobs.sh — box job records: written by `mroom job run`, read by `mroom job list` and the watchdog, which
# share the rules below. Sourced after util.sh.
#
# A record is ~/.local/state/mroom/jobs/<name>.json: {name, every (seconds or null), running, started,
# ended, exit, log}. While a run goes, it keeps the last finished run and says when this one started.

jobs_dir() {
  local dir
  dir="$(mroom_state_dir)/jobs"
  mkdir -p -m 700 "$dir" && printf '%s\n' "$dir"
}

# job_read <record>: sets JOB_NAME, JOB_EVERY, JOB_RUNNING, JOB_STARTED, JOB_ENDED and JOB_EXIT (empty when
# absent). Returns 1 when the file is not a readable job record.
job_read() {
  local fields
  fields="$(jq -r 'select(type == "object" and (.name | type) == "string")
    | [.name, (.every // ""), (.running // false), (.started // ""), (.ended // ""), (.exit // "")]
    | map(tostring) | join("\u001f")' "$1" 2>/dev/null)" || return 1
  [ -n "$fields" ] || return 1
  # shellcheck disable=SC2034  # the callers read these
  IFS=$'\x1f' read -r JOB_NAME JOB_EVERY JOB_RUNNING JOB_STARTED JOB_ENDED JOB_EXIT <<<"$fields"
}

# job_failed: true when the last finished run of the record job_read read exited with an error.
job_failed() { [ -n "$JOB_EXIT" ] && [ "$JOB_EXIT" != 0 ]; }

# job_overdue <now>: true when no run finished within twice the job's --every, which also catches a run
# that hangs. A job without --every is never overdue.
job_overdue() {
  local since="${JOB_ENDED:-$JOB_STARTED}"
  [ -n "$JOB_EVERY" ] && [ -n "$since" ] && (($1 - since > 2 * JOB_EVERY))
}
