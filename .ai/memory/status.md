# Status

*Updated 2026-10-08*

Released: arcana 0.32.0 (`8105ad8`), arcana-core 0.16.0, arcana-ai 0.4.0.
All three are tagged with GitHub releases; arcana's packages build from the
tag (see [release.md](release.md)).

## Open

- **Open:** move arcana to arcana-ai `~> 0.4.0`. It still pins `~> 0.3.0`;
  0.4.0 gives the bus chat services retries by default.
- **Open:** `ChatAgent` (`src/arcana/chat_agent.cr`) falls back to
  `"gpt-4o-mini"` whatever provider it wraps. arcana-ai 0.4.0 fixed the
  same bug in `Chat::Request`; pass the model through (empty = the
  provider's own) when doing the bump above.
- **Open:** a project that gets `.ai/` after its first registration loses
  its owner token. The hook stored it under XDG state
  (`~/.local/state/arcana/tokens/<handle>`); once `.ai/` exists,
  `AgentConfig` looks only in `.ai/arcana.token`, makes a new one, and the
  next session start is refused as "held by another owner". Fix: adopt the
  XDG-state token when `.ai/` has none. Worked around by hand for this repo
  on 2026-10-08 (moved the token).
- **Open:** TTS defaults to `gpt-4o-mini-tts`, which OpenAI's model list
  shows as deprecated (reported by @mj, 2026-10-06). It still works; no
  replacement chosen.
- **Open (the user is deciding):** retiring the `runware` toolset and the
  `tts` tool on `openai` from `bin/arcana.cr`; see
  [services.md](services.md).

Next feature: shared-log topics, see [topics.md](topics.md).
