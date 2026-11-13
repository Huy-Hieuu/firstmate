#!/usr/bin/env bash
# fm-phone.sh - the captain's two-way phone channel: a Telegram bot that
# firstmate long-polls outbound, so no port is opened and no webhook exists.
#
# Inert until configured. Without config/phone every subcommand prints one
# notice and does nothing: no token is read and no connection is made.
# config/phone (local, gitignored) holds key=value lines:
#   token_cmd=<command>  run through `sh -c`; prints the bot token from the
#                        captain's own secret store, for example
#                        `security find-generic-password -s fm-telegram-bot -w`.
#                        The token never sits in a file here, and it reaches
#                        curl through a private config file, never argv.
#   chat_id=<id>         the one allowlisted chat, the captain's own
# Messages from any other chat are dropped unread and never answered.
#
# Usage:
#   fm-phone.sh poll
#       One long poll (FM_PHONE_POLL_SECS, default 10) for new messages, run by
#       a routine (bin/fm-routine.sh). Each allowlisted text message is handled
#       once, in order, and answered on the phone:
#         status            the bin/fm-inbox.sh status record view
#         <task-id>: <text> a keyed answer to that captain-held task, fed to
#                           bin/fm-captain-hold.sh answers --source phone, the
#                           single keyed-answer intake; it closes the call
#                           with the captain's words and the decision log
#                           records it. Refused, and kept as a note instead,
#                           when the task is a ship or scout work item (its
#                           hold may be a landing approval), when its title or
#                           hold reason mentions a merge, landing, release,
#                           deploy, rollback, or PROD, or when the text asks
#                           to defer (`later...`, `defer...`), which firstmate
#                           handles with --until in a turn
#         anything else     a bin/fm-inbox.sh note, which wakes firstmate
#       Every handled message also becomes a note (request id
#       phone-<update_id>, so a replay never duplicates it), marked as coming
#       from the phone: a phone message never approves a merge or a PROD
#       change, and firstmate asks for those in an attended session.
#   fm-phone.sh push <needs-you|fyi> <title> [<body>] [<url>]
#       Send one message to the allowlisted chat; its arguments match
#       config/notify's command channel, so
#       `command:<abs path>/bin/fm-phone.sh push "$1" "$2" "$3" "$4"`
#       makes it a bin/fm-notify.sh channel.
#
# State: state/phone/offset is the next Telegram update id to read.
# FM_PHONE_API (default https://api.telegram.org) is the Bot API base.
# Exit codes: 0 ok or not configured (poll), 1 failure or not configured
# (push), 2 usage.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONF="$FM_HOME/config/phone"
PSTATE="$STATE/phone"
API=${FM_PHONE_API:-https://api.telegram.org}
POLL_SECS=${FM_PHONE_POLL_SECS:-10}
export FM_HOME
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  echo "usage: fm-phone.sh poll | push <needs-you|fyi> <title> [<body>] [<url>]" >&2
  exit 2
}

conf() {  # <key>
  awk -v k="$1" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) } END { print v }' "$CONF"
}

# configured: sets TOKEN and CHAT, or prints why not and returns 1.
configured() {
  [ -f "$CONF" ] || { echo "fm-phone: not configured (no config/phone); nothing done" >&2; return 1; }
  CHAT=$(conf chat_id)
  case "$CHAT" in ''|*[!0-9-]*) echo "fm-phone: config/phone needs a numeric chat_id" >&2; return 1 ;; esac
  [ -n "$(conf token_cmd)" ] || { echo "fm-phone: config/phone needs token_cmd" >&2; return 1; }
  TOKEN=$(sh -c "$(conf token_cmd)" < /dev/null 2>/dev/null | head -n 1 | tr -d '[:space:]')
  case "$TOKEN" in ''|*[!A-Za-z0-9:_-]*) echo "fm-phone: token_cmd printed no usable token" >&2; return 1 ;; esac
}

api() {  # <method> [<json body>]: the response body
  local cfg rc=0
  cfg=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-phone.XXXXXX") || return 1
  printf 'url = "%s/bot%s/%s"\n' "$API" "$TOKEN" "$1" > "$cfg"
  if [ "$#" -ge 2 ]; then
    printf '%s' "$2" | curl -fsS -m 20 -K "$cfg" -H 'Content-Type: application/json' --data-binary @- || rc=$?
  else
    curl -fsS -m $((POLL_SECS + 10)) -K "$cfg" || rc=$?
  fi
  rm -f "$cfg"
  return "$rc"
}

send() {  # <text>
  api sendMessage "$(jq -nc --arg c "$CHAT" --arg t "$(printf '%s' "$1" | cut -c1-3800)" \
    '{chat_id: ($c | tonumber), text: $t, disable_web_page_preview: true}')" >/dev/null
}

note() {  # <update-id> <text>
  "$SCRIPT_DIR/fm-inbox.sh" note --request-id "phone-$1" -- \
    "From the captain's phone (a phone message never approves a merge or a PROD change): $2" >/dev/null 2>&1
}

# keyed <update-id> <task-id> <answer>: the phone reply for one keyed answer.
keyed() {
  local uid=$1 id=$2 answer=$3 show kind about out
  show=$("$SCRIPT_DIR/fm-tasks-axi.sh" show "$id" 2>/dev/null) || show=''
  if ! printf '%s\n' "$show" | grep -qx '  held: yes'; then
    note "$uid" "$id: $answer"
    printf 'Noted for firstmate (no captain call is open under %s).' "$id"
    return
  fi
  kind=$(printf '%s\n' "$show" | sed -n 's/^  kind: //p')
  about=$(printf '%s\n' "$show" | sed -n 's/^  title: //p; s/^  hold_reason: //p')
  if [ "$kind" = ship ] || [ "$kind" = scout ] \
    || printf '%s' "$about" | grep -Eqi '(^|[^a-z])(merge[ds]?|merging|land|landing|release|deploy(s|ed|ment)?|rollback|roll back|prod|production)([^a-z]|$)'; then
    note "$uid" "answer for $id, NOT applied because merges, landings, and PROD changes need the captain's word in an attended session: $answer"
    printf 'Not applied: %s needs your word in an attended session (work items, merges, and PROD are never approved from the phone). Saved for firstmate.' "$id"
    return
  fi
  case "$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')" in
    later*|defer*)
      note "$uid" "defer $id: $answer"
      printf 'Noted: firstmate will defer %s.' "$id"
      return ;;
  esac
  out=$(printf '%s\t%s\tphone\n' "$id" "$answer" \
    | "$SCRIPT_DIR/fm-captain-hold.sh" answers --source "phone (Telegram chat $CHAT)" 2>&1)
  case "$out" in
    closed:*)
      note "$uid" "answered $id from the phone (recorded): $answer"
      printf 'Recorded your answer on %s.' "$id" ;;
    *)
      note "$uid" "answer for $id could not be recorded ($(printf '%s' "$out" | head -n 1 | cut -c1-200)): $answer"
      printf 'Could not record that on %s; saved it for firstmate.' "$id" ;;
  esac
}

poll() {
  local body off uid chat text reply id us=$'\037'
  configured || return 0
  mkdir -p "$PSTATE" || return 1
  POLL_LOCK="$PSTATE/.poll.lock"
  fm_lock_acquire_wait_max "$POLL_LOCK" 1 || return 0
  trap 'fm_lock_release "$POLL_LOCK"' EXIT
  off=$(cat "$PSTATE/offset" 2>/dev/null || echo 0)
  case "$off" in ''|*[!0-9]*) off=0 ;; esac
  body=$(api "getUpdates?offset=$off&timeout=$POLL_SECS&allowed_updates=%5B%22message%22%5D") \
    || { echo "fm-phone: getUpdates failed" >&2; return 3; }
  printf '%s' "$body" | jq -e '.ok == true' >/dev/null 2>&1 || { echo "fm-phone: Telegram refused getUpdates" >&2; return 1; }
  printf '%s' "$body" | jq -r '.result | sort_by(.update_id)[]
      | [(.update_id | tostring), (.message.chat.id // "" | tostring), (.message.text // "" | gsub("[\u001f\r\n]+"; " "))]
      | join("\u001f")' \
    | while IFS=$us read -r uid chat text; do
      case "$uid" in ''|*[!0-9]*) continue ;; esac
      if [ "$chat" = "$CHAT" ]; then
        text=$(printf '%s' "$text" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        id=$(printf '%s' "$text" | sed -n 's/^\([A-Za-z0-9][A-Za-z0-9._-]*\):[[:space:]]*\(..*\)$/\1/p')
        if [ -z "$text" ]; then
          reply='Only text messages are read.'
        elif [ "$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')" = status ] || [ "$text" = /status ]; then
          reply=$("$SCRIPT_DIR/fm-inbox.sh" status 2>/dev/null | head -c 3500)
        elif [ -n "$id" ]; then
          reply=$(keyed "$uid" "$id" "$(printf '%s' "$text" | sed 's/^[^:]*:[[:space:]]*//')")
        elif note "$uid" "$text"; then
          reply='Noted for firstmate.'
        else
          reply='Could not save that note; try again.'
        fi
        send "$reply" || echo "fm-phone: reply to update $uid failed" >&2
      fi
      printf '%s\n' $((uid + 1)) > "$PSTATE/offset.tmp" && mv -f "$PSTATE/offset.tmp" "$PSTATE/offset"
    done
}

push() {  # <level> <title> [<body>] [<url>]
  local level=$1 text
  case "$level" in needs-you|fyi) ;; *) usage ;; esac
  configured || return 1
  text=$2
  [ "$level" = fyi ] || text="Needs you: $text"
  [ -z "${3:-}" ] || text="$text
$3"
  [ -z "${4:-}" ] || text="$text
$4"
  send "$text"
}

CMD=${1:-}
[ "$#" -eq 0 ] || shift
case "$CMD" in
  poll) [ "$#" -eq 0 ] || usage; poll ;;
  push) [ "$#" -ge 2 ] && [ "$#" -le 4 ] || usage; push "$@" ;;
  -h|--help|help) sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//' ;;
  *) usage ;;
esac
