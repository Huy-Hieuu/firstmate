#!/usr/bin/env bash
# tests/fm-focus.test.sh - behavior tests for bin/fm-focus.sh: a morning with
# no free focus block suggests the one meeting whose removal opens it and the
# brief shows that under Your day, a morning with room suggests nothing, and
# all-day events never count as busy.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-focus-tests)
FOCUS="$ROOT/bin/fm-focus.sh"
BRIEF="$ROOT/bin/fm-daily-brief.sh"

at() { perl -MPOSIX=mktime -e 'print mktime(0, $ARGV[1], $ARGV[0], 12 + $ARGV[2], 10, 126)' "$1" "$2" "${3:-0}"; }

# Thursday 12 Nov 2026, 18:00 local; the target is Friday morning.
NOW=$(at 18 0)

# new_home <name>: a home whose calendar source holds a 09:30 and a 10:30
# half-hour meeting on Friday plus an all-day event.
new_home() {
  local home="$TMP_ROOT/$1" a b
  mkdir -p "$home/config" "$home/state" "$home/data"
  a=$(at 9 30 1)
  b=$(at 10 30 1)
  {
    printf '{"id":"c1","section":"day","title":"Standup","start":%s,"end":%s}\n' "$a" $((a + 1800))
    printf '{"id":"c2","section":"day","title":"Weekly sync","start":%s,"end":%s}\n' "$b" $((b + 1800))
    printf '{"id":"c3","section":"day","title":"Offsite","allday":true,"start":%s,"end":%s}\n' "$a" $((a + 86400))
  } > "$home/cal.ndjson"
  FM_HOME="$home" FM_BRIEF_NOW="$NOW" bash "$BRIEF" source calendar cat "$home/cal.ndjson" >/dev/null
  printf '%s\n' "$home"
}

focus() { FM_HOME="$1" FM_BRIEF_NOW="$NOW" bash "$FOCUS" rows; }

test_crowded_morning_suggests_one_meeting() {
  local home out
  home=$(new_home crowded)
  out=$(focus "$home")
  assert_contains "$out" '"section":"focus"' "no focus row for a crowded morning"
  assert_contains "$out" "Tomorrow has no 2 h focus block 09:00-12:00; declining or moving 10:30 Weekly sync would open one" "the suggestion names the wrong meeting"
  FM_HOME="$home" FM_BRIEF_NOW="$NOW" bash "$BRIEF" source focus bash "$FOCUS" rows >/dev/null
  FM_HOME="$home" FM_BRIEF_NOW="$NOW" FM_BRIEF_SNAPSHOT_TIMEOUT=1 bash "$BRIEF" compose
  assert_contains "$(cat "$home/data/brief/"*.md)" "- Focus: Tomorrow has no 2 h focus block" "the brief does not show the focus suggestion"
  pass "a crowded morning suggests the one meeting whose removal opens a focus block"
}

test_room_for_focus_suggests_nothing() {
  local home
  home=$(new_home roomy)
  printf 'block=60\n' > "$home/config/focus"
  assert_equals "" "$(focus "$home")" "a morning with a free hour still got a suggestion"
  printf 'block=180\n' > "$home/config/focus"
  assert_contains "$(focus "$home")" "no single meeting frees one" "a block no single meeting frees was misreported"
  pass "a morning with room suggests nothing and an impossible block says so"
}

fm_test_run test_crowded_morning_suggests_one_meeting test_room_for_focus_suggests_nothing
