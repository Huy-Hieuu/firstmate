#!/usr/bin/env bash
# fm-probe-jira.sh - daily brief source: the captain's open Jira issues,
# read-only.
#
# Reads config/jira (local, gitignored), key=value lines:
#   url=<base URL>       for example https://jira.example.com
#   auth_cmd=<command>   prints the whole Authorization header value, for
#                        example `printf 'Bearer %s' "$(security
#                        find-generic-password -s jira -w)"`; the secret stays
#                        in the captain's own store and never in this file
#   jql=<query>          optional; default
#                        assignee = currentUser() AND resolution = Unresolved ORDER BY updated DESC
# Prints one NDJSON work-radar row per issue from one GET of the REST search
# API; it never creates, edits, transitions, or comments. Exit 3 when the host
# is unreachable (DNS, connect, or timeout), 1 on a missing config or any other
# failure. Run it through `fm-daily-brief.sh source jira`.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
CONF="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/jira"

get() { awk -v k="$1" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) } END { if (v != "") print v }' "$CONF"; }

[ -f "$CONF" ] || { echo "fm-probe-jira: config/jira is missing; add url= and auth_cmd= (see the script header)" >&2; exit 1; }
url=$(get url); url=${url%/}
cmd=$(get auth_cmd)
jql=$(get jql)
[ -n "$jql" ] || jql='assignee = currentUser() AND resolution = Unresolved ORDER BY updated DESC'
[ -n "$url" ] && [ -n "$cmd" ] || { echo "fm-probe-jira: config/jira needs url= and auth_cmd=" >&2; exit 1; }
auth=$(sh -c "$cmd" < /dev/null) && [ -n "$auth" ] || { echo "fm-probe-jira: auth_cmd printed nothing" >&2; exit 1; }

# The header goes through curl's stdin config, never argv.
rc=0
out=$(printf 'header = "Authorization: %s"\n' "$auth" | curl -sS -f --max-time 15 --config - \
  -G "$url/rest/api/2/search" --data-urlencode "jql=$jql" \
  --data-urlencode "fields=summary,status" --data-urlencode "maxResults=${FM_PROBE_JIRA_LIMIT:-50}") || rc=$?
case "$rc" in
  0) ;;
  6|7|28) exit 3 ;;
  *) echo "fm-probe-jira: search failed (curl exit $rc)" >&2; exit 1 ;;
esac
printf '%s' "$out" | jq -c --arg base "$url" '.issues[]? | {
  id: ("jira:" + .key),
  section: "radar",
  title: (.key + " " + (.fields.summary // "") + " [" + (.fields.status.name // "?") + "]"),
  url: ($base + "/browse/" + .key)
}'
