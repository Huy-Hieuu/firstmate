# Captain profile

This directory carries the captain's distilled, project-agnostic knowledge so a new firstmate home starts with it.
It is a seed, not live state: each home keeps its own copies under the gitignored `data/` and `config/`.
This repository is public, so nothing here holds secrets, hostnames, addresses, keys or colleague details.

## Contents

- `captain-shared.md` seeds `data/captain-shared.md`: preferences that apply in every home and every project.
- `captain.md` seeds `data/captain.md`: home-local defaults (worker runtime, delivery, backpass, agents).
- `learnings.md` seeds `data/learnings.md`: operating lessons for firstmate on the captain's MacBook.
- `config/` seeds `config/`: worker runtime pins, runtime backend, dispatch model bands and the startup memory budget.

## Seeding a new home

Copy only files the home does not have yet, so an existing home's records are never overwritten:

```sh
mkdir -p data config
for f in captain.md captain-shared.md learnings.md; do
  [ -e "data/$f" ] || cp "captain-profile/$f" "data/$f"
done
for f in captain-profile/config/*; do
  [ -e "config/$(basename "$f")" ] || cp "$f" "config/"
done
```

Then run `bin/fm-session-start.sh`.

## Updating this profile

When a durable, project-agnostic preference or lesson changes in a home, update the matching file here in the same words and push.
Project-specific knowledge stays in that project's own records, not here.
