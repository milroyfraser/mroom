# shellcheck shell=bash
# util.sh — helpers the box commands share: time, durations, the state folder, box.env and secret files.
# Sourced by lib/job and lib/watchdog, never run on its own. Needs bash 5 and GNU coreutils (design
# section 3). The caller sets MROOM_ROOT (the mroom checkout or install) before sourcing it.

# mroom_now: the time in epoch seconds. MROOM_NOW sets it in tests.
mroom_now() { printf '%s\n' "${MROOM_NOW:-$(date +%s)}"; }

# mroom_state_dir: the folder where box commands keep state between runs, created (mode 700) when missing.
mroom_state_dir() {
  local dir="${XDG_STATE_HOME:-$HOME/.local/state}/mroom"
  mkdir -p -m 700 "$dir" && printf '%s\n' "$dir"
}

# dur_secs <duration>: 90, 90s, 10m, 2h or 1d as whole seconds. Returns 1 for anything else.
dur_secs() {
  [[ "$1" =~ ^([0-9]{1,9})([smhd]?)$ ]] || return 1
  local n=$((10#${BASH_REMATCH[1]}))
  case "${BASH_REMATCH[2]}" in
    "" | s) printf '%s\n' "$n" ;;
    m) printf '%s\n' $((n * 60)) ;;
    h) printf '%s\n' $((n * 3600)) ;;
    d) printf '%s\n' $((n * 86400)) ;;
  esac
}

# dur_text <seconds>: a short duration: 45s, 12m, 3h 12m, 2d 4h. A negative one (the clock went back)
# reads as 0s.
dur_text() {
  local s=$1
  if ((s < 0)); then s=0; fi
  if ((s < 60)); then
    printf '%ss\n' "$s"
  elif ((s < 3600)); then
    printf '%sm\n' $((s / 60))
  elif ((s < 86400)); then
    two_units $((s / 3600)) h $(((s % 3600) / 60)) m
  else
    two_units $((s / 86400)) d $(((s % 86400) / 3600)) h
  fi
}

# two_units <big> <unit> <small> <unit>: "3h 12m", or just "3h" when the small part is 0.
two_units() {
  if (($3 == 0)); then printf '%s%s\n' "$1" "$2"; else printf '%s%s %s%s\n' "$1" "$2" "$3" "$4"; fi
}

# utc_text <epoch>: the time as "2026-10-25 14:02 UTC".
utc_text() { date -u -d "@$1" '+%Y-%m-%d %H:%M UTC'; }

# home_short <path>: the path with the home folder written as ~.
home_short() { printf '%s\n' "${1/#"$HOME"/\~}"; }

# secret_file_ok <file>: true when the file belongs to this user and no one else may read it (600 or 400).
secret_file_ok() {
  local mode
  mode="$(stat -c '%u %a' "$1" 2>/dev/null)" || return 1
  [ "$mode" = "$(id -u) 600" ] || [ "$mode" = "$(id -u) 400" ]
}

# load_box: reads box.env through the one reader (lib/core/config.py) into the array BOX. A box.env that
# is broken stops the caller: config.py has already said which line is wrong.
# shellcheck disable=SC2034  # BOX is read by the scripts that source this file
declare -gA BOX=()
load_box() {
  local text line
  text="$(python3 "$MROOM_ROOT/lib/core/config.py" box)" || return 1
  BOX=()
  while IFS= read -r line; do
    [ -n "$line" ] && BOX["${line%%=*}"]="${line#*=}"
  done <<<"$text"
  return 0
}

# need <tool...>: stops with one line naming every tool this host lacks.
need() {
  local tool missing=()
  for tool in "$@"; do command -v "$tool" >/dev/null 2>&1 || missing+=("$tool"); done
  [ "${#missing[@]}" = 0 ] && return 0
  echo "mroom: this command needs ${missing[*]}, which this host does not have (design section 3)" >&2
  exit 1
}
