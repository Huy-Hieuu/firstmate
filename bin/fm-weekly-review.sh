#!/usr/bin/env bash
# fm-weekly-review.sh - the captain's weekly review: one page a week built in
# code from records firstmate already keeps.
#
# `compose` writes data/brief/week-<YYYY>-<WW>.md (the ISO week of the local
# date), rewritten in place, covering the 7 days before now. Each line comes
# from an existing owner, and a line or section with nothing to report is left
# out, so a quiet week is a short page:
#   Done              backlog tasks closed in the week (bin/fm-tasks-axi.sh)
#                     and the value ledger (fm-daily-brief.sh value-since)
#   Slipped           follow-ups past their nudge or due date (the brief's
#                     `followups` source rows)
#   People            what the captain owes and awaits (`followups` and
#                     `upwork` source rows)
#   Upwork            the pipeline counts (`upwork` source rows)
#   Decisions         bin/fm-decision-log.sh rows of the week
#   Incidents         worker incidents of the week (state/incidents.jsonl)
#   Next week         meeting hours from the calendar feeds in config/calendar
#                     (bin/fm-probe-calendar.sh, a read-only fetch)
#   Investments       bin/fm-invest.sh summary when data/invest/watch.toml exists
#   Skill suggestions data/skill-review/ files written in the week
#   Goals             data/goals.md (bin/fm-goals.sh), to check the week against
# Third-party text in it (ticket, meeting, mail, and news titles) is untrusted;
# `show` fences it. Source rows are read as the brief's routines last stored
# them, so a source that is not enabled contributes nothing.
#
# Usage:
#   fm-weekly-review.sh compose [--post] [--background]
#       --post (the weekly routine) sends one fyi push with the headline;
#       --background returns at once and composes in a detached child, which
#       suits a routine tick's time bound
#   fm-weekly-review.sh show       this week's page, fenced as untrusted records
#
# FM_BRIEF_NOW=<epoch> overrides the clock for tests. Exit codes: 0 ok, 1
# failure, 2 usage.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
ROWS="$STATE/brief/rows"
export FM_HOME
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {
  echo "usage: fm-weekly-review.sh compose [--post] [--background] | show" >&2
  exit 2
}

now() {
  case "${FM_BRIEF_NOW:-}" in ''|*[!0-9]*) date +%s ;; *) printf '%s\n' "$FM_BRIEF_NOW" ;; esac
}

fmt() { perl -MPOSIX=strftime -e 'print strftime($ARGV[0], localtime($ARGV[1]))' "$1" "$2"; }

rows() {  # <source> <section>: that source's stored rows in that section
  [ -f "$ROWS/$1.ndjson" ] || return 0
  jq -c --arg s "$2" 'select((.section // "radar") == $s)' "$ROWS/$1.ndjson" 2>/dev/null
}

titles() {  # <max>: "- <title>" lines from rows on stdin, then "- and N more"
  jq -r -s --argjson n "$1" '
    def one: tostring | gsub("[\r\n\t]+"; " ") | .[0:140];
    (.[:$n][] | "- " + (.title // .id | one)), (if length > $n then "- and \(length - $n) more" else empty end)'
}

count() { awk 'NF { n++ } END { print n + 0 }'; }

section() {  # <heading> <body>: printed only when <body> has text
  [ -n "$2" ] || return 0
  printf '\n\n## %s\n%s' "$1" "$2"
}

# done_tasks <since-date>: "<kind>\t<repo>\t<title>" per task closed since then.
done_tasks() {
  "$SCRIPT_DIR/fm-tasks-axi.sh" list --state 'done' --fields closed --limit 200 2>/dev/null \
    | perl -ne 'BEGIN { $since = shift @ARGV }
        next unless /^\s+([^,]+),done,([^,]*),([^,]*),(.*),(\d{4}-\d\d-\d\d)\s*$/;
        next if $5 lt $since; my ($k, $r, $t) = ($2, $3, $4);
        $t =~ s/^"//; $t =~ s/\\n\.\.\. \(truncated.*$//; $t =~ s/"$//; print "$k\t$r\t$t\n"' "$1" 2>/dev/null
}

# next_week <now>: "<hours>\t<meetings>\t<busiest day and hours>" for the
# coming Monday-to-Sunday week, or nothing without a working calendar.
next_week() {
  local t=$1 start end hours out
  [ -s "$FM_HOME/config/calendar" ] || return 0
  start=$(perl -MPOSIX=mktime -e 'my @t = localtime($ARGV[0]); my $w = $t[6] || 7;
    print mktime(0, 0, 0, $t[3] + 8 - $w, $t[4], $t[5], 0, 0, -1)' "$t")
  end=$((start + 7 * 86400))
  hours=$(( (end - t) / 3600 + 1 ))
  out=$(FM_PROBE_CALENDAR_HOURS=$hours FM_BRIEF_NOW=$t fm_run_timed "${FM_WEEKLY_CALENDAR_TIMEOUT:-15}" \
    "$SCRIPT_DIR/fm-probe-calendar.sh" 2>/dev/null) || return 0
  printf '%s\n' "$out" | jq -r -s --argjson s "$start" --argjson e "$end" '
    [.[] | select((.allday | not) and .start >= $s and .start < $e and (.end // .start) > .start)]
    | select(length > 0)
    | (map(.end - .start) | add / 3600 * 10 | round / 10) as $h
    | (group_by(.start | strflocaltime("%a")) | map({d: (.[0].start | strflocaltime("%a")), h: (map(.end - .start) | add / 3600 * 10 | round / 10)})
       | max_by(.h)) as $b
    | "\($h)\t\(length)\t\($b.d) (\($b.h) h)"' 2>/dev/null
}

compose() {
  local post=0 background=0 arg t since sdate week label page head part
  local done_list value slipped owe waiting up decisions incidents nw invest skills goals body
  for arg in "$@"; do
    case "$arg" in
      --post) post=1 ;;
      --background) background=1 ;;
      *) usage ;;
    esac
  done
  if [ "$background" = 1 ]; then
    mkdir -p "$STATE/brief" || return 1
    set --
    [ "$post" = 0 ] || set -- --post
    nohup "${BASH_SOURCE[0]}" compose "$@" > /dev/null 2> "$STATE/brief/weekly.err" < /dev/null &
    return 0
  fi
  t=$(now)
  since=$((t - 7 * 86400))
  sdate=$(fmt %Y-%m-%d "$since")
  week=$(fmt %G-%V "$t")
  label="$(fmt '%a %d %b' "$since") - $(fmt '%a %d %b' "$t")"

  done_list=$(done_tasks "$sdate")
  value=$("$SCRIPT_DIR/fm-daily-brief.sh" value-since "$since" 2>/dev/null)
  body=''
  if [ -n "$done_list" ]; then
    body="- $(printf '%s\n' "$done_list" | count) task(s) finished: $(printf '%s\n' "$done_list" \
      | awk -F '\t' '{ n[$1]++ } END { for (k in n) printf "%s%d %s", (s++ ? ", " : ""), n[k], k }')
$(printf '%s\n' "$done_list" | head -n 12 | awk -F '\t' '{ printf "  - %s%s\n", $3, ($2 != "" && $2 != "-" ? " (" $2 ")" : "") }')"
  fi
  [ -z "$value" ] || body="${body:+$body
}- Done for you: $value"
  page=$(section Done "$body")

  slipped=$(rows followups needs)
  body=''
  [ -z "$slipped" ] || body=$(printf '%s\n' "$slipped" | titles 8)
  page="$page$(section Slipped "$body")"

  owe=$( { rows followups owe; rows upwork owe; } )
  waiting=$( { rows followups waiting; rows upwork waiting; } )
  body=''
  [ -z "$owe" ] || body="- You owe $(printf '%s\n' "$owe" | count):
$(printf '%s\n' "$owe" | titles 8 | sed 's/^/  /')"
  [ -z "$waiting" ] || body="${body:+$body
}- Waiting on others: $(printf '%s\n' "$waiting" | count)"
  page="$page$(section People "$body")"

  up=$( { rows upwork needs; rows upwork waiting; rows upwork owe; } | jq -r -s '
      map(.section) | group_by(.) | map("\(length) " + ({"needs": "client answer(s) to read", "waiting": "awaiting a client reply",
        "owe": "drafted, not sent"}[.[0]])) | select(length > 0) | "- " + join(", ")' 2>/dev/null)
  page="$page$(section Upwork "$up")"

  decisions=$("$SCRIPT_DIR/fm-decision-log.sh" list --since "$sdate" --limit 50 2>/dev/null)
  [ -z "$decisions" ] || decisions="- $(printf '%s\n' "$decisions" | count) decision(s) recorded:
$(printf '%s\n' "$decisions" | tail -n 10 | sed 's/^/  - /')"
  page="$page$(section Decisions "$decisions")"

  incidents=''
  [ ! -f "$STATE/incidents.jsonl" ] || incidents=$(jq -r -s --argjson s "$since" '
      [.[] | select(.ts >= $s)] | select(length > 0)
      | "- \(length) worker incident(s): " + (group_by(.task) | map(.[0].task + " (\(length))") | join(", "))' \
      "$STATE/incidents.jsonl" 2>/dev/null)
  page="$page$(section Incidents "$incidents")"

  nw=$(next_week "$t")
  [ -z "$nw" ] || nw=$(printf '%s\n' "$nw" | awk -F '\t' '{ printf "- %s h of meetings in %s meeting(s); busiest %s\n", $1, $2, $3 }')
  page="$page$(section "Next week" "$nw")"

  invest=''
  [ ! -f "$DATA/invest/watch.toml" ] || invest=$(fm_run_timed "${FM_WEEKLY_INVEST_TIMEOUT:-30}" "$SCRIPT_DIR/fm-invest.sh" summary 2>/dev/null \
    | sed '1s/^/- /')
  page="$page$(section Investments "$invest")"

  skills=$(perl -e 'my $s = shift; print map { "$_\n" } sort grep { (stat)[9] >= $s } @ARGV' \
    "$since" "$DATA"/skill-review/*.md 2>/dev/null)
  [ -z "$skills" ] || skills="- $(printf '%s\n' "$skills" | count) skill suggestion file(s) await your review:
$(printf '%s\n' "$skills" | sed "s|^$DATA/|  - data/|")"
  page="$page$(section "Skill suggestions" "$skills")"

  goals=$("$SCRIPT_DIR/fm-goals.sh" list 2>/dev/null | head -n 12 | awk -F '\t' '{ printf "- %s: %s\n", $1, $2 }')
  page="$page$(section "Goals to check the week against" "$goals")"

  head=''
  for part in \
    "$(printf '%s\n' "$done_list" | count) finished" \
    "$(printf '%s\n' "$slipped" | count) slipped" \
    "$(printf '%s\n' "$owe" | count) you owe" \
    "$(printf '%s\n' "$nw" | sed -n 's/^- \([0-9.]*\) h of meetings.*/\1/p') h of meetings next week"; do
    case "$part" in 0\ *|\ *) continue ;; esac
    head="${head:+$head, }$part"
  done
  [ -n "$head" ] || head="a quiet week: nothing recorded"
  page="# Week $week ($label)

$head.$page"
  mkdir -p "$DATA/brief" || return 1
  printf '%s\n' "$page" > "$DATA/brief/.week-$week.md.tmp" && mv -f "$DATA/brief/.week-$week.md.tmp" "$DATA/brief/week-$week.md" || return 1
  if [ "$post" = 1 ]; then
    "$SCRIPT_DIR/fm-notify.sh" send fyi "week-$week" "Weekly review: $head" >/dev/null 2>&1 || true
    "$SCRIPT_DIR/fm-notify.sh" clear "week-$week" >/dev/null 2>&1 || true
  fi
}

show() {
  local file
  file="$DATA/brief/week-$(fmt %G-%V "$(now)").md"
  [ -f "$file" ] || { echo "no weekly review for this week yet"; return 0; }
  "$SCRIPT_DIR/fm-records.sh" wrap brief < "$file"
}

CMD=${1:-}
[ "$#" -eq 0 ] || shift
case "$CMD" in
  compose) compose "$@" ;;
  show) [ "$#" -eq 0 ] || usage; show ;;
  -h|--help|help) sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//' ;;
  *) usage ;;
esac
