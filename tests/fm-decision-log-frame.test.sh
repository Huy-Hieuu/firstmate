#!/usr/bin/env bash
# tests/fm-decision-log-frame.test.sh - behavior tests for
# `bin/fm-decision-log.sh frame`: a framed call becomes one captain hold whose
# reason carries every option with its cost, reversibility, and pre-mortem and
# whose revisit date is its --until date, the framing is logged once, and an
# incomplete option or a single option is refused without a hold.
# shellcheck disable=SC2016 # Option lines are literal text.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-decision-frame-tests)
LOG="$ROOT/bin/fm-decision-log.sh"

new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config"
  fm_test_tasks_toml "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  printf '%s\n' "$home"
}

test_frame_holds_options_and_logs() {
  local home show
  home=$(new_home framed)
  printf '%s\n' \
    'Take contract B | 20 h a week for 3 months | hard to exit before month 2 | it crowds out the launch' \
    'Decline B | about $6k | fully reversible | no other lead lands this quarter' \
    | FM_HOME="$home" bash "$LOG" frame contract-b --question "Take contract B?" --until 2026-11-20 >/dev/null \
    || fail "frame failed"
  show=$(FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" show contract-b)
  assert_contains "$show" "held: yes" "the call was not held for the captain"
  assert_contains "$show" "hold_until: 2026-11-20" "the revisit date was not the hold date"
  assert_contains "$show" "1. Take contract B - cost: 20 h a week for 3 months; reversibility: hard to exit before month 2; pre-mortem: it crowds out the launch" "the first option lost a field"
  assert_contains "$show" "2. Decline B - cost: about \$6k" "the second option is missing"
  assert_contains "$(FM_HOME="$home" bash "$LOG" list --item contract-b)" "firstmate/framed: 2 options: Take contract B / Decline B; revisit 2026-11-20" "the framing was not logged"
  pass "a framed call is one held task with every option and its revisit date"
}

test_incomplete_frame_refused() {
  local home rc
  home=$(new_home refused)
  printf 'Only | a | b | c\n' | FM_HOME="$home" bash "$LOG" frame one --question q --until 2026-11-20 2>/dev/null; rc=$?
  assert_equals 1 "$rc" "a single option was accepted"
  printf 'A | cost | rev |\nB | c | r | p\n' | FM_HOME="$home" bash "$LOG" frame two --question q --until 2026-11-20 2>/dev/null; rc=$?
  assert_equals 1 "$rc" "an option without a pre-mortem was accepted"
  assert_not_contains "$(cat "$home/data/backlog.md")" "hold" "a refused frame still held a task"
  pass "an incomplete frame is refused without a hold"
}

fm_test_run test_frame_holds_options_and_logs test_incomplete_frame_refused
