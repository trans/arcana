module Arcana
  module Chat
    abstract class Provider
      include Arcana::Traceable

      abstract def complete(request : Request) : Response
      abstract def name : String

      # Complete with cancellation support. Override for real mid-flight abort.
      def complete(request : Request, ctx : Context) : Response
        raise CancelledError.new if ctx.cancelled?
        complete(request)
      end

      # Stream a chat completion, yielding events as they arrive.
      # Override in subclasses that support streaming.
      def stream(request : Request, ctx : Context? = nil, &block : StreamEvent ->) : Response
        raise Error.new("Streaming not supported by #{name} provider")
      end

      # List available models. Override in subclasses that support it.
      def models : Array(String)
        [] of String
      end
    end
  end
end
