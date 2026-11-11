#!/usr/bin/env bash
# tests/fm-reach.test.sh - behavior tests for bin/fm-reach.sh: any HTTP answer
# is reachable, a connect failure is unreachable, a target is reachable when any
# of its URLs answers, verdicts are cached, and unknown targets are refused.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-reach-tests)
REACH="$ROOT/bin/fm-reach.sh"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
# Fake curl: hosts listed in $REACH_UP answer 403; every other host fails to
# connect. Each call is counted in $REACH_CALLS.
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
url=${!#}
echo "$url" >> "$REACH_CALLS"
case " $REACH_UP " in
  *" $url "*) printf '403'; exit 0 ;;
esac
printf '000'
exit 7
SH
chmod +x "$FAKEBIN/curl"

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/config" "$HOME_DIR/state"
printf '# MoMo over VPN\nmomo https://gerrit.example.test https://jenkins.example.test\n' > "$HOME_DIR/config/reach"
export REACH_CALLS="$TMP_ROOT/calls"

reach() {
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" bash "$REACH" "$@"
}

test_vpn_split() {
  local out rc=0
  out=$(REACH_UP="https://jenkins.example.test" reach --no-cache) || rc=$?
  expect_code 3 "$rc" "github unreachable"
  assert_contains "$out" "github unreachable" "connect failure is unreachable"
  assert_contains "$out" "momo reachable" "a 403 from any URL is reachable"
  rc=0
  REACH_UP="https://api.github.com" reach --no-cache github >/dev/null || rc=$?
  expect_code 0 "$rc" "github reachable"
  pass "VPN-split targets classify independently"
}

test_cache() {
  local out
  : > "$REACH_CALLS"
  REACH_UP="https://api.github.com" reach --no-cache github >/dev/null
  out=$(REACH_UP='' reach github) || true
  assert_contains "$out" "github reachable" "a fresh verdict is served from cache"
  assert_equals 1 "$(wc -l < "$REACH_CALLS" | tr -d ' ')" "cached read makes no request"
  out=$(REACH_UP='' FM_REACH_CACHE_SECS=0 reach github) || true
  assert_contains "$out" "github unreachable" "an expired verdict is re-probed"
  pass "verdicts are cached for the cache window"
}

test_unknown_target() {
  local rc=0
  reach nope 2>/dev/null || rc=$?
  expect_code 2 "$rc" "unknown target"
  pass "unknown targets are refused"
}

fm_test_run test_vpn_split test_cache test_unknown_target
