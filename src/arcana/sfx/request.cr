module Arcana
  module SFX
    struct Request
      property text : String
      property duration_seconds : Float64?
      property prompt_influence : Float64?
      property trace_tags : Hash(String, String)?

      def initialize(
        @text : String,
        @duration_seconds : Float64? = nil,
        @prompt_influence : Float64? = nil,
        @trace_tags : Hash(String, String)? = nil,
      )
      end
    end
  end
end
