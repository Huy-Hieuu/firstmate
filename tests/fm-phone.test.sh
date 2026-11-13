#!/usr/bin/env bash
# tests/fm-phone.test.sh - behavior tests for bin/fm-phone.sh: an unconfigured
# home makes no connection, only the allowlisted chat is read, a keyed answer
# closes a plain captain call, and work items or merge and PROD calls are never
# approved from the phone.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-phone-tests)
PHONE="$ROOT/bin/fm-phone.sh"

# new_home <name>: a markdown-backlog home whose fake curl serves
# $home/updates.json to getUpdates and logs every call to $home/curl.log.
new_home() {
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config"
  fm_test_tasks_toml "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
cfg=''
while [ "$#" -gt 0 ]; do [ "$1" = -K ] && cfg=$2; shift; done
url=$(sed -n 's/^url = "\(.*\)"$/\1/p' "$cfg")
case "$url" in
  */getUpdates*) printf 'GET %s\n' "$url" >> "$FAKE_HOME/curl.log"; cat "$FAKE_HOME/updates.json" ;;
  */sendMessage) printf 'SEND %s\n' "$(jq -r .text)" >> "$FAKE_HOME/curl.log"; echo '{"ok":true}' ;;
esac
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$home"
}

run() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FAKE_HOME="$home" FM_HOME="$home" FM_PHONE_POLL_SECS=1 bash "$PHONE" "$@"
}

updates() {  # <home> <update json objects...>
  local home=$1
  shift
  printf '{"ok":true,"result":[%s]}\n' "$(IFS=,; printf '%s' "$*")" > "$home/updates.json"
}

msg() { printf '{"update_id":%s,"message":{"chat":{"id":%s},"text":"%s"}}' "$1" "$2" "$3"; }

hold() {  # <home> <id> <title> <reason> [<kind>]
  FM_HOME="$1" "$ROOT/bin/fm-tasks-axi.sh" add "$2" "$3" --kind "${5:-captain}" >/dev/null
  FM_HOME="$1" bash "$ROOT/bin/fm-captain-hold.sh" hold "$2" --reason "$4" >/dev/null
}

notes() { cat "$1"/state/inbox/*.note 2>/dev/null; }

test_unconfigured_is_inert() {
  local home out
  home=$(new_home inert)
  updates "$home" "$(msg 1 42 hello)"
  out=$(run "$home" poll 2>&1) || fail "an unconfigured poll failed"
  assert_contains "$out" "not configured" "an unconfigured poll did not say so"
  [ ! -e "$home/curl.log" ] || fail "an unconfigured poll made a connection"
  run "$home" push fyi "Hi" >/dev/null 2>&1 && fail "an unconfigured push reported success"
  pass "without config/phone nothing connects"
}

test_allowlist_notes_and_status() {
  local home log
  home=$(new_home notes)
  printf 'token_cmd=echo 123:abc\nchat_id=42\n' > "$home/config/phone"
  updates "$home" "$(msg 7 999 'stranger says hi')" "$(msg 8 42 'buy milk tomorrow')" "$(msg 9 42 status)"
  run "$home" poll || fail "poll failed"
  log=$(cat "$home/curl.log")
  assert_not_contains "$(notes "$home")" "stranger" "a message from another chat became a note"
  assert_contains "$(notes "$home")" "buy milk tomorrow" "an allowlisted message did not become a note"
  assert_contains "$log" "SEND Noted for firstmate." "the note was not acknowledged on the phone"
  assert_contains "$log" "firstmate status" "status did not reply with the status view"
  assert_equals 2 "$(grep -c '^SEND' "$home/curl.log")" "the stranger got a reply or a reply is missing"
  assert_equals 10 "$(cat "$home/state/phone/offset")" "the offset did not move past the last update"
  run "$home" poll || fail "second poll failed"
  assert_contains "$(grep GET "$home/curl.log" | tail -n 1)" "offset=10" "the next poll did not ask from the stored offset"
  assert_equals 1 "$(notes "$home" | grep -c 'buy milk tomorrow')" "a replayed update duplicated the note"
  pass "only the allowlisted chat is read, notes and status work, and replays stay single"
}

test_keyed_answers() {
  local home log
  home=$(new_home keyed)
  printf 'token_cmd=echo 123:abc\nchat_id=42\n' > "$home/config/phone"
  hold "$home" pick-color "Blue or green?" "Pick a color: blue or green"
  hold "$home" ship-x "Ship X" "approve the change" ship
  hold "$home" prod-call "Roll out the job" "Deploy to PROD now?"
  updates "$home" "$(msg 1 42 'pick-color: green')" "$(msg 2 42 'ship-x: yes')" "$(msg 3 42 'prod-call: yes')"
  run "$home" poll || fail "poll failed"
  log=$(cat "$home/curl.log")
  assert_contains "$(FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" show pick-color)" "state: done" "a plain keyed answer did not close its call"
  assert_contains "$(FM_HOME="$home" bash "$ROOT/bin/fm-decision-log.sh" list --item pick-color)" "green" "the answer was not in the decision log"
  assert_contains "$(FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" show ship-x)" "held: yes" "a work item was released from the phone"
  assert_contains "$(FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" show prod-call)" "held: yes" "a PROD call was answered from the phone"
  assert_contains "$log" "Recorded your answer on pick-color." "the closed call was not confirmed"
  assert_contains "$log" "Not applied: ship-x" "the work-item refusal was not explained"
  assert_contains "$log" "Not applied: prod-call" "the PROD refusal was not explained"
  assert_contains "$(notes "$home")" "NOT applied" "a refused answer was not kept for firstmate"
  pass "a keyed answer closes a plain call while work items and PROD stay with the attended session"
}

fm_test_run test_unconfigured_is_inert test_allowlist_notes_and_status test_keyed_answers
