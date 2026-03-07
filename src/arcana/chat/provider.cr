module Arcana
  module Chat
    abstract class Provider
      include Arcana::Traceable

      abstract def complete(request : Request) : Response
      abstract def name : String

      # List available models. Override in subclasses that support it.
      def models : Array(String)
        [] of String
      end
    end
  end
end
