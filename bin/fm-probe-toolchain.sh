#!/usr/bin/env bash
# fm-probe-toolchain.sh - daily brief source: toolchain problems only the
# captain can fix, as Needs you rows. Read-only.
#
# Checks, each bounded and skipped when its tool is absent:
#   disk    free space on the home volume below FM_PROBE_DISK_MIN_GB (default 10)
#   quota   an agent quota window at or below FM_PROBE_QUOTA_MIN_PCT (default 10)
#           percent remaining, from `quota-axi --json --no-credential-refresh`
#   github  `gh auth status` failing while GitHub is reachable (bin/fm-reach.sh)
# Prints one NDJSON row per problem (section needs) and nothing when all is
# well; always exits 0, because a check that cannot run is not a captain
# problem. Run it through `fm-daily-brief.sh source toolchain`.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

row() {  # <id> <title> [<url>]
  jq -n -c --arg id "tool:$1" --arg t "$2" --arg u "${3:-}" '{id: $id, section: "needs", title: $t, url: $u}'
}

free_kb=$(df -Pk "$HOME" 2>/dev/null | awk 'NR == 2 { print $4 }')
min_gb=${FM_PROBE_DISK_MIN_GB:-10}
case "$free_kb" in
  ''|*[!0-9]*) ;;
  *) [ "$free_kb" -ge $((min_gb * 1048576)) ] || row disk "Disk low: $((free_kb / 1048576)) GB free on the home volume" ;;
esac

if command -v quota-axi >/dev/null 2>&1; then
  fm_run_timed 8 quota-axi --json --no-credential-refresh --max-age 30m 2>/dev/null \
    | jq -c --argjson min "${FM_PROBE_QUOTA_MIN_PCT:-10}" '.providers[]? | .provider as $p | .windows[]?
        | select(.percentRemaining != null and .percentRemaining <= $min)
        | {id: ("tool:quota:" + $p + ":" + .id), section: "needs",
           title: ("Quota low: " + $p + " " + (.label // .id) + " \(.percentRemaining | floor)% left (resets " + (.resetsAt // "?") + ")"),
           url: ""}' 2>/dev/null
fi

if command -v gh >/dev/null 2>&1 && "$SCRIPT_DIR/fm-reach.sh" github >/dev/null 2>&1; then
  fm_run_timed 8 gh auth status --hostname github.com >/dev/null 2>&1 \
    || row github "GitHub CLI is not signed in: run gh auth login"
fi
exit 0
