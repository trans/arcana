# Who supplies services

*Updated 2026-10-08*

- **Direction (the user, 2026-10-06):** arcana supplies the bus; project
  owners write their own services and register them. The daemon shouldn't
  keep growing provider integrations, which age at the speed of whoever
  last cared about them (arcana-ai's Runware identity requests were
  silently ignored by Runware for months).
- `mj:camera` and `mj:voice` supersede the daemon's `runware` toolset and
  the `tts` tool on `openai`. `openai`'s `chat` and `embed` have no
  replacement and stay. **Open (the user is deciding):** whether and when
  to retire those two from `bin/arcana.cr`.
- **Proposed, not decided (2026-10-07):** move the provider toolsets out of
  the daemon into an optional process that registers like any other
  owner's service; admit a media integration into arcana-ai only once two
  projects use it (chat and embeddings stay: they reduce to a few wire
  formats); keep making `Toolset` services trivial to write.
- **Decided (the user, 2026-10-08):** Runware retries and the cap on
  concurrent requests belong in mj's own client, since Infocomic moves its
  images to `mj:camera` before launch. arcana-ai's `Image::Runware` is left
  as is.
- TTS pricing knowledge stays in mj until a second project needs it
  (agreed with @mj, 2026-10-06).
- **Later idea (the user, 2026-10-07):** when there are too many listings
  for agents to scan, Arcana becomes an operator/librarian that answers
  "who can do X?".
