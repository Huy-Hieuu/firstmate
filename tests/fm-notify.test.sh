#!/usr/bin/env bash
# tests/fm-notify.test.sh - behavior tests for bin/fm-notify.sh: once-per-stretch
# dedupe, the no-channel no-op, quiet-time holding of fyi notices and their
# summary flush, needs-you break-through, a failed channel leaving the stretch
# open for retry, and the firstmate-only refusal.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-notify-tests)
NOTIFY="$ROOT/bin/fm-notify.sh"
unset FM_TASK_ID

# new_home <name>: a home whose config/notify records each delivery to sent.log.
new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/state"
  # shellcheck disable=SC2016 # $1..$4 expand later inside the channel command.
  printf 'command:printf "%%s|%%s|%%s|%%s\\n" "$1" "$2" "$3" "$4" >> %s/sent.log\n' "$home" > "$home/config/notify"
  printf '%s\n' "$home"
}

run_notify() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" bash "$NOTIFY" "$@"
}

test_once_per_stretch() {
  local home
  home=$(new_home stretch)
  run_notify "$home" send needs-you pr:42 "PR ready" "checks green" "https://example.test/pr/42" || fail "first send failed"
  run_notify "$home" send needs-you pr:42 "PR ready" || fail "repeat send failed"
  assert_equals 1 "$(wc -l < "$home/sent.log" | tr -d ' ')" "a repeat within the stretch must not deliver"
  assert_grep 'needs-you|PR ready|checks green|https://example.test/pr/42' "$home/sent.log" "channel receives level, title, body, url"
  run_notify "$home" clear pr:42
  run_notify "$home" send needs-you pr:42 "PR ready" || fail "send after clear failed"
  assert_equals 2 "$(wc -l < "$home/sent.log" | tr -d ' ')" "clear ends the stretch"
  pass "a cause notifies once per stretch until cleared"
}

test_no_channel_is_noop() {
  local home="$TMP_ROOT/none" err rc=0
  mkdir -p "$home/state"
  err=$(run_notify "$home" send fyi k1 "hello" 2>&1) || rc=$?
  expect_code 0 "$rc" "no channel"
  assert_contains "$err" "no channel configured" "no-channel notice"
  assert_absent "$home/state/notify/k1" "no stretch opens when nothing was sent"
  pass "no configured channel is a no-op with a notice"
}

test_quiet_hours_hold_and_flush() {
  local home
  home=$(new_home quiet)
  printf '22:00-07:30\nsat,sun 00:00-24:00\n' > "$home/config/quiet-hours"
  # Tuesday 06:00 is inside Monday's overnight window.
  FM_QUIET_HOURS_NOW="2 06:00" run_notify "$home" quiet-now || fail "Tue 06:00 should be quiet"
  FM_QUIET_HOURS_NOW="2 12:00" run_notify "$home" quiet-now && fail "Tue 12:00 should not be quiet"
  FM_QUIET_HOURS_NOW="6 12:00" run_notify "$home" quiet-now || fail "Sat 12:00 should be quiet"
  FM_QUIET_HOURS_NOW="2 23:00" run_notify "$home" send fyi a "Brief posted" || fail "held send failed"
  FM_QUIET_HOURS_NOW="2 23:05" run_notify "$home" send fyi b "Scout finished" || fail "held send failed"
  assert_absent "$home/sent.log" "fyi must wait during quiet hours"
  FM_QUIET_HOURS_NOW="2 23:10" run_notify "$home" send needs-you c "Merge decision" || fail "needs-you send failed"
  assert_grep 'needs-you|Merge decision' "$home/sent.log" "needs-you breaks through quiet hours"
  FM_QUIET_HOURS_NOW="3 08:00" run_notify "$home" flush || fail "flush failed"
  assert_grep 'fyi|2 update(s) held during quiet time|Brief posted;Scout finished|' "$home/sent.log" "held fyi flushed as one summary"
  FM_QUIET_HOURS_NOW="3 08:01" run_notify "$home" flush || fail "second flush failed"
  assert_equals 2 "$(wc -l < "$home/sent.log" | tr -d ' ')" "held notices flush once"
  pass "quiet hours hold fyi, pass needs-you, and flush a summary later"
}

test_quiet_mode_holds_fyi() {
  local home
  home=$(new_home quietmode)
  printf 'quiet\n' > "$home/state/.afk"
  run_notify "$home" quiet-now || fail "/quiet mode should hold fyi"
  printf 'away\n' > "$home/state/.afk"
  run_notify "$home" quiet-now && fail "away mode must not hold fyi"
  pass "/quiet mode holds fyi while away mode does not"
}

test_failed_channel_keeps_stretch_open() {
  local home="$TMP_ROOT/failing" rc=0
  mkdir -p "$home/config" "$home/state"
  printf 'command:exit 7\n' > "$home/config/notify"
  run_notify "$home" send needs-you k "Title" 2>/dev/null || rc=$?
  expect_code 1 "$rc" "every channel failed"
  assert_absent "$home/state/notify/k" "a failed delivery must not open a stretch"
  pass "a failed delivery reports failure and stays retryable"
}

test_worker_refused() {
  local home rc=0
  home=$(new_home worker)
  FM_TASK_ID=some-task run_notify "$home" send needs-you k "Title" 2>/dev/null || rc=$?
  expect_code 6 "$rc" "worker refusal"
  assert_absent "$home/sent.log" "a worker must never push"
  pass "workers and secondmates are refused"
}

fm_test_run test_once_per_stretch test_no_channel_is_noop test_quiet_hours_hold_and_flush \
  test_quiet_mode_holds_fyi test_failed_channel_keeps_stretch_open test_worker_refused
