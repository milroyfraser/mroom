# shellcheck shell=bash
# chat.sh — the chat adapter (design section 7): chat_post sends one message to the box's log channel, and
# chat_problem says why it cannot. Sourced after util.sh and load_box.
#
# v1 talks to Slack as a bot with chat:write, invited to the channel. The token is the SLACK_BOT_TOKEN=...
# line of ~/.config/mroom/secrets/slack.env, which must belong to the box user with mode 600; only
# _chat_token reads it, and the token never reaches a command line. The channel id is box.env's
# MROOM_SLACK_LOG_CHANNEL. A post waits at most 5 seconds.

CHAT_SECRETS="$HOME/.config/mroom/secrets/slack.env"
CHAT_ERROR=""

# _chat_token: the bot token, or nothing. The one reader of secrets/slack.env.
_chat_token() {
  [ -r "$CHAT_SECRETS" ] || return 0
  sed -n 's/^SLACK_BOT_TOKEN=//p' "$CHAT_SECRETS" | head -n1
}

# chat_problem: one line saying why chat cannot post, or nothing when it can.
chat_problem() {
  if [ -z "${BOX[MROOM_SLACK_LOG_CHANNEL]:-}" ]; then
    echo "box.env has no MROOM_SLACK_LOG_CHANNEL"
  elif [ ! -r "$CHAT_SECRETS" ]; then
    echo "there is no ~/.config/mroom/secrets/slack.env"
  elif ! secret_file_ok "$CHAT_SECRETS"; then
    echo "~/.config/mroom/secrets/slack.env must belong to you and have mode 600 (chmod 600 it)"
  elif [ -z "$(_chat_token)" ]; then
    echo "~/.config/mroom/secrets/slack.env has no SLACK_BOT_TOKEN= line"
  fi
}

chat_ready() { [ -z "$(chat_problem)" ]; }

# chat_post <mrkdwn>: posts one message. Returns 0 when Slack took it; 1 when Slack refused it or did not
# answer, with the reason in CHAT_ERROR; 2 when chat is not set up. The message goes to jq and curl on
# stdin and the token through a file descriptor, so neither appears in the process list.
chat_post() {
  local token channel resp
  chat_ready || return 2
  channel="${BOX[MROOM_SLACK_LOG_CHANNEL]}"
  token="$(_chat_token)"
  if ! resp="$(printf '%s' "$1" \
    | jq -Rsc --arg c "$channel" '{channel: $c, text: ., unfurl_links: false, unfurl_media: false}' \
    | curl -sS --max-time 5 -X POST --data-binary @- \
      -K <(printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json; charset=utf-8"\n' "$token") \
      https://slack.com/api/chat.postMessage 2>/dev/null)"; then
    CHAT_ERROR="no answer from Slack"
    return 1
  fi
  [ "$(jq -r '.ok' <<<"$resp" 2>/dev/null)" = true ] && return 0
  CHAT_ERROR="$(jq -r '.error // "an answer without a reason"' <<<"$resp" 2>/dev/null || echo "an answer it could not read")"
  return 1
}
