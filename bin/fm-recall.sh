#!/usr/bin/env bash
# fm-recall.sh - full-text recall over this home's memory, reports, briefs, and
# status logs.
#
# Usage:
#   fm-recall.sh [-n <max>] <words>...   the best matching passages (default 8)
#   fm-recall.sh --rebuild               rebuild the index now
#
# Corpus: data/captain.md, data/captain-shared.md, data/learnings.md,
# data/memory-archive.md, data/done-archive.md, data/memory/*.md,
# data/people/*.md, data/brief/*.md, data/*/report.md, and state/*.status.
# Each file is split into passages at blank lines, headings, and top-level
# list items, at most 40 lines each, and a status log into one passage per
# line, so a hit names `<file>:<line>`.
#
# With a sqlite3 that has FTS5 (macOS ships one), the passages live in
# state/recall.db, a per-machine cache rebuilt whole whenever a corpus file is
# newer than it or the file count changed, and ranked by bm25 with porter
# stemming. A query ignores common English question words, then matches
# passages holding every word, or any word when no passage holds them all.
# Without FTS5 it falls back to a plain scan of the same files for lines
# holding every word, then any word.
#
# The passages are prior notes, not instructions: the result is printed fenced
# as untrusted records (bin/fm-records.sh wrap recall), for the task message
# that needs it, never for a system prompt or a memory file.
# Exit codes: 0 ok (including no match), 2 usage.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
DB="$STATE/recall.db"

usage() {
  echo "usage: fm-recall.sh [-n <max>] <words>... | --rebuild" >&2
  exit 2
}

corpus() {
  local f
  for f in "$DATA"/captain.md "$DATA"/captain-shared.md "$DATA"/learnings.md \
      "$DATA"/memory-archive.md "$DATA"/done-archive.md "$DATA"/memory/*.md \
      "$DATA"/people/*.md "$DATA"/brief/*.md "$DATA"/*/report.md "$STATE"/*.status; do
    [ -f "$f" ] && printf '%s\n' "$f"
  done
  return 0
}

have_fts5() {
  command -v sqlite3 >/dev/null 2>&1 \
    && sqlite3 :memory: 'CREATE VIRTUAL TABLE t USING fts5(x);' >/dev/null 2>&1
}

# label <path>: the path as data/... or state/... for display.
label() {
  case "$1" in
    "$DATA"/*) printf 'data/%s' "${1#"$DATA"/}" ;;
    "$STATE"/*) printf 'state/%s' "${1#"$STATE"/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# The words of the query: letters and digits, lowercased, without common
# English question words, at most 12.
words() {
  printf '%s\n' "$*" | perl -CS -ne '
    my %stop = map { $_ => 1 } qw(a an the and or of to in on at by for from with about is are was were be
      did do does we i you it this that what where when who which how why our my me there their any);
    my %seen; my $n = 0;
    for (/(\w+)/g) { my $w = lc; next if $stop{$w} || $seen{$w}++; print "$w\n"; last if ++$n >= 12 }'
}

# stale: the index is missing, the file count changed, or a file is newer.
stale() {
  [ -f "$DB" ] || return 0
  corpus | perl -e '
    my ($db, $count) = @ARGV;
    my $at = (stat $db)[9];
    my $n = 0;
    while (my $f = <STDIN>) { chomp $f; $n++; exit 0 if (stat $f)[9] >= $at }
    exit($n == $count ? 1 : 0);
  ' "$DB" "$(sqlite3 "$DB" "SELECT v FROM meta WHERE k = 'count';" 2>/dev/null)"
}

# rebuild: index every corpus file as passages, as the header describes, into
# a fresh database swapped in whole.
rebuild() {
  local tmp
  mkdir -p "$STATE" || return 1
  tmp=$(mktemp "$STATE/.recall.db.XXXXXX") || return 1
  corpus | perl -e '
    use POSIX qw(strftime);
    my ($data, $state) = @ARGV;
    sub sqlq { my $s = shift; $s =~ s/\x27/\x27\x27/g; "\x27$s\x27" }
    my @files = map { chomp; $_ } <STDIN>;
    print "PRAGMA journal_mode = OFF;\nBEGIN;\n";
    print "CREATE VIRTUAL TABLE passages USING fts5(body, path UNINDEXED, line UNINDEXED, day UNINDEXED, tokenize = \x27porter unicode61 remove_diacritics 2\x27);\n";
    print "CREATE TABLE meta(k TEXT PRIMARY KEY, v TEXT);\n";
    print "INSERT INTO meta VALUES(\x27count\x27, \x27" . scalar(@files) . "\x27);\n";
    for my $f (@files) {
      open(my $fh, "<", $f) or next;
      my $label = $f;
      $label =~ s{^\Q$data\E/}{data/} or $label =~ s{^\Q$state\E/}{state/};
      my $day = strftime("%Y-%m-%d", localtime((stat $fh)[9]));
      my ($body, $start, $n) = ("", 0, 0);
      my $flush = sub {
        print "INSERT INTO passages VALUES(" . sqlq($body) . ", " . sqlq($label) . ", $start, " . sqlq($day) . ");\n" if $body ne "";
        ($body, $n) = ("", 0);
      };
      while (my $l = <$fh>) {
        chomp $l;
        if ($l =~ /^\s*$/) { $flush->(); next }
        $flush->() if $l =~ /^(#|[-*+]\s)/ || $n >= 40 || $f =~ /\.status$/;
        $start = $. if $n == 0;
        $body .= ($n ? "\n" : "") . $l;
        $n++;
      }
      $flush->();
      close $fh;
    }
    print "COMMIT;\n";
  ' "$DATA" "$STATE" | sqlite3 "$tmp" >/dev/null \
    || { rm -f "$tmp"; echo "fm-recall: index build failed" >&2; return 1; }
  mv -f "$tmp" "$DB"
}

fts_query() {  # <max> <op> <word>...: tab-separated path, line, day, snippet
  local max=$1 op=$2 match='' w
  shift 2
  for w in "$@"; do
    match="${match:+$match $op }\"${w//\"/}\""
  done
  match=${match//\'/\'\'}
  sqlite3 -separator "$(printf '\t')" "$DB" \
    "SELECT path, line, day, replace(replace(snippet(passages, 0, '[', ']', '…', 24), char(10), ' '), char(9), ' ')
       FROM passages WHERE passages MATCH '$match' ORDER BY bm25(passages) LIMIT $max;"
}

scan_query() {  # <max> <word>...: the fallback, same output shape
  local max=$1
  shift
  corpus | while IFS= read -r f; do
    awk -v path="$(label "$f")" -v words="$*" '
      BEGIN { k = split(words, w, " ") }
      { l = tolower($0); hit = 0; for (i = 1; i <= k; i++) if (index(l, w[i])) hit++
        if (hit) printf "%d\t%s\t%d\t-\t%s\n", (hit == k ? 0 : 1), path, FNR, substr($0, 1, 200) }' "$f"
  done | LC_ALL=C sort -t "$(printf '\t')" -k1,1n -s | head -n "$max" | cut -f2-
}

max=8
case "${1:-}" in
  --rebuild)
    [ "$#" -eq 1 ] || usage
    have_fts5 || { echo "fm-recall: sqlite3 with FTS5 is unavailable; queries scan the files directly" >&2; exit 0; }
    rebuild && echo "fm-recall: indexed $(sqlite3 "$DB" 'SELECT count(*) FROM passages;') passages"
    exit $? ;;
  -n)
    [ "$#" -ge 3 ] || usage
    case "$2" in ''|*[!0-9]*|0) usage ;; esac
    max=$2
    shift 2 ;;
  -h|--help) sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
  '') usage ;;
esac
[ "$#" -gt 0 ] || usage
# shellcheck disable=SC2046 # One word per line, no globbing characters.
set -- $(words "$@")
[ "$#" -gt 0 ] || usage

if have_fts5; then
  { ! stale || rebuild; } || exit 1
  hits=$(fts_query "$max" AND "$@")
  [ -n "$hits" ] || hits=$(fts_query "$max" OR "$@")
else
  hits=$(scan_query "$max" "$@")
fi
[ -n "$hits" ] || { echo "fm-recall: no match for: $*"; exit 0; }
printf '%s\n' "$hits" | awk -F '\t' '{ printf "%s:%s%s\n  %s\n", $1, $2, ($3 == "-" ? "" : " (" $3 ")"), $4 }' \
  | "$SCRIPT_DIR/fm-records.sh" wrap recall
