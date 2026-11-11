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

fm_test_run \
  test_view_hides_expired_and_struck_entries \
  test_forget_is_sticky_until_unforgotten \
  test_commit_journals_only_memory_paths
