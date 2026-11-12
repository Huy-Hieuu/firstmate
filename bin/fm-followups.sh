#!/usr/bin/env bash
# fm-followups.sh - the captain's follow-ups: what he waits on from others,
# what he owes, his inbox sorting calls, and reply drafts. Local files only:
# it never sends, posts, or changes mail or any other outside system.
#
# Tracker. data/waiting.md holds one line per follow-up:
#   - #<n> · <YYYY-MM-DD> · <wait|owe> · <who> · <what> · <nudge|due> <YYYY-MM-DD>|no date · <ref> · <quote>
# <ref> is `msg <Message-ID>` for one taken from the captain's sent mail, or
# `captain` when he asked for it himself; <quote> is his exact words or `-`.
# A closed line is struck through, `- ~~...~~ · <done|replied|dropped> <date>`
# (the startup-memory grammar). A decision only the captain can make is a
# captain hold (bin/fm-captain-hold.sh, `--until` to defer it), which the brief
# already shows under Needs you; it never becomes a tracker line.
#
# Quote gate. A follow-up taken from sent mail (`--from sent:<id>`) needs
# `--quote`: the captain's words, found verbatim (whitespace collapsed) in that
# sent message's own text in the mail source rows, and every number in <what>
# must appear in the quote. Anything else is refused and nothing is recorded.
#
# Brief source. `rows` prints the tracker as daily brief rows (run it as
# `fm-daily-brief.sh source followups bin/fm-followups.sh rows`): a wait shows
# under Waiting on others until its nudge date, then under Needs you; an owe
# shows under You owe until the day before its due date, then under Needs you.
# A wait taken from sent mail closes itself as `replied` once an inbox message
# in the mail source rows answers that thread. Reply drafts show under You owe
# for 7 days, or until the captain's sent mail answers the thread.
#
# Usage:
#   fm-followups.sh wait <who> <what> [--nudge YYYY-MM-DD] [--from sent:<id> --quote <text>]
#       default nudge: 3 days from today
#   fm-followups.sh owe <who> <what> [--due YYYY-MM-DD] [--from sent:<id> --quote <text>]
#   fm-followups.sh done <#n> [done|replied|dropped]
#   fm-followups.sh triage <mail-id> <needs|fyi|ignore> <reason>
#       firstmate's sorting call for one inbox message, kept in
#       state/brief/mail-triage and applied by bin/fm-probe-mail.sh
#   fm-followups.sh draft <mail-id> [--force]   (reply body on stdin)
#       writes data/drafts/<mail-id>.md addressed to the original sender only,
#       never sent; one draft per thread unless --force replaces it
#   fm-followups.sh list      open follow-ups and drafts, fenced as records
#   fm-followups.sh rows      the brief source
#
# Sorting calls and drafts are counted in the brief's value ledger. Mail ids are
# the `mail:` and `sent:` row ids of the brief's mail source. FM_BRIEF_NOW=<epoch>
# overrides the clock for tests. Exit codes: 0 ok, 1 refused or failed, 2 usage.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
WAITING="$DATA/waiting.md"
DRAFTS="$DATA/drafts"
MAILROWS="$STATE/brief/rows/mail.ndjson"
MARKS="$STATE/brief/mail-triage"
LOCK="$STATE/brief/.followups.lock"
export FM_HOME
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  sed -n '/^# Usage:/,/^# Sorting calls/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//' >&2
  exit 2
}

die() { printf 'fm-followups: %s\n' "$1" >&2; exit 1; }

now() {
  case "${FM_BRIEF_NOW:-}" in ''|*[!0-9]*) date +%s ;; *) printf '%s\n' "$FM_BRIEF_NOW" ;; esac
}

locked() {
  mkdir -p "$STATE/brief" || return 1
  fm_lock_acquire_wait_max "$LOCK" 10 || die "the follow-up tracker is busy"
  trap 'fm_lock_release "$LOCK"' EXIT
  "$@"
}

# day <offset-days>: the local date <offset> days from now.
day() { perl -MPOSIX=strftime -e 'print strftime("%Y-%m-%d", localtime($ARGV[0] + 86400 * $ARGV[1]))' "$(now)" "$1"; }

# field <text>: one line, no tracker separator, bounded.
field() { printf '%s' "$1" | tr '\t\r\n' '   ' | sed 's/·/-/g; s/^ *//; s/ *$//' | cut -c1-200; }

valid_date() { printf '%s' "$1" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; }

# entries: open tracker lines as TSV n, date, kind, who, what, datekw, date, ref, quote.
entries() {
  [ -f "$WAITING" ] || return 0
  awk -F ' · ' '/^- #[0-9]+ · / && NF >= 8 {
    n = substr($1, 4); split($6, d, " ")
    q = $8; for (i = 9; i <= NF; i++) q = q " · " $i
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", n, $2, $3, $4, $5, d[1], (d[2] == "" ? "-" : d[2]), $7, q
  }' "$WAITING"
}

# close_lines <reason> <n>...: strike the open lines numbered <n>.
close_lines() {
  local reason=$1 tmp
  shift
  [ "$#" -gt 0 ] || return 0
  tmp=$(mktemp "$WAITING.XXXXXX") || return 1
  awk -v ns=" $* " -v tail=" · $reason $(day 0)" '
    /^- #[0-9]+ · / { n = $2; sub(/^#/, "", n); if (index(ns, " " n " ")) { print "- ~~" substr($0, 3) "~~" tail; next } }
    { print }' "$WAITING" > "$tmp" && mv -f "$tmp" "$WAITING"
}

mail_row() {  # <id>: the mail source row with that id, or nothing
  [ -f "$MAILROWS" ] || return 0
  jq -c --arg id "$1" 'select(.id == $id)' "$MAILROWS" | head -n 1
}

add() {
  local kind=$1 who what flag=nudge date='' from='' quote='' row ref=captain n
  shift
  [ "$#" -ge 2 ] || usage
  who=$(field "$1"); what=$(field "$2")
  shift 2
  [ -n "$who" ] && [ -n "$what" ] || usage
  [ "$kind" = owe ] && flag=due
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --nudge|--due) [ "$1" = "--$flag" ] && [ "$#" -ge 2 ] || usage; date=$2; shift 2 ;;
      --from) [ "$#" -ge 2 ] || usage; from=$2; shift 2 ;;
      --quote) [ "$#" -ge 2 ] || usage; quote=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -z "$date" ] && [ "$kind" = wait ] && date=$(day 3)
  [ -z "$date" ] || valid_date "$date" || die "dates are YYYY-MM-DD"
  if [ -n "$from" ]; then
    case "$from" in sent:*) ;; *) die "--from takes a sent mail id (sent:...)" ;; esac
    [ -n "$quote" ] || die "a follow-up from sent mail needs --quote with his exact words"
    row=$(mail_row "$from")
    [ -n "$row" ] && [ "$(printf '%s' "$row" | jq -r .section)" = sent ] \
      || die "$from is not in the current sent mail rows; record nothing"
    printf '%s' "$row" | jq -e --arg q "$quote" --arg what "$what" '
      def norm: gsub("[\\s\u00a0]+"; " ") | gsub("[\u2018\u2019]"; "'"'"'") | gsub("[\u201c\u201d]"; "\"") | ascii_downcase | ltrimstr(" ") | rtrimstr(" ");
      ($q | norm) as $nq
      | ($nq | length) >= 8 and ((.text // "") | norm | contains($nq))
        and all([$what | scan("[0-9]+")][]; . as $d | $q | contains($d))' >/dev/null \
      || die "the quote is not his verbatim words in $from (or <what> has a number the quote lacks); record nothing"
    ref="msg $(printf '%s' "$row" | jq -r '.message_id // ""')"
    [ "$ref" != "msg " ] || ref=captain
    quote="\"$(field "$quote")\""
  elif [ -n "$quote" ]; then
    die "--quote goes with --from sent:<id>"
  fi
  [ -n "$quote" ] || quote=-
  n=$(entries | awk -F '\t' -v k="$kind" -v w="$who" -v x="$what" '$3 == k && $4 == w && $5 == x { print $1; exit }')
  if [ -n "$n" ]; then
    printf '#%s (already tracked)\n' "$n"
    return 0
  fi
  mkdir -p "$DATA" || return 1
  [ -f "$WAITING" ] || printf '# Follow-ups\n\nTracked by bin/fm-followups.sh: one line per follow-up; a struck line is closed.\n\n' > "$WAITING"
  n=$(awk '/^- (~~)?#[0-9]+ · / { s = $2; sub(/^(~~)?#/, "", s); if (s + 0 > m) m = s + 0 } END { print m + 1 }' "$WAITING")
  printf -- '- #%s · %s · %s · %s · %s · %s · %s · %s\n' "$n" "$(day 0)" "$kind" "$who" "$what" \
    "$([ -n "$date" ] && printf '%s %s' "$flag" "$date" || printf 'no date')" "$ref" "$quote" >> "$WAITING"
  printf '#%s\n' "$n"
}

done_cmd() {
  local n=${1#\#} reason=${2:-done}
  case "$n" in ''|*[!0-9]*) usage ;; esac
  case "$reason" in done|replied|dropped) ;; *) usage ;; esac
  entries | awk -F '\t' -v n="$n" '$1 == n { f = 1 } END { exit !f }' || die "no open follow-up #$n"
  close_lines "$reason" "$n"
}

triage() {
  local id=$1 class=$2 reason tmp
  shift 2
  reason=$(field "$*" | cut -c1-100)
  case "$id" in mail:?*) ;; *) die "triage takes an inbox mail id (mail:...)" ;; esac
  case "$class" in needs|fyi|ignore) ;; *) usage ;; esac
  [ -n "$reason" ] || usage
  tmp=$(mktemp "$MARKS.XXXXXX") || return 1
  { [ -f "$MARKS" ] && awk -F '\t' -v id="$id" '$1 != id' "$MARKS"; printf '%s\t%s\t%s\n' "$id" "$class" "$reason"; } > "$tmp"
  mv -f "$tmp" "$MARKS" || return 1
  "$SCRIPT_DIR/fm-daily-brief.sh" value sorted "$id" || true
}

draft() {
  local id=$1 force=${2:-} row file body subject
  case "$force" in ''|--force) ;; *) usage ;; esac
  row=$(mail_row "$id")
  case "$id" in mail:?*) ;; *) row= ;; esac
  [ -n "$row" ] || die "$id is not an inbox message in the current mail rows"
  file="$DRAFTS/$(printf '%s' "$id" | tr -c 'A-Za-z0-9._-' '-').md"
  [ ! -e "$file" ] || [ "$force" = --force ] || die "a draft for this thread exists ($file); --force replaces it"
  body=$(cat)
  [ -n "$(printf '%s' "$body" | tr -d ' \t\n')" ] || die "the reply body on stdin is empty"
  subject=$(printf '%s' "$row" | jq -r '.subject // "" | if test("^re:"; "i") then . else "Re: " + . end')
  mkdir -p "$DRAFTS" || return 1
  {
    printf 'To: %s\n' "$(printf '%s' "$row" | jq -r '.from_addr')"
    printf 'Subject: %s\n' "$(field "$subject")"
    printf 'In-Reply-To: %s\n' "$(printf '%s' "$row" | jq -r '.message_id // ""')"
    printf 'Drafted: %s\n\n' "$(day 0)"
    printf 'Not sent. Firstmate never sends mail: copy this reply into your mail client, check it, and send it yourself.\n\n---\n\n'
    printf '%s\n' "$body"
  } > "$file.tmp" && mv -f "$file.tmp" "$file" || return 1
  "$SCRIPT_DIR/fm-daily-brief.sh" value drafted "$id" || true
  printf '%s\n' "$file"
}

# drafts_tsv: name, to, subject, in-reply-to, drafted date.
drafts_tsv() {
  local f
  for f in "$DRAFTS"/*.md; do
    [ -f "$f" ] || continue
    awk -v name="$(basename "$f")" '
      /^$/ { exit } { k = $0; sub(/:.*/, "", k); v = $0; sub(/^[^:]*: */, "", v); h[k] = v }
      END { printf "%s\t%s\t%s\t%s\t%s\n", name, h["To"], h["Subject"], h["In-Reply-To"], h["Drafted"] }' "$f"
  done
}

rows() {
  local mail=/dev/null replied today soon
  [ -f "$MAILROWS" ] && mail=$MAILROWS
  today=$(day 0); soon=$(day 1)
  # Waits from sent mail whose thread got an inbox reply close themselves.
  # shellcheck disable=SC2046 # One number per word.
  replied=$(entries | jq -R -r --slurpfile mail "$mail" '
    ([$mail[] | select(.section != "sent") | (.refs // [])[]]) as $refs
    | split("\t") | select(.[2] == "wait" and (.[7] | startswith("msg <")))
    | select(.[7][4:] as $m | $refs | index($m)) | .[0]')
  # shellcheck disable=SC2086 # One number per word.
  [ -z "$replied" ] || close_lines replied $replied
  entries | jq -R -c --arg today "$today" --arg soon "$soon" '
    split("\t") | {n: .[0], since: .[1], kind: .[2], who: .[3], what: .[4], date: .[6]}
    | ("follow:#" + .n) as $id
    | if .kind == "wait" then
        if .date != "-" and .date <= $today then
          {id: $id, section: "needs", title: ("No reply from " + .who + " on " + .what + " since " + .since + " - nudge?")}
        else
          {id: $id, section: "waiting", title: (.who + ": " + .what + " (since " + .since + (if .date != "-" then ", nudge " + .date else "" end) + ")")}
        end
      elif .date != "-" and .date <= $soon then
        {id: $id, section: "needs", title: ("You owe " + .who + ": " + .what + " - due " + .date)}
      else
        {id: $id, section: "owe", title: (.who + ": " + .what + (if .date != "-" then " (due " + .date + ")" else "" end))}
      end'
  drafts_tsv | jq -R -c --slurpfile mail "$mail" --arg oldest "$(day -7)" '
    ([$mail[] | select(.section == "sent") | (.refs // [])[]]) as $answered
    | split("\t") | select(.[4] >= $oldest and (.[3] == "" or ($answered | index(.[3]) | not)))
    | {id: ("draft:" + .[0]), section: "owe", title: ("Reply draft for " + .[1] + ": " + .[2] + " - data/drafts/" + .[0])}'
}

list() {
  {
    echo "Open follow-ups (#n, since, kind, who, what, date kind, date, ref, quote):"
    entries
    echo "Reply drafts (file, to, subject, in-reply-to, drafted):"
    drafts_tsv
  } | "$SCRIPT_DIR/fm-records.sh" wrap followups
}

CMD=${1:-}
[ "$#" -eq 0 ] || shift
case "$CMD" in
  wait|owe) locked add "$CMD" "$@" ;;
  done) [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage; locked done_cmd "$@" ;;
  triage) [ "$#" -ge 3 ] || usage; locked triage "$@" ;;
  draft) [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage; draft "$@" ;;
  list) [ "$#" -eq 0 ] || usage; list ;;
  rows) [ "$#" -eq 0 ] || usage; locked rows ;;
  -h|--help|help) sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//' ;;
  *) usage ;;
esac
