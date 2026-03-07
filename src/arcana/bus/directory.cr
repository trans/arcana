require "json"

module Arcana
  # Registry of agent and service capabilities.
  #
  # Each address on the Bus can register a Listing that describes
  # what it does, whether it's an LLM-backed agent or a simple
  # service, and optionally what input schema it expects.
  class Directory
    enum Kind
      Agent
      Service
    end

    struct Listing
      property address : String
      property name : String
      property description : String
      property kind : Kind
      property schema : JSON::Any?    # input schema (services) or hints (agents)
      property tags : Array(String)

      def initialize(
        @address : String,
        @name : String,
        @description : String,
        @kind : Kind,
        @schema : JSON::Any? = nil,
        @tags : Array(String) = [] of String,
      )
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "address", @address
          json.field "name", @name
          json.field "description", @description
          json.field "kind", @kind.to_s.downcase
          json.field "schema", @schema if @schema
          json.field "tags", @tags unless @tags.empty?
        end
      end
    end

    @listings = {} of String => Listing
    @mutex = Mutex.new

    # Register a listing. Overwrites any existing listing at the same address.
    def register(listing : Listing)
      @mutex.synchronize { @listings[listing.address] = listing }
    end

    # Remove a listing by address.
    def unregister(address : String)
      @mutex.synchronize { @listings.delete(address) }
    end

    # Look up a listing by address.
    def lookup(address : String) : Listing?
      @mutex.synchronize { @listings[address]? }
    end

    # List all registered listings.
    def list : Array(Listing)
      @mutex.synchronize { @listings.values }
    end

    # Filter listings by kind.
    def by_kind(kind : Kind) : Array(Listing)
      @mutex.synchronize { @listings.values.select { |l| l.kind == kind } }
    end

    # Filter listings by tag.
    def by_tag(tag : String) : Array(Listing)
      @mutex.synchronize { @listings.values.select { |l| l.tags.includes?(tag) } }
    end

    # Search listings by substring match on name, description, or tags.
    def search(query : String) : Array(Listing)
      q = query.downcase
      @mutex.synchronize do
        @listings.values.select do |l|
          l.name.downcase.includes?(q) ||
            l.description.downcase.includes?(q) ||
            l.tags.any?(&.downcase.includes?(q))
        end
      end
    end

    # Summarize the directory as JSON — useful for injecting into agent prompts.
    def to_json : String
      JSON.build do |json|
        json.array do
          @mutex.synchronize do
            @listings.each_value { |l| l.to_json(json) }
          end
        end
      end
    end
  end
end
