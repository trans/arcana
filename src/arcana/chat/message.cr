require "json"

module Arcana
  module Chat
    # A tool call returned by the model in an assistant message.
    struct ToolCall
      include JSON::Serializable

      property id : String
      property type : String = "function"
      property function : FunctionCall

      struct FunctionCall
        include JSON::Serializable
        property name : String
        property arguments : String  # raw JSON string

        def initialize(@name : String, @arguments : String)
        end
      end

      def initialize(@id : String, @type : String, @function : FunctionCall)
      end

      # Parse the arguments JSON into a Hash.
      def parsed_arguments : Hash(String, JSON::Any)
        JSON.parse(@function.arguments).as_h
      rescue
        {} of String => JSON::Any
      end
    end

    # A single message in a chat conversation.
    struct Message
      property role : String       # "system", "user", "assistant", "tool"
      property content : String?
      property name : String?           # optional speaker name
      property tool_calls : Array(ToolCall)?  # assistant messages only
      property tool_call_id : String?   # tool response messages only

      def initialize(
        @role : String,
        @content : String? = nil,
        @name : String? = nil,
        @tool_calls : Array(ToolCall)? = nil,
        @tool_call_id : String? = nil,
      )
      end

      def self.system(content : String) : self
        new("system", content: content)
      end

      def self.user(content : String, name : String? = nil) : self
        new("user", content: content, name: name)
      end

      def self.assistant(content : String) : self
        new("assistant", content: content)
      end

      # Serialize to the OpenAI-compatible JSON format.
      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "role", @role
          if c = @content
            json.field "content", c
          end
          if n = @name
            json.field "name", n
          end
          if tc = @tool_calls
            json.field "tool_calls" do
              json.array do
                tc.each(&.to_json(json))
              end
            end
          end
          if tcid = @tool_call_id
            json.field "tool_call_id", tcid
          end
        end
      end
    end

    # Manages a rolling conversation history with size limits.
    class History
      MAX_CONTENT_CHARS = 100_000

      getter messages : Array(Message)

      def initialize
        @messages = [] of Message
      end

      def add_system(content : String)
        if @messages.empty? || @messages[0].role != "system"
          @messages.unshift(Message.system(content))
        else
          @messages[0] = Message.system(content)
        end
      end

      def add_user(content : String)
        @messages << Message.user(content)
      end

      def add_assistant(content : String)
        @messages << Message.assistant(content)
      end

      def update_last_assistant(content : String)
        i = @messages.size - 1
        while i >= 0
          if @messages[i].role == "assistant"
            @messages[i] = Message.assistant(content)
            return
          end
          i -= 1
        end
      end

      # Trim middle messages to stay under MAX_CONTENT_CHARS.
      # Keeps system (0), first user+assistant (1-2), and newest messages.
      # Always removes tool_use/tool_result pairs together to maintain
      # the pairing required by the Anthropic API.
      def trim_if_needed
        total = @messages.sum { |m| (m.content || "").size }
        return if total <= MAX_CONTENT_CHARS
        return if @messages.size <= 5
        while total > MAX_CONTENT_CHARS && @messages.size > 5
          idx = 3
          break if idx >= @messages.size - 2 # protect newest messages

          msg = @messages[idx]

          # If this is an assistant message with tool_calls, also remove the
          # following tool_result message(s) to keep them paired.
          if msg.role == "assistant" && msg.tool_calls.try(&.size.>(0))
            total -= (msg.content || "").size
            @messages.delete_at(idx)
            # Remove subsequent tool_result messages
            while idx < @messages.size && @messages[idx].role == "tool"
              total -= (@messages[idx].content || "").size
              @messages.delete_at(idx)
            end
          # If this is a tool_result, remove the preceding assistant message too.
          elsif msg.role == "tool"
            # Find and remove the preceding assistant with tool_calls
            if idx > 0 && @messages[idx - 1].role == "assistant"
              total -= (@messages[idx - 1].content || "").size
              @messages.delete_at(idx - 1)
              idx -= 1
            end
            # Remove this and any following tool_result messages
            while idx < @messages.size && @messages[idx].role == "tool"
              total -= (@messages[idx].content || "").size
              @messages.delete_at(idx)
            end
          else
            removed = @messages.delete_at(idx)
            total -= (removed.content || "").size
          end
        end
      end

      def size : Int32
        @messages.size
      end

      def empty? : Bool
        @messages.empty?
      end
    end
  end
end
