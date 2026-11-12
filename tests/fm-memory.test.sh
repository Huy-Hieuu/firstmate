#!/usr/bin/env bash
# Behavioral coverage for bin/fm-memory.sh: `until` expiry boundary,
# strike-through, sticky forget, and the memory-only data/ git journal.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-memory)
MEMORY="$ROOT/bin/fm-memory.sh"
fm_git_identity

new_data() {  # <name> -> data dir with a learnings.md fixture
  local data="$TMP_ROOT/$1/data"
  mkdir -p "$data"
  cat > "$data/learnings.md" <<'EOF'
# Learnings
- kept entry <!--a:2026-11-01-->
- freeze ended yesterday <!--p:2026-11-01--><!--u:2026-11-10-->
  continuation of the freeze entry
- leave ends today <!--u:2026-11-11-->
- ~~old rule~~ replaced below
- Loom is preferred by ClientX <!--a:2026-11-01-->
- clientxyz is a different client
## ClientX heading
EOF
  printf '%s\n' "$data"
}

mem() {  # <data> <args...>
  local data=$1
  shift
  FM_DATA_OVERRIDE="$data" FM_MEMORY_TODAY=2026-11-11 bash "$MEMORY" "$@"
}

test_view_hides_expired_and_struck_entries() {
  local data out
  data=$(new_data view)
  out=$(mem "$data" view "$data/learnings.md")
  assert_contains "$out" "- leave ends today" "an entry was hidden on its own until date"
  assert_not_contains "$out" "freeze ended yesterday" "an entry past its until date was shown"
  assert_not_contains "$out" "continuation of the freeze" "an expired entry's continuation line was shown"
  assert_not_contains "$out" "old rule" "a struck entry was shown"
  assert_contains "$out" "- kept entry" "an ordinary entry was hidden"
  assert_contains "$out" "2 expired, struck, or forgotten entries hidden" "the hidden count was not reported"
  out=$(mem "$data" due)
  assert_contains "$out" "data/learnings.md:3: expired 2026-11-10:" "due did not list the expired entry"
  assert_contains "$out" "data/learnings.md:6: struck:" "due did not list the struck entry"
  pass "view hides an entry from the day after its until date and struck entries; due lists them"
}

test_forget_is_sticky_until_unforgotten() {
  local data out status
  data=$(new_data forget)
  out=$(mem "$data" forget ClientX)
  assert_contains "$out" "data/learnings.md:7: forgotten clientx: - Loom is preferred by ClientX" "forget did not list the mention"
  out=$(mem "$data" view "$data/learnings.md")
  assert_not_contains "$out" "Loom" "a forgotten entry was shown"
  assert_contains "$out" "clientxyz is a different client" "a longer word containing the term was hidden"
  assert_contains "$out" "## ClientX heading" "a heading was hidden"
  out=$(mem "$data" check "remember that clientx likes Loom"); status=$?
  expect_code 1 "$status" "check on a forgotten term"
  assert_contains "$out" "forgotten term: clientx" "check did not name the term"
  mem "$data" check "an unrelated fact" >/dev/null || fail "check refused text without a forgotten term"
  out=$(mem "$data" unforget CLIENTX)
  assert_contains "$out" "unforgotten: CLIENTX" "unforget did not drop the term case-insensitively"
  mem "$data" check "clientx likes Loom" >/dev/null || fail "an unforgotten term was still refused"
  pass "forget hides whole-word mentions and refuses recapture until unforget"
}

test_commit_journals_only_memory_paths() {
  local data out
  data=$(new_data journal)
  out=$(mem "$data" commit "no repo")
  assert_contains "$out" "is not its own git repository" "commit outside a git repository was not a reported no-op"
  git -C "$data" init -q -b main
  printf 'other\n' > "$data/backlog.md"
  mem "$data" forget ClientX >/dev/null
  out=$(mem "$data" commit "forget ClientX")
  assert_contains "$out" "memory: forget ClientX" "commit did not report the journal commit"
  assert_equals "learnings.md memory/forgotten.txt" "$(git -C "$data" show --name-only --format= HEAD | sort | tr '\n' ' ' | sed 's/ $//')" \
    "the journal commit did not hold exactly the memory paths"
  assert_equals "?? backlog.md" "$(git -C "$data" status --short)" "a non-memory file was committed or staged"
  out=$(mem "$data" commit "again")
  assert_contains "$out" "no memory changes" "an unchanged memory set made another commit"
  pass "commit journals only memory paths, once, and never outside data's own repository"
}

test_capture_requires_verbatim_evidence() {
  local data out status before
  data=$(new_data capture)
  printf 'note: keep Airflow retries at 3 with a 10m backoff\n' > "$data/note.txt"
  before=$(cat "$data/learnings.md")
  out=$(mem "$data" capture learnings.md "$data/note.txt" "keep Airflow retries at 5" "Airflow retries stay at 5" 2>&1); status=$?
  expect_code 1 "$status" "capture with a quote absent from its source"
  assert_contains "$out" "does not appear verbatim" "the refusal did not name the missing quote"
  out=$(mem "$data" capture learnings.md "$data/note.txt" "keep Airflow retries at 3" "Airflow retries stay at 5" 2>&1); status=$?
  expect_code 1 "$status" "capture of a number the quote does not hold"
  assert_contains "$out" "does not contain: 5" "the refusal did not name the unsupported number"
  out=$(mem "$data" capture captain.md chat "should PRs stay short?" "PRs stay short" 2>&1); status=$?
  expect_code 1 "$status" "capture of a question"
  out=$(mem "$data" capture captain.md chat "ClientX wants Loom videos" "ClientX wants Loom videos" 2>&1); status=$?
  expect_code 0 "$status" "capture without a forgotten term"
  mem "$data" forget Loom >/dev/null
  out=$(mem "$data" capture captain.md chat "send ClientX a Loom" "ClientX gets Loom updates" 2>&1); status=$?
  expect_code 1 "$status" "capture of a forgotten term"
  assert_equals "$before" "$(cat "$data/learnings.md")" "a refused capture wrote to the memory file"
  out=$(mem "$data" capture --until 2026-12-15 learnings.md "$data/note.txt" "keep Airflow retries at 3 with a 10m backoff" "Airflow DAG retries stay at 3 with a 10m backoff")
  assert_contains "$(cat "$data/learnings.md")" "- Airflow DAG retries stay at 3 with a 10m backoff <!--a:2026-11-11--><!--u:2026-12-15-->
  > \"keep Airflow retries at 3 with a 10m backoff\" ($data/note.txt, 2026-11-11)" "the captured entry lacks its markers or evidence line"
  pass "capture writes only facts whose numbers sit in a verbatim quote, with the evidence line"
}

test_topic_index_loads_by_alias() {
  local data out status
  data=$(new_data topics)
  mem "$data" new topic airflow "retry policy" >/dev/null
  mem "$data" new person linh-nguyen Linh >/dev/null
  mem "$data" capture people/linh-nguyen.md chat "Linh prefers Slack" "Linh prefers Slack" >/dev/null
  out=$(mem "$data" index)
  assert_contains "$out" "- topic airflow: retry policy" "the index did not list the topic with its alias"
  assert_contains "$out" "- person linh-nguyen: Linh" "the index did not list the person"
  out=$(mem "$data" load "what did we decide on the Retry Policy?")
  assert_contains "$out" "== data/memory/airflow.md ==" "an alias in the text did not load the topic"
  assert_not_contains "$out" "linh-nguyen" "a file the text does not name was loaded"
  assert_contains "$(mem "$data" load "prep for the call with linh")" "Linh prefers Slack" "a person alias did not load the person's facts"
  assert_contains "$(mem "$data" entries)" "data/people/linh-nguyen.md:" "entries did not cover person files"
  printf 'mate-1\n' > "$TMP_ROOT/topics/.fm-secondmate-home"
  out=$(FM_HOME="$TMP_ROOT/topics" mem "$data" capture captain-shared.md chat "always ask first" "Always ask first" 2>&1); status=$?
  expect_code 1 "$status" "capture into captain-shared.md in a secondmate home"
  pass "topic and person files are indexed and load when the text names an alias"
}

fm_test_run \
  test_view_hides_expired_and_struck_entries \
  test_forget_is_sticky_until_unforgotten \
  test_commit_journals_only_memory_paths \
  test_capture_requires_verbatim_evidence \
  test_topic_index_loads_by_alias
