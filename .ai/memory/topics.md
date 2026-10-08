# Shared-log topics (up next)

*Updated 2026-10-08*

The design is `notes/events-and-topics-cleanup.md` (decision dated
2026-07-28, committed in `3054092`). The user confirmed the gist on
2026-10-07 and wants it done soon.

Gist: a `#topic` is a readable log. Publishing appends once; anyone reads
with `after: <seq>` without subscribing; subscribing only buys short
notifications. Late or offline agents catch up from the log. First cut:
registered `#topics` only, a 10,000-entry ring, real-time notifications
only.

**Settle before building:**

1. The notification payload uses `subject`, but proposal #4 in the same
   note renames `Envelope.subject` to `memo`.
2. Whether topics ship bundled with the event-log cleanup (proposals 1–6)
   or on their own; the scope's item 8 hedges on this.
3. The MCP side isn't scoped: there's no `arcana_subscribe` tool, and
   `arcana_register`'s `kind` doesn't accept `"topic"`.
