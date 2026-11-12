#!/usr/bin/env bash
# tests/fm-routine.test.sh - behavior tests for bin/fm-routine.sh: the cursor
# commits only after the routine's wake is acknowledged, a failing probe backs
# off to a bounded delay and alerts once, and a probe with nothing new stays
# silent.
# shellcheck disable=SC2016 # Probe bodies expand in the probe's own shell.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-routine-tests)
ROUTINE="$ROOT/bin/fm-routine.sh"

new_home() {  # <name> <probe-body> -> home path
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data/routines" "$home/state"
  printf '#!/bin/sh\n%s\n' "$2" > "$home/probe.sh"
  chmod +x "$home/probe.sh"
  printf 'schedule=every 15m\nprobe=%s\n' "$home/probe.sh" > "$home/data/routines/r.routine"
  printf '%s\n' "$home"
}

tick() {  # <home> <epoch>
  FM_HOME="$1" FM_HOST_ID=mac-a FM_ROUTINE_NOW="$2" bash "$ROUTINE" tick
}

queued() {  # <home> <key>: count of queued wake rows for <key>
  awk -F '\t' -v k="$2" '$4 == k' "$1/state/.wake-queue" 2>/dev/null | awk 'END { print NR }'
}

ack() {  # <home>: what acknowledging every handled wake does to the queue
  : > "$1/state/.wake-queue"
}

test_cursor_waits_for_ack() {
  local home out t=1000000
  # Each run reports one item and proposes cursor c<run>.
  home=$(new_home cursor 'n=$(($(cat "$FM_HOME/runs" 2>/dev/null || echo 0) + 1)); echo $n > "$FM_HOME/runs"
echo "seen=$FM_ROUTINE_CURSOR" >> "$FM_HOME/cursors"
echo c$n > "$FM_ROUTINE_CURSOR_OUT"
echo "{\"id\":\"item-$n\"}"')
  out=$(tick "$home" "$t")
  assert_contains "$out" "r 1 new" "items produce a summary line"
  assert_equals 1 "$(queued "$home" routine:r)" "one routine wake is queued"
  [ ! -e "$home/state/routines/r/cursor" ] || fail "cursor must not commit before the wake is handled"

  t=$((t + 3600))
  out=$(tick "$home" "$t")
  assert_equals "" "$out" "an unhandled wake keeps the routine quiet"
  assert_equals 1 "$(cat "$home/runs")" "no new probe while the wake is unhandled"
  [ ! -e "$home/state/routines/r/cursor" ] || fail "cursor still uncommitted while the wake is queued"

  ack "$home"
  t=$((t + 3600))
  tick "$home" "$t" >/dev/null
  assert_equals 2 "$(cat "$home/runs")" "the routine probes again after the acknowledgement"
  assert_equals "seen=c1" "$(sed -n 2p "$home/cursors")" "the next probe sees the committed cursor"
  out=$(FM_HOME="$home" bash "$ROUTINE" show r)
  assert_contains "$out" "UNTRUSTED ROUTINE DATA" "pending items are fenced as untrusted"
  assert_contains "$out" "item-2" "show prints the pending items"
  pass "the cursor commits only after the routine's wake is acknowledged"
}

test_lost_wake_is_re_presented() {
  local home t=1000000
  home=$(new_home lost 'echo c1 > "$FM_ROUTINE_CURSOR_OUT"; echo "{\"id\":\"a\"}"')
  tick "$home" "$t" >/dev/null
  # A crash between storing the batch and recording its wake.
  rm -f "$home/state/routines/r/pending.woke"
  ack "$home"
  tick "$home" $((t + 60)) >/dev/null
  assert_equals 1 "$(queued "$home" routine:r)" "the stored batch is woken again"
  [ ! -e "$home/state/routines/r/cursor" ] || fail "a batch never woken must not commit"
  pass "a batch whose wake was lost is re-presented, not committed"
}

test_backoff_is_bounded() {
  local home t=2000000 out retry delays=
  home=$(new_home backoff 'echo boom >&2; exit 1')
  for _ in 1 2 3 4 5 6 7; do
    tick "$home" "$t" >/dev/null
    retry=$(FM_HOME="$home" FM_HOST_ID=mac-a FM_ROUTINE_NOW="$t" bash "$ROUTINE" list | sed -n 's/.*retry_at=\([0-9]*\).*/\1/p')
    delays="$delays $((retry - t))"
    t=$retry
  done
  assert_equals " 900 1800 3600 7200 14400 14400 14400" "$delays" "backoff doubles to the cap and stays there"
  assert_equals 1 "$(queued "$home" routine-failing:r)" "one failing alert for the streak"
  [ ! -e "$home/state/routines/r/cursor" ] || fail "a failed read never moves the cursor"

  printf '#!/bin/sh\nexit 3\n' > "$home/probe.sh"
  out=$(tick "$home" "$t")
  assert_equals "" "$out" "an unreachable source is deferred silently"
  printf '#!/bin/sh\nexit 1\n' > "$home/probe.sh"
  tick "$home" $((t + 300)) >/dev/null
  out=$(FM_HOME="$home" FM_HOST_ID=mac-a FM_ROUTINE_NOW=$((t + 300)) bash "$ROUTINE" list)
  assert_contains "$out" "8 in a row" "a deferral does not count as a failure"
  pass "a failing probe backs off to a bounded delay and alerts once"
}

test_nothing_new_is_silent() {
  local home out t=3000000
  home=$(new_home quiet 'echo c9 > "$FM_ROUTINE_CURSOR_OUT"; echo "NOTHING NEW"')
  out=$(tick "$home" "$t")
  assert_equals "" "$out" "NOTHING NEW prints nothing"
  assert_equals 0 "$(queued "$home" routine:r)" "NOTHING NEW queues no wake"
  assert_equals c9 "$(cat "$home/state/routines/r/cursor")" "with no wake to handle the cursor commits at once"
  printf '#!/bin/sh\nexit 0\n' > "$home/probe.sh"
  out=$(tick "$home" $((t + 900)))
  assert_equals "" "$out" "empty probe output prints nothing"
  assert_equals 0 "$(queued "$home" routine:r)" "empty probe output queues no wake"
  pass "a probe with nothing new stays silent"
}

fm_test_run test_cursor_waits_for_ack test_lost_wake_is_re_presented test_backoff_is_bounded test_nothing_new_is_silent
