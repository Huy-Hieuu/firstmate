#!/usr/bin/env bash
# Regression tests for bin/fm-spawn.sh --sparse: the sparse task copy firstmate
# creates itself for a project that registers a `sparse=` baseline.
#
# These drive the real spawn path on backend=tmux with a fake terminal against
# a throwaway project whose origin advanced after the primary checkout last
# moved. They prove the copy lands at its fixed layout, holds only the
# top-level files plus the baseline and task directories, starts from the
# fetched origin tip, and is recorded with its effective directory set; that a
# brief, flag, and registry disagreement is refused before any copy exists; and
# that a project without the token keeps today's pooled behavior.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-sparse-copy)

# make_case <name> <registry-line-tokens>: a home whose registry names the
# project `project` with the given bracket tokens, and a project with several
# top-level directories whose origin is one commit ahead of the checkout.
make_case() {
  local name=$1 tokens=$2 case_dir home project origin publisher d
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/work/project"
  origin="$case_dir/origin.git"
  publisher="$case_dir/publisher"
  fm_test_spawn_home "$home" codex
  printf 'manual\n' > "$home/config/backlog-backend"
  printf '%s\n' '## Projects' "- project [$tokens] - sparse test project (added 2026-01-01)" > "$home/data/projects.md"

  git init --quiet -b main "$project"
  for d in tools common-libs alexis plutus janus; do
    mkdir -p "$project/$d/sub"
    printf '%s\n' "$d" > "$project/$d/file.txt"
    printf '%s\n' "$d" > "$project/$d/sub/nested.txt"
  done
  printf 'top\n' > "$project/README.md"
  git -C "$project" add -A
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$project" "$origin"
  git -C "$project" remote add origin "file://$origin"
  git -C "$project" fetch --quiet origin

  git clone --quiet "file://$origin" "$publisher"
  printf 'advanced\n' > "$publisher/alexis/advanced.txt"
  git -C "$publisher" add -A
  git -C "$publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm advance
  git -C "$publisher" push --quiet origin main

  CASE_DIR=$case_dir
  HOME_DIR=$home
  PROJECT_DIR=$project
  FAKEBIN_DIR=$(make_spawn_fakebin "$case_dir/fake")
  COPY_DIR="$(cd "$case_dir/work" && pwd -P)/.fm-sparse/$name-t1/project"
}

brief() {  # <id> [fm-brief args...]
  local id=$1
  shift
  FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" "$ROOT/bin/fm-brief.sh" "$id" project "$@" >/dev/null 2>&1 \
    || fail "fm-brief.sh $id $* did not scaffold"
  # fm-brief leaves the task placeholders for firstmate to fill.
  perl -0pi -e "s/\\{TASK\\}/Exercise the sparse copy for $id./; s/\\{FIRSTMATE_SPEC\\}/Confirm only the named directories are present./" \
    "$HOME_DIR/data/$id/brief.md"
}

run_spawn() {  # <id> [fm-spawn args...]
  local id=$1
  shift
  fm_test_run_spawn "$HOME_DIR" "$COPY_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR" "$@"
}

test_tmux_sparse_scout_gets_only_its_directories() {
  local id=sparse-tmux-t1 out status listed
  make_case sparse-tmux 'local-only sparse=tools,common-libs'
  brief "$id" --scout --sparse alexis

  out=$(run_spawn "$id" --scout --sparse alexis --backend tmux)
  status=$?
  expect_code 0 "$status" "a sparse scout spawn on tmux should succeed"$'\n'"$out"
  assert_grep "worktree=$COPY_DIR" "$HOME_DIR/state/$id.meta" "spawn did not record the sparse copy at its fixed layout"
  assert_grep "sparse=alexis,common-libs,tools" "$HOME_DIR/state/$id.meta" "spawn did not record the effective directory set"
  listed=$(cd "$COPY_DIR" && find . -mindepth 1 -maxdepth 1 ! -name .git | LC_ALL=C sort | tr '\n' ' ')
  [ "$listed" = "./README.md ./alexis ./common-libs ./tools " ] \
    || fail "the sparse copy holds '$listed', not only the top-level files and the chosen directories"
  [ -f "$COPY_DIR/alexis/sub/nested.txt" ] || fail "a cone directory is missing its nested files"
  [ -f "$COPY_DIR/alexis/advanced.txt" ] || fail "the sparse copy did not start from the fetched origin tip"
  [ "$(git -C "$COPY_DIR" rev-parse HEAD)" = "$(git -C "$COPY_DIR" rev-parse origin/main)" ] \
    || fail "the sparse copy HEAD is not origin/main"
  [ "$(git -C "$COPY_DIR" sparse-checkout list | tr '\n' ' ')" = "alexis common-libs tools " ] \
    || fail "the sparse copy's cone is '$(git -C "$COPY_DIR" sparse-checkout list | tr '\n' ' ')'"
  [ -z "$(git -C "$COPY_DIR" status --porcelain --untracked-files=all)" ] || fail "the sparse copy is not clean"
  [ "$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD)" = main ] || fail "spawn moved the primary checkout"
  [ -d "$PROJECT_DIR/janus" ] || fail "spawn changed the primary checkout's files"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# sparse copy %s top level: %s\n' "$COPY_DIR" "$listed"
  fi
  pass "a sparse-registered tmux scout gets a fresh copy holding only top-level files, its baseline, and its own directories"
}

test_sparse_disagreements_refuse_before_any_copy() {
  local id out status
  make_case sparse-refuse 'direct-PR sparse=tools'

  id=sparse-refuse-noflag-t1
  brief "$id" --mode direct-PR
  out=$(run_spawn "$id" --mode direct-PR --yolo off --backend tmux)
  status=$?
  [ "$status" -ne 0 ] || fail "a sparse-registered project spawned without --sparse should be refused"
  assert_contains "$out" "registers the sparse baseline sparse=tools" "the missing --sparse refusal did not name the baseline"

  id=sparse-refuse-mismatch-t1
  brief "$id" --mode direct-PR --sparse alexis
  out=$(run_spawn "$id" --mode direct-PR --yolo off --sparse plutus --backend tmux)
  status=$?
  [ "$status" -ne 0 ] || fail "a --sparse that disagrees with the brief should be refused"
  assert_contains "$out" "must record exactly one Sparse checkout: plutus line" "the brief disagreement refusal did not name the expected line"

  id=sparse-refuse-backend-t1
  brief "$id" --mode direct-PR --sparse alexis
  out=$(run_spawn "$id" --mode direct-PR --yolo off --sparse alexis --backend zellij)
  status=$?
  [ "$status" -ne 0 ] || fail "a sparse copy on an unsupported backend should be refused"
  assert_contains "$out" "backend=tmux, backend=herdr, or backend=orca only" "the backend refusal did not name the supported backends"

  out=$(run_spawn sparse-refuse-relaunch-t1 --relaunch --sparse alexis)
  status=$?
  [ "$status" -ne 0 ] || fail "--relaunch --sparse should be refused"
  assert_contains "$out" "--sparse cannot change it" "the relaunch refusal did not explain itself"

  [ ! -e "$CASE_DIR/work/.fm-sparse" ] || fail "a refused spawn created a sparse copy"
  for id in sparse-refuse-noflag-t1 sparse-refuse-mismatch-t1 sparse-refuse-backend-t1; do
    [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn $id published task metadata"
  done
  pass "a missing, disagreeing, or unsupported-backend --sparse is refused before any copy exists"
}

test_project_without_token_refuses_sparse_and_keeps_its_pool() {
  local id out status
  make_case sparse-none 'direct-PR'

  id=sparse-none-flag-t1
  brief "$id" --mode direct-PR --sparse alexis
  out=$(run_spawn "$id" --mode direct-PR --yolo off --sparse alexis --backend tmux)
  status=$?
  [ "$status" -ne 0 ] || fail "--sparse on a project without a baseline should be refused"
  assert_contains "$out" "needs project project to register a sparse baseline" "the no-baseline refusal did not explain itself"

  id=sparse-none-brief-t1
  brief "$id" --mode direct-PR --sparse alexis
  out=$(run_spawn "$id" --mode direct-PR --yolo off --backend tmux)
  status=$?
  [ "$status" -ne 0 ] || fail "a brief with a Sparse checkout line and no --sparse should be refused"
  assert_contains "$out" "records a Sparse checkout line but the spawn has no --sparse" "the brief-only refusal did not explain itself"
  [ ! -e "$CASE_DIR/work/.fm-sparse" ] || fail "a project without a sparse token got a sparse copy"
  pass "a project without a sparse token refuses --sparse and a sparse brief, and never creates a sparse copy"
}

test_failed_spawn_removes_its_unlaunched_copy() {
  local id=sparse-abort-t1 out status
  make_case sparse-abort 'direct-PR sparse=tools'
  brief "$id" --mode direct-PR --sparse alexis
  # The pane never reaches the copy, so the spawn refuses before any launch.
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  out=$(fm_test_run_spawn "$HOME_DIR" "$PROJECT_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR" \
    --mode direct-PR --yolo off --sparse alexis --backend tmux)
  status=$?
  [ "$status" -ne 0 ] || fail "a spawn whose pane never entered the copy should fail"$'\n'"$out"
  assert_contains "$out" "not its recorded worktree" "the spawn failed for another reason"$'\n'"$out"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "the failed spawn published task metadata"
  assert_absent "$CASE_DIR/work/.fm-sparse/$id" "the failed spawn left its unlaunched sparse copy"
  ! git -C "$PROJECT_DIR" worktree list --porcelain | grep -qF ".fm-sparse/$id" \
    || fail "the project still lists the failed spawn's sparse copy"
  pass "a spawn that fails before launching removes the sparse copy it created"
}

test_tmux_sparse_scout_gets_only_its_directories
test_sparse_disagreements_refuse_before_any_copy
test_project_without_token_refuses_sparse_and_keeps_its_pool
test_failed_spawn_removes_its_unlaunched_copy
