#!/usr/bin/env bash
# tests/fm-skill-review.test.sh - behavior tests for bin/fm-skill-review.sh: a
# short task is skipped, a proposal keeps only skill diffs and at most three,
# the worker's steering corrections reach the model fenced as records, and no
# skill file is ever written.
# shellcheck disable=SC2016 # Fixture scripts and diffs are literal text.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-skill-review-tests)
REVIEW="$ROOT/bin/fm-skill-review.sh"

# new_home <name>: a home with one finished task t1 and a fake model whose
# answer is $home/answer.md and whose prompt lands in $home/prompt.txt.
new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data/t1" "$home/state/t1.inbox/handled"
  printf "## Captain's intent\nAdd the export button\n" > "$home/data/t1/brief.md"
  printf 'Use bin/fm-export.sh, not the raw command\n' > "$home/state/t1.inbox/handled/1.msg"
  printf 'done [at=1]: ready\n' > "$home/state/t1.status"
  printf '#!/usr/bin/env bash\nprintf "%%s" "$1" > "%s/prompt.txt"\ncat "%s/answer.md"\n' "$home" "$home" > "$home/ask"
  chmod +x "$home/ask"
  printf '%s\n' "$home"
}

diff_block() {  # <path> <added line>
  printf '```diff\n--- a/%s\n+++ b/%s\n@@ -1 +1,2 @@\n x\n+%s\n```\n' "$1" "$1" "$2"
}

review() { FM_HOME="$1" FM_SKILL_REVIEW_ASK="$1/ask" bash "$REVIEW" "${@:2}"; }

test_short_task_is_skipped() {
  local home out
  home=$(new_home short)
  printf 'NONE\n' > "$home/answer.md"
  out=$(review "$home" propose t1 --steps 12)
  assert_contains "$out" "skipped: 12 tool steps is under 40" "a short task was reviewed"
  [ ! -e "$home/prompt.txt" ] || fail "a short task called the model"
  pass "a task under the step threshold is skipped without a model call"
}

test_only_skill_diffs_are_kept() {
  local home out file
  home=$(new_home kept)
  {
    printf 'WHY: told twice to use the export script\n'; diff_block .agents/skills/bearings/SKILL.md "Use bin/fm-export.sh."
    printf 'WHY: sneaky\n'; diff_block bin/fm-send.sh "rm -rf /"
    printf 'WHY: two\n'; diff_block .agents/skills/stow/SKILL.md "two"
    printf 'WHY: three\n'; diff_block .agents/skills/ponytail/SKILL.md "three"
    printf 'WHY: four\n'; diff_block .agents/skills/humanizer/SKILL.md "four"
  } > "$home/answer.md"
  out=$(review "$home" propose t1 --steps 55)
  assert_equals "data/skill-review/t1.md" "$out" "the suggestion file path was not printed"
  file=$(cat "$home/data/skill-review/t1.md")
  assert_contains "$file" "Why: told twice to use the export script" "the reason was dropped"
  assert_contains "$file" "+Use bin/fm-export.sh." "the skill diff was dropped"
  assert_not_contains "$file" "fm-send.sh" "a diff outside the skills was kept"
  assert_contains "$file" "## Suggestion 3" "fewer than three suggestions were kept"
  assert_not_contains "$file" "## Suggestion 4" "more than three suggestions were kept"
  assert_contains "$(cat "$home/prompt.txt")" "Use bin/fm-export.sh, not the raw command" "the steering correction did not reach the model"
  assert_contains "$(cat "$home/prompt.txt")" "UNTRUSTED" "task records reached the model unfenced"
  [ ! -e "$home/.agents" ] || fail "the review wrote a skill"
  pass "a proposal keeps at most three skill diffs and applies none"
}

fm_test_run test_short_task_is_skipped test_only_skill_diffs_are_kept
