# Arcana Protocol

How messages actually move on the bus, and honest notes on what the
current design does and doesn't guarantee.

## Three layers

```
┌─────────────────────────────────────────┐
│ Protocol (payload convention)           │  request/result/error/need
│   { _proto, _status, data, ... }        │  + {tool: "..."} dispatch
├─────────────────────────────────────────┤
│ Envelope (message shape)                │  from/to/payload/correlation_id
│   Bus routes by `to`, correlates        │  + reply_to, ordering, subject
│   replies by `correlation_id`           │
├─────────────────────────────────────────┤
│ Transport (bytes on the wire)           │  HTTP REST, WebSocket, MCP stdio
└─────────────────────────────────────────┘
```

Each layer is independent. The envelope shape is identical over every
transport. The protocol wrapper is optional — a bare payload works too.

## Envelope

The message data structure:

```json
{
  "from":           "cattacula",
  "to":             "mj",
  "subject":        "generate a shard for the intro",
  "payload":        { /* application data */ },
  "correlation_id": "691d8e16faeeebfe",
  "reply_to":       null,
  "ordering":       "auto",
  "timestamp":      "2026-07-12T21:00:00Z"
}
```

- **`to`** is the routing key. Bus looks up the target's mailbox.
- **`correlation_id`** ties a reply to its request. Sender picks it,
  recipient echoes it back unchanged.
- **`reply_to`**, when set, overrides `from` for reply routing.
  `Arcana::Bus` uses this to create ephemeral `_reply:<id>` mailboxes
  for sync-blocking requests (see below).
- **`ordering`** is `auto | sync | async`. `auto` (default) resolves
  via the target's Directory kind — services get sync (block for
  reply), agents get async (fire and forget). Callers can force
  either explicitly.

## Protocol (payload convention)

Inside `payload`, an optional wrapper gives you request/response
semantics with typed statuses. Sender wraps with `Arcana::Protocol.request(...)`:

```json
{
  "_proto":  "arcana/1",
  "_status": "request",
  "data":    { "tool": "pixelize", "prompt": "..." }
}
```

Recipient replies with one of:

```json
{"_proto":"arcana/1", "_status":"result", "data": {...}}
{"_proto":"arcana/1", "_status":"error",  "_message":"...", "_code":"..."}
{"_proto":"arcana/1", "_status":"need",   "schema":{...},   "_message":"..."}
```

Handlers can send raw payloads (no wrapper); services handle both
shapes. `Arcana::Service#handle` unwraps `data` for you when the
inbound payload is protocol-wrapped.

## Tool dispatch

For services (single-purpose or multi-tool via `Toolset`), the
convention is:

```json
{ "tool": "pixelize", "prompt": "..." }
```

`Arcana::Service` treats `{"tool":"help"}` as a discovery request —
replies with its guide + inputSchema. `Arcana::Toolset` extends this
with an auto-registered `help` tool that returns a full tools
manifest, and dispatches every other tool name to its registered
handler.

## Transports

Three ways to reach the bus. All carry the same envelope shape
underneath.

### HTTP REST

Every operation is a POST with a JSON body:

- `POST /deliver`   — unified send (sync/async by ordering)
- `POST /send`      — plain fire-and-forget
- `POST /request`   — sync send with timeout
- `POST /receive`   — pull messages from your mailbox
- `POST /inbox`     — peek without consuming
- `POST /register`  — create a mailbox + listing
- `POST /publish`   — pub/sub broadcast
- `POST /busy`      — mark yourself busy/idle
- `GET  /directory` — list all listings (filter by `q`, `tag`, `kind`, `capability`)
- `GET  /health`    — liveness check

Body shape for `/deliver`:

```json
{
  "from":       "cattacula",
  "to":         "mj",
  "subject":    "...",
  "payload":    { /* any JSON */ },
  "ordering":   "auto",
  "timeout_ms": 30000
}
```

Response for a sync-resolved delivery is the reply envelope. For
async, `{"ok":true, "ordering":"async", "correlation_id":"..."}`.

Auth: with `ARCANA_AUTH_REQUIRED=1`, every request (except `/health`)
needs `Authorization: Bearer ak_...`. Anonymous localhost is the
default.

### WebSocket

Persistent bidirectional connection to `/bus`. `Arcana::Client` uses
this. Frames are JSON.

**Join frame** (first frame after connect):

```json
{
  "type":        "join",
  "address":     "mj",
  "name":        "Minanime",
  "description": "Image generation studio",
  "kind":        "service",
  "capability":  "image",
  "guide":       "...",
  "schema":      {...},
  "tags":        ["image", "generation"],
  "listed":      true
}
```

Server registers the listing on join. Everything after `type` is
optional.

**Send frame:**

```json
{
  "type":     "send",
  "envelope": { /* full envelope shape from above */ }
}
```

**Publish frame:**

```json
{
  "type":     "publish",
  "topic":    "logs",
  "envelope": {...}
}
```

**Subscribe/unsubscribe frames:**

```json
{"type": "subscribe",   "topic": "logs"}
{"type": "unsubscribe", "topic": "logs"}
```

The server pushes envelopes back to the client whenever a message
arrives at the client's address. No polling.

### MCP (JSON-RPC 2.0 over stdio)

Used by Claude Code (or any MCP client) via the `arcana-mcp` bridge
process. The bridge translates tool calls into REST calls to the
daemon. Tools: `arcana_directory`, `arcana_deliver`, `arcana_publish`,
`arcana_register`, `arcana_inbox`, `arcana_receive`, `arcana_expect`,
`arcana_freeze`, `arcana_health`, `arcana_events`.

## Full round-trip: MCP `arcana_deliver` to a remote Toolset

Concrete flow when Claude Code calls
`arcana_deliver to:"mj" payload:{"tool":"pixelize","prompt":"a shard"}`:

```
Claude Code
  │  JSON-RPC 2.0 over stdio (tools/call)
  ▼
arcana-mcp process
  │  HTTP POST /deliver
  │  body: {from:"mcp-bridge", to:"mj", payload:{...}, ordering:"auto"}
  ▼
arcana daemon
  │  parse → Envelope
  │  create ephemeral _reply:<corr_id> mailbox
  │  set envelope.reply_to = _reply:<corr_id>
  │  Bus.deliver(env, timeout: 30s)
  │    Directory says mj.kind=service → resolve ordering=sync
  │    deliver to mj's mailbox
  │
  │  WebSocket handler for mj is watching that mailbox
  │  ships the envelope as a JSON frame down the WebSocket
  ▼
mj process (Arcana::Client)
  │  on_message fires
  │  Toolset.dispatch: read data.str("tool") == "pixelize"
  │  handler runs (returns JSON::Any)
  │  wrap as Protocol.result
  │  client.send(reply_envelope)   -- correlation_id preserved
  ▼
arcana daemon
  │  WebSocket handler receives send frame
  │  routes reply to _reply:<corr_id>
  │  Bus.deliver (still blocked from earlier) unblocks with the reply
  ▼
arcana daemon HTTP handler
  │  writes reply envelope as JSON in HTTP response body
  ▼
arcana-mcp
  │  wraps as JSON-RPC response
  ▼
Claude Code
```

Ephemeral `_reply:<id>` mailboxes are how sync-blocking works — the
Bus creates a temporary mailbox keyed by correlation_id, sets
`reply_to`, blocks reading, cleans up after reply or timeout.

## Robustness

Honest assessment.

### What is guarded

- **Poison-pill payload survival.** `Service#handle` and
  `Toolset#dispatch` both have outer rescues. A bad payload replies
  with `Protocol.error` and the consumer fiber keeps going. One bad
  message doesn't hang the queue.
- **Sender-not-registered check.** `/send`, `/deliver`, and
  `/publish` reject messages from unregistered `from` addresses. No
  spoofing of local senders.
- **Bearer-token auth.** Optional (`ARCANA_AUTH_REQUIRED=1`), gates
  all REST + WebSocket. Keys stored as SHA-256 with public prefix.
  Constant-time comparison on verification.
- **Mailbox tokens.** Optional shared secret per address; protects
  another agent from reading your mailbox.
- **Snapshot persistence.** Directory + mailboxes + tokens saved on
  graceful shutdown, restored on startup. Survives clean restarts.
- **Auto-unwrap stringified JSON payloads.** MCP clients that
  double-encode payloads still land the fields where services expect
  them (envelope_from_json normalizes at the boundary).
- **`did_you_mean` on delivery failure.** Suggests closest registered
  address when delivery targets a typo.
- **Idle-agent grace period.** 7-day default TTL on listings, 30-day
  on mailboxes. Env-overridable.

### What is not guarded

- **Message durability across crashes.** Snapshots only fire on
  graceful shutdown. A crash (SIGKILL, OOM, panic) loses all
  in-flight and queued messages since the last snapshot. There is no
  write-through per-message durability — the hooks exist
  (`on_deliver`, `on_consume`) but they're no-ops.
- **Handler-crash message loss.** When a Service/Toolset handler
  crashes on a message, the fiber survives (poison-pill guard) but
  the message that caused it is gone — recipient replies error, no
  retry, no dead-letter queue.
- **WebSocket at-most-once.** No app-level ACK. If a WebSocket frame
  is lost during transport (unlikely on localhost, plausible over
  WAN), the recipient never processed it and no one knows.
- **Sync-request timeout on remote handler death.** If a Toolset
  handler over WebSocket crashes without replying, the sync caller
  blocks until the 30s timeout, then gets a nil reply. Not "no such
  address" — you can't distinguish "recipient is slow" from
  "recipient died mid-handler."
- **No backpressure.** Mailbox is an unbounded `Deque`. A runaway or
  malicious sender can queue unlimited messages, exhausting memory.
- **No rate limiting.** Any authenticated caller can hammer the bus
  at line rate.
- **Sync reply lookup uses a mutex-guarded Hash.** Fine at low
  concurrency. At thousands of concurrent sync requests, contention
  on `@pending_replies` will show up.
- **Prune scan is O(N) with mutex held.** Every hour the prune fiber
  walks every listing under the Directory's mutex. Fine at hundreds,
  starts to bite at tens of thousands.
- **Auto-ordering falls back to async for unknown addresses.** A
  sender doing `ordering: auto` to an address that isn't in the
  Directory gets fire-and-forget semantics — silently if the mailbox
  exists. Set `ordering: sync` explicitly if you care.
- **No cross-participant transactions.** Multi-step flows are
  application-level; a crash mid-flow leaves partial state.
- **Snapshot restore is best-effort.** Observed at least one case
  where a mailbox message present in the event log wasn't present
  after restart (unclear root cause). Snapshot-consistency spec
  coverage is thin.

### What's between the two (opt-in but not automatic)

- **Event log.** Every material action (register, send, publish,
  subscribe, freeze, auth failure) writes an event to disk (`~/.arcana/events/`
  by default). Not per-message payload durability, but a solid audit
  trail for debugging and reconstruction.
- **Expected-response tracking.** `arcana_expect action:"await"`
  blocks until all outstanding correlation_ids reply — useful for
  multi-agent coordination but you have to opt in per flow.

## Efficiency

Honest assessment of the current implementation's costs.

### Cheap

- **In-process routing.** Bus.deliver → mailbox.push is a hash
  lookup + deque append + channel signal. Sub-microsecond at Crystal
  speeds.
- **JSON payload parsing.** stdlib JSON is reasonably fast at the
  message sizes we typically move.
- **WebSocket framing.** Persistent connection, no per-message
  handshake.

### Wasteful but currently fine

- **Envelope verbosity.** Every frame carries `from`, `to`, `subject`,
  `correlation_id`, `reply_to`, `ordering`, `timestamp` even when
  most are empty. ~100 bytes of metadata per message. Fine at typical
  message sizes; wouldn't be for a chatty high-volume channel.
- **Serialize-then-parse across MCP.** MCP client → arcana-mcp:
  JSON-RPC parse. arcana-mcp → daemon: JSON serialize + parse. Three
  round-trips through JSON for one call. Fine at MCP tool-call
  latency budgets (~ms), wasteful for hot loops.
- **Ephemeral `_reply:<id>` mailboxes.** Create + register + block-read
  + cleanup per sync delivery. Fine at 10s of concurrent syncs; the
  Directory-lookup and mailbox-create paths are hash-ops.
- **Full-file snapshot writes.** Every save serializes the entire
  Directory + all mailboxes + tokens into one file, then
  atomic-rename. At small state, negligible. At thousands of
  listings with queued messages, it's a full re-write on every save.
- **openai:tts inline mode temp-file round-trip.** Writes to disk
  then reads back. `<1MB` payloads, negligible. See TODO for
  synthesize_bytes promotion.
- **Stringified-payload auto-unwrap.** Every envelope's payload is
  scanned for looks-like-JSON string, potentially parsed twice. Cheap
  but redundant when clients send correctly-typed objects.

### Would bite at scale

- **Reply-lookup mutex.** `@pending_replies` is a Hash guarded by one
  Mutex. Contention on high concurrent sync-request loads.
- **Directory mutex.** Every register, unregister, touch, lookup
  contends on the same Mutex. Fine at tens; becomes a bottleneck at
  thousands of concurrent operations.
- **Prune walk.** O(N) over all listings, holding the Directory
  mutex. At tens of thousands, this is a noticeable stall every hour.
- **Event-log fsync.** Every event writes to disk. If the event log
  is enabled and you're processing thousands of messages per second,
  disk IO becomes the bottleneck.
- **No connection pooling** in arcana-mcp's HTTP client to the
  daemon. New TCP handshake per REST call from the bridge.

None of these are urgent today. See
[project_scale_concerns.md](../../../../.claude/projects/-home-trans-Projects-arcana/memory/project_scale_concerns.md)
for the tracked list.

## Summary in one paragraph

Arcana runs a JSON envelope on any of three transports (HTTP, WebSocket,
MCP stdio), routes by an opaque address, and correlates replies by an
id. Sync semantics are built from ephemeral reply mailboxes. Discovery
is a two-step: `arcana_directory` for who's on the bus, `{"tool":"help"}`
to any participant for what it does. The design is well-guarded against
individual bad actors (poison pills, malformed payloads) but weak on
message durability (crashes lose in-flight work) and unbounded resource
consumption (no backpressure, no rate limiting). Fine for its current
scale (dozens of agents, sub-100 messages/second); would need work to
push into thousands.
