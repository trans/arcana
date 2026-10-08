# Project memory

Notes that AI agents working on this project keep for each other:
decisions, plans and lessons that are not obvious from the code or the git
history. Read these before starting work; update them when something here
changes. `../config.yml` names this project's agent on the Arcana bus.

| File | What it holds |
|---|---|
| [status.md](status.md) | Released versions and the open items: arcana-ai 0.4.0 bump, ChatAgent model fallback, owner-token migration, TTS default |
| [coordination.md](coordination.md) | This project's handle (`@arcana`), arcana-ai's consumers, and the peers on the bus |
| [services.md](services.md) | Who supplies services: owners, not the daemon; what's decided and what's still open |
| [registration.md](registration.md) | Handles, owner tokens, presence and the session hooks (0.32.0) |
| [release.md](release.md) | How releases are cut, in which order, and the packaging-from-the-tag gotcha |
| [topics.md](topics.md) | Shared-log topics, up next, and the three questions to settle first |
| [roadmap.md](roadmap.md) | Later work: SaaS auth stage 3, durability, audio transport, mailbox privacy |

Keep each note short and dated (`*Updated YYYY-MM-DD*`), with absolute
dates and commit hashes. Check the code or `git log` before acting on
anything here; notes go stale. Machine-specific facts don't belong here.

## Handling inbox notes

Other agents leave notes in `.ai/inbox/`. A note in the inbox has not been
dealt with yet, so the inbox holds only unprocessed notes. To process one:

1. Commit the note as it arrived, before anything else, so the original is
   kept in history.
2. Put what matters into the memory notes here, in your own words.
3. Delete the note in a following commit, and cite the commit that still
   has it (`git show <commit>:.ai/inbox/<file>`).

If a note is reference material that will be consulted again, such as a
spec or a design, move it here as its own file instead of summarizing it.
If the repo is public, a note with private details is summarized without
committing the original.

## Intake

The user shares files for the work at hand in `.ai/intake/`. Look there
when starting a session. The files are the user's: don't commit, move or
delete them unless asked.

## Arcana

Outbound Arcana messages need the user's go-ahead, message by message:
draft and offer, then wait. Reading and receiving mail is fine.
