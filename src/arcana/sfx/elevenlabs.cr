require "http/client"
require "json"

module Arcana
  module SFX
    class ElevenLabs < Provider
      ENDPOINT = "https://api.elevenlabs.io/v1/sound-generation"

      def initialize(
        @api_key : String,
        @endpoint : String = ENDPOINT,
        trace : Proc(String, Nil)? = nil,
      )
        raise ConfigError.new("API key is required for ElevenLabs SFX") if @api_key.strip.empty?
        @trace = trace
      end

      def name : String
        "elevenlabs"
      end

      def generate(request : Request, output_path : String) : Result
        payload = build_payload(request)

        emit_request_trace(request)

        response = post_api(payload)

        emit_response_trace(response)

        unless response.success?
          raise APIError.new(response.status_code, response.body, "elevenlabs:sfx")
        end

        File.open(output_path, "wb") do |file|
          file.write(response.body.to_slice)
        end

        Result.new(output_path, "elevenlabs",
          raw_request: payload,
          status_code: response.status_code,
          content_type: response.headers["Content-Type"]? || "",
          content_length: response.body.bytesize.to_i64)
      end

      private def build_payload(request : Request) : String
        JSON.build do |json|
          json.object do
            json.field "text", request.text
            if duration = request.duration_seconds
              json.field "duration_seconds", duration
            end
            if influence = request.prompt_influence
              json.field "prompt_influence", influence
            end
          end
        end
      end

      private def post_api(payload : String) : HTTP::Client::Response
        headers = api_headers
        uri = URI.parse(@endpoint)
        client = HTTP::Client.new(uri)
        client.connect_timeout = 30.seconds
        client.read_timeout = 120.seconds
        client.post(uri.request_target, headers: headers, body: payload)
      end

      private def api_headers : HTTP::Headers
        HTTP::Headers{
          "xi-api-key"   => @api_key,
          "Content-Type" => "application/json",
        }
      end

      private def emit_request_trace(request : Request) : Nil
        tags = request.trace_tags || {} of String => String
        emit_trace({
          phase:      "api_request_sfx",
          event_type: "api_request",
          provider:   "elevenlabs",
          endpoint:   @endpoint,
          tags:       tags.to_json,
        })
      end

      private def emit_response_trace(response : HTTP::Client::Response) : Nil
        emit_trace({
          phase:          "api_response_sfx",
          event_type:     "api_response",
          provider:       "elevenlabs",
          endpoint:       @endpoint,
          status_code:    response.status_code,
          content_type:   response.headers["Content-Type"]? || "",
          content_length: response.headers["Content-Length"]? || "",
        })
      end
    end
  end
end
