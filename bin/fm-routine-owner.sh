#!/usr/bin/env bash
# fm-routine-owner.sh - which machine owns this home's proactive routines.
#
# Two machines can share one private data/ (for example through a synced data
# repository); only one of them may run scheduled routines, or the captain gets
# two briefs and two inbox reads. The lease lives in the shared record
# data/routines/owner as two lines, `host=<id>` and `at=<epoch>`. It is live
# while `at` is younger than FM_ROUTINE_OWNER_TTL seconds (default 7200); the
# owner refreshes it by claiming again on every routine tick. A routine runner
# runs only when `check` succeeds.
#
# Usage:
#   fm-routine-owner.sh claim [--force]
#       Take or refresh the lease for this machine. Succeeds when the lease is
#       absent, already this machine's, or stale; refuses (exit 6) while another
#       machine holds a live lease unless --force is given, which is the
#       captain-directed explicit handover.
#   fm-routine-owner.sh check
#       Exit 0 when this machine holds a live lease, 1 otherwise.
#   fm-routine-owner.sh status
#       Print "<host> <epoch> <live|stale>"; print nothing and exit 1 when no
#       lease exists.
#   fm-routine-owner.sh release
#       Drop the lease if this machine holds it; a no-op otherwise.
#   fm-routine-owner.sh host
#       Print this machine's id: FM_HOST_ID, else the macOS LocalHostName,
#       else `hostname -s`.
#
# Exit codes: 0 ok, 1 check or status miss, 2 usage, 6 refused.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
OWNER="$DATA/routines/owner"
TTL=${FM_ROUTINE_OWNER_TTL:-7200}
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  echo "usage: fm-routine-owner.sh claim [--force] | check | status | release | host" >&2
  exit 2
}

this_host() {
  local id=${FM_HOST_ID:-}
  [ -n "$id" ] || id=$(scutil --get LocalHostName 2>/dev/null || true)
  [ -n "$id" ] || id=$(hostname -s)
  printf '%s\n' "$id"
}

# read_lease: set LEASE_HOST and LEASE_AT; nonzero when absent or torn.
read_lease() {
  LEASE_HOST=$(sed -n 's/^host=//p' "$OWNER" 2>/dev/null | head -n 1)
  LEASE_AT=$(sed -n 's/^at=//p' "$OWNER" 2>/dev/null | head -n 1)
  [ -n "$LEASE_HOST" ] || return 1
  case "$LEASE_AT" in ''|*[!0-9]*) LEASE_AT=0 ;; esac
}

lease_live() {
  [ $(( $(date +%s) - LEASE_AT )) -lt "$TTL" ]
}

write_lease() {
  mkdir -p "$(dirname "$OWNER")"
  printf 'host=%s\nat=%s\n' "$1" "$(date +%s)" > "$OWNER.tmp.$$"
  mv -f "$OWNER.tmp.$$" "$OWNER"
}

CMD=${1:-}
[ "$#" -eq 0 ] || shift
ME=$(this_host)

case "$CMD" in
  claim)
    force=0
    case "${1:-}" in '') ;; --force) force=1 ;; *) usage ;; esac
    mkdir -p "$(dirname "$OWNER")"
    LOCK="$(dirname "$OWNER")/.owner.lock"
    fm_lock_acquire_wait "$LOCK"
    trap 'fm_lock_release "$LOCK"' EXIT
    if [ "$force" = 0 ] && read_lease && [ "$LEASE_HOST" != "$ME" ] && lease_live; then
      echo "fm-routine-owner: refused: $LEASE_HOST holds a live lease (use --force to hand over)" >&2
      exit 6
    fi
    write_lease "$ME"
    ;;
  check)
    [ "$#" -eq 0 ] || usage
    read_lease && [ "$LEASE_HOST" = "$ME" ] && lease_live
    ;;
  status)
    [ "$#" -eq 0 ] || usage
    read_lease || exit 1
    if lease_live; then state=live; else state=stale; fi
    printf '%s %s %s\n' "$LEASE_HOST" "$LEASE_AT" "$state"
    ;;
  release)
    [ "$#" -eq 0 ] || usage
    if read_lease && [ "$LEASE_HOST" = "$ME" ]; then
      rm -f "$OWNER"
    fi
    ;;
  host)
    [ "$#" -eq 0 ] || usage
    printf '%s\n' "$ME"
    ;;
  -h|--help|help)
    sed -n '2,/^set -eu$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
    ;;
  *) usage ;;
esac
