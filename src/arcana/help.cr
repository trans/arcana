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
          agents will remember it. Any single token (`alice`, `cattacula`)
          or two-token colon form (`openai:chat`) works; the colon is a
          naming convention, not a type marker.
        - `kind` (`agent` or `service`) and `capability` (`chat`,
          `image`, `tts`, `embed`, `markdown`, ...) are separate fields
          on your registration. Services should set both; agents just
          need the address.
        MD

      "discovery" => <<-MD,
        **Discovery:** use `arcana_directory` to find agents and services
        on the bus. Filter by `kind`, `tag`, or `capability` — e.g.
        `arcana_directory capability:"chat"` to list all chat providers,
        `arcana_directory kind:"agent"` to list humans/assistants. Each
        listing includes a `guide` field with usage. To get help from any
        *service*, send `_intent: "help"` in the payload — the service
        replies with its guide and schema.
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
