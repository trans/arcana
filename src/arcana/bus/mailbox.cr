module Arcana
  # A buffered inbox for a single agent address.
  class Mailbox
    getter address : String

    def initialize(@address : String, capacity : Int32 = 256)
      @channel = Channel(Envelope).new(capacity)
      @count = Atomic(Int32).new(0)
    end

    # Number of messages waiting to be received.
    def pending : Int32
      @count.get
    end

    # Deliver an envelope to this mailbox.
    def deliver(envelope : Envelope)
      @count.add(1)
      @channel.send(envelope)
    end

    # Block until an envelope arrives.
    def receive : Envelope
      msg = @channel.receive
      @count.sub(1)
      msg
    end

    # Block until an envelope arrives or timeout expires.
    # Returns nil on timeout.
    def receive(timeout : Time::Span) : Envelope?
      select
      when msg = @channel.receive
        @count.sub(1)
        msg
      when timeout(timeout)
        nil
      end
    end

    # Non-blocking receive. Returns nil if empty.
    def try_receive : Envelope?
      select
      when msg = @channel.receive
        @count.sub(1)
        msg
      else
        nil
      end
    end
  end
end
