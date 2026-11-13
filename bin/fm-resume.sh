#!/usr/bin/env bash
# fm-resume.sh - a context pack: where the captain left off in one context,
# such as a project ("resume momo") or a person or client ("resume upwork
# client lan"), and nothing else. Read-only: it changes no record.
#
# A context is one or more words; a record matches when it holds every word of
# at least 3 letters (all words when none is that long) as a whole word, case
# insensitively. Sections, each printed only when something matches:
#   Fleet       the bearings snapshot (bin/fm-bearings-snapshot.sh --json, the
#               one fleet-state source): work under way, open captain calls,
#               queued items and their gates, recently landed work, PRs, and
#               reports whose row matches
#   Follow-ups  open lines of data/waiting.md (bin/fm-followups.sh's tracker)
#   Decisions   the newest matching decision-log rows (bin/fm-decision-log.sh)
#   Memory      topic and person files the context names (bin/fm-memory.sh load)
#   Recall      the best matching older notes, reports, briefs, and status
#               lines (bin/fm-recall.sh), fenced as untrusted records
#
# Usage:
#   fm-resume.sh <context>...
# FM_RESUME_SNAPSHOT_TIMEOUT (default 90) bounds the snapshot in seconds.
# Exit codes: 0 ok (including nothing found), 2 usage.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
export FM_HOME
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {
  echo "usage: fm-resume.sh <context>..." >&2
  exit 2
}

case "${1:-}" in
  -h|--help) sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
  ''|-*) usage ;;
esac
CONTEXT="$*"

# The words a match needs, one per line, lowercased and regex-safe.
WORDS=$(printf '%s\n' "$CONTEXT" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n' ' ' | tr ' ' '\n' | awk 'NF')
LONG=$(printf '%s\n' "$WORDS" | awk 'length >= 3')
[ -z "$LONG" ] || WORDS=$LONG
[ -n "$WORDS" ] || usage
WORDS_JSON=$(printf '%s\n' "$WORDS" | jq -R -s -c 'split("\n") | map(select(. != ""))')

matches() {  # stdin lines holding every word
  perl -ne 'BEGIN { @w = map { qr/(?<![a-z0-9])\Q$_\E(?![a-z0-9])/i } split /\n/, shift @ARGV }
    my $l = $_; print if !grep { $l !~ $_ } @w' "$WORDS"
}

section() {  # <heading> <body>
  [ -n "$2" ] || return 0
  printf '\n## %s\n%s\n' "$1" "$2"
}

printf '# Resume: %s\n' "$CONTEXT"

snap=$(fm_run_timed "${FM_RESUME_SNAPSHOT_TIMEOUT:-90}" "$SCRIPT_DIR/fm-bearings-snapshot.sh" --json 2>/dev/null) || snap=''
fleet=''
if [ -n "$snap" ]; then
  fleet=$(printf '%s' "$snap" | jq -r --argjson w "$WORDS_JSON" '
    def hit: tostring | ascii_downcase as $t | all($w[]; . as $x | $t | test("(?<![a-z0-9])" + $x + "(?![a-z0-9])"));
    def one: tostring | gsub("[\r\n\t]+"; " ") | .[0:160];
    ((.in_flight // [])[] | select(hit) | "- Under way: " + (.name // .id | one) + " (" + (.repo // .owner // "" | tostring) + "): " + (.doing // .state // "" | one)),
    ((.decisions_open // [])[] | select(hit) | "- Your call: " + (.summary // .question // .id | one)),
    ((.recorded_prs // [])[] | select(hit) | "- PR awaiting you: " + (.id // "" | one) + " " + (.url // "")),
    ((.gates // [])[] | select(hit) | "- Queued: " + (.title // .id | one) + (if (.reason // "-") != "-" then " (" + (.reason | one) + ")" else "" end)),
    ((.landed // [])[] | select(hit) | "- Landed: " + (.what // .id | one)),
    ((.reports // [])[] | select(hit) | "- Report: " + (. | if type == "object" then (.path // .id // "" | tostring) else tostring end))' 2>/dev/null)
else
  fleet="- Fleet snapshot unavailable."
fi
section Fleet "$fleet"

followups=''
[ ! -f "$DATA/waiting.md" ] || followups=$(grep -E '^- #' "$DATA/waiting.md" | matches | head -n 15)
section Follow-ups "$followups"

decisions=$("$SCRIPT_DIR/fm-decision-log.sh" list --limit 500 2>/dev/null | matches | tail -n 8 | sed 's/^/- /')
section Decisions "$decisions"

memory=$("$SCRIPT_DIR/fm-memory.sh" load "$CONTEXT" 2>/dev/null)
case "$memory" in 'no topic or person file is named'*) memory='' ;; esac
section Memory "$memory"

recall=$("$SCRIPT_DIR/fm-recall.sh" -n 6 "$CONTEXT" 2>/dev/null)
case "$recall" in *'[UNTRUSTED'*) ;; *) recall='' ;; esac
section Recall "$recall"
