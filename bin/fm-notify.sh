#!/usr/bin/env bash
# fm-notify.sh - push one captain-facing notice to the configured phone or
# desktop channel, at most once per stretch of the same cause.
#
# Only firstmate invokes this: a worker or secondmate (FM_TASK_ID set) is
# refused, because workers never address the captain and a secondmate reaches
# the captain through its parent channel. A payload carries metadata - a short
# title, an optional short body, and a link - never secrets, credentials, or
# message bodies copied from mail or chat.
#
# Usage:
#   fm-notify.sh send <needs-you|fyi> <key> <title> [<body>] [<url>]
#       Deliver one notice for cause <key> ([A-Za-z0-9][A-Za-z0-9._:-]*).
#       A key already notified in the current stretch is skipped until
#       `clear <key>` ends that stretch. During quiet time (see quiet-now) an
#       fyi notice is held, not delivered; needs-you always delivers. Before
#       delivering outside quiet time, any held fyi notices are flushed first
#       as one summary notice.
#   fm-notify.sh clear <key>
#       End the stretch for <key>, so its next send delivers again. Safe when
#       no stretch is open.
#   fm-notify.sh flush
#       Outside quiet time, deliver held fyi notices as one summary notice.
#   fm-notify.sh quiet-now
#       Exit 0 when fyi notices are held right now, 1 otherwise. Quiet time is
#       a config/quiet-hours window or this home's /quiet mode (state/.afk in
#       quiet mode, bin/fm-wake-lib.sh fm_afk_mode).
#
# config/notify (local, gitignored): one channel directive per non-empty,
# non-comment line, the same directive shape as config/wedge-alarm:
#   command:<cmd>   run <cmd> via `sh -c` with $1=level $2=title $3=body $4=url
#   off             disable every channel
# Every command channel runs best-effort, bounded by FM_NOTIFY_TIMEOUT_SECS
# (default 10). A notice counts as delivered when at least one channel exits 0.
# No file, an empty file, or `off` makes send a no-op that prints one notice on
# stderr and exits 0 without opening a stretch.
#
# config/quiet-hours (local, gitignored): one window per non-empty, non-comment
# line, `[<days>] HH:MM-HH:MM`, where <days> is a comma list of mon..sun and
# names the day a window starts on (default: every day). A window whose end is
# not after its start crosses midnight; 24:00 is a valid end. Example:
#   22:00-07:30
#   sat,sun 00:00-24:00
# FM_QUIET_HOURS_NOW="<iso-weekday 1-7> <HH:MM>" overrides the clock for tests.
#
# State: state/notify/<key> marks an open stretch; state/notify/held holds the
# titles of held fyi notices. Exit codes: 0 delivered, skipped, held, or no
# channel; 1 every channel failed; 2 usage; 6 refused (not firstmate).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
NOTIFY_DIR="$STATE/notify"
HELD="$NOTIFY_DIR/held"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {
  echo "usage: fm-notify.sh send <needs-you|fyi> <key> <title> [<body>] [<url>] | clear <key> | flush | quiet-now" >&2
  exit 2
}

die() {
  echo "fm-notify: $*" >&2
  exit 2
}

valid_key() {
  case "$1" in
    ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._:-]*) return 1 ;;
  esac
  [ "${#1}" -le 128 ]
}

# clean <max-chars> <text>: one line, no control characters, bounded length.
clean() {
  printf '%s' "$2" | LC_ALL=C tr -d '\000-\010\013-\037\177' | tr '\t\n\r' '   ' | cut -c "1-$1"
}

# quiet_minutes <HH:MM> -> minutes since midnight, or nonzero for bad input.
quiet_minutes() {
  case "$1" in
    [0-9][0-9]:[0-5][0-9]) ;;
    *) return 1 ;;
  esac
  local m=$((10#${1%%:*} * 60 + 10#${1##*:}))
  [ "$m" -le 1440 ] || return 1
  printf '%s\n' "$m"
}

day_number() {
  case "$1" in
    mon) echo 1 ;; tue) echo 2 ;; wed) echo 3 ;; thu) echo 4 ;;
    fri) echo 5 ;; sat) echo 6 ;; sun) echo 7 ;; *) return 1 ;;
  esac
}

# days_include <days-csv|*> <iso-weekday>
days_include() {
  local day n
  [ "$1" = '*' ] && return 0
  for day in ${1//,/ }; do
    n=$(day_number "$day") || return 1
    [ "$n" = "$2" ] && return 0
  done
  return 1
}

in_quiet_hours() {
  local file="$CONFIG/quiet-hours" now dow hhmm cur yday line days span start end day
  [ -f "$file" ] || return 1
  now=${FM_QUIET_HOURS_NOW:-$(date '+%u %H:%M')}
  dow=${now%% *}
  hhmm=${now#* }
  cur=$(quiet_minutes "$hhmm") || die "bad clock '$now'"
  yday=$(( (dow + 5) % 7 + 1 ))
  set -f
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    # shellcheck disable=SC2086
    set -- $line
    case $# in
      0) continue ;;
      1) days='*'; span=$1 ;;
      2) days=$1; span=$2 ;;
      *) die "bad config/quiet-hours line: $line" ;;
    esac
    if [[ $span != *-* ]] || ! start=$(quiet_minutes "${span%%-*}") || ! end=$(quiet_minutes "${span#*-}"); then
      die "bad config/quiet-hours window: $span"
    fi
    if [ "$days" != '*' ]; then
      for day in ${days//,/ }; do
        day_number "$day" >/dev/null || die "bad config/quiet-hours day: $day"
      done
    fi
    if [ "$start" -lt "$end" ]; then
      [ "$cur" -ge "$start" ] && [ "$cur" -lt "$end" ] && days_include "$days" "$dow" && return 0
    else
      [ "$cur" -ge "$start" ] && days_include "$days" "$dow" && return 0
      [ "$cur" -lt "$end" ] && days_include "$days" "$yday" && return 0
    fi
  done < "$file"
  return 1
}

quiet_now() {
  if [ -e "$STATE/.afk" ] && [ "$(fm_afk_mode "$STATE")" = quiet ]; then
    return 0
  fi
  in_quiet_hours
}

# channels: print each configured command, or nothing when none or off.
channels() {
  local file="$CONFIG/notify" line cmds=()
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in
      ''|'#'*) ;;
      off) return 0 ;;
      command:?*) cmds+=("${line#command:}") ;;
      *) echo "fm-notify: ignoring unknown config/notify directive: $line" >&2 ;;
    esac
  done < "$file"
  [ "${#cmds[@]}" -eq 0 ] || printf '%s\n' "${cmds[@]}"
}

# deliver <level> <title> <body> <url>: 0 when any channel succeeded, 3 when
# no channel is configured, 1 when every channel failed.
deliver() {
  local cmd any=0 ok=1 rc
  while IFS= read -r cmd; do
    any=1
    rc=0
    fm_run_timed "${FM_NOTIFY_TIMEOUT_SECS:-10}" sh -c "$cmd" fm-notify "$@" </dev/null >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
      ok=0
    else
      echo "fm-notify: channel exited $rc: $cmd" >&2
    fi
  done < <(channels)
  [ "$any" = 1 ] || return 3
  return "$ok"
}

flush_held() {
  local count body rc=0
  [ -s "$HELD" ] || return 0
  quiet_now && return 0
  count=$(wc -l < "$HELD" | tr -d ' ')
  body=$(clean 500 "$(paste -sd ';' "$HELD")")
  deliver fyi "$count update(s) held during quiet time" "$body" '' || rc=$?
  case "$rc" in
    0|3) rm -f "$HELD" ;;
    *) return "$rc" ;;
  esac
}

if [ -n "${FM_TASK_ID:-}" ]; then
  echo "fm-notify: refused: only firstmate pushes to the captain (FM_TASK_ID=$FM_TASK_ID)" >&2
  exit 6
fi

CMD=${1:-}
[ "$#" -eq 0 ] || shift
mkdir -p "$NOTIFY_DIR"
LOCK="$NOTIFY_DIR/.lock"

case "$CMD" in
  send)
    [ "$#" -ge 3 ] && [ "$#" -le 5 ] || usage
    level=$1 key=$2
    case "$level" in needs-you|fyi) ;; *) die "level must be needs-you or fyi: $level" ;; esac
    valid_key "$key" || die "bad key: $key"
    title=$(clean 120 "$3")
    body=$(clean 500 "${4:-}")
    url=$(clean 500 "${5:-}")
    case "$url" in ''|https://*|http://*) ;; *) die "url must be http(s): $url" ;; esac
    [ -n "$title" ] || die "empty title"
    fm_lock_acquire_wait "$LOCK"
    trap 'fm_lock_release "$LOCK"' EXIT
    if [ -e "$NOTIFY_DIR/$key" ]; then
      exit 0
    fi
    if [ -z "$(channels)" ]; then
      echo "fm-notify: no channel configured (config/notify); notice not sent" >&2
      exit 0
    fi
    if [ "$level" = fyi ] && quiet_now; then
      printf '%s\n' "$title" >> "$HELD"
      date +%s > "$NOTIFY_DIR/$key"
      exit 0
    fi
    flush_held || true
    rc=0
    deliver "$level" "$title" "$body" "$url" || rc=$?
    case "$rc" in
      0) date +%s > "$NOTIFY_DIR/$key" ;;
      3) echo "fm-notify: no channel configured (config/notify); notice not sent" >&2 ;;
      *) exit 1 ;;
    esac
    ;;
  clear)
    [ "$#" -eq 1 ] || usage
    valid_key "$1" || die "bad key: $1"
    rm -f "$NOTIFY_DIR/$1"
    ;;
  flush)
    [ "$#" -eq 0 ] || usage
    fm_lock_acquire_wait "$LOCK"
    trap 'fm_lock_release "$LOCK"' EXIT
    flush_held
    ;;
  quiet-now)
    [ "$#" -eq 0 ] || usage
    quiet_now
    ;;
  -h|--help|help)
    sed -n '2,/^set -eu$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
    ;;
  *) usage ;;
esac
