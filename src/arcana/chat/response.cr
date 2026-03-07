require "json"

module Arcana
  module Chat
    struct Response
      property content : String?
      property tool_calls : Array(ToolCall)
      property finish_reason : String?
      property model : String
      property provider : String
      property raw_request : String  # full request body sent to API
      property raw_json : String     # full response body from API

      # Token usage from the API response.
      property prompt_tokens : Int32?
      property completion_tokens : Int32?

      # Anthropic prompt caching tokens.
      property cache_read_tokens : Int32?
      property cache_creation_tokens : Int32?

      def initialize(
        @content : String? = nil,
        @tool_calls : Array(ToolCall) = [] of ToolCall,
        @finish_reason : String? = nil,
        @model : String = "",
        @provider : String = "",
        @raw_request : String = "",
        @raw_json : String = "",
        @prompt_tokens : Int32? = nil,
        @completion_tokens : Int32? = nil,
        @cache_read_tokens : Int32? = nil,
        @cache_creation_tokens : Int32? = nil,
      )
      end

      # Did the model return any tool calls?
      def has_tool_calls? : Bool
        !@tool_calls.empty?
      end

      # Find the first tool call matching a given function name.
      def tool_call(name : String) : ToolCall?
        @tool_calls.find { |tc| tc.function.name == name }
      end

      # Parse from an OpenAI-compatible JSON response body.
      def self.from_openai_json(raw : String, provider : String = "openai") : self
        parsed = JSON.parse(raw)

        choices = parsed["choices"]?.try(&.as_a?)
        unless choices && !choices.empty?
          return new(raw_json: raw, provider: provider)
        end

        message = choices[0]["message"]?
        finish = choices[0]["finish_reason"]?.try(&.as_s?)
        model = parsed["model"]?.try(&.as_s?) || ""

        content = message.try { |m| m["content"]?.try(&.as_s?) }

        tool_calls = [] of ToolCall
        if tcs = message.try { |m| m["tool_calls"]?.try(&.as_a?) }
          tcs.each do |tc|
            fn = tc["function"]?
            next unless fn
            tool_calls << ToolCall.new(
              id: tc["id"]?.try(&.as_s?) || "",
              type: tc["type"]?.try(&.as_s?) || "function",
              function: ToolCall::FunctionCall.new(
                name: fn["name"]?.try(&.as_s?) || "",
                arguments: fn["arguments"]?.try(&.as_s?) || "{}",
              ),
            )
          end
        end

        usage = parsed["usage"]?
        prompt_tokens = usage.try { |u| u["prompt_tokens"]?.try(&.as_i?) }
        completion_tokens = usage.try { |u| u["completion_tokens"]?.try(&.as_i?) }

        new(
          content: content,
          tool_calls: tool_calls,
          finish_reason: finish,
          model: model,
          provider: provider,
          raw_json: raw,
          prompt_tokens: prompt_tokens,
          completion_tokens: completion_tokens,
        )
      end
    end
  end
end
