require "json"

module Arcana
  # Shutdown snapshots for crash recovery.
  #
  # Captures the full bus state (directory listings, mailbox messages,
  # frozen messages, tokens) into a single JSON file. Reloaded at startup
  # to restore everything as it was at last clean shutdown.
  #
  # See `bin/arcana.cr` for the SIGTERM/SIGINT trap that calls `save`,
  # and the startup load that calls `load`.
  module Snapshot
    VERSION = 1

    # Write the full bus state to `path` atomically (tmp + rename).
    def self.save(bus : Bus, directory : Directory, server : Server, path : String) : Nil
      json = JSON.build do |j|
        j.object do
          j.field "version", VERSION
          j.field "saved_at", Time.utc.to_rfc3339
          j.field "listings" do
            j.array do
              directory.list.each do |l|
                j.object do
                  j.field "address", l.address
                  j.field "name", l.name
                  j.field "description", l.description
                  j.field "kind", l.kind.to_s.downcase
                  j.field "schema", l.schema if l.schema
                  j.field "guide", l.guide if l.guide
                  j.field "tags", l.tags unless l.tags.empty?
                  if seen = directory.last_seen(l.address)
                    j.field "last_seen", seen.to_rfc3339
                  end
                end
              end
            end
          end
          j.field "mailboxes" do
            j.array do
              bus.addresses.each do |addr|
                next if addr.starts_with?("_reply:") # skip transient reply mailboxes
                mb = bus.mailbox(addr)
                snap = mb.dump
                next if snap[:messages].empty? && snap[:frozen].empty?
                j.object do
                  j.field "address", addr
                  j.field "last_activity", mb.last_activity.to_rfc3339
                  j.field "messages" do
                    j.array do
                      snap[:messages].each { |env| env.to_json(j) }
                    end
                  end
                  j.field "frozen" do
                    j.array do
                      snap[:frozen].each do |id, env|
                        j.object do
                          j.field "id", id
                          j.field "by", snap[:frozen_by][id]? || ""
                          j.field "envelope" { env.to_json(j) }
                        end
                      end
                    end
                  end
                end
              end
            end
          end
          j.field "tokens" do
            j.array do
              server.tokens.each do |addr, tok|
                j.object do
                  j.field "address", addr
                  j.field "token", tok
                end
              end
            end
          end
        end
      end

      tmp = "#{path}.tmp"
      File.write(tmp, json)
      File.rename(tmp, path) # atomic on POSIX
    end

    # Restore bus state from `path`. Returns true if loaded, false if
    # the file does not exist. Raises on malformed JSON.
    def self.load(bus : Bus, directory : Directory, server : Server, path : String) : Bool
      return false unless File.exists?(path)
      parsed = JSON.parse(File.read(path))

      restore_listings(directory, parsed["listings"]?)
      restore_mailboxes(bus, parsed["mailboxes"]?)
      restore_tokens(server, parsed["tokens"]?)

      # Ensure every restored listing has a mailbox. The snapshot omits
      # empty mailboxes to save space, but the bus needs one to exist for
      # send() to queue messages for offline agents.
      directory.list.each do |listing|
        bus.mailbox(listing.address) unless bus.has_mailbox?(listing.address)
      end

      true
    end

    private def self.restore_listings(directory : Directory, raw : JSON::Any?) : Nil
      return unless raw
      raw.as_a.each do |entry|
        address = entry["address"].as_s
        kind = entry["kind"]?.try(&.as_s?) == "service" ? Directory::Kind::Service : Directory::Kind::Agent
        listing = Directory::Listing.new(
          address: Directory.bare_name(address),
          name: entry["name"]?.try(&.as_s?) || Directory.bare_name(address),
          description: entry["description"]?.try(&.as_s?) || "",
          kind: kind,
          schema: entry["schema"]?,
          guide: entry["guide"]?.try(&.as_s?),
          tags: entry["tags"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String,
        )
        unless directory.lookup(address)
          directory.register(listing)
          if last_seen_raw = entry["last_seen"]?.try(&.as_s?)
            ts = (Time.parse_rfc3339(last_seen_raw) rescue nil)
            directory.set_last_seen(Directory.qualify(Directory.bare_name(address), kind), ts) if ts
          end
        end
      end
    end

    private def self.restore_mailboxes(bus : Bus, raw : JSON::Any?) : Nil
      return unless raw
      raw.as_a.each do |entry|
        address = entry["address"].as_s
        mb = bus.mailbox(address)

        messages = entry["messages"]?.try(&.as_a?.try(&.map { |m| Envelope.from_json(m.to_json) })) || [] of Envelope

        frozen = {} of String => Envelope
        frozen_by = {} of String => String
        if frozen_raw = entry["frozen"]?.try(&.as_a?)
          frozen_raw.each do |fe|
            id = fe["id"].as_s
            env = Envelope.from_json(fe["envelope"].to_json)
            frozen[id] = env
            if by = fe["by"]?.try(&.as_s?)
              frozen_by[id] = by unless by.empty?
            end
          end
        end

        mb.load_snapshot(messages, frozen, frozen_by)
        if la_raw = entry["last_activity"]?.try(&.as_s?)
          ts = (Time.parse_rfc3339(la_raw) rescue nil)
          mb.last_activity = ts if ts
        end
      end
    end

    private def self.restore_tokens(server : Server, raw : JSON::Any?) : Nil
      return unless raw
      tokens = {} of String => String
      raw.as_a.each do |entry|
        addr = entry["address"].as_s
        tok = entry["token"].as_s
        tokens[addr] = tok
      end
      server.load_tokens(tokens)
    end
  end
end
