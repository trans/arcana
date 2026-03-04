module Arcana
  module TTS
    struct Result
      property output_path : String
      property model : String
      property provider : String

      def initialize(@output_path : String, @model : String = "", @provider : String = "")
      end
    end
  end
end
