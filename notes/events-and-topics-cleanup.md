# Design notes: events + topics cleanup

Design brief for a future bundled cleanup of the event log format,
event-type taxonomy, and the topic namespace. Nothing here is shipped.
Recording it so we can pick it up cleanly when we're ready.

**Motivating principle:** self-describing data. Someone reading a JSON
blob from the event log — or from any bus channel — should not need
prior knowledge to understand what the fields mean. Field names should
say what they are. Cognitive load is the enemy.

## What's wrong with the current shape

### Event log fields are semantically opaque

Current `Arcana::Events::Event` uses generic `subject`/`object` fields
whose meaning shifts per event type:

| Event type | subject | object |
|---|---|---|
| `message.sent` | recipient | sender |
| `message.consumed` | recipient (who consumed) | — |
| `message.rejected` | recipient (whose queue was full) | sender |
| `listing.registered` | new address | — |
| `listing.pruned` | pruned address | — |
| `subscription.added` | topic | subscriber |
| `topic.published` | topic | publisher |
| `auth.failed` | path or address | — |

Reading a JSON row cold, you can't tell which is which without a
lookup table. This fails the self-describing test.

### Event type names are inconsistent

- `subscription.added` / `subscription.removed` vs `topic.published` —
  pub/sub events split across two prefixes. Should be one namespace.
- `message.sent` and `message.delivered` fire at nearly the same
  moment for the same operation. Redundant — one should go.

### `Envelope.subject` collides with the term

The envelope's `subject` is a caller memo (per our earlier
resolution). The word "subject" doing double duty as (a) a memo field
and (b) a routing-target field in Event confuses everyone.

### Topics are second-class

Topics have no listing, no metadata, no discoverability. They exist
implicitly the moment someone subscribes. No way to ask "what topics
exist on this bus?" without walking every subscription record.
Meanwhile agents and services have first-class `Directory::Listing`
records with names, descriptions, guides, tags.

## Proposed changes, bundled

Everything below lands together as one coherent major bump
(arcana-core X.0.0 + arcana Y.0.0). Piecemeal isn't worth the churn.

### 1. Event data carries the object it acts on

Instead of generic `subject`/`object`, each event carries the actual
data structure it concerns:

```json
{"type":"message.delivered",  "envelope": {...metadata, no payload...}}
{"type":"message.rejected",   "envelope": {...}, "reason":"mailbox_full"}
{"type":"message.received",   "envelope": {...}}
{"type":"message.frozen",     "envelope": {...}, "by":"supervisor"}
{"type":"message.thawed",     "envelope": {...}}

{"type":"listing.registered", "listing": {"address":"@mj","kind":"agent","name":"..."}}
{"type":"listing.unregistered","listing": {"address":"@mj"}}
{"type":"listing.pruned",     "listing": {"address":"@bob-old"}}
{"type":"listing.busy_changed","listing": {"address":"@mj"}, "busy": true}

{"type":"topic.subscribed",   "topic":"#logs", "subscriber":"aix"}
{"type":"topic.unsubscribed", "topic":"#logs", "subscriber":"aix"}
{"type":"topic.published",    "topic":"#logs", "publisher":"@bob"}

{"type":"auth.failed",        "path":"/deliver", "reason":"missing bearer", "transport":"rest"}
```

`envelope` and `listing` are direct serializations of the underlying
`Arcana::Envelope` and `Arcana::Directory::Listing` structs. `topic`
is a string (topics have no struct — see below). Payload is always
omitted from event envelopes (size + secrets).

### 2. Consistent event-type namespaces

- `subscription.added` → `topic.subscribed`
- `subscription.removed` → `topic.unsubscribed`
- `topic.published` stays

All three are past-tense verbs under one noun prefix.

### 3. Drop `message.sent`, keep `message.delivered`

They fire at the same moment for the same operation. `delivered`
matches `arcana_deliver` (the MCP tool) and makes a stronger truth
claim (in an in-process bus, delivery is guaranteed on successful send).

Also consider: `message.consumed` → `message.received` for consistency
of "message.<past-tense-verb>" from the message's perspective.

### 4. `Envelope.subject` → `Envelope.memo`

The current name misdescribes it — it's a caller memo, not routing
metadata. Renaming here also kills the `subject`/`object` confusion in
Event once Event drops those fields (per #1).

### 5. `involving:` cross-cutting filter on `arcana_events`

Since the primary-party field name varies per event type (recipient,
address, subscriber, publisher, ...), replace the current single-field
filter with `involving:X` — matches events where X is any semantic
party. `arcana_events involving:"@arcana"` returns everything about
@arcana without needing to know which field name applies per type.

Retain per-type filters (`recipient:X`, `topic:X`, etc.) for callers
who want precision.

### 6. `sys.message.sent` firehose renames

`sys.message.sent` → `#sys.message.delivered` (if topics get the #
sigil per #7). Otherwise `sys.message.delivered`. Follows the
message-event rename in #3.

### 7. Topics are first-class addresses with `#` sigil

Currently:
- Addresses (agents, services, toolsets) live in `Directory#listings`
- Topics live in `Bus#subscriptions` — parallel namespace, no metadata

Proposal:
- Topics are addresses. `#logs`, `#sys.message.delivered`, `#aix`.
- Topic listings have `kind: "topic"` and get all the normal fields
  (description, guide, tags).
- `arcana_directory kind:"topic"` lists every channel.
- Subscribing = "add me to this topic-address's fan-out list"
  (stored as metadata on the topic listing, not in a parallel Bus
  map).

Sigil convention (parallel to `@` for agents):
- `@name` — agent
- `#name` — topic
- `name` or `owner:capability` — service/toolset
- `_reply:<hex>` — internal ephemeral

## Open questions

### Topic semantics: fan-out vs shared log

**Decision (2026-07-28): Model B — shared log.** See "MVP: shared-log
topics" section below for the concrete scope. Prior weighing kept for
context:

**Model A — Fan-out (what arcana does today, cosmetic change):**
- Topic address is a routing hub with no persistent queue.
- Publish = deliver a copy to each subscriber's private mailbox.
- Late subscribers miss earlier publishes.
- Simple. Stateless topics.

**Model B — Shared log (Kafka / NATS JetStream shape):**
- Topic address has a real persistent queue (backed by a mailbox).
- Publish = append to that queue + fan small notifications.
- Anyone (if public) reads from any offset with their own cursor.
- Subscribing = "notify me when new entries land."
- Late subscribers can catch up. One-source-of-truth per channel.
- Requires: retention policy per topic, cursor semantics, cadence
  handling.

Why B won: the sigil unification (`@agent`, `service`, `#topic` all
"mailboxes with sigils") is only coherent if `#topic` really is a
mailbox — same read API, same peek, same storage. Under Model A a
`#topic` would be a routing hub that looks like a mailbox but isn't
readable, which breaks the framing. Model B also eliminates the N-copy
fan-out cost (1 payload + N tiny notifications instead of N full
copies) and lets late/offline consumers catch up without special
infrastructure.

## MVP: shared-log topics

Concrete scope for the first cut. Anything not listed is deferred.

**In scope:**

1. **`#` sigil recognized; new `Directory::Kind::Topic`.**
   Address rules symmetric with `@` for agents: `#name` required for
   `kind: topic`; registering a topic without `#` (or an agent with `#`)
   raises with a clear error message.
2. **Registration required.** No lazy topic creation. Publishing to an
   unregistered `#topic` fails loudly. Registration carries retention
   policy, description, tags — same shape as agent/service registration.
   Reasons: symmetry with other sigiled kinds, typo containment
   (`#new` vs `#news` fails instead of silently vanishing), and giving
   retention/ownership/schema a place to live.
3. **Retention: bounded ring, default 10 000 entries.** Registration
   can override:
   `arcana_register kind:"topic" address:"#news" retention:{ring: 50000}`
   TTL-based retention is a later addition — ring covers the common
   case.
4. **Publish = 1 append + N notifications.**
   `publish(topic, envelope)`:
   - Append the envelope once to the topic's mailbox (single copy).
   - For each subscriber, deliver a small notification envelope to
     their private mailbox.
   Notification payload shape:
   ```json
   {"topic":"#news","from":"@alice","seq":42,
    "correlation_id":"abc","subject":"Q3 planning notes"}
   ```
   No full payload in the notification — subscriber reads the topic
   mailbox with `after:<seq>` if they want the content.
5. **Subscribe with `cadence: "always"` only for MVP.**
   `arcana_subscribe topic:"#news" cadence:"always"` — real-time
   notification on every publish. The field is accepted from day one;
   values other than `"always"` return "not yet implemented" so the
   API doesn't need to change when digest cadences land.
6. **Cursor reads are peek-only, client-side cursor.**
   `arcana_inbox address:"#news" after:<seq>` — non-destructive,
   returns messages since the caller-supplied seq. `arcana_receive`
   on a `#topic` is rejected (destructive receive is incompatible
   with sharing — first-come-first-serve turns it into a work queue).
7. **Discovery.** `arcana_directory kind:"topic"` lists topics with
   description/tags/retention.
8. **`sys.message.sent` migration.** Renamed to `#sys.message.sent`
   (still called `.sent` here — see #3 in the main proposal, which
   would rename it to `#sys.message.delivered` if that ships in the
   same bundle). Bus registers it itself on startup; write is
   restricted to the bus (`send`/`send?` hooks); anyone can peek or
   subscribe. The metadata payload is already small (~200 bytes), so
   this topic doesn't gain much from "1 vs N copies" — its win from
   the migration is purely uniformity + peek-without-subscribe.

**Deferred (accept API shape, defer implementation):**

- **Cadence > `always`.** Daily/weekly/monthly digests need a
  per-(subscriber, topic) scheduler with `next_fire_at` and pending
  seq buffer, must survive restart, must handle catch-up if the bus
  was down over a fire time. Real infrastructure — build after MVP.
- **Server-tracked cursors.** MVP puts the cursor client-side.
  Consumers who want managed cursors can either store the last-seen
  seq themselves or subscribe (using notification seq as their
  cursor). A managed-cursor mode can be layered on later without
  breaking the peek API.
- **Filtered subscriptions.** Server-side predicates
  (`arcana_subscribe #news filter:{tag:"security"}`) are a nice-to-have,
  not MVP.
- **Per-topic ACLs.** Anyone can publish and subscribe by default.
  Access control ties into the SaaS auth story (Stage 3+) and inherits
  whatever listing-level policy that sprint produces.

**Open MVP questions still worth revisiting before implementation:**

- Notification for a `#topic` — deliver directly to the subscriber's
  mailbox, or through a wrapper envelope so subscribers can
  distinguish topic-notifications from direct mail? Probably a
  distinct `subject: "topic.notification"` on the envelope plus the
  notification payload above is enough.
- What happens to notifications when a subscriber's mailbox is full?
  Current `sys.message.sent` firehose drops silently
  (`broadcast_system_send`). Same policy here — best-effort — since
  the subscriber can always catch up by reading the topic mailbox
  directly.

### Access control on topics (and everything else)

Public vs private, allow/deny lists. Ties into the SaaS auth story
(Stage 3+, deferred). Topic-level policy is a special case of
listing-level policy. If we build listing-level policy for the
multi-tenant story eventually, topics inherit it.

For the first cut of this cleanup, could add a `visibility: public |
private` stub field on listings with no enforcement — placeholder for
the auth work. Or defer entirely and revisit with the SaaS auth
sprint.

## Migration

### Event log format

Old JSONL files under `~/.arcana/events/` (or wherever the event log
lives) use the old `subject`/`object` shape. Two options:

1. **Cold cutover.** New events written in the new shape. Old files
   stay as-is. Tooling that reads events handles both shapes. Simple.
2. **Migration script.** `arcana-admin migrate-events` walks the log
   dir and rewrites old JSONL to the new shape. Cleaner reader code.

**Recommendation: cold cutover.** Event log is audit trail, not
queried heavily. Mixed-shape reading is fine.

### Snapshot format

Listings with `kind: "topic"` will start appearing in the snapshot. If
we mark them non-ephemeral (user-created), they persist through
restarts. Backward-compatible — old snapshots have no topic listings,
new ones may.

### Callers

- **arcana-mcp**: filter parameter names change (`concerning:`,
  `involving:` etc.). Update at the same time as the daemon.
- **arcana-core Client**: nothing to change — clients don't consume
  events directly; they use the /events REST endpoint or the topic
  firehose.
- **Downstream (mj, aix, etc.)**: subscribers to `sys.message.sent`
  need to switch to `#sys.message.delivered` (or whatever we settle
  on). AIX's shift is one string constant.

## Not in scope

- Per-message durability across hard crashes (Postgres event backend
  is the tracked path; separate from this cleanup).
- Full access-control enforcement. Just a stub field maybe.
- Rename of `Directory::Listing` itself. Struct name is fine.
- Cadence handling beyond `always`, server-tracked cursors, filtered
  subscriptions, per-topic ACLs — all v2 of the shared-log MVP.

## Origin

Thomas raised the cognitive-load principle in a design conversation
on 2026-07-24 after AIX's `subject`/`object` confusion. Full
back-and-forth in the session transcript. This is the crystallized
proposal. Nothing here is shipped as of this note; picking up when
we're ready.
