#!/usr/bin/env bash
# fm-friction.sh - friction sentinel and wake loop guard for one home.
#
# Both read this home's own logs only and never another home's: worker status
# logs (state/*.status), the delivered-wake log (state/.watch-deliveries.log),
# and the watcher triage log (state/.watch-triage.log). A line is normalized
# before it is compared: timestamps, [at=]/[key=]/[corr=] tags, URLs, and
# directory parts of paths are removed or replaced, and every run of three or
# more digits becomes N, so the same failure on a different message number or
# time reads the same while short endpoint ids such as w1F:p2 stay distinct.
#
# Usage:
#   fm-friction.sh check
#       The watcher check (state/friction.check.sh after `arm`): run the loop
#       guard, then `scan` when the last scan is older than
#       FM_FRICTION_SCAN_SECS (default 86400). Prints only loop-guard alerts.
#   fm-friction.sh loop
#       Loop guard. Reads delivered wakes added since the last run and keeps
#       one streak per normalized wake, so the same stale endpoint or the same
#       check result counts as one streak even when other wakes interleave.
#       Each repeat extends the streak; no repeat for FM_LOOP_GAP_SECS
#       (default 7200) ends it. When a streak reaches FM_LOOP_THRESHOLD
#       (default 5) it prints one `loop guard: ...` line, once per streak; the
#       watcher turns it into a check wake. Exempt: declared paused waits,
#       heartbeats, signals, rearm resurfacing, informational batches, and
#       the guard's own wakes. The first run only records the log size, so
#       old history never alerts.
#   fm-friction.sh scan
#       Friction sentinel. Reads lines added since the last scan - `blocked`
#       and `failed` status lines, every non-exempt stale or check wake, and
#       triage lines naming an error, failure, refusal, or timeout - and
#       upserts one row per normalized signature into data/friction.jsonl.
#       A first scan reads each log from its start.
#   fm-friction.sh top [<n>]
#       Print the <n> (default 3) most frequent signatures:
#       <count>x <turns> turns [<sources>] <sig>: <sample>
#   fm-friction.sh arm | disarm
#       Write and register, or remove, state/friction.check.sh through
#       bin/fm-check-register.sh / bin/fm-check-unregister.sh.
#
# Records:
#   data/friction.jsonl  one JSON object per signature, most frequent first:
#     {"sig":<12 hex>,"sample":..,"count":<lines seen>,"turns":<wakes
#      delivered, each one firstmate turn>,"sources":["status"|"wake"|
#      "triage",..],"first":"YYYY-MM-DD","last":"YYYY-MM-DD"}
#   state/friction/offsets   per-log byte offsets (`<key>\t<bytes>`).
#   state/friction/streaks   loop-guard streaks
#                            (`<norm>\t<count>\t<epoch>\t<alerted>\t<sample>`).
#   state/friction/last-scan epoch of the last scan.
# FM_FRICTION_NOW=<epoch> overrides the clock for tests.
#
# Exit codes: 0 ok (also when another run holds the lock), 1 write failed,
# 2 usage.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
DIR="$STATE/friction"
OFFSETS="$DIR/offsets"
STREAKS="$DIR/streaks"
LAST_SCAN="$DIR/last-scan"
FRICTION="$DATA/friction.jsonl"
DELIVERIES="$STATE/.watch-deliveries.log"
TRIAGE="$STATE/.watch-triage.log"
CHECK_ID=friction
NOW=${FM_FRICTION_NOW:-$(date +%s)}

usage() {
  sed -n '/^# Usage:/,/^# Records:/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//' >&2
  exit 2
}

# Shared awk helpers: norm() is the comparison key, strip() the readable sample,
# exempt_wake() the wakes neither the guard nor the sentinel counts.
AWK_LIB='
function strip(s) {
  sub(/^\[[^]]*\][ ]*/, "", s)
  gsub(/\[[a-z]+=[^]]*\]/, "", s)
  gsub(/corr=[0-9a-f]+/, "", s)
  gsub(/https?:\/\/[^ ]+/, "<url>", s)
  gsub(/[^ <]*\//, "", s)
  gsub(/[ \t]+/, " ", s); sub(/^ /, "", s); sub(/ $/, "", s)
  return substr(s, 1, 200)
}
function norm(s) {
  s = strip(s)
  gsub(/[0-9][0-9][0-9]+/, "N", s)
  return s
}
function exempt_wake(r) {
  if (r !~ /^(stale|check): /) return 1
  return (r ~ /declared pause|loop guard:|rearm-resurface|informational status batch/)
}
'

offset_get() {  # <key>
  [ -f "$OFFSETS" ] || return 0
  awk -F'\t' -v k="$1" '$1 == k { print $2 }' "$OFFSETS"
}

offset_set() {  # <key> <bytes>
  local tmp
  tmp=$(mktemp "$DIR/.offsets.XXXXXX") || return 1
  { [ ! -f "$OFFSETS" ] || awk -F'\t' -v k="$1" '$1 != k' "$OFFSETS"; printf '%s\t%s\n' "$1" "$2"; } > "$tmp" \
    && mv -f "$tmp" "$OFFSETS"
}

# new_lines <key> <file>: print the complete lines added since <key>'s offset
# and advance it. A file shorter than its offset is read again from the start.
new_lines() {
  local key=$1 file=$2 off size chunk complete
  [ -f "$file" ] || return 0
  off=$(offset_get "$key")
  size=$(wc -c < "$file" | tr -d ' ')
  case "$off" in ''|*[!0-9]*) off=0 ;; esac
  [ "$off" -le "$size" ] || off=0
  [ "$off" -lt "$size" ] || return 0
  chunk=$(tail -c +"$((off + 1))" "$file" | head -c "$((size - off))"; printf x)
  chunk=${chunk%x}
  case "$chunk" in
    *$'\n'*) complete=${chunk%"${chunk##*$'\n'}"} ;;
    *) complete= ;;
  esac
  printf '%s' "$complete"
  offset_set "$key" "$((off + ${#complete}))"
}

lock() {
  mkdir -p "$DIR" || exit 1
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  fm_lock_try_acquire "$DIR/.lock" || exit 0
}

unlock() { fm_lock_release "$DIR/.lock"; }

run_loop() {
  local key=loop:deliveries lines tmp alerts
  if [ -z "$(offset_get "$key")" ]; then
    [ -f "$DELIVERIES" ] || return 0
    offset_set "$key" "$(wc -c < "$DELIVERIES" | tr -d ' ')"
    return 0
  fi
  lines=$(new_lines "$key" "$DELIVERIES"; printf x)
  lines=${lines%x}
  tmp=$(mktemp "$DIR/.streaks.XXXXXX") || return 1
  alerts=$(printf '%s' "$lines" | awk -F'\t' -v now="$NOW" -v gap="${FM_LOOP_GAP_SECS:-7200}" \
    -v thr="${FM_LOOP_THRESHOLD:-5}" -v streaks="$STREAKS" -v out="$tmp" "$AWK_LIB"'
    BEGIN {
      while ((getline l < streaks) > 0) {
        split(l, a, "\t")
        if (now - a[3] <= gap) { c[a[1]] = a[2]; t[a[1]] = a[3]; f[a[1]] = a[4]; s[a[1]] = a[5] }
      }
    }
    {
      r = $NF
      if (exempt_wake(r)) next
      raw = strip(r)
      k = norm(raw)
      if (!(k in c)) { c[k] = 0; f[k] = 0; s[k] = substr(raw, 1, 160) }
      c[k]++
      t[k] = now
    }
    END {
      for (k in c) {
        if (c[k] >= thr && f[k] == 0) { print "\"" s[k] "\" " c[k] " times"; f[k] = 1 }
        printf "%s\t%s\t%s\t%s\t%s\n", k, c[k], t[k], f[k], s[k] > out
      }
    }') || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$STREAKS" || return 1
  [ -n "$alerts" ] || return 0
  printf 'loop guard: %s; stop repeating the same step - find the cause (bin/fm-reach.sh for an unreachable host), then steer one corrective note, pause the source, or hold it for the captain\n' \
    "$(printf '%s\n' "$alerts" | paste -sd '|' - | sed 's/|/ | /g')"
}

# collect: print `<source>\t<turn>\t<norm>\t<sample>` for each new friction line.
collect() {
  local f key
  for f in "$STATE"/*.status; do
    [ -f "$f" ] || continue
    key="scan:status:$(basename "$f")"
    new_lines "$key" "$f" | awk "$AWK_LIB"'
      /^(blocked|failed)[ :[]/ { printf "status\t0\t%s\t%s\n", norm($0), strip($0) }'
  done
  new_lines scan:deliveries "$DELIVERIES" | awk -F'\t' "$AWK_LIB"'
    { r = $NF; if (!exempt_wake(r)) printf "wake\t1\t%s\t%s\n", norm(r), strip(r) }'
  new_lines scan:triage "$TRIAGE" | awk "$AWK_LIB"'
    tolower($0) ~ /error|failed|refused|could not|cannot|timed out/ { printf "triage\t0\t%s\t%s\n", norm($0), strip($0) }'
}

run_scan() {
  local raw agg sig rows tmp today
  raw=$(collect) || return 1
  printf '%s' "$NOW" > "$LAST_SCAN" || return 1
  [ -n "$raw" ] || return 0
  # One row per signature: <norm>\t<count>\t<turns>\t<sources>\t<sample>.
  agg=$(printf '%s\n' "$raw" | awk -F'\t' '
    { k = $3; if (!(k in cnt)) { order[++m] = k; smp[k] = $4 }
      cnt[k]++; turns[k] += $2
      if (index("," src[k] ",", "," $1 ",") == 0) src[k] = (src[k] == "" ? $1 : src[k] "," $1) }
    END { for (i = 1; i <= m; i++) { k = order[i]; printf "%s\t%s\t%s\t%s\t%s\n", k, cnt[k], turns[k], src[k], smp[k] } }')
  rows=$(printf '%s\n' "$agg" | while IFS= read -r line; do
    sig=$(printf '%s' "${line%%$'\t'*}" | shasum -a 256 | cut -c1-12)
    printf '%s\t%s\n' "$sig" "${line#*$'\t'}"
  done)
  mkdir -p "$DATA" || return 1
  [ -f "$FRICTION" ] || : > "$FRICTION" || return 1
  today=$(date -u -r "$NOW" +%Y-%m-%d 2>/dev/null || date -u -d "@$NOW" +%Y-%m-%d)
  tmp=$(mktemp "$DATA/.friction.XXXXXX") || return 1
  printf '%s\n' "$rows" | jq -R -n -c --slurpfile old "$FRICTION" --arg today "$today" '
    [inputs | select(length > 0) | split("\t")
      | {sig: .[0], count: (.[1] | tonumber), turns: (.[2] | tonumber), sources: (.[3] | split(",")), sample: .[4]}] as $new
    | reduce $new[] as $n (($old | map({key: .sig, value: .}) | from_entries);
        .[$n.sig] = (if .[$n.sig] then
            .[$n.sig] | .count += $n.count | .turns += $n.turns | .sources = ((.sources + $n.sources) | unique) | .last = $today
          else
            {sig: $n.sig, sample: $n.sample, count: $n.count, turns: $n.turns, sources: $n.sources, first: $today, last: $today}
          end))
    | [.[]] | sort_by(-.count) | .[]' > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$FRICTION" || { rm -f "$tmp"; return 1; }
}

cmd_top() {
  local n=${1:-3}
  case "$n" in ''|*[!0-9]*) usage ;; esac
  [ -s "$FRICTION" ] || return 0
  jq -s -r --argjson n "$n" \
    'sort_by(-.count) | .[:$n][] | "\(.count)x \(.turns) turns [\(.sources | join(","))] \(.sig): \(.sample)"' "$FRICTION"
}

cmd_arm() {
  local shim="$STATE/$CHECK_ID.check.sh" tmp home
  [ -d "$STATE" ] || { echo "error: state directory is unavailable" >&2; exit 1; }
  home=$(cd "$FM_HOME" && pwd -P) || exit 1
  tmp=$(umask 077; mktemp "$STATE/.friction-check.XXXXXX") || exit 1
  if ! printf '%s\n' '#!/usr/bin/env bash' "export FM_HOME=$(printf '%q' "$home")" \
      "exec $(printf '%q' "$SCRIPT_DIR/fm-friction.sh") check" > "$tmp" \
    || ! chmod 0700 "$tmp" || ! mv -f "$tmp" "$shim"; then
    rm -f "$tmp"
    exit 1
  fi
  FM_HOME="$home" "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID" >/dev/null \
    || { rm -f "$shim"; echo "error: could not register the friction check" >&2; exit 1; }
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

cmd_disarm() {
  "$SCRIPT_DIR/fm-check-unregister.sh" "$CHECK_ID" >/dev/null || exit 1
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

CMD=${1:-}
[ "$#" -eq 0 ] || shift
case "$CMD" in
  check|loop|scan)
    [ "$#" -eq 0 ] || usage
    lock
    rc=0
    if [ "$CMD" != scan ]; then run_loop || rc=1; fi
    if [ "$CMD" = scan ] || { [ "$CMD" = check ] \
      && [ "$((NOW - $(cat "$LAST_SCAN" 2>/dev/null || echo 0)))" -ge "${FM_FRICTION_SCAN_SECS:-86400}" ]; }; then
      run_scan || rc=1
    fi
    unlock
    exit "$rc"
    ;;
  top) [ "$#" -le 1 ] || usage; cmd_top "$@" ;;
  arm) [ "$#" -eq 0 ] || usage; cmd_arm ;;
  disarm) [ "$#" -eq 0 ] || usage; cmd_disarm ;;
  *) usage ;;
esac
