module Arcana
  # OTP-inspired actor base class.
  #
  # Subclass and implement `handle` to process incoming envelopes.
  # Actors register in the Directory, listen on the Bus, and follow
  # the Protocol handshake automatically.
  #
  #   class MyAgent < Arcana::Actor
  #     def init
  #       # setup state
  #     end
  #
  #     def handle(envelope : Arcana::Envelope)
  #       data = extract_data(envelope.payload)
  #       reply(envelope, Protocol.result(JSON::Any.new("done")))
  #     end
  #   end
  #
  #   agent = MyAgent.new(bus, dir, "my-agent", "My Agent", "Does things")
  #   agent.start
  #
  abstract class Actor
    getter address : String
    getter? running : Bool = false

    def initialize(
      @bus : Bus,
      @directory : Directory,
      @address : String,
      @name : String,
      @description : String,
      @kind : Directory::Kind = Directory::Kind::Agent,
      @schema : JSON::Any? = nil,
      @tags : Array(String) = [] of String,
    )
      @mailbox = nil
    end

    @mailbox : Mailbox?

    # -- Lifecycle hooks (override as needed) --

    # Called when the actor starts, before processing messages.
    def init
    end

    # Called when the actor stops.
    def terminate
    end

    # Handle an incoming envelope. Override this.
    abstract def handle(envelope : Envelope)

    # Called when `handle` raises. Default: re-raise (let it crash).
    # Override to swallow errors and keep processing.
    def on_error(envelope : Envelope, error : Exception)
      raise error
    end

    # -- Execution --

    # Register in directory and bus. Called before `run`.
    def register
      @directory.register(Directory::Listing.new(
        address: @address,
        name: @name,
        description: @description,
        kind: @kind,
        schema: @schema,
        tags: @tags,
      ))
      @mailbox = @bus.mailbox(@address)
    end

    # Run the message loop. Blocks until stopped or crashed.
    def run
      init
      mb = @mailbox.not_nil!
      @running = true
      while @running
        envelope = mb.receive
        begin
          handle(envelope)
        rescue ex
          on_error(envelope, ex)
        end
      end
      terminate
    end

    # Start in a new fiber (standalone, unsupervised).
    def start
      register
      spawn { run }
    end

    # Signal the actor to stop after processing the current message.
    def stop
      @running = false
      @directory.unregister(@address)
    end

    # -- Helpers for subclasses --

    # Extract data from a payload, whether protocol-wrapped or raw.
    protected def extract_data(payload : JSON::Any) : JSON::Any
      if Protocol.proto?(payload)
        Protocol.data(payload) || JSON::Any.new(nil)
      else
        payload
      end
    end

    # Send a reply to an envelope, respecting reply_to.
    protected def reply(envelope : Envelope, payload : JSON::Any)
      to = envelope.reply_to || envelope.from
      return if to.empty?
      @bus.send?(Envelope.new(
        from: @address,
        to: to,
        subject: envelope.subject,
        payload: payload,
        correlation_id: envelope.correlation_id,
      ))
    end
  end
end
