module Arcana
  module Embed
    abstract class Provider
      include Arcana::Traceable

      abstract def embed(request : Request) : Result
      abstract def name : String
    end
  end
end
