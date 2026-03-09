module Arcana
  # An autonomous LLM-backed agent that listens on the Bus and
  # processes messages through a Chat provider. Maintains conversation
  # history per correspondent and replies automatically.
  #
  # No human in the loop — runs as a fiber on the Arcana server.
  #
  #   agent = Arcana::ChatAgent.new(
  #     bus: bus,
  #     directory: dir,
  #     address: "assistant",
  #     name: "Assistant",
  #     description: "General-purpose AI assistant",
  #     provider: Arcana::Chat::OpenAI.new(api_key: ENV["OPENAI_API_KEY"]),
  #     system_prompt: "You are a helpful assistant.",
  #   )
  #   agent.start
  #
  class ChatAgent < Actor
    # Max conversation turns per correspondent before trimming.
    property max_turns : Int32 = 50
    # Model parameters.
    property model : String
    property temperature : Float64
    property max_tokens : Int32

    def initialize(
      bus : Bus,
      directory : Directory,
      address : String,
      name : String,
      description : String,
      @provider : Chat::Provider,
      @system_prompt : String = "You are a helpful assistant.",
      @model : String = "",
      @temperature : Float64 = 0.7,
      @max_tokens : Int32 = 1024,
      kind : Directory::Kind = Directory::Kind::Agent,
      schema : JSON::Any? = nil,
      guide : String? = nil,
      tags : Array(String) = [] of String,
    )
      super(bus, directory, address, name, description, kind, schema, guide, tags)
      @conversations = {} of String => Chat::History
    end

    def init
    end

    def handle(envelope : Envelope)
      from = envelope.from
      return if from.empty?

      history = conversation_for(from)

      # Format the incoming message as user content.
      user_content = format_incoming(envelope)
      history.add_user(user_content)
      history.trim_if_needed

      # Build the chat request.
      model = @model.empty? ? "gpt-4o-mini" : @model
      request = Chat::Request.new(
        messages: history.messages,
        model: model,
        temperature: @temperature,
        max_tokens: @max_tokens,
      )

      # Call the LLM.
      response = @provider.complete(request)
      content = response.content || ""

      history.add_assistant(content)

      # Reply on the bus.
      reply_payload = JSON::Any.new({
        "message" => JSON::Any.new(content),
      })
      reply(envelope, reply_payload)
    end

    # Swallow errors and reply with an error message instead of crashing.
    def on_error(envelope : Envelope, error : Exception)
      error_payload = JSON::Any.new({
        "error" => JSON::Any.new(error.message || "Unknown error"),
      })
      reply(envelope, error_payload)
    end

    # Reset conversation history for a correspondent.
    def reset_conversation(address : String)
      @conversations.delete(address)
    end

    # Clear all conversation histories.
    def reset_all
      @conversations.clear
    end

    private def conversation_for(address : String) : Chat::History
      @conversations[address] ||= begin
        h = Chat::History.new
        h.add_system(@system_prompt)
        h
      end
    end

    private def format_incoming(envelope : Envelope) : String
      payload = envelope.payload
      # If payload has a "message" string field, use that directly.
      if msg = payload["message"]?.try(&.as_s?)
        prefix = envelope.subject.empty? ? "" : "[#{envelope.subject}] "
        "#{prefix}#{msg}"
      else
        # Otherwise serialize the whole payload.
        prefix = envelope.subject.empty? ? "" : "Subject: #{envelope.subject}\n"
        "#{prefix}#{payload.to_json}"
      end
    end
  end
end
