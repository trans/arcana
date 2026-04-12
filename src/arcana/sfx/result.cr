module Arcana
  module SFX
    struct Result
      property output_path : String
      property provider : String
      property raw_request : String
      property status_code : Int32
      property content_type : String
      property content_length : Int64

      def initialize(
        @output_path : String,
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
