#!/usr/bin/env bash
# bin/backends/orca.sh - the Orca terminal session-provider adapter.
#
# Orca owns both the task worktree and the terminal endpoint. A secondmate's
# home is registered as its own Orca project instead, and its terminal opens in
# that project's main worktree (fm_backend_orca_home_worktree_ensure). Orca's
# terminal API names only an interrupt and an Enter; Escape and the Ctrl+U
# composer clear are delivered as their raw single bytes through `--text`, which
# Orca writes to the pty unchanged (verified live, Orca 1.4.278).
#
# Target string shape: the Orca terminal id accepted by `orca terminal ...`.

# Shared composer-content classifier (empty|pending|unknown, and the fleet-wide
# dead-shell-vs-agent-composer rule). Owned by bin/fm-composer-lib.sh, reused by
# every backend so the decision cannot drift.
# shellcheck source=bin/fm-composer-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../fm-composer-lib.sh"
# Shared harness-process identity for the recovery-grade agent-state reading.
# shellcheck source=bin/fm-agent-process-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../fm-agent-process-lib.sh"

fm_backend_orca_tool_check() {
  command -v orca >/dev/null 2>&1 || { echo "error: backend=orca selected but the 'orca' CLI is not installed" >&2; return 1; }
}

fm_backend_orca_runtime_check() {
  fm_backend_orca_tool_check || return 1
  local out
  out=$(orca status --json 2>/dev/null) || {
    echo "error: backend=orca selected but 'orca status --json' failed; start Orca and wait for the runtime to be ready" >&2
    return 1
  }
  # shellcheck disable=SC2016  # Single quotes are deliberate: ${...} belongs to the Node snippet.
  printf '%s' "$out" | node -e '
const fs = require("fs");
let data;
try {
  data = JSON.parse(fs.readFileSync(0, "utf8"));
} catch (err) {
  console.error("error: invalid Orca status JSON: " + err.message);
  process.exit(1);
}
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  console.error("error: Orca runtime is not ready" + (msg ? ": " + msg : ""));
  process.exit(1);
}
const r = data.result || {};
const runtime = r.runtime || {};
const reachable = runtime.reachable ?? r.runtimeReachable;
const state = runtime.state || r.runtimeState || "";
if (reachable === true && state === "ready") process.exit(0);
console.error(`error: backend=orca requires a ready Orca runtime (reachable=${String(reachable)}, state=${state || "unknown"})`);
process.exit(1);
'
}

# Snapshot only the explicitly selected tmux session's local environment, never
# its server-global environment or the invoking process. The caller places these
# quoted assignments in its private staged launch file, never terminal input.
# Every allowlisted name must exist in the session; an explicit -NAME record is
# a deliberate unset, and a missing name refuses rather than falling back.
fm_backend_orca_launch_env_args() {  # <tmux-session> <newline-separated names>
  node - "$1" "$2" <<'JS'
const { spawnSync } = require("child_process");
const [session, names] = process.argv.slice(2);
function refuse(name) {
  // Do not echo tmux output or errors: they may contain credential values.
  const required = name === undefined ? "" : ` (required name ${name})`;
  console.error(`error: cannot snapshot configured tmux launch environment${required}; refusing Orca launch`);
  process.exit(1);
}
function read(name) {
  // Without -u, tmux sanitizes values when the client lacks a UTF-8 locale.
  const args = ["-u", "show-environment", "-t", `=${session}`];
  if (name !== undefined) args.push(name);
  // latin1 maps each byte to one code unit, so values that are not valid UTF-8
  // reach the launch file byte for byte instead of as replacement characters.
  const result = spawnSync("tmux", args, {
    encoding: "latin1", timeout: 10000, maxBuffer: 4 * 1024 * 1024,
  });
  if (result.error || result.status !== 0) refuse(name);
  return result.stdout;
}
// Verify the session even for an empty allowlist. Never derive names from raw
// multiline values or tmux's automatically populated update-environment.
read();
const assignments = [];
for (const name of new Set(names.split("\n").filter(Boolean))) {
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)) refuse();
  // Read each name separately so embedded/trailing newlines are preserved and
  // a value resembling another NAME=value line cannot supply another variable.
  const output = read(name);
  if (!output.endsWith("\n")) refuse(name);
  const record = output.slice(0, -1);
  if (record === `-${name}`) continue;
  if (!record.startsWith(`${name}=`)) refuse(name);
  const value = record.slice(name.length + 1);
  if (value.includes("\0")) refuse(name);
  assignments.push(`${name}='${value.replace(/'/g, "'\\''")}'`);
}
process.stdout.write(assignments.join(" "), "latin1");
JS
}

fm_backend_orca_json_get() {  # <field> ; fields: worktree-id worktree-path terminal-handle worktree-terminal-handle repo-id repo-path
  # Terminal handles are accepted only from verified terminal result shapes:
  # result.terminal or a root terminal object with .handle. Undocumented
  # result.id and result.worktree.terminal shapes are ignored until a real Orca
  # smoke run proves them.
  local field=$1
  node -e '
const fs = require("fs");
const field = process.argv[1];
const data = JSON.parse(fs.readFileSync(0, "utf8"));
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  if (msg) console.error(msg);
  process.exit(2);
}
const r = data.result || {};
const wt = r.worktree || r.item || r;
const explicitTerm = r.terminal || null;
const repo = r.repo || r.repository || r;
function scalar(v) {
  return (typeof v === "string" || typeof v === "number") ? String(v) : "";
}
function handle(obj) {
  if (!obj) return "";
  if (typeof obj === "string" || typeof obj === "number") return String(obj);
  return scalar(obj.handle) || "";
}
let v = "";
if (field === "worktree-id") v = wt.id || wt.worktreeId || r.worktreeId || "";
if (field === "worktree-path") v = wt.path || (wt.git && wt.git.path) || r.path || "";
if (field === "terminal-handle") v = handle(explicitTerm || r) || "";
if (field === "worktree-terminal-handle") v = handle(explicitTerm) || "";
if (field === "repo-id") v = repo.id || repo.repoId || r.repoId || "";
if (field === "repo-path") v = (r.repo || r.repository || {}).path || "";
if (!v) process.exit(1);
process.stdout.write(String(v));
' "$field"
}

fm_backend_orca_json_ok() {
  node -e '
const fs = require("fs");
const input = fs.readFileSync(0, "utf8").trim();
if (!input) process.exit(0);
let data;
try {
  data = JSON.parse(input);
} catch (err) {
  console.error("invalid Orca JSON: " + err.message);
  process.exit(2);
}
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  if (msg) console.error(msg);
  process.exit(2);
}
'
}

fm_backend_orca_run_json() {
  local out
  out=$("$@") || return 1
  printf '%s' "$out" | fm_backend_orca_json_ok
}

fm_backend_orca_repo_ensure() {  # <project-path>
  local project=$1 out repo_id
  fm_backend_orca_tool_check || return 1
  out=$(orca repo show --repo "path:$project" --json 2>/dev/null || true)
  if repo_id=$(printf '%s' "$out" | fm_backend_orca_json_get repo-id 2>/dev/null); then
    printf '%s' "$repo_id"
    return 0
  fi
  out=$(orca repo add --path "$project" --json) || return 1
  repo_id=$(printf '%s' "$out" | fm_backend_orca_json_get repo-id) || {
    echo "error: orca repo add did not return a repo id for $project" >&2
    return 1
  }
  printf '%s' "$repo_id"
}

# Print a failed Orca call's `<code>: <message>` from its JSON error, or its raw
# output when that is not an Orca error object.
fm_backend_orca_error_detail() {  # <output>
  printf '%s' "$1" | node -e '
const fs = require("fs");
const input = fs.readFileSync(0, "utf8").trim();
let detail = input;
try {
  const e = JSON.parse(input).error;
  if (e && (e.code || e.message)) detail = [e.code, e.message].filter(Boolean).join(": ");
} catch (err) {}
process.stdout.write(detail || "no output");
' 2>/dev/null || printf '%s' "${1:-no output}"
}

# A failed `orca worktree create` can still leave the copy it was making: Orca
# finishes creating it after reporting the error. Poll the task's worktree name
# for a bounded time and remove a copy that turns up only while it is not the
# project and holds no change; otherwise name the removal command.
fm_backend_orca_create_leftover_remove() {  # <project-path> <name>
  local project=$1 name=$2 out wt_id wt_path i project_real
  project_real=$(CDPATH='' cd -- "$project" 2>/dev/null && pwd -P) || project_real=$project
  for i in $(seq 1 15); do
    [ "$i" -eq 1 ] || sleep 3
    out=$(orca worktree show --worktree "name:$name" --json 2>/dev/null) || continue
    wt_id=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-id 2>/dev/null) || continue
    wt_path=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-path 2>/dev/null) || continue
    if [ "$(CDPATH='' cd -- "$wt_path" 2>/dev/null && pwd -P)" != "$project_real" ] &&
      [ -z "$(git -C "$wt_path" status --porcelain --untracked-files=all 2>/dev/null || echo dirty)" ] &&
      fm_backend_orca_remove_worktree "$wt_id" >/dev/null 2>&1; then
      echo "note: removed the copy $wt_path that the failed orca worktree create left for $name" >&2
      return 0
    fi
    break
  done
  echo "warning: if the failed orca worktree create left a copy for $name, inspect it and run 'orca worktree rm --worktree name:$name --force'" >&2
}

fm_backend_orca_worktree_create() {  # <project-path> <name>
  local project=$1 name=$2 repo_id out wt_id wt_path terminal rc=0
  repo_id=$(fm_backend_orca_repo_ensure "$project") || return 1
  out=$(orca worktree create --repo "id:$repo_id" --name "$name" --no-parent --setup skip --json) || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "error: orca worktree create failed for $name (exit $rc): $(fm_backend_orca_error_detail "$out")" >&2
    fm_backend_orca_create_leftover_remove "$project" "$name"
    return 1
  fi
  wt_id=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-id) || {
    echo "error: orca worktree create did not return a worktree id for $name" >&2
    return 1
  }
  terminal=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-terminal-handle 2>/dev/null || true)
  wt_path=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-path) || {
    echo "error: orca worktree create did not return a path for $name" >&2
    [ -z "$terminal" ] || fm_backend_orca_kill "$terminal" >/dev/null 2>&1 || true
    if fm_backend_orca_remove_worktree "$wt_id" >/dev/null; then
      return 1
    fi
    if [ -n "$terminal" ]; then
      printf '%s\t\t%s' "$wt_id" "$terminal"
    else
      printf '%s\t' "$wt_id"
    fi
    return 2
  }
  printf '%s\t%s' "$wt_id" "$wt_path"
  [ -z "$terminal" ] || printf '\t%s' "$terminal"
}

# Resolve a worktree firstmate created itself (a sparse task copy) instead of
# asking Orca to create one: Orca lists every linked worktree of a repository it
# knows, so the project is registered first and the copy is then looked up by
# path, briefly retried while Orca notices it. Prints `<worktree-id>\t<path>`,
# the shape fm_backend_orca_worktree_create prints.
fm_backend_orca_worktree_adopt() {  # <project-path> <worktree-path>
  local project=$1 path=$2 out wt_id wt_path i
  fm_backend_orca_repo_ensure "$project" >/dev/null || return 1
  for i in $(seq 1 10); do
    [ "$i" -eq 1 ] || sleep 1
    out=$(orca worktree show --worktree "path:$path" --json 2>/dev/null) || continue
    wt_id=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-id 2>/dev/null) || continue
    wt_path=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-path 2>/dev/null) || continue
    printf '%s\t%s' "$wt_id" "$wt_path"
    return 0
  done
  echo "error: orca worktree show did not resolve the worktree at $path: $(fm_backend_orca_error_detail "${out:-}")" >&2
  return 1
}

fm_backend_orca_terminal_create() {  # <worktree-id> <title>
  local worktree_id=$1 title=$2 out terminal
  fm_backend_orca_tool_check || return 1
  out=$(orca terminal create --worktree "id:$worktree_id" --title "$title" --json) || return 1
  terminal=$(printf '%s' "$out" | fm_backend_orca_json_get terminal-handle) || {
    echo "error: orca terminal create did not return a terminal handle for $title" >&2
    return 1
  }
  printf '%s' "$terminal"
}

fm_backend_orca_send_text_line() {  # <terminal-id> <text>
  local terminal=$1 text=$2
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json orca terminal send --terminal "$terminal" --text "$text" --enter --json
}

fm_backend_orca_send_literal() {  # <terminal-id> <text>
  local terminal=$1 text=$2
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json orca terminal send --terminal "$terminal" --text "$text" --json
}

# fm_backend_orca_worktree_id_valid: the Orca-owned record-integrity check for
# a recorded `orca_worktree_id=` value. Orca issues the id and firstmate stores
# it verbatim and hands it straight back as `--worktree "id:<value>"`, so the
# id is an OPAQUE selector: this predicate proves one metadata line still holds
# exactly one intact, inert value, it never reconstructs an id or infers one
# from ambient Orca state.
#
# Two shapes are accepted, and firstmate must keep accepting both because
# records outlive Orca releases:
#   - the atom form ("wt-7", a bare uuid), which older records carry;
#   - the current compound form "<repo-atom>::<absolute-worktree-path>", whose
#     path half routinely contains spaces (an Orca workspace path).
#
# Refused: empty, leading or trailing whitespace, any control character (so a
# line break, carriage return, or tab can never smuggle a second value onto one
# record line), a second "::" (which would make the split ambiguous), a
# non-atom repo half, and a relative or bare path half. The path half is
# otherwise whatever the filesystem allows on one line: it is Orca's workspace
# path, and teardown binds it to the path Orca reports before acting on it.
# The atom halves reuse fm_backend_endpoint_atom_valid, the shared endpoint
# character contract owned by bin/fm-backend.sh, which is the dispatcher that
# sources this adapter; the compound SHAPE stays here because it is Orca's,
# not the fleet-wide endpoint contract's.
fm_backend_orca_worktree_id_valid() {  # <value>
  local value=${1-} repo path
  case "$value" in
    '') return 1 ;;
    *[[:cntrl:]]*) return 1 ;;
    ' '*|*' ') return 1 ;;
  esac
  case "$value" in
    *::*)
      repo=${value%%::*}
      path=${value#*::}
      case "$path" in
        *::*) return 1 ;;
        /?*) ;;
        *) return 1 ;;
      esac
      fm_backend_endpoint_atom_valid "$repo"
      ;;
    *)
      fm_backend_endpoint_atom_valid "$value"
      ;;
  esac
}

fm_backend_orca_remove_worktree() {  # <worktree-id>
  local worktree_id=${1:-}
  [ -n "$worktree_id" ] || { echo "error: missing Orca worktree id; cannot remove worktree" >&2; return 1; }
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json orca worktree rm --worktree "id:$worktree_id" --force --json
}

fm_backend_orca_worktree_path() {
  local worktree_id=${1:-} out path
  [ -n "$worktree_id" ] || { echo "error: missing Orca worktree id; cannot resolve worktree path" >&2; return 1; }
  fm_backend_orca_tool_check || return 1
  out=$(orca worktree show --worktree "id:$worktree_id" --json) || return 1
  path=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-path) || {
    echo "error: orca worktree show did not return a path for $worktree_id" >&2
    return 1
  }
  printf '%s' "$path"
}

fm_backend_orca_capture() {  # <terminal-id> <lines>
  local terminal=$1 lines=${2:-40} out
  fm_backend_orca_tool_check || return 1
  out=$(orca terminal read --terminal "$terminal" --limit "$lines" --json) || return 1
  fm_backend_orca_json_text "$out"
}

fm_backend_orca_json_text() {  # <json> [screen]
  printf '%s' "$1" | FM_ORCA_REQUIRE_SCREEN="${2:-}" node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(0, "utf8"));
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  if (msg) console.error(msg);
  process.exit(2);
}
const r = data.result || {};
if (process.env.FM_ORCA_REQUIRE_SCREEN === "screen") {
  const source = (r.terminal || r).source;
  if (source !== "screen") {
    console.error("orca terminal read returned source " + JSON.stringify(source === undefined ? null : source) + ", not a rendered screen");
    process.exit(3);
  }
}
if (r.terminal && Array.isArray(r.terminal.tail)) {
  process.stdout.write(r.terminal.tail.join("\n"));
} else if (Array.isArray(r.tail)) {
  process.stdout.write(r.tail.join("\n"));
} else {
  process.stdout.write(r.text || r.output || r.content || r.preview || "");
}
'
}

# fm_backend_orca_composer_capture: the orca composer screen - the bottom
# rows of the terminal's RENDERED frame (`terminal read --screen`). The default
# read is accumulated stream output, not the screen: a TUI that repaints only
# its status row (omp idles that way) fills the stream tail with status-row
# repaints, so the composer row above it falls out of any bounded tail and the
# verdict was `unknown` for an idle omp; the stream also keeps stale repaint
# fragments (an old `Working…` line) the screen no longer shows. Only a read
# Orca labels `source: screen` is accepted: `screen-unavailable` (Orca fell
# back to the stream) or an absent source fails the capture, so the verdict
# stays `unknown` rather than classifying stream output as the composer. It is
# still one bounded read, never paged back into scrollback, where a stale
# startup banner (codex's bordered "permissions" box) could compete with - and
# once outrank - the live composer.
fm_backend_orca_composer_capture() {  # <terminal-id> [expected-label]
  local out
  fm_backend_orca_tool_check || return 1
  out=$(orca terminal read --terminal "$1" --screen --limit "$FM_COMPOSER_CAPTURE_LINES" --json) || return 1
  fm_backend_orca_json_text "$out" screen
}

# fm_backend_orca_composer_caps: static capability facts, not logic (see the
# capability model in bin/fm-composer-lib.sh). Orca's `terminal read --screen`
# returns plain text with no styling or cursor position, so styled and cursor
# stay 0 - the conservative degradation.
fm_backend_orca_composer_caps() {
  printf 'styled=0\ncursor=0\nidentity=0\nrows=%s\n' "$FM_COMPOSER_CAPTURE_LINES"
}

# fm_backend_orca_composer_state: thin adapter - capture plus capabilities in,
# shared verdict out. Every shape (bordered boxes AND the borderless bare-glyph
# row this adapter never learned, which left every claude/codex/pi/muse steer
# unconfirmed) lives in bin/fm-composer-lib.sh.
fm_backend_orca_composer_state() {  # <terminal-id> [expected-label] -> empty|pending|pending-unproven|unknown
  local cap verdict
  cap=$(fm_backend_orca_composer_capture "$1") || { printf 'unknown'; return 0; }
  verdict=$(fm_composer_classify_screen "$(fm_backend_orca_composer_caps)" "$cap")
  [ "$verdict" != need-identity ] || verdict=unknown
  printf '%s' "$verdict"
}

fm_backend_orca_send_key() {  # <terminal-id> <key>
  local terminal=$1 key=$2
  fm_backend_orca_tool_check || return 1
  case "$key" in
    C-c|ctrl+c|Ctrl-c|Ctrl-C)
      fm_backend_orca_run_json orca terminal send --terminal "$terminal" --interrupt --json
      ;;
    Enter|enter)
      fm_backend_orca_run_json orca terminal send --terminal "$terminal" --text "" --enter --json
      ;;
    Escape|escape|Esc)
      fm_backend_orca_run_json orca terminal send --terminal "$terminal" --text $'\033' --json
      ;;
    C-u|ctrl+u|Ctrl-u|Ctrl-U)
      fm_backend_orca_run_json orca terminal send --terminal "$terminal" --text $'\025' --json
      ;;
    *)
      echo "error: unsupported Orca key '$key'" >&2
      return 1
      ;;
  esac
}

# fm_backend_orca_send_text_submit: type <text> once, then drive the shared
# verify-and-retry-Enter loop (bin/fm-composer-lib.sh:
# fm_composer_submit_retry_core) against the shared composer verdict, so a
# slash-command popup placeholder fill gets the required second Enter without
# duplicating text.
fm_backend_orca_send_text_submit() {  # <terminal-id> <text> <retries> <enter-sleep> <settle>
  local terminal=$1 text=$2 retries=$3 sleep_s=$4 settle=$5
  fm_backend_orca_tool_check || { printf 'send-failed'; return 0; }
  fm_backend_orca_send_literal "$terminal" "$text" || { printf 'send-failed'; return 0; }
  sleep "$settle"
  fm_composer_submit_retry_core fm_backend_orca_send_key fm_backend_orca_composer_state \
    "$terminal" "$retries" "$sleep_s"
}

# fm_backend_orca_kill: close one recorded task terminal. A missing CLI is a
# close that was never even attempted, not an endpoint proven gone - with no
# CLI there is no read that could show the terminal absent - so it reports the
# failure its tool check already named instead of a success. The close call
# itself stays best-effort: whether an accepted-then-failed close left the
# terminal alive is not yet decidable without a presence re-read proven
# against the real Orca binary (docs/verification/runtime-backends.md
# "Endpoint close").
fm_backend_orca_kill() {  # <terminal-id>
  fm_backend_orca_tool_check || return 1
  orca terminal close --terminal "$1" --json >/dev/null 2>&1 || true
}

# fm_backend_orca_home_worktree_ensure: the Orca worktree a secondmate home's
# terminal opens in. The home is Orca's main worktree of a project registered
# at the home itself (`orca repo add` is idempotent), so its id is Orca's own
# `<repo id>::<real path>` composite and Firstmate never asks Orca to create or
# remove a worktree for it. Orca records the real path (/tmp homes read
# /private/tmp on macOS), so the lookup uses the resolved path and refuses a
# result whose path is not exactly the home.
fm_backend_orca_home_worktree_ensure() {  # <home-dir> -> worktree id
  local home=$1 real out wt_id wt_path
  fm_backend_orca_tool_check || return 1
  real=$(cd "$home" 2>/dev/null && pwd -P) || {
    echo "error: secondmate home $home cannot be resolved for Orca" >&2
    return 1
  }
  out=$(orca worktree show --worktree "path:$real" --json 2>/dev/null) || out=
  if ! wt_id=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-id 2>/dev/null); then
    out=$(orca repo add --path "$real" --json) || {
      printf '%s' "$out" | fm_backend_orca_json_ok || true
      echo "error: orca repo add failed for secondmate home $real" >&2
      return 1
    }
    printf '%s' "$out" | fm_backend_orca_json_ok || return 1
    out=$(orca worktree show --worktree "path:$real" --json) || {
      echo "error: Orca has no worktree for secondmate home $real after registering it" >&2
      return 1
    }
    wt_id=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-id) || {
      echo "error: orca worktree show did not return a worktree id for $real" >&2
      return 1
    }
  fi
  wt_path=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-path 2>/dev/null) || wt_path=
  if [ "$wt_path" != "$real" ] || [ "${wt_id#*::}" != "$real" ]; then
    echo "error: Orca resolved secondmate home $real to worktree '$wt_id' at '${wt_path:-unknown}'; refusing to open the secondmate anywhere else" >&2
    return 1
  fi
  printf '%s' "$wt_id"
}

# fm_backend_orca_home_forget: drop the Orca project a retired secondmate home
# was registered as, after the home itself is gone. Only a project whose own
# root is exactly the recorded home path is forgotten, so a home that Orca
# shows as one worktree of a larger project never removes that project.
# `setup-delete --force` forgets saved workspace details and keeps files. The
# id comes from an already validated task record.
fm_backend_orca_home_forget() {  # <worktree-id>
  local wt_id=${1:-} repo_id path out repo_path
  case "$wt_id" in ?*::/*) ;; *) return 0 ;; esac
  repo_id=${wt_id%%::*}
  path=${wt_id#*::}
  fm_backend_orca_tool_check || return 1
  out=$(orca repo show --repo "id:$repo_id" --json 2>/dev/null) || return 0
  repo_path=$(printf '%s' "$out" | fm_backend_orca_json_get repo-path 2>/dev/null) || return 0
  [ "$repo_path" = "$path" ] || return 0
  fm_backend_orca_run_json orca project setup-delete --setup "$repo_id" --force --json >/dev/null
}

# fm_backend_orca_session_state: classify one Orca pty session from the process
# table. Orca reports each session's process (a `login` wrapper on macOS, whose
# child is the interactive shell); the shell's terminal foreground process
# group is what the user sees running. Any verified harness in that group is
# `alive`, a group of nothing but shells is `dead`, anything else is
# `ambiguous`, and a table or foreground read that fails is `unreadable`.
fm_backend_orca_session_state() {  # <session-pid> -> alive|dead|ambiguous|unreadable
  local session=$1 table shell_pid tpgid pid ppid pgid tp comm args argv0 seen=0 other=0 shell=0
  case "$session" in ''|*[!0-9]*) printf 'unreadable'; return 0 ;; esac
  table=$(LC_ALL=C ps -A -o pid=,ppid=,pgid=,tpgid=,comm= 2>/dev/null) || { printf 'unreadable'; return 0; }
  shell_pid=
  tpgid=
  while read -r pid ppid pgid tp comm; do
    [ "$pid" = "$session" ] || continue
    if [ "$(fm_agent_process_classify_name "$comm")" = shell ]; then
      shell_pid=$pid
      tpgid=$tp
    fi
    break
  done <<EOF
$table
EOF
  if [ -z "$shell_pid" ]; then
    while read -r pid ppid pgid tp comm; do
      [ "$ppid" = "$session" ] || continue
      shell_pid=$pid
      tpgid=$tp
      break
    done <<EOF
$table
EOF
  fi
  case "$tpgid" in ''|*[!0-9]*|0) printf 'unreadable'; return 0 ;; esac
  while read -r pid ppid pgid tp comm; do
    [ "$pgid" = "$tpgid" ] || continue
    seen=1
    args=$(LC_ALL=C ps -p "$pid" -o args= 2>/dev/null) || args=
    args=${args#"${args%%[![:space:]]*}"}
    argv0=${args%%[[:space:]]*}
    case "$(fm_agent_process_classify "$comm" "$argv0" "$args" "$pid")" in
      agent) printf 'alive'; return 0 ;;
      shell) shell=1 ;;
      *) other=1 ;;
    esac
  done <<EOF
$table
EOF
  if [ "$seen" -eq 0 ]; then
    printf 'unreadable'
  elif [ "$other" -eq 0 ] && [ "$shell" -eq 1 ]; then
    printf 'dead'
  else
    printf 'ambiguous'
  fi
}

# fm_backend_orca_session_pids: the process id Orca reports for each live pty
# session, from `orca diagnostics memory`. With a pty id, only that session;
# with `worktree:<id>`, every session in that worktree. Fails when the
# inventory cannot be read.
fm_backend_orca_session_pids() {  # <pty-id|worktree:<id>>
  local selector=$1 out
  out=$(orca diagnostics memory --json 2>/dev/null) || return 1
  printf '%s' "$out" | node -e '
const fs = require("fs");
const sel = process.argv[1];
let data;
try { data = JSON.parse(fs.readFileSync(0, "utf8")); } catch (err) { process.exit(2); }
if (data.ok === false || !data.result || !Array.isArray(data.result.worktrees)) process.exit(2);
for (const w of data.result.worktrees) {
  for (const s of (Array.isArray(w.sessions) ? w.sessions : [])) {
    const hit = sel.startsWith("worktree:") ? w.worktreeId === sel.slice(9) : s.sessionId === sel;
    if (hit && Number.isInteger(s.pid)) console.log(s.pid);
  }
}
' "$selector"
}

# fm_backend_orca_agent_state: recovery-grade agent state for one terminal (see
# bin/fm-backend.sh's fm_backend_agent_state for the vocabulary). `orca terminal
# show` names the terminal's pty; a closed or exited terminal reads
# `orphaned`, and a handle the running Orca no longer knows reads
# `terminal_handle_stale` - both are `missing`. The pty's process is then
# located in Orca's session inventory and classified by its foreground process
# group (fm_backend_orca_session_state). A connected pty with no inventory
# entry, or any read that fails, is `unreadable`, never death.
fm_backend_orca_agent_state() {  # <terminal-id>
  local terminal=$1 out shown pty pids pid
  fm_backend_orca_tool_check 2>/dev/null || { printf 'unreadable'; return 0; }
  out=$(orca terminal show --terminal "$terminal" --json 2>/dev/null) || true
  shown=$(printf '%s' "$out" | node -e '
const fs = require("fs");
let data;
try { data = JSON.parse(fs.readFileSync(0, "utf8")); } catch (err) { console.log("unreadable"); process.exit(0); }
if (data.ok === false) {
  const code = data.error && data.error.code;
  console.log(code === "terminal_handle_stale" || code === "terminal_not_found" ? "missing" : "unreadable");
  process.exit(0);
}
const t = (data.result || {}).terminal;
if (!t || typeof t !== "object") { console.log("unreadable"); process.exit(0); }
if (t.orphaned === true) { console.log("missing"); process.exit(0); }
if (typeof t.ptyId !== "string" || !t.ptyId || /[\t\n]/.test(t.ptyId)) { console.log("unreadable"); process.exit(0); }
console.log("pty\t" + t.ptyId);
') || shown=unreadable
  case "$shown" in
    missing|unreadable) printf '%s' "$shown"; return 0 ;;
    pty$'\t'?*) pty=${shown#pty$'\t'} ;;
    *) printf 'unreadable'; return 0 ;;
  esac
  pids=$(fm_backend_orca_session_pids "$pty") || { printf 'unreadable'; return 0; }
  pid=$(printf '%s\n' "$pids" | sed -n '1p')
  if [ -z "$pid" ] || [ "$(printf '%s\n' "$pids" | grep -c .)" -ne 1 ]; then
    printf 'unreadable'
    return 0
  fi
  fm_backend_orca_session_state "$pid"
}

# fm_backend_orca_worktree_agent_state: whether any live pty session in one Orca
# worktree runs a harness agent: `none` when every session is shell-only or
# there are none, `alive` when one holds an agent, and `ambiguous` or
# `unreadable` otherwise. A secondmate respawn checks its home this way before
# opening a new terminal, so an agent left running in a terminal whose handle
# went stale is never joined by a second one.
fm_backend_orca_worktree_agent_state() {  # <worktree-id>
  local wt_id=$1 pids pid state verdict=none
  fm_backend_orca_tool_check 2>/dev/null || { printf 'unreadable'; return 0; }
  pids=$(fm_backend_orca_session_pids "worktree:$wt_id") || { printf 'unreadable'; return 0; }
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    state=$(fm_backend_orca_session_state "$pid")
    case "$state" in
      alive) printf 'alive'; return 0 ;;
      dead) ;;
      *) verdict=$state ;;
    esac
  done <<EOF
$pids
EOF
  printf '%s' "$verdict"
}
