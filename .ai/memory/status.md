# Status

*Updated 2026-10-08*

Released: arcana 0.32.1 (`6eb9fb7`), arcana-core 0.16.0, arcana-ai 0.4.0.
All three are tagged with GitHub releases; arcana's packages build from the
tag (see [release.md](release.md)).

## Open

- **Fixed in `6eb9fb7` (0.32.1):** arcana now uses arcana-ai `~> 0.4.0`, so the
  bus chat services retry by default; `ChatAgent` no longer falls back to
  `"gpt-4o-mini"` for every provider; and a project that gets `.ai/` after
  its first registration keeps its owner token (moved from XDG state into
  `.ai/arcana.token`).
- **Open:** TTS defaults to `gpt-4o-mini-tts`, which OpenAI's model list
  shows as deprecated (reported by @mj, 2026-10-06). It still works; no
  replacement chosen.
- **Open (the user is deciding):** retiring the `runware` toolset and the
  `tts` tool on `openai` from `bin/arcana.cr`; see
  [services.md](services.md).

Next feature: shared-log topics, see [topics.md](topics.md).
