module Arcana
  module Chat
    # Events yielded during streaming chat completion.
    struct StreamEvent
      enum Type
        TextDelta
        ToolUse
        Done
        Error
      end

      property type : Type
      property text : String?
      property tool_call : ToolCall?
      property response : Response?
      property error : String?

      def initialize(
        @type : Type,
        @text : String? = nil,
        @tool_call : ToolCall? = nil,
        @response : Response? = nil,
        @error : String? = nil,
      )
      end

      def self.text_delta(text : String) : self
        new(type: Type::TextDelta, text: text)
      end

      def self.tool_use(tool_call : ToolCall) : self
        new(type: Type::ToolUse, tool_call: tool_call)
      end

      def self.done(response : Response) : self
        new(type: Type::Done, response: response)
      end

      def self.error(message : String) : self
        new(type: Type::Error, error: message)
      end
    end
  end
end
