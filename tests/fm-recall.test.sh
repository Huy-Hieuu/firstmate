#!/usr/bin/env bash
# tests/fm-recall.test.sh - behavior tests for bin/fm-recall.sh: a query finds
# the passage that holds its words and names its file and line, the index
# follows corpus changes, and the plain scan answers where FTS5 is missing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-recall-tests)
RECALL="$ROOT/bin/fm-recall.sh"

new_home() {  # <name>: a home with a report, a status log, and learnings
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data/airflow-scout" "$home/state"
  cat > "$home/data/airflow-scout/report.md" <<'EOF'
# Airflow scout

## Background
The scheduler runs on MoMo infra.

## Decision
We decided the Airflow retry policy is three retries with a ten minute backoff.
EOF
  printf 'done [at=1]: herdr sidebar tree landed\n' > "$home/state/herdr-tree.status"
  printf '%s\n' '- Gerrit needs the VPN. <!--a:2026-11-01-->' > "$home/data/learnings.md"
  printf '%s\n' "$home"
}

recall() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" bash "$RECALL" "$@"
}

test_query_names_the_matching_passage() {
  local home out
  home=$(new_home fts)
  out=$(recall "$home" "what did we decide about the Airflow retry policy?")
  assert_contains "$out" "[UNTRUSTED RECALL DATA]" "recall output is not fenced as untrusted records"
  assert_contains "$out" "data/airflow-scout/report.md:6" "the hit does not name the decision passage's file and line"
  assert_not_contains "$out" "report.md:4" "a passage without the query words was returned"
  out=$(recall "$home" herdr sidebar)
  assert_contains "$out" "state/herdr-tree.status:1" "a status log was not searched"
  out=$(recall "$home" gerrit kubernetes)
  assert_contains "$out" "data/learnings.md:1" "a query whose words never meet did not fall back to any word"
  printf '%s\n' '- Jenkins deploys need the release tag. <!--a:2026-11-02-->' >> "$home/data/learnings.md"
  touch -t 203001010000 "$home/data/learnings.md"
  assert_contains "$(recall "$home" jenkins release)" "data/learnings.md:2" "the index missed a changed file"
  mkdir -p "$home/data/people"
  printf '%s\n' '- Linh owns the jaeger rollout.' > "$home/data/people/linh.md"
  assert_contains "$(recall "$home" jaeger)" "data/people/linh.md:1" "the index missed a new file"
  pass "a query names the passage holding its words and the index follows corpus changes"
}

test_scan_answers_without_fts5() {
  local home out bin="$TMP_ROOT/nofts-bin"
  home=$(new_home scan)
  mkdir -p "$bin"
  printf '#!/bin/sh\nexit 1\n' > "$bin/sqlite3"
  chmod +x "$bin/sqlite3"
  out=$(PATH="$bin:$PATH" recall "$home" -n 1 airflow backoff)
  assert_contains "$out" "data/airflow-scout/report.md:7" "the plain scan did not find the line holding every word"
  assert_not_contains "$out" "report.md:1" "the plain scan ranked a partial match above a full one"
  [ ! -e "$home/state/recall.db" ] || fail "the plain scan wrote an index"
  pass "without FTS5 a plain scan answers the same query"
}

fm_test_run test_query_names_the_matching_passage test_scan_answers_without_fts5
