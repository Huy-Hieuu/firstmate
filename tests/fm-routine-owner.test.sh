#!/usr/bin/env bash
# tests/fm-routine-owner.test.sh - behavior tests for bin/fm-routine-owner.sh:
# one machine owns routines, another is refused while the lease is live, takes
# over once it is stale, and can take over explicitly with --force.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-routine-owner-tests)
OWNER="$ROOT/bin/fm-routine-owner.sh"

as_host() {  # <home> <host> <args...>
  local home=$1 host=$2
  shift 2
  FM_HOME="$home" FM_HOST_ID="$host" bash "$OWNER" "$@"
}

test_single_owner() {
  local home="$TMP_ROOT/single" rc=0
  mkdir -p "$home/data"
  as_host "$home" mac-a check && fail "no lease yet"
  as_host "$home" mac-a claim || fail "first claim failed"
  as_host "$home" mac-a check || fail "owner check"
  as_host "$home" mac-b check && fail "non-owner must not pass check"
  as_host "$home" mac-b claim 2>/dev/null || rc=$?
  expect_code 6 "$rc" "live lease refuses another machine"
  as_host "$home" mac-a claim || fail "owner refresh failed"
  as_host "$home" mac-b claim --force || fail "forced handover failed"
  as_host "$home" mac-b check || fail "new owner check"
  as_host "$home" mac-a check && fail "old owner lost the lease"
  as_host "$home" mac-a release
  as_host "$home" mac-b check || fail "non-holder release must be a no-op"
  as_host "$home" mac-b release
  as_host "$home" mac-b status >/dev/null && fail "released lease is gone"
  pass "one machine owns routines; --force hands over; release drops only its own"
}

test_stale_takeover() {
  local home="$TMP_ROOT/stale" out
  mkdir -p "$home/data/routines"
  printf 'host=mac-a\nat=%s\n' "$(( $(date +%s) - 7300 ))" > "$home/data/routines/owner"
  out=$(as_host "$home" mac-b status)
  assert_contains "$out" "mac-a" "status names the holder"
  assert_contains "$out" "stale" "an old heartbeat is stale"
  as_host "$home" mac-a check && fail "a stale lease is not ownership"
  as_host "$home" mac-b claim || fail "stale lease must be claimable"
  as_host "$home" mac-b check || fail "takeover check"
  pass "a stale lease is taken over without --force"
}

fm_test_run test_single_owner test_stale_takeover
