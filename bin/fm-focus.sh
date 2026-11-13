#!/usr/bin/env bash
# fm-focus.sh - focus suggestions for the captain's next workday morning, read
# from the calendar rows the daily brief already fetched. Suggestions only: it
# never edits, declines, or moves a calendar event.
#
# The rule. The target is the next workday window that has not ended yet and
# that the calendar rows still cover (state/brief/rows/calendar.ndjson, which
# reaches 36 hours past its fetch time). When the timed meetings in that window
# leave no free stretch of at least <block> minutes, it prints one daily brief
# row (section focus, shown under Your day) naming the shortest meeting whose
# removal would open such a stretch, or saying no single meeting would. All-day
# events never block focus time. Otherwise it prints nothing.
#
# config/focus (local, gitignored, optional) holds key=value lines:
#   window=HH:MM-HH:MM   default 09:00-12:00
#   block=<minutes>      default 120
#   days=<mon,...>       workdays, default mon,tue,wed,thu,fri
#
# Usage:
#   fm-focus.sh rows     the brief source; run it as
#                        `fm-daily-brief.sh source focus bin/fm-focus.sh rows`
# It is off until that routine exists, and it needs the brief's calendar
# source (config/calendar) to have rows; without them it prints nothing.
# FM_BRIEF_NOW=<epoch> overrides the clock for tests. Exit codes: 0 ok, 1
# failure, 2 usage.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CAL="$STATE/brief/rows/calendar.ndjson"
CONF="$FM_HOME/config/focus"

usage() {
  echo "usage: fm-focus.sh rows" >&2
  exit 2
}

conf() {  # <key> <default>
  local v=''
  [ ! -f "$CONF" ] || v=$(awk -v k="$1" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) } END { print v }' "$CONF")
  printf '%s\n' "${v:-$2}"
}

now() {
  case "${FM_BRIEF_NOW:-}" in ''|*[!0-9]*) date +%s ;; *) printf '%s\n' "$FM_BRIEF_NOW" ;; esac
}

rows() {
  local t at window block days target
  t=$(now)
  [ -s "$CAL" ] || return 0
  at=$(cat "${CAL%.ndjson}.at" 2>/dev/null || echo "$t")
  case "$at" in ''|*[!0-9]*) at=$t ;; esac
  window=$(conf window 09:00-12:00)
  block=$(conf block 120)
  days=$(conf days mon,tue,wed,thu,fri)
  case "$window" in [0-2][0-9]:[0-5][0-9]-[0-2][0-9]:[0-5][0-9]) ;; *) echo "fm-focus: bad window $window" >&2; return 1 ;; esac
  case "$block" in ''|*[!0-9]*) echo "fm-focus: bad block $block" >&2; return 1 ;; esac
  # "<window start epoch> <window end epoch>" of the target day, or nothing.
  target=$(perl -MPOSIX=mktime,strftime -e '
    my ($now, $horizon, $win, $days) = @ARGV;
    my ($sh, $sm, $eh, $em) = $win =~ /(\d+):(\d+)-(\d+):(\d+)/;
    for my $d (0 .. 3) {
      my @t = localtime($now);
      my $s = mktime(0, $sm, $sh, $t[3] + $d, $t[4], $t[5], 0, 0, -1);
      my $e = mktime(0, $em, $eh, $t[3] + $d, $t[4], $t[5], 0, 0, -1);
      next unless index($days, lc strftime("%a", localtime $s)) >= 0;
      next if $e <= $now;
      exit 0 if $e > $horizon;
      print "$s $e\n"; exit 0;
    }' "$t" $((at + 36 * 3600)) "$window" "$days") || return 1
  [ -n "$target" ] || return 0
  jq -c -s --argjson now "$t" --argjson ws "${target% *}" --argjson we "${target#* }" \
    --argjson block $((block * 60)) --arg window "$window" '
    def one: tostring | gsub("[\r\n\t]+"; " ") | .[0:60];
    def maxgap: sort_by(.s)
      | reduce .[] as $x ({cur: $ws, max: 0}; .max = ([.max, ($x.s - .cur)] | max) | .cur = ([.cur, $x.e] | max))
      | [.max, ($we - .cur)] | max;
    [ .[] | select((.section // "") == "day" and (.allday | not) and .start < $we and (.end // .start) > $ws)
      | . + {s: ([.start, $ws] | max), e: ([(.end // .start), $we] | min)} ] as $busy
    | select(($busy | maxgap) < $block)
    | ([range(0; $busy | length) as $i | $busy[$i] | select(($busy[:$i] + $busy[$i + 1:] | maxgap) >= $block)]
       | sort_by(.e - .s, .s) | first) as $m
    | ($ws | strflocaltime("%Y-%m-%d")) as $date
    | (if $date == ($now | strflocaltime("%Y-%m-%d")) then "Today"
       elif $date == ($now + 86400 | strflocaltime("%Y-%m-%d")) then "Tomorrow"
       else ($ws | strflocaltime("%A")) end) as $day
    | ($block / 3600 * 10 | round / 10 | tostring) as $h
    | {id: ("focus:" + $date), section: "focus", wake: false,
       title: ($day + " has no " + $h + " h focus block " + $window + "; "
         + (if $m == null then "no single meeting frees one"
            else "declining or moving " + ($m.start | strflocaltime("%H:%M")) + " " + ($m.title // "" | one) + " would open one" end))}' "$CAL"
}

case "${1:-}" in
  rows) [ "$#" -eq 1 ] || usage; rows ;;
  -h|--help|help) sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//' ;;
  *) usage ;;
esac
