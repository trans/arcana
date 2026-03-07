module Arcana
  # Cancellation context for in-flight API requests.
  #
  # Create a context, pass it to `complete`, and call `cancel` from
  # another fiber to abort the request.
  #
  #   ctx = Arcana::Context.new
  #   spawn { sleep 5.seconds; ctx.cancel }
  #   response = provider.complete(request, ctx)
  #
  class Context
    getter? cancelled : Bool = false

    def initialize
      @channel = Channel(Nil).new(1)
    end

    # Cancel the context. Safe to call multiple times.
    def cancel
      return if @cancelled
      @cancelled = true
      @channel.send(nil) rescue nil
    end

    # Block until cancelled or timeout. Returns true if cancelled.
    def wait(timeout : Time::Span) : Bool
      select
      when @channel.receive
        true
      when timeout(timeout)
        false
      end
    end
  end

  class CancelledError < Error
    def initialize(msg = "Request cancelled")
      super(msg)
    end
  end
end
