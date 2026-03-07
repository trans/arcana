module Arcana
  # Central message router for agent-to-agent communication.
  #
  # Supports direct delivery (send) and fan-out (publish/subscribe).
  #
  #   bus = Arcana::Bus.new
  #   writer = bus.mailbox("writer")
  #   artist = bus.mailbox("artist")
  #
  #   bus.subscribe("image:ready", "writer")
  #
  #   # Direct message
  #   bus.send(Envelope.new(from: "writer", to: "artist", subject: "generate", payload: ...))
  #
  #   # Topic broadcast
  #   bus.publish("image:ready", Envelope.new(from: "artist", payload: ...))
  #
  class Bus
    @mailboxes = {} of String => Mailbox
    @subscriptions = {} of String => Set(String)
    @mutex = Mutex.new

    # Get or create a mailbox for an address.
    def mailbox(address : String, capacity : Int32 = 256) : Mailbox
      @mutex.synchronize do
        @mailboxes[address] ||= Mailbox.new(address, capacity)
      end
    end

    # Does a mailbox exist for this address?
    def has_mailbox?(address : String) : Bool
      @mutex.synchronize { @mailboxes.has_key?(address) }
    end

    # Remove a mailbox. Messages in flight are lost.
    def remove_mailbox(address : String)
      @mutex.synchronize { @mailboxes.delete(address) }
    end

    # List all registered addresses.
    def addresses : Array(String)
      @mutex.synchronize { @mailboxes.keys.sort }
    end

    # -- Direct delivery --

    # Send an envelope to its `to` address.
    def send(envelope : Envelope)
      mb = @mutex.synchronize { @mailboxes[envelope.to]? }
      raise Error.new("No mailbox for address: #{envelope.to}") unless mb
      mb.deliver(envelope)
    end

    # Send, but silently drop if the target mailbox doesn't exist.
    def send?(envelope : Envelope) : Bool
      mb = @mutex.synchronize { @mailboxes[envelope.to]? }
      return false unless mb
      mb.deliver(envelope)
      true
    end

    # -- Pub/Sub --

    # Subscribe an address to a topic.
    def subscribe(topic : String, address : String)
      @mutex.synchronize do
        (@subscriptions[topic] ||= Set(String).new) << address
      end
    end

    # Unsubscribe an address from a topic.
    def unsubscribe(topic : String, address : String)
      @mutex.synchronize do
        @subscriptions[topic]?.try(&.delete(address))
      end
    end

    # List topics an address is subscribed to.
    def subscriptions(address : String) : Array(String)
      @mutex.synchronize do
        @subscriptions.compact_map do |topic, addrs|
          topic if addrs.includes?(address)
        end
      end
    end

    # List subscribers for a topic.
    def subscribers(topic : String) : Array(String)
      @mutex.synchronize do
        @subscriptions[topic]?.try(&.to_a.sort) || [] of String
      end
    end

    # Publish an envelope to all subscribers of a topic.
    # The envelope's `to` is set to each subscriber's address on delivery.
    def publish(topic : String, envelope : Envelope)
      subs = @mutex.synchronize { @subscriptions[topic]?.try(&.dup) }
      return unless subs

      subs.each do |address|
        mb = @mutex.synchronize { @mailboxes[address]? }
        next unless mb
        msg = Envelope.new(
          from: envelope.from,
          to: address,
          subject: envelope.subject.empty? ? topic : envelope.subject,
          payload: envelope.payload,
          correlation_id: envelope.correlation_id,
          reply_to: envelope.reply_to,
        )
        mb.deliver(msg)
      end
    end

    # -- Request/Response --

    # Send an envelope and wait for a reply. Creates a temporary reply
    # mailbox, sets reply_to, and blocks until a response arrives or
    # the timeout expires. The reply mailbox is cleaned up automatically.
    def request(envelope : Envelope, timeout : Time::Span = 30.seconds) : Envelope?
      reply_address = "_reply:#{envelope.correlation_id}"
      reply_mb = mailbox(reply_address)

      msg = Envelope.new(
        from: envelope.from,
        to: envelope.to,
        subject: envelope.subject,
        payload: envelope.payload,
        correlation_id: envelope.correlation_id,
        reply_to: reply_address,
      )

      send(msg)
      result = reply_mb.receive(timeout)
      remove_mailbox(reply_address)
      result
    end
  end
end
