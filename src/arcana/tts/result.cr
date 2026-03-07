module Arcana
  module TTS
    struct Result
      property output_path : String
      property model : String
      property provider : String
      property raw_request : String   # JSON request body sent to API
      property status_code : Int32    # HTTP status
      property content_type : String  # response Content-Type
      property content_length : Int64 # response body size in bytes

      def initialize(
        @output_path : String,
        @model : String = "",
        @provider : String = "",
        @raw_request : String = "",
        @status_code : Int32 = 0,
        @content_type : String = "",
        @content_length : Int64 = 0,
      )
      end
    end
  end
end
