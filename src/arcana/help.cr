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
          - `foo` — bare single token (typically a service)
          - `@foo` — agent-handle single token (leading `@` sigil,
            conversational identity)
          - `owner:capability` — two-token colon form (services)
        - The `@` sigil is a naming *convention*: it lets a project's
          Claude/Codex agent register as `@mj` alongside the same
          project's tool service registered as `mj`. Both are distinct
          entities with distinct mailboxes.
        - `kind` (`agent` or `service`) and `capability` (`chat`,
          `image`, `tts`, `embed`, `markdown`, ...) are separate fields
          on your registration. Set them explicitly; the bus does not
          derive them from the sigil or the colon.
        MD

      "discovery" => <<-MD,
        **Discovery:** two-step.

        Step 1 — list what's on the bus with `arcana_directory`. Filter
        by `kind`, `tag`, or `capability`. Providers advertise their
        offerings via `tags` — e.g. `arcana_directory tag:"chat"` finds
        every entity that offers a chat tool (openai, anthropic, gemini,
        ...). `arcana_directory kind:"agent"` lists humans/assistants.
        Each listing has a short `guide` for at-a-glance context.

        Step 2 — ask any participant what it offers by sending
        `{"tool":"help"}`. The reply is a Protocol.result wrapping a
        manifest: `{"name":"...","description":"...","tools":[{"name":"...","description":"...","inputSchema":{...}}, ...]}`.
        Then invoke with `{"tool":"<name>", ...args}`.

        Default built-in providers use this shape — `arcana` for
        utilities (echo, markdown), `openai` for chat/embed/tts,
        `anthropic` for chat, `gemini` for chat, `runware` for image.
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
