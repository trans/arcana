module Arcana
  module TTS
    struct Request
      property text : String
      property voice : String
      property model : String
      property response_format : String
      property instructions : String?  # style/persona instructions
      property speed : Float64?        # 0.25-4.0
      property trace_tags : Hash(String, String)?

      def initialize(
        @text : String,
        @voice : String = "alloy",
        @model : String = "gpt-4o-mini-tts",
        @response_format : String = "opus",
        @instructions : String? = nil,
        @speed : Float64? = nil,
        @trace_tags : Hash(String, String)? = nil,
      )
      end
    end
  end
end
