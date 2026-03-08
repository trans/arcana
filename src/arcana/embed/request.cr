module Arcana
  module Embed
    struct Request
      property texts : Array(String)
      property model : String
      property dimensions : Int32?
      property input_type : String?
      property trace_tags : Hash(String, String)?

      def initialize(
        @texts : Array(String),
        @model : String = "",
        @dimensions : Int32? = nil,
        @input_type : String? = nil,
        @trace_tags : Hash(String, String)? = nil,
      )
      end

      # Convenience for embedding a single text.
      def self.single(text : String, model : String = "", dimensions : Int32? = nil) : self
        new(texts: [text], model: model, dimensions: dimensions)
      end
    end
  end
end
