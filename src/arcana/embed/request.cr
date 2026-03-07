module Arcana
  module Embed
    struct Request
      property texts : Array(String)
      property model : String
      property trace_tags : Hash(String, String)?

      def initialize(
        @texts : Array(String),
        @model : String = "",
        @trace_tags : Hash(String, String)? = nil,
      )
      end

      # Convenience for embedding a single text.
      def self.single(text : String, model : String = "") : self
        new(texts: [text], model: model)
      end
    end
  end
end
