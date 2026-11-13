#!/usr/bin/env bash
# tests/fm-weekly-review.test.sh - behavior tests for bin/fm-weekly-review.sh:
# the week's page is built from the home's own records, counts them in its
# headline, and leaves out every section with nothing to report.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-weekly-review-tests)
WEEKLY="$ROOT/bin/fm-weekly-review.sh"
NOW=$(perl -MPOSIX=mktime -e 'print mktime(0, 0, 16, 13, 10, 126)')  # Fri 13 Nov 2026 16:00 local

test_week_page_from_records() {
  local home="$TMP_ROOT/week" page
  mkdir -p "$home/data" "$home/state/brief/rows" "$home/config"
  fm_test_tasks_toml "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
- [x] export-button - Add the export button (repo: app) (kind: ship) (done 2026-11-12)
- [x] old-thing - Something from last month (repo: app) (kind: ship) (done 2026-10-01)
EOF
  {
    printf '{"id":"f:1","section":"needs","title":"Send Linh the migration doc (due Wed)"}\n'
    printf '{"id":"f:2","section":"owe","title":"Review estimate for client Y"}\n'
  } > "$home/state/brief/rows/followups.ndjson"
  FM_HOME="$home" FM_BRIEF_NOW="$NOW" bash "$WEEKLY" compose || fail "compose failed"
  page=$(cat "$home/data/brief/week-2026-46.md")
  assert_contains "$page" "1 finished, 1 slipped, 1 you owe." "the headline does not count the week"
  assert_contains "$page" "Add the export button (app)" "a task finished this week is missing"
  assert_not_contains "$page" "Something from last month" "a task finished last month was counted"
  assert_contains "$page" "## Slipped" "the slipped follow-up section is missing"
  assert_contains "$page" "Review estimate for client Y" "what the captain owes is missing"
  assert_not_contains "$page" "## Incidents" "an empty incidents section was shown"
  assert_not_contains "$page" "## Investments" "an investments section was shown without a watch list"
  assert_not_contains "$page" "## Upwork" "an Upwork section was shown without its source"
  assert_contains "$(FM_HOME="$home" FM_BRIEF_NOW="$NOW" bash "$WEEKLY" show)" "UNTRUSTED" "show did not fence the page"
  pass "the weekly page counts the week's records and leaves out empty sections"
}

fm_test_run test_week_page_from_records
