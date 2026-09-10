# Orca compound worktree-id teardown - before/after CLI transcript

Same scenario at three commits: a task recorded with the Orca-issued compound id
`<repo-uuid>::/.../My Repo (fork)/ship wt` (spaces + parentheses), torn down via bin/fm-teardown.sh against a fake orca CLI.

```
=== 34bd418 : recorded metadata line ===
orca_worktree_id=74c6a297-f6ab-433d-b0ca-6136c9b1dbea::/tmp/orca-evi/run/34bd418/My Repo (fork)/ship wt
=== fm-teardown.sh orcacompoundz7 ===
REFUSED: Orca endpoint metadata for task orcacompoundz7 is malformed or inconsistent; preserving task state.
exit=1
=== orca CLI calls ===
=== worktree dir still present? ===
YES - /tmp/orca-evi/run/34bd418/My Repo (fork)/ship wt
=== task metadata still present? ===
YES (task state preserved)

=== 19ba3f4 : recorded metadata line ===
orca_worktree_id=74c6a297-f6ab-433d-b0ca-6136c9b1dbea::/tmp/orca-evi/run/19ba3f4/My Repo (fork)/ship wt
=== fm-teardown.sh orcacompoundz7 ===
REFUSED: Orca endpoint metadata for task orcacompoundz7 is malformed or inconsistent; preserving task state.
exit=1
=== orca CLI calls ===
=== worktree dir still present? ===
YES - /tmp/orca-evi/run/19ba3f4/My Repo (fork)/ship wt
=== task metadata still present? ===
YES (task state preserved)

=== HEAD : recorded metadata line ===
orca_worktree_id=74c6a297-f6ab-433d-b0ca-6136c9b1dbea::/tmp/orca-evi/run/HEAD/My Repo (fork)/ship wt
=== fm-teardown.sh orcacompoundz7 ===
teardown orcacompoundz7 complete (window term-compound, worktree /tmp/orca-evi/run/HEAD/My Repo (fork)/ship wt)
Backlog: orcacompoundz7 just finished (this home keeps no markdown backlog at /private/tmp/orca-evi/run/HEAD/data/backlog.md). Update /private/tmp/orca-evi/run/HEAD/data/backlog.md - move orcacompoundz7 to Done, keep Done to the 10 most recent, then re-scan Queued and dispatch only work whose blockers are gone and date is due.
exit=0
=== orca CLI calls ===
orca [worktree] [show] [--worktree] [id:74c6a297-f6ab-433d-b0ca-6136c9b1dbea::/tmp/orca-evi/run/HEAD/My Repo (fork)/ship wt] [--json]
orca [terminal] [close] [--terminal] [term-compound] [--json]
orca [worktree] [rm] [--worktree] [id:74c6a297-f6ab-433d-b0ca-6136c9b1dbea::/tmp/orca-evi/run/HEAD/My Repo (fork)/ship wt] [--force] [--json]
=== worktree dir still present? ===
YES - /tmp/orca-evi/run/HEAD/My Repo (fork)/ship wt
=== task metadata still present? ===
no (torn down)

```
