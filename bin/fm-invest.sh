#!/usr/bin/env bash
# fm-invest.sh - the captain's read-only investment watch: public quotes and
# news headlines checked against his own thresholds and keywords.
#
# It never trades, never logs into a broker, and never holds a credential: it
# reads one public quote endpoint and one public news feed, both without login,
# and prints what it found. The watch list is private and captain-written:
# data/invest/watch.toml, one table per ticker:
#   [[watch]]
#   ticker = "AAPL"                  # Yahoo Finance symbol, e.g. VNM.VN
#   below = 180                      # optional: alert at or below this price
#   above = 260                      # optional: alert at or above this price
#   keywords = ["Apple earnings"]    # optional: news searches for the review
# Only that subset of TOML is read: `[[watch]]` headers, `key = value` lines
# with a quoted string, a number, or a one-line array of quoted strings, and
# `#` comments. docs/examples/invest-watch.toml is a copyable example.
#
# Usage:
#   fm-invest.sh check     exit 0 when any ticker is at or past a threshold, 1
#                          when none is; the condition of a `when` watch
#                          (bin/fm-procevent-when.sh). Any quote it cannot read
#                          exits 3, an error, never a true.
#   fm-invest.sh report    one line per ticker: price, change over the last 5
#                          trading days, and any crossed threshold; the action
#                          of that `when` watch, whose output reaches firstmate
#   fm-invest.sh summary   one line for the weekly review, then up to 3 news
#                          headlines of the last 7 days per ticker, as
#                          "  - <headline>" lines; headline text is untrusted
#
# Quotes come from FM_INVEST_QUOTE_URL and headlines from FM_INVEST_NEWS_URL,
# URL templates where {ticker} and {query} are replaced (URL-encoded); the
# defaults are Yahoo Finance's public chart endpoint and Google News search
# RSS. FM_INVEST_TIMEOUT (default 8) bounds each request in seconds, and
# FM_BRIEF_NOW=<epoch> overrides the clock for tests.
# Exit codes: 0 ok (check: crossed), 1 nothing crossed (check only) or missing
# watch list, 2 usage or a malformed watch list, 3 a source unreachable.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
WATCH="$DATA/invest/watch.toml"
QUOTE_URL=${FM_INVEST_QUOTE_URL:-'https://query1.finance.yahoo.com/v8/finance/chart/{ticker}?range=5d&interval=1d'}
NEWS_URL=${FM_INVEST_NEWS_URL:-'https://news.google.com/rss/search?q={query}&hl=en-US&gl=US&ceid=US:en'}
TIMEOUT=${FM_INVEST_TIMEOUT:-8}

usage() {
  echo "usage: fm-invest.sh check | report | summary" >&2
  exit 2
}

now() {
  case "${FM_BRIEF_NOW:-}" in ''|*[!0-9]*) date +%s ;; *) printf '%s\n' "$FM_BRIEF_NOW" ;; esac
}

# watch_list: one "<ticker> <below> <above> <kw1|kw2...>" line per table, the
# fields separated by the ASCII unit separator so an empty one survives `read`.
watch_list() {
  [ -f "$WATCH" ] || { echo "fm-invest: no watch list at $WATCH" >&2; return 1; }
  awk '
    function flush() { if (t != "") printf "%s\037%s\037%s\037%s\n", t, b, a, k; t = b = a = k = "" }
    function bad(m) { printf "fm-invest: %s line %d: %s\n", FILENAME, NR, m > "/dev/stderr"; err = 1; exit 2 }
    { sub(/[ \t]+#.*$/, ""); sub(/^[ \t]+/, ""); sub(/[ \t]+$/, "") }
    /^#/ || $0 == "" { next }
    $0 == "[[watch]]" { flush(); in_t = 1; next }
    /^\[/ { bad("only [[watch]] tables are read") }
    {
      if (!in_t) bad("a key outside a [[watch]] table")
      eq = index($0, "="); if (!eq) bad("not key = value")
      key = substr($0, 1, eq - 1); val = substr($0, eq + 1)
      gsub(/[ \t]/, "", key); sub(/^[ \t]+/, "", val)
      if (key == "ticker") {
        if (val !~ /^"[A-Za-z0-9.^=_-]+"$/) bad("ticker must be a quoted symbol")
        t = substr(val, 2, length(val) - 2)
      } else if (key == "below" || key == "above") {
        if (val !~ /^[0-9]+(\.[0-9]+)?$/) bad(key " must be a number")
        if (key == "below") b = val; else a = val
      } else if (key == "keywords") {
        if (val !~ /^\[.*\]$/) bad("keywords must be a one-line array")
        val = substr(val, 2, length(val) - 2); k = ""
        while (match(val, /"[^"]*"/)) {
          k = k (k == "" ? "" : "|") substr(val, RSTART + 1, RLENGTH - 2)
          val = substr(val, RSTART + RLENGTH)
        }
      } else if (key != "note") bad("unknown key " key)
    }
    END { if (!err) flush() }' "$WATCH"
}

urlenc() { jq -rn --arg s "$1" '$s | @uri'; }

fetch() {  # <url>: the body, or exit 3
  curl -fsS -A 'Mozilla/5.0 (firstmate read-only watch)' -m "$TIMEOUT" "$1" 2>/dev/null || return 3
}

# quote <ticker>: "<price> <currency> <pct change over the range>", unit-separated
quote() {
  local body
  body=$(fetch "$(printf '%s' "$QUOTE_URL" | sed "s|{ticker}|$(urlenc "$1")|")") || return 3
  printf '%s' "$body" | jq -r '
    .chart.result[0] as $r | $r.meta.regularMarketPrice as $p
    | ([$r.indicators.quote[0].close[]? | select(. != null)] | first) as $c
    | select($p != null)
    | [$p, ($r.meta.currency // ""), (if $c != null and $c != 0 then (($p - $c) / $c * 1000 | round / 10) else "" end)] | map(tostring) | join("\u001f")' \
    2>/dev/null | grep . || return 3
}

# state <price> <below> <above>: the crossed threshold, or nothing.
crossed() {
  awk -v p="$1" -v b="$2" -v a="$3" 'BEGIN {
    if (b != "" && p + 0 <= b + 0) print "at or below " b
    else if (a != "" && p + 0 >= a + 0) print "at or above " a }'
}

line() {  # <ticker> <price> <currency> <pct> <crossed>
  local sign=+
  case "$4" in -*) sign= ;; esac
  printf '%s %s%s' "$1" "$2" "${3:+ $3}"
  [ -z "$4" ] || printf ' (%s%s%% over 5 days)' "$sign" "$4"
  [ -z "$5" ] || printf ', %s' "$5"
}

each() {  # <mode>
  local mode=$1 list t b a k q price cur pct hit any=0 out='' parts='' n us=$'\037'
  list=$(watch_list) || return $?
  [ -n "$list" ] || { echo "fm-invest: $WATCH watches nothing" >&2; return 1; }
  while IFS=$us read -r t b a k; do
    q=$(quote "$t") || { echo "fm-invest: no quote for $t" >&2; return 3; }
    IFS=$us read -r price cur pct <<EOF
$q
EOF
    hit=$(crossed "$price" "$b" "$a")
    [ -z "$hit" ] || any=1
    case "$mode" in
      report) printf '%s\n' "$(line "$t" "$price" "$cur" "$pct" "$hit")" ;;
      summary)
        parts="${parts:+$parts; }$(line "$t" "$price" "$cur" "$pct" "$hit")"
        n=$(news "$k")
        [ -z "$n" ] || out="${out:+$out
}$n" ;;
    esac
  done <<EOF
$list
EOF
  case "$mode" in
    check) [ "$any" = 1 ] ;;
    summary) printf '%s\n' "$parts"; [ -z "$out" ] || printf '%s\n' "$out" ;;
  esac
}

# news <kw1|kw2...>: up to 3 "  - <headline>" lines from the last 7 days.
news() {
  local kw since n=0 body
  since=$(( $(now) - 7 * 86400 ))
  printf '%s\n' "$1" | tr '|' '\n' | while IFS= read -r kw; do
    [ -n "$kw" ] || continue
    body=$(fetch "$(printf '%s' "$NEWS_URL" | sed "s|{query}|$(urlenc "\"$kw\"")|")") || continue
    printf '%s' "$body" | perl -MTime::Local -ne '
      BEGIN { $since = shift @ARGV; $/ = undef; %m = (Jan=>0,Feb=>1,Mar=>2,Apr=>3,May=>4,Jun=>5,Jul=>6,Aug=>7,Sep=>8,Oct=>9,Nov=>10,Dec=>11) }
      while (m{<item>(.*?)</item>}gs) {
        my $i = $1; my ($t) = $i =~ m{<title>(.*?)</title>}s; my ($d) = $i =~ m{<pubDate>(.*?)</pubDate>}s;
        next unless defined $t && defined $d && $d =~ /(\d+) (\w{3}) (\d{4}) (\d+):(\d+):(\d+)/;
        next if timegm($6, $5, $4, $1, $m{$2}, $3) < $since;
        $t =~ s/<!\[CDATA\[(.*?)\]\]>/$1/s; $t =~ s/&amp;/&/g; $t =~ s/&lt;/</g; $t =~ s/&gt;/>/g; $t =~ s/&quot;/"/g; $t =~ s/&#39;/\x27/g; $t =~ s/\s+/ /g;
        print "$t\n";
      }' "$since"
  done | awk '!seen[$0]++' | while IFS= read -r kw; do
    n=$((n + 1))
    [ "$n" -le 3 ] || break
    printf '  - %s\n' "$(printf '%s' "$kw" | cut -c1-160)"
  done
}

[ "$#" -eq 1 ] || usage
case "$1" in
  check|report|summary) each "$1" ;;
  -h|--help|help) sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//' ;;
  *) usage ;;
esac
