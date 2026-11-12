#!/usr/bin/env bash
# tests/fm-incident.test.sh - behavior tests for bin/fm-incident.sh: the
# recovery verdict order (captain-only cause, visible outward action, muted,
# escalate after two retries, one retry) and the decision-log row a retry
# leaves behind.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-incident-tests)
INCIDENT="$ROOT/bin/fm-incident.sh"

new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data"
  printf '%s\n' "$home"
}

record() {  # <home> <now> <args...>
  local home=$1 now=$2
  shift 2
  FM_HOME="$home" FM_INCIDENT_NOW="$now" bash "$INCIDENT" record "$@"
}

test_retry_budget_then_escalate_then_mute() {
  local home out now=1800000000
  home=$(new_home budget)
  out=$(record "$home" "$now" w1 "pane died")
  assert_contains "$out" "retry: relaunch once: fm-control.sh w1 relaunch --note" "first incident retries"
  assert_contains "$out" "Check what you already did" "the retry note tells the worker to check its own progress"
  out=$(record "$home" $((now + 60)) w1 "pane died")
  assert_contains "$out" "retry:" "second incident in the hour still retries"
  out=$(record "$home" $((now + 120)) w1 "pane died")
  assert_contains "$out" "escalate:" "a third incident in the hour escalates instead of retrying"
  record "$home" $((now + 180)) w1 x >/dev/null
  record "$home" $((now + 240)) w1 x >/dev/null
  out=$(record "$home" $((now + 300)) w1 x)
  assert_contains "$out" "muted:" "more than five incidents in the hour are muted"
  out=$(record "$home" $((now + 300)) other "pane died")
  assert_contains "$out" "retry:" "another task keeps its own budget"
  out=$(record "$home" $((now + 3700 + 300)) w1 "pane died")
  assert_contains "$out" "retry:" "the retry budget renews after an hour"
  assert_contains "$(FM_HOME="$home" bash "$ROOT/bin/fm-decision-log.sh" list --item w1)" \
    "w1 firstmate/relaunch: pane died (via incident-ledger; rule one automatic retry)" \
    "a retry is recorded in the decision log"
  pass "two retries per hour, then escalate, then mute"
}

test_captain_and_outward_never_retry() {
  local home out
  home=$(new_home outward)
  out=$(record "$home" 1800000000 w2 "login expired" --captain)
  assert_contains "$out" "captain:" "a captain-only cause is never relaunched"
  printf 'working [at=1]: started\ndone [at=2]: PR ready https://github.com/o/r/pull/12\n' > "$home/state/w3.status"
  out=$(record "$home" 1800000000 w3 "pane died")
  assert_contains "$out" "no-retry:" "a status line naming a PR blocks a rerun"
  printf 'working [at=1]: change at https://gerrit.example.com/c/proj/+/125794 uploaded\n' > "$home/state/w4.status"
  out=$(record "$home" 1800000000 w4 "pane died")
  assert_contains "$out" "no-retry:" "a Gerrit change URL blocks a rerun"
  printf 'pr=https://example.test/pr/1\n' > "$home/state/w5.meta"
  out=$(record "$home" 1800000000 w5 "pane died")
  assert_contains "$out" "no-retry:" "a recorded pr= blocks a rerun"
  out=$(record "$home" 1800000000 w6 "pane died" --outward)
  assert_contains "$out" "no-retry:" "--outward blocks a rerun"
  assert_absent "$home/data/decisions.jsonl" "verdicts other than retry write no decision row"
  pass "captain-only causes and outward actions never retry"
}

fm_test_run test_retry_budget_then_escalate_then_mute test_captain_and_outward_never_retry
