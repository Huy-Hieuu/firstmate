#!/usr/bin/env bash
# fm-probe-gerrit.sh - daily brief source: Gerrit changes awaiting the
# captain's attention, read-only.
#
# Prints one NDJSON work-radar row per change on gerrit-axi's "your turn" list
# (`gerrit-axi status`), using gerrit-axi's own configured host, user, and SSH
# access; it never votes, comments, or submits. Exit 3 when Gerrit is
# unreachable (a transport error, for example while the VPN is off), 1 on any
# other failure, with gerrit-axi's error on stderr. Run it through
# `fm-daily-brief.sh source gerrit`.
set -u

out=$(gerrit-axi status --json --limit "${FM_PROBE_GERRIT_LIMIT:-50}" --fields owner,updated,url 2>&1) || {
  printf '%s\n' "$out" >&2
  if printf '%s' "$out" | jq -e '.kind == "transport"' >/dev/null 2>&1; then exit 3; fi
  exit 1
}
printf '%s' "$out" | jq -c '.changes[]? | {
  id: ("gerrit:" + (.change | tostring)),
  section: "radar",
  title: ("Gerrit " + (.change | tostring) + ": " + .subject + (if .owner then " (" + .owner + ")" else "" end)),
  url: (.url // ""),
  updated: (.updated // "")
}'
