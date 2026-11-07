# Captain preferences
<!-- memory tiers: see the stow skill -->

Home-local defaults for a new firstmate home.
Cross-home preferences live in `data/captain-shared.md` (seeded from `captain-profile/captain-shared.md`).
Add project- and domain-specific preferences here as they appear.

## Worker runtime

- Crewmates always run `omp` (`config/crew-harness`).
- A task that needs one of a project's `.claude/commands` still runs on omp, and its brief tells the worker to read and follow that command file.
- Secondmates run `omp claude-opus-5-5 medium` (`config/secondmate-harness`); their workers get per-task effort.
- When `config/backend` is `orca`, secondmates cannot be hosted in Orca: spawn them with `--backend tmux`.
- Main and secondmates run `claude-opus-5-5`; `retry.fallbackChains` stays empty in `~/.omp/agent/config.yml`.
- omp compacts at 250k context for every session (`compaction.thresholdTokens: 250000`).

## Delivery

- No no-mistakes pipeline anywhere in the fleet: register remote-backed projects as `direct-PR` unless he asks otherwise.
- Every ship brief carries the ADR rule from `data/captain-shared.md`.

## Self-improvement (backpass)

- Backpass may run daily: one worker per repo with commits in the last day shows proposed `AGENTS.md` and skill edits on a Lavish board.
- Only the edits he accepts ship, as a direct PR.
- A repo with an open backpass worker is skipped.

## AI agents

- For AI agents, prefer explicit workflow, strong evaluation and tight feedback loops.
- The goal is better agents through the full improvement loop on real agents: problem, fix, diff review, apply, re-run, compare.
- No artificial caps on test-set size or spend in an eval loop; keep only runaway-loop guards.
