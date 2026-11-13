#!/usr/bin/env bash
# tests/fm-invest.test.sh - behavior tests for bin/fm-invest.sh: the check
# condition is true only when a threshold is crossed, an unreadable quote is an
# error rather than a false or true, a malformed watch list is refused, and the
# summary keeps only recent headlines.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-invest-tests)
INVEST="$ROOT/bin/fm-invest.sh"
NOW=1794790800

rfc822() { LC_ALL=C perl -MPOSIX=strftime -e 'print strftime("%a, %d %b %Y %H:%M:%S GMT", gmtime($ARGV[0]))' "$1"; }

# new_home <name> <price>: a home watching AAPL (below 180, above 260) whose
# quote and news come from local fixture files.
new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data/invest" "$home/fx"
  cat > "$home/data/invest/watch.toml" <<'EOF'
# fixture
[[watch]]
ticker = "AAPL"
below = 180
above = 260   # trim near the high
keywords = ["Apple earnings"]
EOF
  printf '{"chart":{"result":[{"meta":{"regularMarketPrice":%s,"currency":"USD"},"indicators":{"quote":[{"close":[200,null,%s]}]}}]}}\n' "$2" "$2" > "$home/fx/AAPL.json"
  cat > "$home/fx/news.xml" <<EOF
<rss><channel>
<item><title>Apple earnings beat &amp; raise</title><pubDate>$(rfc822 $((NOW - 86400)))</pubDate></item>
<item><title>Old Apple story</title><pubDate>$(rfc822 $((NOW - 30 * 86400)))</pubDate></item>
</channel></rss>
EOF
  printf '%s\n' "$home"
}

invest() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_BRIEF_NOW=$NOW FM_INVEST_QUOTE_URL="file://$home/fx/{ticker}.json" \
    FM_INVEST_NEWS_URL="file://$home/fx/news.xml?q={query}" bash "$INVEST" "$@"
}

test_check_reflects_thresholds() {
  local home rc
  home=$(new_home quiet 210)
  invest "$home" check 2>/dev/null; rc=$?
  assert_equals 1 "$rc" "a price inside the band reported a crossing"
  home=$(new_home low 175.5)
  invest "$home" check 2>/dev/null; rc=$?
  assert_equals 0 "$rc" "a price below the floor was not a crossing"
  assert_contains "$(invest "$home" report)" "AAPL 175.5 USD (-12.3% over 5 days), at or below 180" "the report line is wrong"
  rm -f "$home/fx/AAPL.json"
  invest "$home" check 2>/dev/null; rc=$?
  assert_equals 3 "$rc" "an unreadable quote did not exit as unreachable"
  pass "check is true only on a crossing and an unreadable quote is an error"
}

test_malformed_watch_list_refused() {
  local home rc
  home=$(new_home bad 210)
  printf '[[watch]]\nticker = AAPL\n' > "$home/data/invest/watch.toml"
  invest "$home" check 2>/dev/null; rc=$?
  assert_equals 2 "$rc" "an unquoted ticker was accepted"
  pass "a malformed watch list is refused"
}

test_summary_keeps_recent_headlines() {
  local home out
  home=$(new_home news 270)
  out=$(invest "$home" summary)
  assert_contains "$out" "at or above 260" "the summary missed the crossing"
  assert_contains "$out" "  - Apple earnings beat & raise" "a recent headline is missing"
  assert_not_contains "$out" "Old Apple story" "a month-old headline was kept"
  pass "the summary lists prices and only recent headlines"
}

fm_test_run test_check_reflects_thresholds test_malformed_watch_list_refused test_summary_keeps_recent_headlines
