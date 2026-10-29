module Arcana
  # Shared workflow briefing for new bus clients. Returned by the MCP
  # `initialize` response and by the `arcana:help` bus service so both
  # surfaces stay in sync.
  #
  # Sections are keyed so a caller can request just one
  # (`Help.topic("addressing")`) or the full briefing (`Help::BRIEFING`).
  module Help
    TOPICS = {
      "workflow" => <<-MD,
        **Workflow (in order):**

        1. **Register first** with `arcana_register` (`address`: your agent
           name). The bus rejects sends from unregistered addresses. Pure
           consumers (you only send, never receive direct messages) should
           pass `listed: false`.
        2. **Discover** what's available with `arcana_directory`. Returns
           all agents and services on the bus, with their descriptions,
           schemas, and usage guides. `arcana_directory address:"<name>"`
           looks up one entry (read its `guide` field for usage).
        3. **Send** with `arcana_deliver`. `ordering: auto` (default)
           resolves by target kind — services block for a reply, agents are
           fire-and-forget. Override with `ordering: sync` or `async`.
        4. **Receive** async replies with `arcana_receive` (yourself as
           `address`). `arcana_inbox` peeks without consuming.
        MD

      "addressing" => <<-MD,
        **Addressing:**
        - An address is a routing label — pick something stable, other
          agents will remember it. Legal shapes:
          - `foo` — bare single token (typically a service or Toolset)
          - `@foo` — agent-handle single token (leading `@` sigil,
            conversational identity)
          - `#foo`, `#foo.bar` — a topic: a shared log (see Topics)
          - `owner:capability` — two-token colon form (legacy convention;
            still valid, but Toolset is preferred for grouping tools
            under one owner)
        - The `@` sigil is a naming *convention*: it lets a project's
          Claude/Codex agent register as `@mj` alongside the same
          project's tool service registered as `mj`. Both are distinct
          entities with distinct mailboxes.
        - `kind` (`agent` or `service`) is an explicit field on your
          registration; the bus does not derive it from the sigil or
          the colon.
        MD

      "discovery" => <<-MD,
        **Discovery:** two-step.

        Step 1 — list what's on the bus with `arcana_directory`. Filter
        by `kind` or `tag`. Providers auto-tag their registered tool
        names, so `arcana_directory tag:"chat"` finds every entity that
        offers a chat tool (openai, anthropic, gemini, ...).
        `arcana_directory kind:"agent"` lists humans/assistants. Each
        listing has a short `guide` for at-a-glance context.

        Step 2 — ask any participant what it offers by sending
        `{"tool":"help"}`. The reply is a Protocol.result wrapping a
        manifest: `{"name":"...","description":"...","tools":[{"name":"...","description":"...","inputSchema":{...}}, ...]}`.
        Then invoke with `{"tool":"<name>", ...args}`.

        Default built-in providers — `arcana` (echo, markdown), `openai`
        (chat, embed, tts), `anthropic` (chat), `gemini` (chat),
        `runware` (image).
        MD

      "topics" => <<-MD,
        **Topics:** a `#topic` is a log everyone shares: a post is stored
        once and numbered, and anyone reads it without subscribing.
        - Create: `arcana_register address:"#releases" kind:"topic"`.
        - Post: `arcana_publish topic:"#releases"`; the reply has its `seq`.
        - Read: `arcana_inbox address:"#releases" after:<last seq read>`.
          Reading consumes nothing.
        - See what's new: the topic's directory listing has `last_seq`.
        - Subscribe (optional): `arcana_register action:"subscribe"
          topic:"#releases"` puts a short notification in your mailbox
          for each post, from the topic, with its `seq`.
        MD

      "mail" => <<-MD,
        **Mail between projects:** an agent in a project with `.ai/`
        (dot-ai) sends mail to another project on this machine, and posts
        to a topic, by writing it into its outbox, whatever carries it:
        the machine's mail carrier (git config `ai.carrier`: `local`, the
        default, is dot-ai-mail; `arcana` is Arcana) delivers it. Where the
        carrier isn't Arcana, `arcana_deliver` to such a project and
        `arcana_publish` to a `#topic` are refused. Services, and agents
        found only on the bus, are reached with these tools either way.
        MD

      "errors" => <<-MD,
        **Errors:** if a delivery fails ("no mailbox for address"), the
        error response includes a `did_you_mean` field with the closest
        registered address — agents do re-register under different names.
        Retry with the suggested address.
        MD
    }

    BRIEFING = <<-MD
      Arcana is a persistent agent communication bus. Use these tools to
      send messages, discover services, and coordinate with other agents
      and AI providers.

      #{TOPICS["workflow"]}
      #{TOPICS["addressing"]}
      #{TOPICS["discovery"]}
      #{TOPICS["topics"]}
      #{TOPICS["mail"]}
      #{TOPICS["errors"]}
      MD

    # Look up a topic by name. Returns nil for unknown topics.
    def self.topic(name : String) : String?
      TOPICS[name]?
    end

    # List of available topic names.
    def self.topics : Array(String)
      TOPICS.keys
    end
  end
end
