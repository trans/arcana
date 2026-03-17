module Arcana
  # A buffered inbox for a single agent address.
  #
  # Backed by a Deque (not a Channel) so messages can be inspected
  # without consuming them and selectively received by id.
  class Mailbox
    getter address : String

    def initialize(@address : String)
      @messages = Deque(Envelope).new
      @mutex = Mutex.new
      @signal = Channel(Nil).new(1) # buffered signal for wake-ups
    end

    # Number of messages waiting to be received.
    def pending : Int32
      @mutex.synchronize { @messages.size }
    end

    # Deliver an envelope to this mailbox.
    def deliver(envelope : Envelope)
      @mutex.synchronize { @messages.push(envelope) }
      # Wake any blocking receiver (non-blocking send, ok if buffer full)
      select
      when @signal.send(nil)
      else
      end
    end

    # Non-destructive listing of message metadata.
    def inbox : Array(NamedTuple(correlation_id: String, from: String, subject: String, timestamp: Time))
      @mutex.synchronize do
        @messages.map do |env|
          {correlation_id: env.correlation_id, from: env.from, subject: env.subject, timestamp: env.timestamp}
        end
      end
    end

    # Block until an envelope arrives.
    def receive : Envelope
      loop do
        msg = try_receive
        return msg if msg
        @signal.receive
      end
    end

    # Block until an envelope arrives or timeout expires.
    # Returns nil on timeout.
    def receive(timeout : Time::Span) : Envelope?
      deadline = Time.instant + timeout
      loop do
        msg = try_receive
        return msg if msg
        remaining = deadline - Time.instant
        return nil if remaining <= Time::Span.zero
        select
        when @signal.receive
          # woken up, loop back to check deque
        when timeout(remaining)
          return try_receive # one last try
        end
      end
    end

    # Receive a specific message by correlation_id. Returns nil if not found.
    def receive(id : String) : Envelope?
      @mutex.synchronize do
        idx = @messages.index { |env| env.correlation_id == id }
        if idx
          @messages.delete_at(idx)
        end
      end
    end

    # Non-blocking receive. Returns nil if empty.
    def try_receive : Envelope?
      @mutex.synchronize do
        @messages.shift?
      end
    end
  end
end
