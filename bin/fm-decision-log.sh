#!/usr/bin/env bash
# fm-decision-log.sh - append-only log of captain decisions and of autonomous
# firstmate actions, readable by later sessions.
#
# A row points at its backlog item instead of copying it: the captain-held
# task (bin/fm-captain-hold.sh) keeps the exact words and the resolution
# block, and this log keeps one short line per decision so a later session can
# see what was decided, when, through which channel, and by whom.
#
# Usage:
#   fm-decision-log.sh add --item <id> --choice <text> --source <source>
#                          [--action <verb>] [--actor captain|firstmate]
#                          [--rule <text>]
#       Append one row. <id> is the backlog item (usually the captain-held
#       task id) or the task the action touched. --action defaults to
#       `decided`, --actor to `captain`. --rule names the standing rule or
#       routine that authorized an autonomous action.
#   fm-decision-log.sh list [--item <id>] [--since YYYY-MM-DD] [--limit <n>]
#       Print matching rows oldest first, one per line:
#       <date> <item> <actor>/<action>: <choice> (via <source>[; rule <rule>])
#       --limit keeps the newest <n> rows (default 20).
#   fm-decision-log.sh frame <task-id> --question <text> --until YYYY-MM-DD
#                            [--repo <repo>]   (options on stdin)
#       Decision support: turn one open decision into a short options record
#       and hold it for the captain. Stdin holds 2 to 4 option lines,
#       `<option> | <cost> | <reversibility> | <pre-mortem>`, every field
#       non-empty; the pre-mortem is the likeliest way that option fails. The
#       record becomes the hold reason through bin/fm-captain-hold.sh hold
#       --until <date> (the revisit date; a missing task is created with the
#       question as its title), so bearings, the brief, and the task show the
#       options, and one `framed` row by firstmate is appended here. The
#       captain's later answer goes through bin/fm-captain-hold.sh answer as
#       for any captain call, which adds its own row.
#
# Record: data/decisions.jsonl (durable, private), one JSON object per line:
#   {"ts":"<UTC ISO-8601>","date":"YYYY-MM-DD","item":..,"action":..,
#    "choice":..,"source":..,"actor":"captain|firstmate","rule":..,
#    "unattended":true|false}
# `unattended` is true when this home's away record (state/.afk) exists.
# Text fields are flattened to one line and capped at 300 characters.
#
# Writers call `add` fire-and-forget (`|| true`), so the log never blocks the
# action it records. Producers: bin/fm-captain-hold.sh (each newly recorded
# captain answer), bin/fm-incident.sh (each automatic retry).
#
# Exit codes: 0 ok, 1 write failed, 2 usage.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
LOG="$DATA/decisions.jsonl"

usage() {
  sed -n '/^# Usage:/,/^# Record:/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//' >&2
  exit 2
}

flat() {  # <text>: one line, no control characters, at most 300 characters
  printf '%s' "$1" | tr '\t\n\r' '   ' | tr -d '\000-\037\177' | cut -c1-300
}

trim() { flat "$1" | sed 's/^ *//; s/ *$//'; }

cmd_add() {
  local item='' choice='' source='' action=decided actor=captain rule='' unattended=false
  while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || usage
    case "$1" in
      --item) item=$2 ;;
      --choice) choice=$2 ;;
      --source) source=$2 ;;
      --action) action=$2 ;;
      --actor) actor=$2 ;;
      --rule) rule=$2 ;;
      *) usage ;;
    esac
    shift 2
  done
  [ -n "$item" ] && [ -n "$choice" ] && [ -n "$source" ] || usage
  case "$actor" in captain|firstmate) ;; *) usage ;; esac
  [ ! -e "$STATE/.afk" ] || unattended=true
  mkdir -p "$DATA" || return 1
  jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg date "$(date -u +%Y-%m-%d)" \
    --arg item "$(flat "$item")" --arg action "$(flat "$action")" --arg choice "$(flat "$choice")" \
    --arg source "$(flat "$source")" --arg actor "$actor" --arg rule "$(flat "$rule")" \
    --argjson unattended "$unattended" \
    '{ts:$ts,date:$date,item:$item,action:$action,choice:$choice,source:$source,actor:$actor,rule:$rule,unattended:$unattended}' \
    >> "$LOG" || return 1
}

cmd_list() {
  local item='' since='' limit=20
  while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || usage
    case "$1" in
      --item) item=$2 ;;
      --since) since=$2 ;;
      --limit) limit=$2 ;;
      *) usage ;;
    esac
    shift 2
  done
  case "$limit" in ''|*[!0-9]*) usage ;; esac
  [ -s "$LOG" ] || return 0
  jq -r --arg item "$item" --arg since "$since" \
    'select(($item == "" or .item == $item) and ($since == "" or .date >= $since))
     | "\(.date) \(.item) \(.actor)/\(.action): \(.choice) (via \(.source)\(if (.rule // "") != "" then "; rule \(.rule)" else "" end))"' \
    "$LOG" | tail -n "$limit"
}

cmd_frame() {
  local id=${1:-} question='' until='' repo='' line opt cost rev pm n=0 names='' reason title=()
  [ -n "$id" ] || usage
  shift
  while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || usage
    case "$1" in
      --question) question=$2 ;;
      --until) until=$2 ;;
      --repo) repo=$2 ;;
      *) usage ;;
    esac
    shift 2
  done
  [ -n "$question" ] && [ -n "$until" ] || usage
  question=$(flat "$question")
  reason="Decide: $question"
  while IFS= read -r line; do
    [ -n "$(printf '%s' "$line" | tr -d '[:space:]')" ] || continue
    IFS='|' read -r opt cost rev pm <<EOF
$line
EOF
    opt=$(trim "$opt") cost=$(trim "$cost") rev=$(trim "$rev") pm=$(trim "${pm:-}")
    if [ -z "$opt" ] || [ -z "$cost" ] || [ -z "$rev" ] || [ -z "$pm" ]; then
      echo "fm-decision-log: an option line needs <option> | <cost> | <reversibility> | <pre-mortem>: $line" >&2
      return 1
    fi
    n=$((n + 1))
    reason="$reason
$n. $opt - cost: $cost; reversibility: $rev; pre-mortem: $pm"
    names="${names:+$names / }$opt"
  done
  if [ "$n" -lt 2 ] || [ "$n" -gt 4 ]; then
    echo "fm-decision-log: frame needs 2 to 4 options on stdin, got $n" >&2
    return 1
  fi
  reason="$reason
Revisit by $until."
  "$SCRIPT_DIR/fm-tasks-axi.sh" show "$id" >/dev/null 2>&1 || title=(--title "$question")
  "$SCRIPT_DIR/fm-captain-hold.sh" hold "$id" --reason "$reason" --until "$until" \
    ${repo:+--repo "$repo"} "${title[@]+"${title[@]}"}" || return 1
  cmd_add --item "$id" --action framed --actor firstmate --source decision-support \
    --choice "$n options: $names; revisit $until"
}

CMD=${1:-}
[ "$#" -eq 0 ] || shift
case "$CMD" in
  add) cmd_add "$@" ;;
  list) cmd_list "$@" ;;
  frame) cmd_frame "$@" ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
