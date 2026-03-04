module Arcana
  module Image
    struct Request
      property prompt : String
      property width : Int32
      property height : Int32
      property identity : Identity?
      property control : Control?
      property output_format : String  # "WEBP", "PNG"
      property enhance_prompt : Bool   # let provider rewrite prompt
      property trace_tags : Hash(String, String)?  # opaque metadata passed to trace events

      def initialize(
        @prompt : String,
        @width : Int32 = 1024,
        @height : Int32 = 1024,
        @identity : Identity? = nil,
        @control : Control? = nil,
        @output_format : String = "WEBP",
        @enhance_prompt : Bool = false,
        @trace_tags : Hash(String, String)? = nil,
      )
      end
    end
  end
end
