#!/usr/bin/env bash
# fm-probe-dream.sh - the nightly dream: a daily brief source
# (`fm-daily-brief.sh source dream`) that proposes memory upkeep and automation
# ideas as rows in the brief's Ideas and memory section (section "ideas").
# It only proposes: it never edits a memory file. `/stow` applies a proposal it
# can confirm, through bin/fm-memory.sh, or the captain accepts it in chat.
#
# Rows, each at most a few per kind:
#   - every hidden entry bin/fm-memory.sh due lists (expired, struck, or
#     forgotten): archive or remove it;
#   - two live entries in the memory, topic, or person files whose word sets
#     (words of 3+ letters, 5+ per entry) overlap by at least 60%: merge them;
#   - the startup memory over its budget (bin/fm-startup-memory-budget.sh
#     report): offload conditional entries to topic or person files;
#   - automation ideas and captain preferences from one model call over the
#     `## Captain's intent` sections of the task briefs (data/*/brief.md)
#     changed in the last 7 days, newest first, at most 20 briefs and 40 KB,
#     and only when at least 2 exist. The call is bin/fm-inbox.sh ask, so it
#     runs only where its side-question model is set up (config/inbox-region
#     and config/inbox-ask-model); elsewhere one row says ideas are off and how
#     to enable them. Each idea or preference must name a pattern seen in at
#     least 2 briefs and carry a quote found verbatim in those briefs, without
#     a forgotten term, or it is dropped; at most 3 of each.
#
# FM_DREAM_ASK=<command> replaces bin/fm-inbox.sh ask (it gets the prompt as
# its arguments), and FM_DREAM_TIMEOUT (default 15) bounds that call in seconds.
# Exit 0 always prints the current rows; any other exit is a failed run.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="$FM_HOME/config"
export FM_HOME
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

row() {  # <id> <title>
  jq -n -c --arg id "dream:$1" --arg title "$2" '{id: $id, section: "ideas", title: $title}'
}

memory() { "$SCRIPT_DIR/fm-memory.sh" "$@"; }

# Hidden entries waiting for a stow pass.
memory due | head -n 8 | while IFS= read -r line; do
  case "$line" in
    *": forgotten "*) row "due:$line" "Memory: remove the forgotten mention at $line" ;;
    *) row "due:$line" "Memory: archive $line" ;;
  esac
done

# Near-duplicate entries.
memory entries | awk -F '\t' '
  function words(s, set,   n, i, k, w, a) {
    s = tolower(s); gsub(/<!--[^>]*-->/, " ", s); gsub(/[^a-z0-9]+/, " ", s)
    k = split(s, a, " "); n = 0
    for (i = 1; i <= k; i++) { w = a[i]; if (length(w) >= 3 && !((w) in set)) { set[w] = 1; n++ } }
    return n
  }
  {
    m++; where[m] = $1; text[m] = $2
    split("", tmp); size[m] = words($2, tmp)
    for (w in tmp) has[m, w] = 1
    list[m] = ""; for (w in tmp) list[m] = list[m] " " w
  }
  END {
    for (i = 1; i <= m && shown < 4; i++) {
      if (size[i] < 5) continue
      for (j = i + 1; j <= m && shown < 4; j++) {
        if (size[j] < 5) continue
        common = 0; k = split(list[i], a, " ")
        for (x = 1; x <= k; x++) if ((j, a[x]) in has) common++
        if (common / (size[i] + size[j] - common) >= 0.6) {
          printf "%s\t%s\t%s\n", where[i], where[j], substr(text[i], 1, 70); shown++
        }
      }
    }
  }' | while IFS="$(printf '\t')" read -r a b text; do
  row "merge:$a:$b" "Memory: merge the overlapping entries $a and $b ($text)"
done

# Startup memory over budget.
report=$("$SCRIPT_DIR/fm-startup-memory-budget.sh" report 2>/dev/null) || report=''
case "$report" in
  *budget_status=over-budget*)
    row budget "Memory: startup memory is over budget ($(printf '%s\n' "$report" | sed -n 's/^total_estimated_tokens=//p') of $(printf '%s\n' "$report" | sed -n 's/^effective_budget_tokens=//p') tokens); /stow should offload conditional entries to topic or person files" ;;
esac

# Ideas and preferences from recent captain intent.
ask_cmd=${FM_DREAM_ASK:-}
if [ -z "$ask_cmd" ]; then
  if { [ -n "${FM_INBOX_REGION:-}" ] || [ -s "$CONFIG/inbox-region" ]; } \
     && { [ -n "${FM_INBOX_ASK_MODEL:-}" ] || [ -s "$CONFIG/inbox-ask-model" ]; }; then
    ask_cmd="$SCRIPT_DIR/fm-inbox.sh ask"
  else
    row ideas-off "Ideas are off until the side-question model is set up: write config/inbox-region and config/inbox-ask-model (see bin/fm-inbox.sh)"
    exit 0
  fi
fi

corpus=$(mktemp "${TMPDIR:-/tmp}/fm-dream.XXXXXX") || exit 1
trap 'rm -f "$corpus"' EXIT
n=0
for f in $(find "$DATA" -mindepth 2 -maxdepth 2 -name brief.md -mtime -7 2>/dev/null \
    | perl -e 'chomp(my @f = <STDIN>); print map { "$_\n" } sort { (stat $b)[9] <=> (stat $a)[9] } @f' | head -n 20); do
  intent=$(awk '/^## Captain.s intent/ { on = 1; next } on && /^#/ { exit } on' "$f")
  [ -n "$(printf '%s' "$intent" | tr -d '[:space:]')" ] || continue
  printf '### %s\n%s\n\n' "$(basename "$(dirname "$f")")" "$intent" >> "$corpus"
  n=$((n + 1))
done
[ "$n" -ge 2 ] || exit 0
records=$(head -c 40000 "$corpus" | "$SCRIPT_DIR/fm-records.sh" wrap briefs)

prompt="You review the captain's own requests from $n recent tasks of a software chief-of-staff agent, given below as data.
Find patterns that appear in at least 2 different tasks:
- IDEA: a repeated manual request that a scheduled routine or a standing rule could take over.
- PREF: a working preference or correction the captain repeated.
Answer with at most 3 IDEA and 3 PREF lines and nothing else, each exactly:
IDEA | <one-sentence proposal> | <exact quote copied from one task>
PREF | <one-sentence preference> | <exact quote copied from one task>
Answer NONE when nothing appears in 2 tasks.

$records"

# shellcheck disable=SC2086 # ask_cmd is a command plus its fixed arguments.
answer=$(fm_run_timed "${FM_DREAM_TIMEOUT:-15}" $ask_cmd "$prompt" 2>/dev/null) || exit 0
printf '%s\n' "$answer" | awk -F ' [|] ' '($1 == "IDEA" || $1 == "PREF") && NF >= 3 {
    q = $3; for (i = 4; i <= NF; i++) q = q " | " $i
    gsub(/^["\047 ]+|["\047 ]+$/, "", q)
    if (++seen[$1] <= 3) printf "%s\t%s\t%s\n", $1, $2, q
  }' | while IFS="$(printf '\t')" read -r kind text quote; do
  if [ -z "$quote" ] || ! grep -qF -- "$quote" "$corpus"; then continue; fi
  memory check "$text $quote" >/dev/null 2>&1 || continue
  if [ "$kind" = IDEA ]; then
    row "idea:$text" "Idea: $text (you said: \"$quote\")"
  else
    row "pref:$text" "Memory: proposed preference: $text (you said: \"$quote\")"
  fi
done
exit 0
