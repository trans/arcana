module Arcana
  module Image
    struct Result
      property output_path : String
      property cost : Float64?
      property model : String
      property provider : String      # "runware", "openai"
      property raw_request : String   # JSON request body sent to API
      property raw_response : String  # JSON response body (or status info for binary)

      def initialize(
        @output_path : String,
        @model : String,
        @provider : String,
        @cost : Float64? = nil,
        @raw_request : String = "",
        @raw_response : String = "",
      )
      end
    end
  end
end
