# shellcheck shell=bash
# persona.sh — what the persona's guard (lib/persona) and alert triage (actions/triage) agree on: the alert
# keys, the hidden markers that hold them in an issue's description, and the text checks. Sourced, never run
# on its own; needs bash 5, jq and python3. The caller sets MROOM_ROOT.
#
# An alert key is "<provider>:<numeric id>" for an error issue's first alert, and
# "<provider>:<numeric id>:<kind>:<when>" for a later one (design section 7), such as sentry:1001 and
# sentry:1001:regressed:2026-10-28. Triage's own alarm uses the key triage:<yyyymmdd>. The marker in the
# description of the issue that holds an alert is one line, and only the guard writes it:
#
#   <!-- mroom-alert key=sentry:1001 -->

PERSONA_KEY_RE='^[a-z][a-z0-9_-]{0,31}:[0-9]{1,20}(:[a-z][a-z0-9-]{0,31}:[A-Za-z0-9._-]{1,40})?$'

persona_key_ok() { [[ "$1" =~ $PERSONA_KEY_RE ]]; }

# persona_base_key <key>: the error's own key, the first two parts (sentry:1001).
persona_base_key() { local rest="${1#*:}"; printf '%s:%s' "${1%%:*}" "${rest%%:*}"; }

persona_marker() { printf '<!-- mroom-alert key=%s -->' "$1"; }

# persona_unmarked: stdin to stdout, with every HTML comment's opening escaped (&lt;!--), so no text the
# guard is given can hold a marker, however it nests one: only the guard writes them. Deleting matches
# instead would not do: one pass over <!-<!-- x -->- ... leaves a marker behind.
persona_unmarked() { sed 's/<!--/\&lt;!--/g'; }

# persona_text <mode> [<arg>...]: lib/core/text.py (redact | no-token | defang <host>...), isolated.
persona_text() { python3 -I "$MROOM_ROOT/lib/core/text.py" "$@"; }

# persona_config <key> <default>: one value from mroom.toml; an empty default means nothing when it is not set.
persona_config() {
  if [ -z "$2" ]; then python3 "$MROOM_ROOT/lib/core/config.py" get "$1" --optional
  else python3 "$MROOM_ROOT/lib/core/config.py" get "$1" --default "$2"; fi
}

# persona_name: persona.name, or Agent.
persona_name() { persona_config persona.name Agent; }
