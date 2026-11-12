#!/usr/bin/env bash
# fm-incident.sh - incident ledger and the one-automatic-retry verdict for a
# stuck, dead, or wedged worker.
#
# The relaunch itself stays in firstmate's turn (bin/fm-control.sh relaunch);
# this script only records the incident and prints which recovery step the
# ledger allows, so repeated recovery cannot turn into an unbounded loop.
#
# Usage:
#   fm-incident.sh record <task> <cause> [--captain] [--outward]
#       Append one incident and print one verdict line, `<verdict>: <advice>`.
#       --captain   only the captain can fix the cause (a login, credential,
#                   or permission he must grant).
#       --outward   an outward action (push, PR, sent message) happened that
#                   the task record does not show.
#   fm-incident.sh list [<task>]
#       Print the last 24 hours of incidents, one per line:
#       <UTC time> <task> <verdict>: <cause>
#
# Verdicts, first match wins:
#   captain   --captain: tell the captain what he must fix, and do not relaunch.
#   no-retry  an outward action is visible: --outward, a `pr=` line in
#             state/<task>.meta, or a status line naming a pull request,
#             merge request, or Gerrit change URL or the word "pushed". Never
#             rerun; reconcile what already went out and report.
#   muted     more than 5 incidents for <task> in the last hour: already
#             escalated, say nothing new.
#   escalate  2 retries already in the last hour: stop retrying and follow the
#             recovery playbook's failure step.
#   retry     relaunch once with a note telling the worker to check what it
#             already did before repeating any step. A retry verdict also
#             appends a bin/fm-decision-log.sh row (actor firstmate).
#
# Record: state/incidents.jsonl (per machine), one JSON object per line:
#   {"ts":<epoch>,"task":..,"cause":..,"verdict":..}
# FM_INCIDENT_NOW=<epoch> overrides the clock for tests.
#
# Exit codes: 0 verdict printed, 1 write failed, 2 usage.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LEDGER="$STATE/incidents.jsonl"
MAX_RETRIES=2
MUTE_AFTER=5

usage() {
  sed -n '/^# Usage:/,/^# Verdicts/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//' >&2
  exit 2
}

valid_task() {
  case "$1" in ''|*[!A-Za-z0-9._-]*|.*) return 1 ;; esac
}

outward_visible() {  # <task>
  grep -q '^pr=.' "$STATE/$1.meta" 2>/dev/null && return 0
  grep -Eq 'https?://[^ ]+/(pull|merge_requests|\+)/[0-9]+|(^|[^a-z])pushed([^a-z]|$)' \
    "$STATE/$1.status" 2>/dev/null
}

count_since() {  # <task> <since-epoch> [<verdict>]
  [ -s "$LEDGER" ] || { echo 0; return; }
  jq -s --arg task "$1" --argjson since "$2" --arg verdict "${3:-}" \
    '[.[] | select(.task == $task and .ts >= $since and ($verdict == "" or .verdict == $verdict))] | length' \
    "$LEDGER" 2>/dev/null || echo 0
}

cmd_record() {
  local task=${1:-} cause=${2:-} captain=0 outward=0 now hour verdict advice
  [ "$#" -ge 2 ] || usage
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --captain) captain=1 ;;
      --outward) outward=1 ;;
      *) usage ;;
    esac
    shift
  done
  valid_task "$task" || usage
  [ -n "$cause" ] || usage
  cause=$(printf '%s' "$cause" | tr '\t\n\r' '   ' | tr -d '\000-\037\177' | cut -c1-300)
  now=${FM_INCIDENT_NOW:-$(date +%s)}
  hour=$((now - 3600))
  if [ "$captain" = 1 ]; then
    verdict=captain
    advice="only the captain can fix this; tell him what to do and do not relaunch"
  elif [ "$outward" = 1 ] || outward_visible "$task"; then
    verdict=no-retry
    advice="an outward action already happened; never rerun - reconcile what went out and report"
  elif [ "$(count_since "$task" "$hour")" -ge "$MUTE_AFTER" ]; then
    verdict=muted
    advice="more than $MUTE_AFTER incidents this hour; already escalated, say nothing new"
  elif [ "$(count_since "$task" "$hour" retry)" -ge "$MAX_RETRIES" ]; then
    verdict=escalate
    advice="$MAX_RETRIES retries this hour already; stop retrying and report the failure"
  else
    verdict=retry
    advice="relaunch once: fm-control.sh $task relaunch --note 'You were relaunched after: $cause. Check what you already did (git log, status file, open PRs, sent messages) before repeating any step.'"
  fi
  mkdir -p "$STATE" || return 1
  jq -nc --argjson ts "$now" --arg task "$task" --arg cause "$cause" --arg verdict "$verdict" \
    '{ts:$ts,task:$task,cause:$cause,verdict:$verdict}' >> "$LEDGER" || return 1
  if [ "$verdict" = retry ]; then
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-decision-log.sh" add \
      --item "$task" --action relaunch --actor firstmate --choice "$cause" \
      --source incident-ledger --rule "one automatic retry" >/dev/null 2>&1 || true
  fi
  printf '%s: %s\n' "$verdict" "$advice"
}

cmd_list() {
  local task=${1:-} now
  [ "$#" -le 1 ] || usage
  [ -s "$LEDGER" ] || return 0
  now=${FM_INCIDENT_NOW:-$(date +%s)}
  jq -r --arg task "$task" --argjson since "$((now - 86400))" \
    'select(.ts >= $since and ($task == "" or .task == $task))
     | "\(.ts | todate) \(.task) \(.verdict): \(.cause)"' "$LEDGER"
}

CMD=${1:-}
[ "$#" -eq 0 ] || shift
case "$CMD" in
  record) cmd_record "$@" ;;
  list) cmd_list "$@" ;;
  *) usage ;;
esac
