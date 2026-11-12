#!/usr/bin/env bash
# fm-routine.sh - captain-registered routines: scheduled shell probes that wake
# firstmate only when they find something new.
#
# A routine is one private definition, data/routines/<id>.routine, where <id>
# matches [a-z0-9][a-z0-9-]* (at most 48 characters). Its non-comment lines
# are key=value:
#   schedule=every <N>m | every <N>h | daily HH:MM | weekdays HH:MM | <days> HH:MM
#       <days> is a comma list of mon..sun. Times are local wall-clock time
#       (TZ), never a monotonic clock, because a laptop sleeps.
#   probe=<command>      run through `sh -c` from FM_HOME (required)
#   reach=<target>...    optional bin/fm-reach.sh targets; while any is
#                        unreachable the run is deferred, not failed
#   min_interval=<secs>  optional pacing floor between probe runs (default 300)
#   action=<one line>    optional instruction firstmate follows on a wake
# data/routines/<id>.paused pauses a routine (see pause/resume).
#
# Probe contract. The probe gets FM_ROUTINE_ID, FM_ROUTINE_CURSOR (the
# committed cursor text, empty on the first run), and FM_ROUTINE_CURSOR_OUT (a
# file it may write its proposed next cursor to). It prints one line per NEW
# item since the cursor, NDJSON such as {"id":"...","title":"..."} recommended.
# No output, or the single line `NOTHING NEW`, means nothing new. Exit 0 is
# success, exit 3 means its source is unreachable right now (deferred, not a
# failure), and any other exit or the time bound is a failure.
#
# Tick (the standing watcher check). Only the machine holding the routine-owner
# lease runs routines (bin/fm-routine-owner.sh claim refreshes it each tick).
# For each routine:
#   - Two-phase cursor: a run that finds items stores them and the proposed
#     cursor as pending and queues one `check: routine <id>` wake (key
#     routine:<id>). The cursor commits only on a later tick that finds that
#     wake row gone, i.e. acknowledged after handling; until then the routine
#     does not probe again. A crash or lost wake re-presents the same items.
#   - Nothing new: no wake and no output; a proposed cursor commits at once.
#   - Failure keeps the cursor and backs off exponentially from
#     FM_ROUTINE_BACKOFF_BASE (default 900s) to FM_ROUTINE_BACKOFF_MAX
#     (default 14400s); the first time the delay reaches the cap, one
#     `routine-failing:<id>` wake is queued for that failure streak.
#   - A daily slot missed by less than FM_ROUTINE_CATCHUP_SECS (default 43200)
#     runs once late; an older one records a `missed` receipt instead.
# The tick prints one summary line only when it queued a wake or found an
# invalid definition, so an idle tick prints nothing and costs no tokens. All
# probes share a budget below the watcher's FM_CHECK_TIMEOUT; each is bounded by
# FM_ROUTINE_PROBE_TIMEOUT (default 20s), and routines that do not fit wait for
# the next sweep.
#
# Usage:
#   fm-routine.sh list                each routine's schedule, state, last outcome
#   fm-routine.sh show <id>           action plus pending items and last error,
#                                     fenced as untrusted records
#   fm-routine.sh run-now <id>        run at the next tick regardless of the
#                                     schedule or backoff (min_interval holds)
#   fm-routine.sh pause|resume <id>
#   fm-routine.sh tick                one scheduler pass (what the check runs)
#   fm-routine.sh arm | disarm        write and register, or remove,
#                                     state/routines.check.sh
#
# State: state/routines/<id>/ holds cursor, pending, pending.cursor,
# pending.woke, run (pacing fields), and error. FM_ROUTINE_NOW=<epoch> overrides
# the clock for tests. Exit codes: 0 ok, 1 failure, 2 usage.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
DEFS="$DATA/routines"
RSTATE="$STATE/routines"
CHECK_ID=routines
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

num() { case "${1:-}" in ''|*[!0-9]*) printf '%s\n' "${2:-0}" ;; *) printf '%s\n' "$1" ;; esac; }

BACKOFF_BASE=$(num "${FM_ROUTINE_BACKOFF_BASE:-}" 900)
BACKOFF_MAX=$(num "${FM_ROUTINE_BACKOFF_MAX:-}" 14400)
CATCHUP=$(num "${FM_ROUTINE_CATCHUP_SECS:-}" 43200)
PROBE_TIMEOUT=$(num "${FM_ROUTINE_PROBE_TIMEOUT:-}" 20)
BUDGET=$(( $(num "${FM_CHECK_TIMEOUT:-}" 30) - 5 ))

usage() {
  echo "usage: fm-routine.sh list | show <id> | run-now <id> | pause <id> | resume <id> | tick | arm | disarm" >&2
  exit 2
}

now() { num "${FM_ROUTINE_NOW:-}" "$(date +%s)"; }

fmt_time() { perl -MPOSIX=strftime -e 'print strftime("%Y-%m-%d %H:%M", localtime($ARGV[0]))' "$1"; }

valid_id() {
  case "$1" in ''|[!a-z0-9]*|*[!a-z0-9-]*) return 1 ;; esac
  [ "${#1}" -le 48 ]
}

need_id() {
  valid_id "${1:-}" && [ -f "$DEFS/$1.routine" ] || { echo "fm-routine: no routine named '${1:-}'" >&2; exit 2; }
}

def_get() {  # <file> <key>: the last value of <key>
  awk -v k="$2" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) } END { if (v != "") print v }' "$1"
}

# parse_schedule <text>: set S_EVERY (seconds) or S_DAYS (ISO weekday digits)
# plus S_H and S_M; nonzero for an invalid schedule.
parse_schedule() {
  local spec=$1 when days d out=
  S_EVERY='' S_DAYS='' S_H='' S_M=''
  read -r when days <<EOF
$spec
EOF
  case "$when" in
    every)
      d=${days%[mh]}
      case "$d" in ''|*[!0-9]*) return 1 ;; esac
      case "$days" in
        *m) S_EVERY=$(( 10#$d * 60 )) ;;
        *h) S_EVERY=$(( 10#$d * 3600 )) ;;
        *) return 1 ;;
      esac
      [ "$S_EVERY" -gt 0 ]
      return ;;
    daily) out=1234567 ;;
    weekdays) out=12345 ;;
    *)
      for d in $(printf '%s' "$when" | tr ',' ' '); do
        case "$d" in
          mon) out="${out}1" ;; tue) out="${out}2" ;; wed) out="${out}3" ;; thu) out="${out}4" ;;
          fri) out="${out}5" ;; sat) out="${out}6" ;; sun) out="${out}7" ;;
          *) return 1 ;;
        esac
      done ;;
  esac
  case "$days" in
    [0-2][0-9]:[0-5][0-9]) ;;
    *) return 1 ;;
  esac
  S_H=$((10#${days%:*})) S_M=$((10#${days#*:}))
  [ "$S_H" -le 23 ] && [ -n "$out" ] || return 1
  S_DAYS=$out
}

latest_slot() {  # <now>: the latest scheduled time at or before <now>
  perl -MPOSIX=mktime -e '
    my ($now, $h, $m, $days) = @ARGV;
    for my $d (0 .. 7) {
      my @t = localtime($now - $d * 86400);
      my $c = mktime(0, $m, $h, $t[3], $t[4], $t[5], 0, 0, -1);
      my $w = (localtime $c)[6] || 7;
      if ($c <= $now && index($days, $w) >= 0) { print "$c\n"; exit 0 }
    }
    exit 1' "$1" "$S_H" "$S_M" "$S_DAYS"
}

# --- per-routine run record -------------------------------------------------
run_load() {  # <dir>
  local k v
  R_LAST_TRY=0 R_LAST_OK=0 R_SLOT=0 R_FAILS=0 R_RETRY_AT=0 R_ALERTED=0 R_OUTCOME='' R_OUTCOME_AT=0 R_INVALID=''
  [ -f "$1/run" ] || return 0
  while IFS='=' read -r k v; do
    case "$k" in
      last_try) R_LAST_TRY=$(num "$v") ;;
      last_ok) R_LAST_OK=$(num "$v") ;;
      slot) R_SLOT=$(num "$v") ;;
      fails) R_FAILS=$(num "$v") ;;
      retry_at) R_RETRY_AT=$(num "$v") ;;
      alerted) R_ALERTED=$(num "$v") ;;
      outcome) R_OUTCOME=$v ;;
      outcome_at) R_OUTCOME_AT=$(num "$v") ;;
      invalid) R_INVALID=$v ;;
    esac
  done < "$1/run"
}

run_save() {  # <dir>
  printf 'last_try=%s\nlast_ok=%s\nslot=%s\nfails=%s\nretry_at=%s\nalerted=%s\noutcome=%s\noutcome_at=%s\ninvalid=%s\n' \
    "$R_LAST_TRY" "$R_LAST_OK" "$R_SLOT" "$R_FAILS" "$R_RETRY_AT" "$R_ALERTED" \
    "$R_OUTCOME" "$R_OUTCOME_AT" "$R_INVALID" > "$1/run.tmp" && mv -f "$1/run.tmp" "$1/run"
}

outcome() { R_OUTCOME=$1 R_OUTCOME_AT=$NOW; }

# --- tick ---------------------------------------------------------------------
SUMMARY=

say() { SUMMARY="${SUMMARY:+$SUMMARY; }$1"; }

wake_items() {  # <id> <dir>
  local n
  n=$(awk 'END { print NR }' "$2/pending")
  fm_wake_append check "routine:$1" \
    "check: routine $1: $n new item(s); read them with $SCRIPT_DIR/fm-routine.sh show $1" || return 1
  : > "$2/pending.woke"
  say "$1 $n new"
}

# settle_pending <id> <dir>: 0 when the routine may probe now.
settle_pending() {
  local id=$1 dir=$2
  [ -f "$dir/pending" ] || { rm -f "$dir/pending.cursor" "$dir/pending.woke"; return 0; }
  if [ ! -f "$dir/pending.woke" ]; then
    wake_items "$id" "$dir"
    return 1
  fi
  if fm_wake_queued_keys check | grep -Fqx "routine:$id"; then
    return 1
  fi
  # The wake was acknowledged after handling: commit phase two.
  if [ -f "$dir/pending.cursor" ]; then
    mv -f "$dir/pending.cursor" "$dir/cursor" || return 1
  fi
  rm -f "$dir/pending" && rm -f "$dir/pending.woke"
}

# due <id> <dir> <def>: 0 when a probe should run now; sets DUE_SLOT.
due() {
  local id=$1 dir=$2 def=$3 floor slot forced=0
  DUE_SLOT=
  floor=$(num "$(def_get "$def" min_interval)" 300)
  [ -f "$dir/run-now" ] && forced=1
  [ $((NOW - R_LAST_TRY)) -ge "$floor" ] || return 1
  [ "$forced" = 1 ] || [ "$NOW" -ge "$R_RETRY_AT" ] || return 1
  if [ -n "$S_EVERY" ]; then
    [ "$forced" = 1 ] || [ $((NOW - R_LAST_OK)) -ge "$S_EVERY" ]
    return
  fi
  slot=$(latest_slot "$NOW") || return 1
  if [ "$slot" -gt "$R_SLOT" ]; then
    if [ $((NOW - slot)) -gt "$CATCHUP" ]; then
      R_SLOT=$slot
      outcome "missed $(fmt_time "$slot")"
      run_save "$dir"
    else
      DUE_SLOT=$slot
      return 0
    fi
  fi
  [ "$forced" = 1 ]
}

# probe <id> <dir> <def> <bound>: run the probe once and record its outcome.
probe() {
  local id=$1 dir=$2 def=$3 bound=$4 cmd rc=0 items delay i target
  cmd=$(def_get "$def" probe)
  for target in $(def_get "$def" reach); do
    if ! "$SCRIPT_DIR/fm-reach.sh" "$target" >/dev/null 2>&1; then
      outcome "deferred: $target unreachable"
      run_save "$dir"
      return 0
    fi
  done
  rm -f "$dir/run-now" "$dir/pending.cursor"
  R_LAST_TRY=$NOW
  (
    cd "$FM_HOME" || exit 1
    FM_ROUTINE_ID=$id
    FM_ROUTINE_CURSOR=$(cat "$dir/cursor" 2>/dev/null || true)
    FM_ROUTINE_CURSOR_OUT="$dir/pending.cursor"
    export FM_HOME FM_ROUTINE_ID FM_ROUTINE_CURSOR FM_ROUTINE_CURSOR_OUT
    fm_run_timed "$bound" sh -c "$cmd" < /dev/null
  ) > "$dir/probe.out" 2> "$dir/error" || rc=$?
  items=$(grep -v '^[[:space:]]*$' "$dir/probe.out" || true)
  [ "$items" != "NOTHING NEW" ] || items=
  if [ "$rc" -eq 3 ]; then
    rm -f "$dir/pending.cursor"
    outcome "deferred: source unreachable"
  elif [ "$rc" -ne 0 ]; then
    rm -f "$dir/pending.cursor"
    [ "$rc" -eq 124 ] && printf 'probe did not finish within %ss\n' "$bound" >> "$dir/error"
    R_FAILS=$((R_FAILS + 1))
    delay=$BACKOFF_BASE i=1
    while [ "$i" -lt "$R_FAILS" ] && [ "$delay" -lt "$BACKOFF_MAX" ]; do
      delay=$((delay * 2)) i=$((i + 1))
    done
    [ "$delay" -le "$BACKOFF_MAX" ] || delay=$BACKOFF_MAX
    R_RETRY_AT=$((NOW + delay))
    outcome "failed (exit $rc, $R_FAILS in a row)"
    if [ "$delay" -ge "$BACKOFF_MAX" ] && [ "$R_ALERTED" = 0 ]; then
      fm_wake_append check "routine-failing:$id" \
        "check: routine $id: probe failed $R_FAILS times in a row, now retrying every ${BACKOFF_MAX}s; see $SCRIPT_DIR/fm-routine.sh show $id" \
        && R_ALERTED=1 && say "$id failing"
    fi
  else
    : > "$dir/error"
    R_LAST_OK=$NOW R_FAILS=0 R_RETRY_AT=0 R_ALERTED=0
    [ -z "$DUE_SLOT" ] || R_SLOT=$DUE_SLOT
    if [ -z "$items" ]; then
      [ ! -f "$dir/pending.cursor" ] || mv -f "$dir/pending.cursor" "$dir/cursor"
      outcome "nothing new"
    else
      printf '%s\n' "$items" > "$dir/pending.tmp" && mv -f "$dir/pending.tmp" "$dir/pending"
      outcome "$(printf '%s\n' "$items" | awk 'END { print NR }') new"
      run_save "$dir"
      wake_items "$id" "$dir"
      return 0
    fi
  fi
  run_save "$dir"
}

tick() {
  local def id dir remaining defs=() reason
  for def in "$DEFS"/*.routine; do [ -f "$def" ] && defs+=("$def"); done
  [ "${#defs[@]}" -gt 0 ] || return 0
  "$SCRIPT_DIR/fm-routine-owner.sh" claim >/dev/null 2>&1 || return 0
  mkdir -p "$RSTATE" || return 1
  TICK_LOCK="$RSTATE/.tick.lock"
  fm_lock_acquire_wait_max "$TICK_LOCK" 1 || return 0
  trap 'fm_lock_release "$TICK_LOCK"' EXIT
  NOW=$(now)
  for def in "${defs[@]}"; do
    id=$(basename "$def" .routine)
    valid_id "$id" || continue
    dir="$RSTATE/$id"
    mkdir -p "$dir" || continue
    run_load "$dir"
    reason=
    parse_schedule "$(def_get "$def" schedule)" || reason="bad schedule"
    [ -n "$(def_get "$def" probe)" ] || reason="no probe"
    if [ -n "$reason" ]; then
      if [ "$R_INVALID" != "$reason" ]; then
        R_INVALID=$reason
        run_save "$dir"
        say "$id invalid definition: $reason"
      fi
      continue
    fi
    if [ -n "$R_INVALID" ]; then R_INVALID=; run_save "$dir"; fi
    settle_pending "$id" "$dir" || continue
    [ ! -f "$DEFS/$id.paused" ] || continue
    due "$id" "$dir" "$def" || continue
    remaining=$((BUDGET - SECONDS))
    [ "$remaining" -ge 3 ] || break
    [ "$remaining" -le "$PROBE_TIMEOUT" ] || remaining=$PROBE_TIMEOUT
    probe "$id" "$dir" "$def" "$remaining"
  done
  [ -z "$SUMMARY" ] || printf 'routines: %s\n' "$SUMMARY" | cut -c1-240
}

# --- inspection -----------------------------------------------------------------
list() {
  local def id dir state
  if ! "$SCRIPT_DIR/fm-routine-owner.sh" check 2>/dev/null; then
    echo "note: this machine does not hold the routine-owner lease; routines run where it is held"
  fi
  NOW=$(now)
  for def in "$DEFS"/*.routine; do
    [ -f "$def" ] || continue
    id=$(basename "$def" .routine)
    dir="$RSTATE/$id"
    run_load "$dir"
    if [ -n "$R_INVALID" ]; then state="invalid: $R_INVALID"
    elif [ -f "$dir/pending" ]; then state="waiting for its wake to be handled"
    elif [ -f "$DEFS/$id.paused" ]; then state=paused
    elif [ "$R_RETRY_AT" -gt "$NOW" ]; then state="backoff until $(fmt_time "$R_RETRY_AT") retry_at=$R_RETRY_AT"
    else state=idle
    fi
    printf '%s\t%s\t%s\t' "$id" "$(def_get "$def" schedule)" "$state"
    if [ -n "$R_OUTCOME" ]; then
      printf 'last: %s at %s\n' "$R_OUTCOME" "$(fmt_time "$R_OUTCOME_AT")"
    else
      printf 'last: never run\n'
    fi
  done
}

show() {
  local id=$1 dir="$RSTATE/$1" def="$DEFS/$1.routine" action
  action=$(def_get "$def" action)
  printf 'routine %s (%s)\n' "$id" "$(def_get "$def" schedule)"
  printf 'action: %s\n' "${action:-surface what needs the captain; otherwise stay silent}"
  if [ -f "$dir/pending" ]; then
    printf 'pending items (the cursor commits after this wake is acknowledged; nothing captain-relevant means a silent wake):\n'
    "$SCRIPT_DIR/fm-records.sh" wrap routine < "$dir/pending"
  else
    echo "no pending items"
  fi
  if [ -s "$dir/error" ]; then
    echo "last probe error:"
    "$SCRIPT_DIR/fm-records.sh" wrap routine < "$dir/error"
  fi
}

# --- arm / disarm -----------------------------------------------------------------
arm() {
  local home device want tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || { echo "fm-routine: state directory is unavailable" >&2; return 1; }
  home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || { echo "fm-routine: cannot resolve FM_HOME" >&2; return 1; }
  device=$(fm_pr_file_device "$STATE") || return 1
  want=$(printf '%s\n' '#!/usr/bin/env bash' \
    '# Auto-generated by fm-routine.sh - routine scheduler tick.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-routine.sh") tick")
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || { echo "fm-routine: check path is unavailable" >&2; return 1; }
  if [ "$(cat "$CHECK_SHIM" 2>/dev/null)" != "$want" ]; then
    tmp=$(umask 077; mktemp "$STATE/.fm-routine-check.XXXXXX") || return 1
    if ! printf '%s\n' "$want" > "$tmp" || ! chmod 0700 "$tmp" || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
      rm -f -- "$tmp"
      echo "fm-routine: could not write $CHECK_SHIM" >&2
      return 1
    fi
  fi
  # A shim without a matching trust binding makes the watcher report it every
  # sweep, so a failed registration leaves no shim behind.
  if ! FM_HOME="$home" "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID" >/dev/null; then
    fm_custom_check_registered "$STATE" "$CHECK_ID" || rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
    echo "fm-routine: could not register $CHECK_SHIM" >&2
    return 1
  fi
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

CMD=${1:-}
[ "$#" -eq 0 ] || shift
case "$CMD" in
  tick) [ "$#" -eq 0 ] || usage; tick ;;
  list) [ "$#" -eq 0 ] || usage; list ;;
  show) [ "$#" -eq 1 ] || usage; need_id "$1"; show "$1" ;;
  run-now) [ "$#" -eq 1 ] || usage; need_id "$1"; mkdir -p "$RSTATE/$1" && : > "$RSTATE/$1/run-now" ;;
  pause) [ "$#" -eq 1 ] || usage; need_id "$1"; : > "$DEFS/$1.paused" ;;
  resume) [ "$#" -eq 1 ] || usage; need_id "$1"; rm -f "$DEFS/$1.paused" ;;
  arm) [ "$#" -eq 0 ] || usage; arm ;;
  disarm)
    [ "$#" -eq 0 ] || usage
    rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
    printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID" ;;
  -h|--help|help) sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//' ;;
  *) usage ;;
esac
