#!/usr/bin/env bash
# fm-skill-review.sh - post-task skill review: after a ship or scout that took
# many tool steps, one tool-less model call proposes at most 3 skill changes
# as a suggestion file for the captain. It never writes a skill.
#
# Usage:
#   fm-skill-review.sh propose <task-id> --steps <n>
#       <n> is the worker's tool-step count as firstmate observed it. Below
#       FM_SKILL_REVIEW_MIN_STEPS (default 40) it prints `skipped:` and does
#       nothing, and a task already reviewed keeps its first file. Otherwise it
#       sends the task's instructions (data/<task-id>/brief.md), firstmate's
#       steering messages to the worker (state/<task-id>.inbox, the corrections
#       that signal what a skill should have said), its status log, the start
#       of its report, and the name and description of every skill under
#       .agents/skills/, all fenced as records, to one model call that has no
#       tools: bin/fm-inbox.sh ask, so it runs only where that side-question
#       model is set up (config/inbox-region, config/inbox-ask-model).
#       From the answer it keeps at most 3 unified diffs whose every path is
#       .agents/skills/<name>/SKILL.md (a new skill diffs from /dev/null),
#       each with its one-line reason, and writes them to
#       data/skill-review/<task-id>.md with each target file's git blob sha at
#       proposal time, so an apply can see the file changed since. It prints
#       that path, or `no suggestions`.
#   fm-skill-review.sh list
#       The suggestion files, newest first.
#
# Applying a suggestion is the captain's call: firstmate applies only the ones
# he names, as an ordinary change to shared tracked material (the
# firstmate-coding-guidelines skill and this repository's delivery path).
# FM_SKILL_REVIEW_ASK=<command> replaces bin/fm-inbox.sh ask (it gets the
# prompt as its arguments), and FM_SKILL_REVIEW_TIMEOUT (default 60) bounds
# that call in seconds. Exit codes: 0 ok (including skipped or off), 1
# failure, 2 usage.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="$FM_HOME/config"
OUT="$DATA/skill-review"
export FM_HOME
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {
  echo "usage: fm-skill-review.sh propose <task-id> --steps <n> | list" >&2
  exit 2
}

records() {  # <source> <max bytes> <file>...: the files' text, fenced
  local src=$1 max=$2 f
  shift 2
  for f in "$@"; do
    [ -f "$f" ] || continue
    printf '### %s\n' "${f#"$FM_HOME"/}"
    cat "$f"
    printf '\n'
  done | head -c "$max" | "$SCRIPT_DIR/fm-records.sh" wrap "$src"
}

skill_index() {
  local f name desc
  for f in "$FM_ROOT"/.agents/skills/*/SKILL.md; do
    [ -f "$f" ] || continue
    name=$(basename "$(dirname "$f")")
    desc=$(awk '/^description:/ { sub(/^description:[ >-]*/, ""); d = $0; on = 1; next }
      on && /^  / { sub(/^ +/, ""); d = (d == "" ? $0 : d " " $0); next } on { exit } END { print d }' "$f" | cut -c1-240)
    printf -- '- %s: %s\n' "$name" "$desc"
  done
}

propose() {
  local id=${1:-} steps='' min ask_cmd prompt answer file kept
  [ -n "$id" ] || usage
  shift
  [ "${1:-}" = --steps ] && [ "$#" -eq 2 ] || usage
  steps=$2
  case "$id" in *[!A-Za-z0-9._-]*) usage ;; esac
  case "$steps" in ''|*[!0-9]*) usage ;; esac
  min=${FM_SKILL_REVIEW_MIN_STEPS:-40}
  if [ "$steps" -lt "$min" ]; then
    printf 'skipped: %s tool steps is under %s\n' "$steps" "$min"
    return 0
  fi
  file="$OUT/$id.md"
  if [ -f "$file" ]; then
    printf '%s\n' "${file#"$FM_HOME"/}"
    return 0
  fi
  [ -f "$DATA/$id/brief.md" ] || { echo "fm-skill-review: no instructions at data/$id/brief.md" >&2; return 1; }
  ask_cmd=${FM_SKILL_REVIEW_ASK:-}
  if [ -z "$ask_cmd" ]; then
    if { [ -n "${FM_INBOX_REGION:-}" ] || [ -s "$CONFIG/inbox-region" ]; } \
       && { [ -n "${FM_INBOX_ASK_MODEL:-}" ] || [ -s "$CONFIG/inbox-ask-model" ]; }; then
      ask_cmd="$SCRIPT_DIR/fm-inbox.sh ask"
    else
      echo "skipped: skill review is off until the side-question model is set up (config/inbox-region and config/inbox-ask-model; see bin/fm-inbox.sh)"
      return 0
    fi
  fi

  # shellcheck disable=SC2046 # Steering message files, one word each.
  prompt="You review one finished task of a software chief-of-staff agent (task $id, $steps tool steps).
Agents follow skills: markdown files .agents/skills/<name>/SKILL.md whose description says when to load them.
Propose at most 3 skill changes that would have saved this task steps or avoided the corrections firstmate had to send the worker.
Treat the steering messages as the strongest signal. Prefer a small edit to an existing skill over a new skill. Never propose a change to any other file.
For each change write one line 'WHY: <one sentence naming the correction or repeated step>' followed by one unified diff in a \`\`\`diff block whose paths are a/.agents/skills/<name>/SKILL.md and b/.agents/skills/<name>/SKILL.md (a new skill: --- /dev/null).
Answer NONE when no skill change would help.

Existing skills:
$(skill_index)

$(records instructions 16000 "$DATA/$id/brief.md")

$(records steering 12000 $(find "$STATE/$id.inbox" -name '*.msg' 2>/dev/null | sort))

$(records status 6000 "$STATE/$id.status" "$DATA/$id/status.log")

$(records report 8000 "$DATA/$id/report.md")"

  # shellcheck disable=SC2086 # ask_cmd is a command plus its fixed arguments.
  answer=$(fm_run_timed "${FM_SKILL_REVIEW_TIMEOUT:-60}" $ask_cmd "$prompt" 2>/dev/null) \
    || { echo "fm-skill-review: the model call failed" >&2; return 1; }
  kept=$(printf '%s\n' "$answer" | perl -e '
    local $/; my $a = <STDIN>; my ($n, $why) = (0, "");
    my $path = qr{^(?:---|\+\+\+) (?:/dev/null|[ab]/\.agents/skills/[a-z0-9][a-z0-9-]*/SKILL\.md)\s*$};
    while ($a =~ /(?:^WHY:\s*(.+?)\s*$)?\s*^```diff\s*\n(.*?)^```\s*$/msg) {
      my ($w, $d) = ($1 // "", $2);
      my @heads = grep { /^(?:---|\+\+\+) / } split /\n/, $d;
      next unless @heads >= 2 && !grep { $_ !~ $path } @heads;
      next unless grep { m{^\+\+\+ b/} } @heads;
      last if ++$n > 3;
      print "## Suggestion $n\n\n", ($w ne "" ? "Why: $w\n\n" : ""), "```diff\n$d```\n\n";
    }')
  if [ -z "$kept" ]; then
    echo "no suggestions"
    return 0
  fi
  mkdir -p "$OUT" || return 1
  {
    printf '# Skill suggestions from %s\n\n' "$id"
    printf 'Proposed by one tool-less model call after %s tool steps; nothing has been applied.\n' "$steps"
    printf 'Firstmate applies only the suggestions the captain names, through the normal shared-material change path.\n\n'
    printf 'Target files at proposal time (git blob sha, or new):\n\n'
    printf '%s\n' "$kept" | sed -n 's|^+++ b/\(\.agents/skills/[a-z0-9-]*/SKILL\.md\).*|\1|p' | sort -u | while IFS= read -r f; do
      if [ -f "$FM_ROOT/$f" ]; then
        printf -- '- %s %s\n' "$f" "$(git -C "$FM_ROOT" hash-object "$f" 2>/dev/null || echo unknown)"
      else
        printf -- '- %s new\n' "$f"
      fi
    done
    printf '\n%s\n' "$kept"
  } > "$file.tmp" && mv -f "$file.tmp" "$file" || return 1
  printf '%s\n' "${file#"$FM_HOME"/}"
}

list() {
  [ -d "$OUT" ] || return 0
  perl -e 'print map { "$_\n" } sort { (stat $b)[9] <=> (stat $a)[9] } @ARGV' "$OUT"/*.md 2>/dev/null \
    | sed "s|^$FM_HOME/||"
}

CMD=${1:-}
[ "$#" -eq 0 ] || shift
case "$CMD" in
  propose) propose "$@" ;;
  list) [ "$#" -eq 0 ] || usage; list ;;
  -h|--help|help) sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//' ;;
  *) usage ;;
esac
