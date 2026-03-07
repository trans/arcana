require "json"

module Arcana
  module Chat
    # A server-side tool that the provider executes (e.g. web_search).
    # Unlike Tool, the client doesn't execute these — results come back
    # inline in the same response.
    struct ServerTool
      property type : String
      property name : String
      property config : Hash(String, JSON::Any)

      def initialize(@type : String, @name : String, @config = {} of String => JSON::Any)
      end

      # Convenience: web search with optional max_uses.
      def self.web_search(max_uses : Int32? = nil) : self
        config = {} of String => JSON::Any
        config["max_uses"] = JSON::Any.new(max_uses.to_i64) if max_uses
        new("web_search_20250305", "web_search", config)
      end

      # Convenience: code execution.
      def self.code_execution : self
        new("code_execution_20250522", "code_execution")
      end
    end
  end
end
