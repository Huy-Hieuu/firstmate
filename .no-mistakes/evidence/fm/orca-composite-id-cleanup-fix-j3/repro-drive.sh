#!/usr/bin/env bash
# Manual E2E: an Orca-issued compound worktree id (repo atom :: absolute path
# with spaces and parentheses) recorded verbatim in task metadata, then torn
# down through bin/fm-teardown.sh against a fake `orca` CLI.
set -u
export FM_GATE_REFUSE_BYPASS=1
SRC=$1 CASE=$2
BASE=/tmp/orca-evi/run/$CASE
rm -rf "$BASE"; mkdir -p "$BASE"
id=orcacompoundz7
proj="$BASE/project"
wt="$BASE/My Repo (fork)/ship wt"
state="$BASE/state"; data="$BASE/data"; config="$BASE/config"
mkdir -p "$data/$id" "$state" "$config" "$BASE/My Repo (fork)"
worktree_id="74c6a297-f6ab-433d-b0ca-6136c9b1dbea::$wt"

git init -q "$proj"; git -C "$proj" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$proj" remote add origin "$proj.origin.git"
git -C "$proj" worktree add --quiet -b "fm/$id" "$wt"
touch "$state/.last-watcher-beat"
cat > "$state/$id.meta" <<EOF
window=fm-$id
endpoint_task_id=$id
terminal=term-compound
worktree=$wt
project=$proj
harness=claude
kind=ship
mode=local-only
yolo=off
backend=orca
orca_worktree_id=$worktree_id
EOF

fb="$BASE/fakebin"; mkdir -p "$fb"
export FM_ORCA_LOG="$BASE/orca.log"; : > "$FM_ORCA_LOG"
cat > "$fb/orca" <<'SH'
#!/usr/bin/env bash
set -u
export FM_GATE_REFUSE_BYPASS=1
{ printf 'orca'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'; } >> "$FM_ORCA_LOG"
if [ "${1:-}" = status ]; then echo '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}'; exit 0; fi
if [ "${2:-}" = show ]; then printf '{"ok":true,"result":{"worktree":{"id":"%s","path":"%s"}}}\n' "$FM_WT_ID" "$FM_WT_PATH"; exit 0; fi
echo '{"ok":true}'
SH
chmod +x "$fb/orca"
export FM_WT_ID="$worktree_id" FM_WT_PATH="$wt"
mkdir -p "$BASE/neutral/bin"; printf '#!/usr/bin/env bash\nexit 0\n' > "$BASE/neutral/bin/fm-guard.sh"; chmod +x "$BASE/neutral/bin/fm-guard.sh"

echo "=== $CASE : recorded metadata line ==="
grep orca_worktree_id "$state/$id.meta"
echo "=== fm-teardown.sh $id ==="
PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$BASE/neutral" FM_STATE_OVERRIDE="$state" \
  FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
  "$SRC/bin/fm-teardown.sh" "$id" 2>&1
echo "exit=$?"
echo "=== orca CLI calls ==="; cat "$FM_ORCA_LOG"
echo "=== worktree dir still present? ==="; [ -d "$wt" ] && echo "YES - $wt" || echo "no (removed)"
echo "=== task metadata still present? ==="; [ -f "$state/$id.meta" ] && echo "YES (task state preserved)" || echo "no (torn down)"
