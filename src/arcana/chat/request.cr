module Arcana
  module Chat
    struct Request
      property messages : Array(Message)
      property model : String
      property temperature : Float64
      property max_tokens : Int32
      property tools : Array(Tool)?
      property tool_choice : String?  # "auto", "required", "none", or {"type":"function","function":{"name":"..."}}
      property trace_tags : Hash(String, String)?

      def initialize(
        @messages : Array(Message),
        @model : String = "gpt-4o-mini",
        @temperature : Float64 = 0.7,
        @max_tokens : Int32 = 150,
        @tools : Array(Tool)? = nil,
        @tool_choice : String? = nil,
        @trace_tags : Hash(String, String)? = nil,
      )
      end

      # Build from a History object.
      def self.from_history(
        history : History,
        model : String = "gpt-4o-mini",
        temperature : Float64 = 0.7,
        max_tokens : Int32 = 150,
        tools : Array(Tool)? = nil,
        tool_choice : String? = nil,
        trace_tags : Hash(String, String)? = nil,
      ) : self
        new(
          messages: history.messages.dup,
          model: model,
          temperature: temperature,
          max_tokens: max_tokens,
          tools: tools,
          tool_choice: tool_choice,
          trace_tags: trace_tags,
        )
      end
    end
  end
end
