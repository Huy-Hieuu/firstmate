# Fleet learnings
<!-- memory tiers: see the stow skill -->

Project-agnostic operating lessons from running firstmate on the captain's MacBook (omp main in an Orca pane, secondmates on tmux).

## Orca

- Spawn with the real filesystem path of a project, never a symlink path: a symlink makes Orca mint a second repo identity and spawn takes about 128 s instead of about 26 s.
- Orca worktrees are linked worktrees: index and HEAD are isolated, but objects and refs are shared with the captain's repo.
- No worker may run `git gc`, `git worktree prune/remove`, `git reflog expire`, or force-update a branch it did not create.
- Main omp in an Orca pane cannot run `fm-afk-launch.sh start`, `fm-control relaunch` or `fm-spawn --relaunch`; they refuse there.
- A task whose Orca worktree id no longer resolves fails teardown even with `--force`: close its item, `orca terminal close`, and move `state/<id>.*` to `state/manual-retired/`.
- Secondmates run on tmux while `config/backend` is `orca`.
- A dead secondmate respawns only with `bin/fm-spawn.sh <id> --secondmate --backend tmux`, also when stuck on "omp session is shutting down".
- A main-spawned `task` subagent also receives watcher wakes: tell it to ignore them; only main drains and acknowledges.

## Supervision under load

- When the Mac is heavily loaded, `fm-send.sh` and wake drains can take 1-3 minutes: run them with a long timeout (400 s or more).
- A "TURN WOULD END BLIND" notice can be a false alarm under heavy load.
- Check it in one call: `ls -la state/.last-watcher-beat` (mtime current) and `pgrep -fl 'firstmate/bin/fm-watch'` (arm child and watcher present for this home).
- If both look live, do not re-arm, kill or restart anything.
- On omp, arm the watcher only on the first cycle or when a notification says it is missing or unhealthy.
- The MacBook sleeps for hours: long tool calls then time out; retry later.
- After an omp crash (for example an uncaught EPIPE), run session start again and arm the watcher once.
- "Permission request cancelled" means the captain must allow commands; ask him.
- Repeated `reasoning_extraction` refusals in a long session mean compact or restart the session.

## Lavish boards

- One listener per board (`bin/fm-procevent.sh retire <source-id>`).
- A board listener owned by a worker is lost when that worker closes: the captain's comment lands in the home's `state/procevent-inbox` and no wake reaches anyone.
- When a board worker closes, move the listener to the mate (`task:mate`), or have the mate drain its inbox.
- Before telling the captain a board "waits for your pick", read that session's chat in `~/.lavish-axi/state.json` (`sessions.<id>.chat[].text`).
- When he says a board shows "agent is not listening", arm it for main with `bin/fm-procevent-lavish.sh arm <abs board.html>`, then ask him to submit again.
- Answer a question on a board with `(cd <board dir> && lavish-axi reply board.html --agent-reply "<Vietnamese>")`, then `bin/fm-procevent.sh handled`.
- After a lavish-axi upgrade, old listeners loop on empty results: retire them and move dead workers' inbox messages to `handled/`.

## Merging

- `fm-pr-merge.sh` refuses "named head unreachable" when the worker pushed without a tracking ref: `git -C <worktree> fetch -q origin "+refs/heads/<b>:refs/remotes/origin/<b>"` first.
- It waives only one `--allow-red` name; with the captain's word to waive more, use `gh pr merge --admin --match-head-commit <sha>` after checking the gating checks.
- Where a branch rule only demands an approving review, merge with `bin/fm-pr-merge.sh <id> <url> --attended-override -- --admin`.

## Updates

- The captain's local `main` may carry local commits that are not upstream, so `bin/fm-update.sh` prints "skipped: diverged".
- Update by rebasing with git only, rely on CI or a smoke run (no local test suites), then restart the secondmates.
- "omp update" means the omp CLI (`omp update`, Homebrew); use `PATH=/opt/homebrew/bin` in bash.

## Browsers

- The captain's own Chrome (remote debugging on) is for main only: his mail, router and pages.
- Every new connection to it makes him click Allow: never stop it, and touch only the tabs he names.
- All product UI tests use a dedicated test Chrome profile instead: `open -na "Google Chrome" --args --user-data-dir="$HOME/.chrome-fm-test" --remote-debugging-port=9333 --no-first-run`.
- Connect to it with `CHROME_DEVTOOLS_AXI_BROWSER_URL=http://127.0.0.1:9333` and a per-worker session name.
- It can quit overnight: check `curl 127.0.0.1:9333/json/version` and relaunch with the same command; never clear its data and never run two copies.

## Break-glass main

- Two tmux windows can run Claude Code with `--remote-control` under two different Claude accounts as a backup main reachable from claude.ai/code.
- While omp main holds the lock, the backup is read-only; if omp main dies, the captain tells the backup to take over with `bin/fm-session-start.sh`.
- After a tmux restart the backup can sit on Claude's Chrome-extension and fullscreen-renderer prompts: press Esc, then "2" and Enter.
