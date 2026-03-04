module Arcana
  module Image
    struct Result
      property output_path : String
      property cost : Float64?
      property model : String
      property provider : String  # "runware", "openai"

      def initialize(
        @output_path : String,
        @model : String,
        @provider : String,
        @cost : Float64? = nil,
      )
      end
    end
  end
end
