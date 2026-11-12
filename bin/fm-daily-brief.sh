#!/usr/bin/env bash
# fm-daily-brief.sh - the captain's daily brief: one deterministic page built in
# code from routine source rows, the bearings snapshot, and the value ledger.
#
# Sources. Each brief source is its own routine (bin/fm-routine.sh) whose probe
# is `fm-daily-brief.sh source <name>`, so it gets the scheduler's pacing,
# reachability deferral, backoff, and its own two-phase cursor. The wrapper runs
# the source command (default bin/fm-probe-<name>.sh), which prints the
# source's CURRENT rows as NDJSON objects with a string "id", and exits 3 when
# the source is unreachable right now. On success the wrapper stores the rows
# as state/brief/rows/<name>.ndjson with their time, prints only the rows whose
# id is not in the routine cursor (so new rows wake firstmate through the
# routine), and proposes every current id as the next cursor. A routine whose
# probe ends in `>/dev/null` keeps its source brief-only: no wake, cursor still
# committed. A failed or unreachable run keeps the previous rows, and the brief
# shows them with their age. Row fields the brief reads:
#   id, title, url          every row
#   section                 needs | day | radar (default radar)
#   start, end, allday      day rows: epoch seconds, all-day flag
#   join, attendees, keys   day rows: join link, other attendees, ticket keys
#   clash                   day rows: overlaps another timed event
#   remind_at               epoch; once now >= remind_at and before start, one
#                           needs-you push goes out (the meeting reminder)
#
# Brief. `compose` writes data/brief/<YYYY-MM-DD>.md (local date), rewritten in
# place on each run and never empty: a value line, Needs you (open captain
# decisions, recorded PRs, source rows marked needs, failing routines), Your day
# (meetings, clashes, join links, a prep card for each meeting with other people
# starting within 4h), Work radar, Fleet, and Routines. Third-party text in it
# (ticket and meeting titles) is untrusted; `show` fences it.
#   Notify on new rows: each Needs you row has a key; a key not seen in the
#   previous compose gets one needs-you push through bin/fm-notify.sh, and a key
#   that disappears ends its push stretch, so an unchanged row never pushes
#   twice. The first compose in a home only records the keys. `--post` (the
#   daily 08:00 routine) sends one fyi summary push instead of per-row pushes
#   and starts the "since the last brief" value window. The fleet snapshot can
#   take tens of seconds, so `--background` returns at once and composes in a
#   detached child, which suits a routine tick's time bound.
#
# Value ledger. data/value.jsonl holds one {"ts","kind","key"} line per thing
# done for the captain (landed, meeting-prepped); `value <kind> <key>` appends
# one unless that kind and key are already recorded. The brief's first line
# counts the entries since the last posted brief.
#
# Presence. `show --if-away` prints today's brief, fenced as untrusted records,
# only when the captain was last active on an earlier day or at least
# FM_BRIEF_AWAY_SECS (default 10800) ago, then records now in
# state/last-active; the session-start digest calls it.
#
# Usage:
#   fm-daily-brief.sh source <name> [<command>...]
#   fm-daily-brief.sh compose [--post] [--background]
#   fm-daily-brief.sh show [--if-away]
#   fm-daily-brief.sh value <kind> <key>
#
# FM_BRIEF_NOW=<epoch> overrides the clock for tests. Exit codes: 0 ok, 1
# failure, 2 usage, 3 source unreachable (source only).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
BRIEFS="$DATA/brief"
BSTATE="$STATE/brief"
ROWS="$BSTATE/rows"
VALUE="$DATA/value.jsonl"
export FM_HOME
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {
  echo "usage: fm-daily-brief.sh source <name> [<command>...] | compose [--post] [--background] | show [--if-away] | value <kind> <key>" >&2
  exit 2
}

now() {
  case "${FM_BRIEF_NOW:-}" in ''|*[!0-9]*) date +%s ;; *) printf '%s\n' "$FM_BRIEF_NOW" ;; esac
}

valid_name() {
  case "$1" in ''|[!a-z0-9]*|*[!a-z0-9-]*) return 1 ;; esac
  [ "${#1}" -le 32 ]
}

day_of() { perl -MPOSIX=strftime -e 'print strftime("%Y-%m-%d", localtime($ARGV[0]))' "$1"; }

# notify_set <list> <level> <seed>: reads "<key>\t<title>\t<url>" lines on
# stdin. Pushes each key absent from <list> unless <seed> is 1, ends the push
# stretch of each listed key that is gone, and rewrites <list> with the current
# keys that are notified (a failed push is retried next time).
notify_set() {
  local list=$1 level=$2 seed=$3 key title url tmp nkey
  tmp=$(mktemp "$list.XXXXXX") || return 1
  touch "$list"
  while IFS="$(printf '\t')" read -r key title url; do
    [ -n "$key" ] || continue
    nkey=brief-$(printf '%s' "$key" | tr -c 'A-Za-z0-9._:-' '_' | cut -c1-120)
    if grep -Fqx -- "$key" "$list" || [ "$seed" = 1 ]; then
      printf '%s\n' "$key" >> "$tmp"
    elif "$SCRIPT_DIR/fm-notify.sh" send "$level" "$nkey" "$title" "" "$url" < /dev/null >/dev/null 2>&1; then
      printf '%s\n' "$key" >> "$tmp"
    fi
  done
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    grep -Fqx -- "$key" "$tmp" && continue
    nkey=brief-$(printf '%s' "$key" | tr -c 'A-Za-z0-9._:-' '_' | cut -c1-120)
    "$SCRIPT_DIR/fm-notify.sh" clear "$nkey" < /dev/null >/dev/null 2>&1 || true
  done < "$list"
  mv -f "$tmp" "$list"
}

# --- source -----------------------------------------------------------------------
source_cmd() {
  local name=$1 tmp rc=0 t ids
  shift
  valid_name "$name" || usage
  [ "$#" -gt 0 ] || set -- "$SCRIPT_DIR/fm-probe-$name.sh"
  mkdir -p "$ROWS" || return 1
  tmp=$(mktemp "$ROWS/.$name.XXXXXX") || return 1
  "$@" < /dev/null > "$tmp" || rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp"
    return "$rc"
  fi
  if ! jq -c 'select(type == "object" and (.id | type) == "string")' "$tmp" > "$tmp.ok" 2>/dev/null; then
    rm -f "$tmp" "$tmp.ok"
    echo "fm-daily-brief: source $name printed something other than NDJSON rows" >&2
    return 1
  fi
  rm -f "$tmp"
  t=$(now)
  mv -f "$tmp.ok" "$ROWS/$name.ndjson" && printf '%s\n' "$t" > "$ROWS/$name.at" || return 1
  # Meeting reminders: rows inside their reminder window.
  jq -r --argjson now "$t" \
    'select(.remind_at != null and .remind_at <= $now and (.start // ($now + 1)) > $now)
     | [.id, ("Soon: " + ((.title // .id) | tostring | .[0:100])), (.join // .url // "")] | @tsv' \
    "$ROWS/$name.ndjson" | notify_set "$BSTATE/reminded-$name" needs-you 0
  ids=$(jq -r '.id' "$ROWS/$name.ndjson")
  if [ -n "${FM_ROUTINE_CURSOR_OUT:-}" ]; then
    printf '%s\n' "$ids" > "$FM_ROUTINE_CURSOR_OUT"
  fi
  # New rows only: ids absent from the committed cursor.
  printf '%s\n' "${FM_ROUTINE_CURSOR:-}" \
    | jq -c -R -n --slurpfile rows "$ROWS/$name.ndjson" \
      '[inputs | select(. != "")] as $seen | $rows[] | select(.id as $i | $seen | index($i) | not)'
}

# --- compose ----------------------------------------------------------------------
# The jq program that turns the gathered inputs into normalized brief rows,
# then either the markdown page (mode=page) or one output list (mode=needs|prep).
# shellcheck disable=SC2016 # A jq program: $names are jq variables.
BRIEF_JQ='
def one: tostring | gsub("[\r\n\t]+"; " ") | .[0:140];
def hm: if strflocaltime("%Y-%m-%d") == $date then strflocaltime("%H:%M") else strflocaltime("%a %H:%M") end;
def link: if (.url // "") != "" then " - " + .url else "" end;
def age($at): if $at == null then "never fetched"
  elif ($now - $at) < 1800 then "fresh"
  else "as of " + ($at | strflocaltime("%a %H:%M")) end;

($sources | to_entries | map(.key as $s | .value.rows[] | . + {src: $s})) as $all
| [ $all[] | select((.section // "radar") == "day") ] as $day0
| ($day0 | sort_by(.start // 0)) as $day
| [ $all[] | select((.section // "radar") == "radar") ] as $radar
| ([ ($snap.decisions_open // [])[] |
      {key: ("hold:" + (.key // .id)), title: ("Decision: " + (.summary | one)), url: "", note: (.owner // "")} ]
   + [ ($snap.recorded_prs // [])[] |
      {key: ("pr:" + .url), title: ("PR awaiting you: " + (.id | one)), url: .url, note: ""} ]
   + [ $all[] | select(.section == "needs") |
      {key: .id, title: (.title // .id | one), url: (.url // ""), note: .src} ]
   + [ $routines[] | select(.failing) |
      {key: ("routine:" + .id), title: ("Routine " + .id + " is failing: " + (.last | one)), url: "", note: ""} ]
  ) as $needs
| [ $day[] | select((.allday | not) and ((.attendees // []) | length) > 0
      and .start >= $now and .start - $now <= 14400) ] as $soon
| ($soon | map(. as $m | ($m.keys // []) as $k |
      $m + {related: [ $radar[] | select(.title as $t | any($k[]; . as $kk | $t | contains($kk))) ]})) as $prep
| if $mode == "needs" then $needs[] | [.key, .title, .url] | @tsv
  elif $mode == "prep" then $prep[] | .id
  else
  ([ $day[] | select(.allday | not) ] | length) as $meetings
  | "# Brief " + $date,
    "",
    ($value | if . == "" then "Since the last brief: nothing recorded yet." else "Since the last brief: " + . + "." end),
    "",
    "\($needs | length) need you · \($meetings) meeting(s) · \($radar | length) on the work radar",
    "",
    "## Needs you",
    (if ($needs | length) == 0 then "- Nothing needs you right now." else
      ($needs[] | "- " + .title + link + (if .note != "" then " (" + .note + ")" else "" end)) end),
    "",
    "## Your day",
    (if ($sources | has("calendar") | not) then "- No calendar source yet." else
      (if ($day | length) == 0 then "- No meetings in the next 36 hours." else
        ($day[] | "- " + (if .allday then "all day" else (.start | hm) + "-" + (.end // .start | strflocaltime("%H:%M")) end)
          + " " + (.title // "" | one)
          + (if .clash then " [clash]" else "" end)
          + (if (.join // "") != "" then " - join " + .join else "" end)) end),
      "- Calendar " + age($sources.calendar.at) end),
    ($prep[] | "",
      "### Prep: " + (.title // "" | one) + " at " + (.start | hm),
      "- With: " + ((.attendees // []) | map(one) | join(", ")),
      (if (.related | length) > 0 then (.related[] | "- Open: " + (.title | one) + link) else "- Open: nothing linked on the radar." end),
      "- Next step: " + (if (.related | length) > 0 then "review the open items above before the call." else "skim the invite and agenda." end)),
    "",
    "## Work radar",
    ([ $sources | to_entries[] | select(.key != "calendar" and .key != "toolchain") ] as $work
     | if ($work | length) == 0 then "- No work sources yet." else
       ($work[] | [.value.rows[] | select((.section // "radar") == "radar")] as $r
        | "- " + .key + ": \($r | length) item(s), " + age(.value.at),
          ($r[:10][] | "  - " + (.title // .id | one) + link),
          (if ($r | length) > 10 then "  - and \($r | length - 10) more" else empty end)) end),
    "",
    "## Fleet",
    (if $snap == {} then "- Fleet snapshot unavailable." else
      "- \(($snap.in_flight // []) | length) under way, \(($snap.gates // []) | length) queued behind a gate",
      (($snap.in_flight // [])[:12][] | "  - " + (.name | one) + " (" + (.repo // "" | tostring) + "): " + (.doing // .state // "" | one)),
      (if (($snap.landed // []) | length) > 0 then "- Recently landed:", (($snap.landed // [])[:6][] | "  - " + (.what | one)) else empty end)
    end),
    "",
    "## Routines",
    (if ($routines | length) == 0 then "- No routines registered." else
      ($routines[] | "- " + .id + ": " + (.state | one) + "; " + (.last | one)) end)
  end'

compose() {
  local post=0 background=0 arg t date snap sources routines value since page seed
  for arg in "$@"; do
    case "$arg" in
      --post) post=1 ;;
      --background) background=1 ;;
      *) usage ;;
    esac
  done
  mkdir -p "$BSTATE" "$BRIEFS" || return 1
  if [ "$background" = 1 ]; then
    set --
    [ "$post" = 0 ] || set -- --post
    nohup "${BASH_SOURCE[0]}" compose "$@" > /dev/null 2> "$BSTATE/compose.err" < /dev/null &
    return 0
  fi
  COMPOSE_LOCK="$BSTATE/.compose.lock"
  fm_lock_acquire_wait_max "$COMPOSE_LOCK" 5 || { echo "fm-daily-brief: another compose is running" >&2; return 1; }
  trap 'fm_lock_release "$COMPOSE_LOCK"' EXIT
  t=$(now)
  date=$(day_of "$t")
  snap=$(fm_run_timed "${FM_BRIEF_SNAPSHOT_TIMEOUT:-150}" "$SCRIPT_DIR/fm-bearings-snapshot.sh" --json 2>/dev/null) \
    && printf '%s' "$snap" | jq -e 'type == "object"' >/dev/null 2>&1 || snap='{}'
  sources=$(
    for f in "$ROWS"/*.ndjson; do
      [ -f "$f" ] || continue
      jq -n --arg n "$(basename "$f" .ndjson)" --argjson at "$(cat "${f%.ndjson}.at" 2>/dev/null || echo null)" \
        --slurpfile rows "$f" '{($n): {at: $at, rows: $rows}}'
    done | jq -s 'add // {}')
  routines=$("$SCRIPT_DIR/fm-routine.sh" list 2>/dev/null | awk -F '\t' 'NF >= 4' \
    | jq -R -s '[split("\n")[] | select(. != "") | split("\t")
        | {id: .[0], state: .[2], last: .[3],
           failing: ((.[2] | test("^(invalid|backoff)")) or (.[3] | test("^last: failed")))}]')
  since=$(cat "$BSTATE/posted" 2>/dev/null || echo $((t - 86400)))
  value=$( { [ -f "$VALUE" ] && cat "$VALUE"; } | jq -r -s --argjson since "$since" '
      [.[] | select(.ts > $since)] | group_by(.kind)
      | map("\(length) " + (if .[0].kind == "landed" then "landed" elif .[0].kind == "meeting-prepped" then "meeting(s) prepped" else .[0].kind end))
      | join(", ")' 2>/dev/null)
  set -- --argjson now "$t" --arg date "$date" --arg value "$value" \
    --argjson snap "$snap" --argjson sources "$sources" --argjson routines "${routines:-[]}"
  page=$(jq -n -r "$@" --arg mode page "$BRIEF_JQ") || return 1
  [ -n "$page" ] || return 1
  printf '%s\n' "$page" > "$BRIEFS/.$date.md.tmp" && mv -f "$BRIEFS/.$date.md.tmp" "$BRIEFS/$date.md" || return 1
  jq -n -r "$@" --arg mode prep "$BRIEF_JQ" | while IFS= read -r arg; do
    value_add meeting-prepped "$arg"
  done
  seed=0
  [ -f "$BSTATE/notified" ] || seed=1
  [ "$post" = 0 ] || seed=1
  jq -n -r "$@" --arg mode needs "$BRIEF_JQ" | notify_set "$BSTATE/notified" needs-you "$seed"
  if [ "$post" = 1 ]; then
    arg=$(printf '%s\n' "$page" | sed -n 5p)
    case "$arg" in
      "0 need you · 0 meeting(s) · 0 on the work radar") ;;
      *)
        "$SCRIPT_DIR/fm-notify.sh" send fyi "brief-$date" "Brief: $arg" >/dev/null 2>&1 || true
        "$SCRIPT_DIR/fm-notify.sh" clear "brief-$date" >/dev/null 2>&1 || true ;;
    esac
    printf '%s\n' "$t" > "$BSTATE/posted"
  fi
}

# --- value / show ---------------------------------------------------------------
value_add() {
  local kind=$1 key=$2
  valid_name "$kind" && [ -n "$key" ] || usage
  mkdir -p "$DATA" || return 1
  if [ -f "$VALUE" ] && jq -e -s --arg k "$kind" --arg key "$key" 'any(.[]; .kind == $k and .key == $key)' "$VALUE" >/dev/null 2>&1; then
    return 0
  fi
  jq -n -c --argjson ts "$(now)" --arg kind "$kind" --arg key "$key" '{ts: $ts, kind: $kind, key: $key}' >> "$VALUE"
}

show() {
  local ifaway=0 t last file
  case "${1:-}" in
    '') ;;
    --if-away) ifaway=1 ;;
    *) usage ;;
  esac
  t=$(now)
  file="$BRIEFS/$(day_of "$t").md"
  if [ "$ifaway" = 1 ]; then
    last=$(cat "$STATE/last-active" 2>/dev/null || echo 0)
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    printf '%s\n' "$t" > "$STATE/last-active" 2>/dev/null || true
    [ -f "$file" ] || return 0
    if [ "$(day_of "$last")" = "$(day_of "$t")" ] && [ $((t - last)) -lt "${FM_BRIEF_AWAY_SECS:-10800}" ]; then
      return 0
    fi
  fi
  [ -f "$file" ] || { echo "no brief for today yet"; return 0; }
  "$SCRIPT_DIR/fm-records.sh" wrap brief < "$file"
}

CMD=${1:-}
[ "$#" -eq 0 ] || shift
case "$CMD" in
  source) [ "$#" -ge 1 ] || usage; source_cmd "$@" ;;
  compose) compose "$@" ;;
  show) [ "$#" -le 1 ] || usage; show "$@" ;;
  value) [ "$#" -eq 2 ] || usage; value_add "$1" "$2" ;;
  -h|--help|help) sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//' ;;
  *) usage ;;
esac
