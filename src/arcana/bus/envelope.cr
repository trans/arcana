require "json"

module Arcana
  # A message passed between agents via the Bus.
  struct Envelope
    property from : String
    property to : String
    property subject : String
    property payload : JSON::Any
    property correlation_id : String
    property reply_to : String?
    property timestamp : Time

    def initialize(
      @from : String,
      @to : String = "",
      @subject : String = "",
      @payload : JSON::Any = JSON::Any.new(nil),
      @correlation_id : String = Random::Secure.hex(8),
      @reply_to : String? = nil,
      @timestamp : Time = Time.utc,
    )
    end

    # Create a reply to this envelope.
    def reply(from : String, payload : JSON::Any, subject : String? = nil) : Envelope
      Envelope.new(
        from: from,
        to: @reply_to || @from,
        subject: subject || @subject,
        payload: payload,
        correlation_id: @correlation_id,
      )
    end
  end
end
