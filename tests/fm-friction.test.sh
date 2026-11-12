#!/usr/bin/env bash
# tests/fm-friction.test.sh - behavior tests for bin/fm-friction.sh: the loop
# guard alerts once per streak of the same normalized wake (a contribution
# check failing behind a VPN, a stuck-busy worker), ignores old history and
# declared pauses, and ends a streak after a quiet gap; the friction sentinel
# upserts normalized signatures with counts and wasted turns.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-friction-tests)
FRICTION="$ROOT/bin/fm-friction.sh"

new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data"
  printf '%s\n' "$home"
}

run_friction() {  # <home> <now> <args...>
  local home=$1 now=$2
  shift 2
  FM_HOME="$home" FM_FRICTION_NOW="$now" bash "$FRICTION" "$@"
}

deliver() {  # <home> <reason>: append one delivered-wake row as fm-watch.sh writes it
  printf '%s\t%s     bash %s/bin/fm-watch.sh\t%s\n' "$RANDOM" "Thu Nov 12 04:42:51 2026" "$1" "$2" \
    >> "$1/state/.watch-deliveries.log"
}

GH_FAIL='check: /h/state/contributions.check.sh: contributions: observation unavailable for https://github.com/o/r/pull/16 - core read exited 1 with 19s of budget left: error connecting to api.github.com'

test_loop_guard_catches_repeated_wakes_once() {
  local home out i now=1800000000
  home=$(new_home loop)
  deliver "$home" "$GH_FAIL"
  out=$(run_friction "$home" "$now" loop)
  assert_equals "" "$out" "the first run only records history and never alerts"
  for i in 1 2 3 4; do
    deliver "$home" "$GH_FAIL"
    deliver "$home" "signal: /h/state/other.turn-ended"
    deliver "$home" "stale: firstmate:fm-dal (unread firstmate instruction: stuck-busy after 2 consecutive busy-deferred due doorbells; /h/state/dal.inbox/10$i.msg stays unhandled and no doorbell was typed; inspect the worker)"
    deliver "$home" "stale: firstmate:fm-paused (paused 9000s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds)"
  done
  out=$(run_friction "$home" $((now + 300)) loop)
  assert_equals "" "$out" "four repeats stay under the threshold"
  deliver "$home" "$GH_FAIL"
  deliver "$home" "stale: firstmate:fm-dal (unread firstmate instruction: stuck-busy after 2 consecutive busy-deferred due doorbells; /h/state/dal.inbox/105.msg stays unhandled and no doorbell was typed; inspect the worker)"
  deliver "$home" "stale: firstmate:fm-paused (paused 9300s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds)"
  out=$(run_friction "$home" $((now + 600)) loop)
  assert_contains "$out" "loop guard: " "the fifth identical wake alerts"
  assert_contains "$out" "error connecting to api.github.com\" 5 times" "the failing contribution check is named with its count"
  assert_contains "$out" "stuck-busy" "the stuck-busy worker is caught across different message numbers"
  assert_not_contains "$out" "declared pause" "a declared paused wait is exempt"
  assert_not_contains "$out" "turn-ended" "signals are exempt"
  deliver "$home" "check: /h/state/friction.check.sh: $out"
  deliver "$home" "$GH_FAIL"
  out=$(run_friction "$home" $((now + 900)) loop)
  assert_equals "" "$out" "a streak alerts once, and the guard ignores its own wake"
  for i in 1 2 3 4 5; do deliver "$home" "$GH_FAIL"; done
  out=$(run_friction "$home" $((now + 900 + 7201)) loop)
  assert_contains "$out" "5 times" "after a quiet gap a new streak starts and can alert again"
  pass "loop guard alerts once per streak of the same wake"
}

test_scan_upserts_signatures() {
  local home out
  home=$(new_home scan)
  printf 'working [at=1]: started\nblocked [at=1794400000]: gh auth failed for https://github.com/o/r\n' > "$home/state/w1.status"
  printf 'blocked [at=1794400999]: gh auth failed for https://github.com/o/other\n' > "$home/state/w2.status"
  deliver "$home" "$GH_FAIL"
  deliver "$home" "$GH_FAIL"
  deliver "$home" "heartbeat"
  printf '[2026-11-12T10:01:14+0700] absorbed heartbeat (no captain-relevant change)\n[2026-11-12T10:02:00+0700] spawn failed: could not create worktree\n' \
    > "$home/state/.watch-triage.log"
  run_friction "$home" 1800000000 scan || fail "scan failed"
  out=$(run_friction "$home" 1800000000 top 5)
  assert_contains "$out" "2x 2 turns [wake]" "repeated wakes count as wasted turns"
  assert_contains "$out" "2x 0 turns [status] " "blocked lines from two workers share one signature"
  assert_contains "$out" "1x 0 turns [triage]" "triage errors are counted"
  assert_not_contains "$out" "heartbeat" "routine heartbeats are not friction"
  assert_not_contains "$out" "working" "ordinary status lines are not friction"
  deliver "$home" "$GH_FAIL"
  run_friction "$home" 1800000100 scan || fail "rescan failed"
  out=$(run_friction "$home" 1800000100 top 1)
  assert_contains "$out" "3x 3 turns [wake]" "a rescan adds only new lines to the existing signature"
  assert_equals 3 "$(wc -l < "$home/data/friction.jsonl" | tr -d ' ')" "one row per signature"
  pass "scan upserts normalized signatures with counts and turns"
}

fm_test_run test_loop_guard_catches_repeated_wakes_once test_scan_upserts_signatures
