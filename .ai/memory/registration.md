# Agent handles and registration

*Updated 2026-10-08*

Shipped in arcana 0.32.0 (`8105ad8`) and arcana-core 0.16.0.

- **One handle per project**, shared by whichever agent works there (the
  user, 2026-10-07: the user switches between Claude Code and Codex and
  doesn't run both at once).
- The key is `arcana.handle`, not `name`: a registration already has a
  separate display `name`, and "handle" is the established term for `@`
  addresses. `arcana.description` becomes the listing's description.
- **Owner token** (`.ai/arcana.token`, listed in `.git/info/exclude`; under
  `$XDG_STATE_HOME/arcana/tokens/` for a project without `.ai/`) decides
  who may re-register, mark presence, or unregister a handle.
  Re-registering with it answers `status: "yours"`; another token gets 409
  with the holder's listing.
- The owner token deliberately does **not** protect mail: gating reads
  would break agents and tools that don't pass it. **Decided (the user,
  2026-10-08):** leave mailboxes readable for now; real separation comes
  with authenticated identities (SaaS auth stage 3).
- `arcana hook` (session-start, stop, session-end) serves both Claude Code
  and Codex. Session end moves unread mail into `.ai/inbox/` and marks the
  handle offline instead of unregistering it, so mail sent between sessions
  waits for the next agent. `/clear` is left alone.
- Known gap: see the owner-token item in [status.md](status.md).
