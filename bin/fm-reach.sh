#!/usr/bin/env bash
# fm-reach.sh - classify whether a named network target is reachable right now.
#
# A VPN can make one set of hosts (for example a company's Gerrit and Jenkins)
# reachable while another (GitHub) is not, and the reverse when it is off. A
# probe asks this helper first and defers on `unreachable` instead of counting a
# failure or alarming; `unreachable` says nothing about the source's health.
#
# Usage:
#   fm-reach.sh [--no-cache] [<target>...]
#       Print "<target> reachable|unreachable" for each named target, or for
#       every known target when none is named. Exit 0 when all are reachable,
#       3 when any is unreachable, 2 for usage or an unknown target.
#
# A target is reachable when any of its URLs returns any HTTP response,
# including 401, 403, or 404; a connect failure, DNS failure, TLS failure, or
# timeout is unreachable. Each URL gets one request bounded by
# FM_REACH_TIMEOUT_SECS (default 4). A verdict is cached per target in
# state/reach/<target> for FM_REACH_CACHE_SECS (default 60).
#
# Targets: `github https://api.github.com` is built in. config/reach (local,
# gitignored) adds or replaces targets, one per non-empty, non-comment line:
#   <name> <url> [<url>...]
# where <name> matches [a-z0-9][a-z0-9-]*. Example:
#   momo https://gerrit.mservice.io https://jenkins.mservice.io
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CACHE_DIR="$STATE/reach"
CACHE_SECS=${FM_REACH_CACHE_SECS:-60}
TIMEOUT=${FM_REACH_TIMEOUT_SECS:-4}

usage() {
  echo "usage: fm-reach.sh [--no-cache] [<target>...]" >&2
  exit 2
}

# targets: print "<name> <url>..." lines; config/reach overrides built-ins.
targets() {
  local line name lines='github https://api.github.com'
  if [ -f "$CONFIG/reach" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line=${line%%#*}
      [ -n "${line//[[:space:]]/}" ] || continue
      name=$(printf '%s\n' "$line" | awk '{print $1}')
      case "$name" in
        [!a-z0-9]*|*[!a-z0-9-]*) echo "fm-reach: bad target name in config/reach: $name" >&2; return 2 ;;
      esac
      lines="$lines"$'\n'"$line"
    done < "$CONFIG/reach"
  fi
  printf '%s\n' "$lines" | awk '{ urls = ""; for (i = 2; i <= NF; i++) urls = urls " " $i; if (urls != "") { if (!($1 in seen)) order[++n] = $1; seen[$1] = urls } }
    END { for (i = 1; i <= n; i++) print order[i] seen[order[i]] }'
}

probe() {  # <url...>
  local url code
  for url in "$@"; do
    code=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" "$url" 2>/dev/null) || true
    case "$code" in ''|000) ;; *) return 0 ;; esac
  done
  return 1
}

use_cache=1
if [ "${1:-}" = --no-cache ]; then
  use_cache=0
  shift
fi
case "${1:-}" in -h|--help|help)
  sed -n '2,/^set -eu$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
  exit 0 ;;
-*) usage ;;
esac

known=$(targets)
if [ "$#" -eq 0 ]; then
  # shellcheck disable=SC2046
  set -- $(printf '%s\n' "$known" | awk '{print $1}')
fi

mkdir -p "$CACHE_DIR"
status=0
now=$(date +%s)
for name in "$@"; do
  urls=$(printf '%s\n' "$known" | awk -v n="$name" '$1 == n { $1 = ""; print }')
  [ -n "$urls" ] || { echo "fm-reach: unknown target: $name" >&2; exit 2; }
  verdict='' at='' cached=''
  if [ "$use_cache" = 1 ] && [ -f "$CACHE_DIR/$name" ]; then
    read -r at cached < "$CACHE_DIR/$name" || true
    case "$at:$cached" in
      *[!0-9]*:reachable|*[!0-9]*:unreachable|:*) ;;
      *:reachable|*:unreachable) [ $((now - at)) -ge "$CACHE_SECS" ] || verdict=$cached ;;
    esac
  fi
  if [ -z "$verdict" ]; then
    # shellcheck disable=SC2086
    if probe $urls; then verdict=reachable; else verdict=unreachable; fi
    printf '%s %s\n' "$now" "$verdict" > "$CACHE_DIR/$name"
  fi
  printf '%s %s\n' "$name" "$verdict"
  [ "$verdict" = reachable ] || status=3
done
exit "$status"
