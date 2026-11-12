#!/usr/bin/env bash
# tests/fm-daily-brief.test.sh - behavior tests for bin/fm-daily-brief.sh: a
# Needs you row pushes once and an unchanged row never pushes again, a brief
# source's new rows wake firstmate once through its routine cursor, and an
# unreachable source is deferred while the brief keeps its last rows.
# shellcheck disable=SC2016 # Channel and probe bodies expand later.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-daily-brief-tests)
BRIEF="$ROOT/bin/fm-daily-brief.sh"
ROUTINE="$ROOT/bin/fm-routine.sh"
unset FM_TASK_ID FM_ROUTINE_CURSOR FM_ROUTINE_CURSOR_OUT

# new_home <name>: a home whose config/notify records each push to sent.log.
new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/state" "$home/data/routines"
  printf 'command:printf "%%s|%%s\\n" "$1" "$2" >> %s/sent.log\n' "$home" > "$home/config/notify"
  printf '%s\n' "$home"
}

brief() {  # <home> <epoch> <args...>
  local home=$1 t=$2
  shift 2
  FM_HOME="$home" FM_BRIEF_NOW="$t" FM_HOST_ID=mac-a bash "$BRIEF" "$@"
}

sent() { cat "$1/sent.log" 2>/dev/null | awk 'END { print NR }'; }

test_needs_row_pushes_once() {
  local home t=1794790800
  home=$(new_home needs)
  printf '{"id":"tool:disk","section":"needs","title":"Disk low"}\n' > "$home/rows"
  brief "$home" "$t" source toolchain cat "$home/rows" >/dev/null
  brief "$home" "$t" compose
  assert_equals 0 "$(sent "$home")" "the first compose only records the rows it finds"
  assert_contains "$(cat "$home/data/brief/"*.md)" "Disk low" "the brief lists the Needs you row"

  printf '{"id":"tool:quota","section":"needs","title":"Quota low"}\n' >> "$home/rows"
  brief "$home" "$t" source toolchain cat "$home/rows" >/dev/null
  brief "$home" $((t + 900)) compose
  brief "$home" $((t + 1800)) compose
  assert_equals 1 "$(sent "$home")" "a new row pushes once and an unchanged row never again"
  assert_equals "needs-you|Quota low" "$(cat "$home/sent.log")" "the push names the new row"

  printf '{"id":"tool:disk","section":"needs","title":"Disk low"}\n' > "$home/rows"
  brief "$home" "$t" source toolchain cat "$home/rows" >/dev/null
  brief "$home" $((t + 2700)) compose
  printf '{"id":"tool:quota","section":"needs","title":"Quota low"}\n' >> "$home/rows"
  brief "$home" "$t" source toolchain cat "$home/rows" >/dev/null
  brief "$home" $((t + 3600)) compose
  assert_equals 2 "$(sent "$home")" "a row that cleared and came back pushes again"
  pass "a Needs you row pushes once per appearance"
}

test_source_new_rows_wake_once() {
  local home t=1794790800
  home=$(new_home wake)
  printf '{"id":"gerrit:1","title":"Change 1"}\n' > "$home/rows"
  printf 'schedule=every 15m\nprobe=%s source gerrit cat %s\n' "$BRIEF" "$home/rows" > "$home/data/routines/gerrit.routine"
  FM_HOME="$home" FM_HOST_ID=mac-a FM_ROUTINE_NOW="$t" bash "$ROUTINE" tick >/dev/null
  assert_equals 1 "$(awk -F '\t' '$4 == "routine:gerrit"' "$home/state/.wake-queue" | awk 'END { print NR }')" "a new row wakes firstmate"
  : > "$home/state/.wake-queue"
  FM_HOME="$home" FM_HOST_ID=mac-a FM_ROUTINE_NOW=$((t + 900)) bash "$ROUTINE" tick >/dev/null
  FM_HOME="$home" FM_HOST_ID=mac-a FM_ROUTINE_NOW=$((t + 1800)) bash "$ROUTINE" tick >/dev/null
  assert_equals 0 "$(awk 'END { print NR }' "$home/state/.wake-queue")" "an unchanged row does not wake again"
  printf '{"id":"gerrit:2","title":"Change 2"}\n' >> "$home/rows"
  FM_HOME="$home" FM_HOST_ID=mac-a FM_ROUTINE_NOW=$((t + 2700)) bash "$ROUTINE" tick >/dev/null
  assert_contains "$(FM_HOME="$home" bash "$ROUTINE" show gerrit)" "gerrit:2" "the wake carries only the new row"
  assert_not_contains "$(FM_HOME="$home" bash "$ROUTINE" show gerrit)" "gerrit:1" "the old row is not re-presented"
  pass "a brief source's new rows wake firstmate once"
}

test_unreachable_source_is_deferred() {
  local home t=1794790800 rc=0 out
  home=$(new_home deferred)
  printf '{"id":"jira:A-1","title":"A-1 Fix it"}\n' > "$home/rows"
  brief "$home" "$t" source jira cat "$home/rows" >/dev/null
  brief "$home" $((t + 7200)) source jira sh -c 'exit 3' >/dev/null || rc=$?
  assert_equals 3 "$rc" "an unreachable source reports deferral, not failure"
  brief "$home" $((t + 7200)) compose
  out=$(cat "$home/data/brief/"*.md)
  assert_contains "$out" "A-1 Fix it" "the brief keeps the last rows"
  assert_contains "$out" "jira: 1 item(s), as of" "the brief shows how old they are"
  pass "an unreachable source is deferred and the brief keeps its last rows"
}

test_dream_only_proposes_quoted_rows() {
  local home t ask out before
  home=$(new_home dream)
  t=$(date +%s)
  mkdir -p "$home/data/t1" "$home/data/t2"
  printf "# Task\n## Captain's intent\nrun the Upwork search for me again\n## Firstmate spec\nx\n" > "$home/data/t1/brief.md"
  printf "# Task\n## Captain's intent\nplease run the Upwork search again today\n" > "$home/data/t2/brief.md"
  printf -- '- freeze ended <!--u:2000-01-01-->\n- keep pull request descriptions short and focused always <!--a:2026-11-01-->\n- keep pull request descriptions short and focused please <!--a:2026-11-01-->\n' > "$home/data/learnings.md"
  before=$(cat "$home/data/learnings.md")
  ask="$home/ask.sh"
  printf '#!/bin/sh\nprintf "%%s\\n" "IDEA | Schedule the Upwork search daily | run the Upwork search for me again" "PREF | Prefers dark mode | I love dark mode"\n' > "$ask"
  chmod +x "$ask"
  FM_HOME="$home" FM_BRIEF_NOW="$t" FM_DREAM_ASK="$ask" bash "$BRIEF" source dream >/dev/null
  brief "$home" "$t" compose
  out=$(cat "$home/data/brief/"*.md)
  assert_contains "$out" "## Ideas and memory" "the brief has no Ideas and memory section"
  assert_contains "$out" "Idea: Schedule the Upwork search daily" "a quoted idea was not proposed"
  assert_not_contains "$out" "dark mode" "a preference whose quote is in no brief was proposed"
  assert_contains "$out" "Memory: archive data/learnings.md:1: expired 2000-01-01" "an expired entry was not proposed for archiving"
  assert_contains "$out" "Memory: merge the overlapping entries data/learnings.md:2 and data/learnings.md:3" "overlapping entries were not proposed for a merge"
  assert_not_contains "$out" "dream: " "the dream was listed on the work radar"
  assert_equals "$before" "$(cat "$home/data/learnings.md")" "the dream edited a memory file"
  rm -f "$home/data/t2/brief.md"
  FM_HOME="$home" FM_BRIEF_NOW="$t" bash "$BRIEF" source dream >/dev/null
  brief "$home" "$t" compose
  assert_contains "$(cat "$home/data/brief/"*.md)" "Ideas are off until the side-question model is set up" "an unconfigured home does not say how to enable ideas"
  pass "the dream proposes memory upkeep and quoted ideas in the brief without editing memory"
}

fm_test_run test_needs_row_pushes_once test_source_new_rows_wake_once test_unreachable_source_is_deferred test_dream_only_proposes_quoted_rows
