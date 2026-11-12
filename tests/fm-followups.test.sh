#!/usr/bin/env bash
# tests/fm-followups.test.sh - behavior tests for the brief's inbox and
# follow-up sources: mail sorting wakes firstmate only for unsorted mail, the
# quote gate refuses words the captain did not write, a wait closes on a reply
# and asks for a nudge when due, reply drafts stay one per thread addressed to
# the sender, and the Upwork log maps to the right brief sections.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-followups-tests)
BRIEF="$ROOT/bin/fm-daily-brief.sh"
FOLLOW="$ROOT/bin/fm-followups.sh"
NOW=1794790800
unset FM_TASK_ID FM_ROUTINE_CURSOR FM_ROUTINE_CURSOR_OUT FM_UPWORK_LOG

new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/state" "$home/data/career"
  cat > "$home/mail.ndjson" <<'EOF'
{"folder":"inbox","uid":"11","uidvalidity":"7","ts":1794790000,"from":"Client Y","from_addr":"y@client.example","to":"me","cc":"boss@client.example","subject":"Estimate","message_id":"<a1@client.example>","in_reply_to":"","refs":[],"seen":false,"text":"Can you send a revised estimate by Thursday?"}
{"folder":"inbox","uid":"12","uidvalidity":"7","ts":1794790100,"from":"News","from_addr":"noreply@news.example","to":"me","cc":"","subject":"Weekly digest","message_id":"<n1@news.example>","in_reply_to":"","refs":[],"seen":false,"text":"hi"}
{"folder":"sent","uid":"5","uidvalidity":"9","ts":1794790200,"from":"Me","from_addr":"me@x.example","to":"Linh <linh@x.example>","cc":"","subject":"Migration","message_id":"<s5@x.example>","in_reply_to":"","refs":[],"seen":true,"text":"Hi Linh,\nI'll send you the migration doc   by Friday.\nCould you review change 12345?"}
EOF
  printf 'ignore from noreply@\n' > "$home/config/mail-triage"
  printf '%s\n' "$home"
}

run() {  # <home> <epoch> <script> <args...>
  local home=$1 t=$2
  shift 2
  FM_HOME="$home" FM_BRIEF_NOW="$t" FM_BRIEF_SNAPSHOT_TIMEOUT=1 \
    FM_PROBE_MAIL_FETCH="cat $home/mail.ndjson" bash "$@"
}

page() { cat "$1/data/brief/"*.md; }

test_mail_sorting() {
  local home out
  home=$(new_home sorting)
  out=$(run "$home" "$NOW" "$BRIEF" source mail)
  assert_contains "$out" '"mail:7/11"' "unsorted mail wakes firstmate"
  assert_not_contains "$out" '"mail:7/12"' "mail a captain rule already sorted does not wake firstmate"
  assert_contains "$out" '"sent:9/5"' "a sent mail with a promise or question wakes firstmate"
  run "$home" "$NOW" "$FOLLOW" triage mail:7/11 needs "client asks for an estimate by Thursday" || fail "triage failed"
  run "$home" "$NOW" "$BRIEF" source mail > /dev/null
  run "$home" "$NOW" "$BRIEF" compose
  out=$(sed -n '/^## Needs you/,/^## Your day/p' "$home/data/brief/"*.md)
  assert_contains "$out" "Mail from Client Y: Estimate (client asks for an estimate by Thursday)" "firstmate's call puts the mail under Needs you with its reason"
  assert_not_contains "$(page "$home")" "Weekly digest" "ignored mail stays off the page"
  assert_contains "$(page "$home")" "1 email(s) sorted" "a sorting call counts in the value line"
  pass "mail sorting wakes only for unsorted mail and shows firstmate's call"
}

test_quote_gate() {
  local home rc=0
  home=$(new_home quote)
  run "$home" "$NOW" "$BRIEF" source mail > /dev/null
  run "$home" "$NOW" "$FOLLOW" owe Linh "migration doc" --from sent:9/5 --quote "I will send the doc tomorrow" 2>/dev/null || rc=$?
  assert_equals 1 "$rc" "words he did not write are refused"
  rc=0
  run "$home" "$NOW" "$FOLLOW" wait Linh "review of change 999" --from sent:9/5 --quote "Could you review change 12345?" 2>/dev/null || rc=$?
  assert_equals 1 "$rc" "a number missing from the quote is refused"
  rc=0
  run "$home" "$NOW" "$FOLLOW" owe Linh "migration doc" --from sent:9/5 2>/dev/null || rc=$?
  assert_equals 1 "$rc" "a follow-up from sent mail without a quote is refused"
  [ ! -f "$home/data/waiting.md" ] || fail "a refused follow-up recorded nothing"
  run "$home" "$NOW" "$FOLLOW" owe Linh "migration doc" --due 2026-11-30 --from sent:9/5 \
    --quote "I'll send you the migration doc by Friday" > /dev/null || fail "his verbatim words (whitespace aside) are accepted"
  assert_contains "$(cat "$home/data/waiting.md")" "\"I'll send you the migration doc by Friday\"" "the exact quote is kept as evidence"
  pass "the quote gate keeps only his own words"
}

test_wait_lifecycle() {
  local home out
  home=$(new_home wait)
  run "$home" "$NOW" "$BRIEF" source mail > /dev/null
  run "$home" "$NOW" "$FOLLOW" wait Linh "review of change 12345" --nudge 2026-11-20 --from sent:9/5 \
    --quote "Could you review change 12345?" > /dev/null || fail "wait failed"
  out=$(run "$home" "$NOW" "$FOLLOW" rows)
  assert_contains "$out" '"section":"waiting"' "a wait shows under Waiting on others before its nudge date"
  out=$(run "$home" $((NOW + 30 * 86400)) "$FOLLOW" rows)
  assert_contains "$out" '"section":"needs"' "a wait past its nudge date asks the captain to nudge"
  printf '%s\n' '{"folder":"inbox","uid":"13","uidvalidity":"7","ts":1794790300,"from":"Linh","from_addr":"linh@x.example","subject":"Re: Migration","message_id":"<r1@x.example>","in_reply_to":"<s5@x.example>","refs":["<s5@x.example>"],"seen":false,"text":"Done."}' >> "$home/mail.ndjson"
  run "$home" "$NOW" "$BRIEF" source mail > /dev/null
  out=$(run "$home" "$NOW" "$FOLLOW" rows)
  assert_not_contains "$out" "follow:#1" "a reply in the thread closes the wait"
  assert_contains "$(cat "$home/data/waiting.md")" "~~ · replied" "the closed wait is struck through as replied"
  pass "a wait asks for a nudge when due and closes on a reply"
}

test_draft_one_per_thread() {
  local home file rc=0
  home=$(new_home draft)
  run "$home" "$NOW" "$BRIEF" source mail > /dev/null
  file=$(printf 'Thanks, I will look at it.\n' | run "$home" "$NOW" "$FOLLOW" draft mail:7/11) || fail "draft failed"
  assert_equals "To: y@client.example" "$(sed -n 1p "$file")" "the draft goes to the original sender only"
  assert_not_contains "$(cat "$file")" "boss@client.example" "nobody else is copied"
  printf 'Again\n' | run "$home" "$NOW" "$FOLLOW" draft mail:7/11 2>/dev/null || rc=$?
  assert_equals 1 "$rc" "a second draft for the same thread is refused"
  assert_contains "$(cat "$file")" "Thanks, I will look at it." "the first draft is kept"
  pass "reply drafts stay one per thread addressed to the sender"
}

test_upwork_pipeline() {
  local home out
  home=$(new_home upwork)
  cat > "$home/data/career/upwork.md" <<'EOF'
# Upwork

## Sent proposals

- 2026-11-01 SENT (by him): Voice agent - https://www.upwork.com/jobs/~0221
- 2026-11-11 SENT (by him): Agent platform -
  https://www.upwork.com/jobs/~0222 - client details
- 2026-11-10 DRAFTED in his Chrome, not sent: RAG chatbot ~0223 (letter file)
- 2026-11-05 SENT (by him): Eval harness https://www.upwork.com/jobs/~0224
  - 2026-11-12 INTERVIEW: client asked for a call
- 2026-11-05 SENT (by him): Old one ~0225
  - 2026-11-09 DECLINED by the client
- 2026-11-12 ~0226 checked and skipped
EOF
  out=$(run "$home" "$NOW" "$ROOT/bin/fm-probe-upwork.sh")
  assert_contains "$out" '{"id":"upwork:~0221","section":"waiting","title":"Upwork client, no reply since 2026-11-01 - follow-up due: Voice agent"' "an old sent proposal says a follow-up is due"
  assert_contains "$out" '"section":"waiting","title":"Upwork client reply awaited since 2026-11-11: Agent platform"' "a recent sent proposal awaits the client"
  assert_contains "$out" '"section":"owe","title":"Upwork proposal drafted 2026-11-10, not sent: RAG chatbot"' "a drafted proposal is something he owes"
  assert_contains "$out" '"section":"needs","title":"Upwork client answered (2026-11-12): Eval harness"' "a client answer needs him"
  assert_not_contains "$out" "~0225" "a closed proposal leaves the pipeline"
  assert_not_contains "$out" "~0226" "a line without a status is not a pipeline entry"
  pass "the Upwork log maps to brief sections"
}

fm_test_run test_mail_sorting test_quote_gate test_wait_lifecycle test_draft_one_per_thread test_upwork_pipeline
