module Arcana
  # A buffered inbox for a single agent address.
  class Mailbox
    getter address : String

    def initialize(@address : String, capacity : Int32 = 256)
      @channel = Channel(Envelope).new(capacity)
    end

    # Deliver an envelope to this mailbox.
    def deliver(envelope : Envelope)
      @channel.send(envelope)
    end

    # Block until an envelope arrives.
    def receive : Envelope
      @channel.receive
    end

    # Block until an envelope arrives or timeout expires.
    # Returns nil on timeout.
    def receive(timeout : Time::Span) : Envelope?
      select
      when msg = @channel.receive
        msg
      when timeout(timeout)
        nil
      end
    end

    # Non-blocking receive. Returns nil if empty.
    def try_receive : Envelope?
      select
      when msg = @channel.receive
        msg
      else
        nil
      end
    end
  end
end
