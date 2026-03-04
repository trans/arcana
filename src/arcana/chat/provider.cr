module Arcana
  module Chat
    abstract class Provider
      include Arcana::Traceable

      abstract def complete(request : Request) : Response
      abstract def name : String
    end
  end
end
