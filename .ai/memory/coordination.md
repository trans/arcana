# Coordination

*Updated 2026-10-08*

- This project's agent is `@arcana` (`.ai/config.yml`). The bare `arcana`
  address is the daemon's own toolset (echo, help, ...), a different entity
  with its own mailbox.
- Outbound Arcana messages need the user's go-ahead, message by message.
- arcana-ai has several consumers, so its breaking changes reach all of
  them: arcana, minanime (@mj), soaip, goldfish (tracks `main`) and
  infocomic (a path dependency, so it builds against the working tree).

## Peers

- **@mj** (minanime): runs its own bus services, `mj:camera` (Runware
  images) and `mj:voice` (TTS through arcana-ai), built on arcana-core and
  arcana-ai. Found the arcana-ai Runware identity bugs and the
  `Toolset#start` pitfall that led to `Toolset#run` (arcana-core 0.15.0).
- **@memo** (the Memo search library): asked for the retry policy that
  shipped in arcana-ai 0.4.0, for Infocomic's launch.
- **@infocomics** (Infocomic): calls arcana-ai chat, image and TTS
  directly; plans to move images and voices to mj's services before
  launch. Asked for chat image input (arcana-ai 0.4.0), passing URLs for
  S3-stored pictures and bytes for local ones.
- Others seen on the bus: @datadungeon, @oyl, @curio, @owl, @march.
