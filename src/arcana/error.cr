module Arcana
  class ConfigError < Error; end

  class APIError < Error
    getter status_code : Int32
    getter response_body : String

    def initialize(@status_code : Int32, @response_body : String, provider : String = "unknown")
      super("#{provider} API error (#{@status_code}): #{@response_body}")
    end
  end
end
