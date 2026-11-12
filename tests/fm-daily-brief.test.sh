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

fm_test_run test_needs_row_pushes_once test_source_new_rows_wake_once test_unreachable_source_is_deferred
