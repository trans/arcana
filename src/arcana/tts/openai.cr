require "http/client"
require "json"

module Arcana
  module TTS
    class OpenAI < Provider
      ENDPOINT = "https://api.openai.com/v1/audio/speech"

      getter model : String

      def initialize(
        @api_key : String,
        @model : String = "gpt-4o-mini-tts",
        @endpoint : String = ENDPOINT,
        trace : Proc(String, Nil)? = nil,
      )
        raise ConfigError.new("API key is required for OpenAI TTS") if @api_key.strip.empty?
        @trace = trace
      end

      def name : String
        "openai"
      end

      def synthesize(request : Request, output_path : String) : Result
        model = request.model.empty? ? @model : request.model
        payload = build_payload(request, model)

        emit_request_trace(request, model)

        response = post_api(payload)

        emit_response_trace(request, response)

        unless response.success?
          raise APIError.new(response.status_code, response.body, "openai:tts")
        end

        File.open(output_path, "wb") do |file|
          file.write(response.body.to_slice)
        end

        Result.new(output_path, model, "openai",
          raw_request: payload,
          status_code: response.status_code,
          content_type: response.headers["Content-Type"]? || "",
          content_length: response.body.bytesize.to_i64)
      end

      def stream(request : Request, ctx : Context? = nil, &block : Bytes ->) : Result
        raise CancelledError.new if ctx.try(&.cancelled?)

        model = request.model.empty? ? @model : request.model
        payload = build_payload(request, model)
        headers = Util.bearer_headers(@api_key)
        uri = URI.parse(@endpoint)
        client = HTTP::Client.new(uri)
        client.connect_timeout = 30.seconds
        client.read_timeout = 60.seconds

        if c = ctx
          spawn do
            until c.cancelled?
              sleep 100.milliseconds
            end
            client.close rescue nil
          end
        end

        total_bytes = 0_i64
        content_type = ""

        begin
          client.post(uri.request_target, headers: headers, body: payload) do |response|
            unless response.success?
              body = response.body_io.gets_to_end
              raise APIError.new(response.status_code, body, "openai:tts:stream")
            end

            content_type = response.headers["Content-Type"]? || ""
            buf = Bytes.new(8192)

            while (bytes_read = response.body_io.read(buf)) > 0
              raise CancelledError.new if ctx.try(&.cancelled?)
              chunk = buf[0, bytes_read]
              total_bytes += bytes_read
              block.call(chunk)
            end
          end
        rescue ex : CancelledError
          raise ex
        rescue ex : IO::Error
          raise CancelledError.new if ctx.try(&.cancelled?)
          raise ex
        end

        Result.new("",
          model: model,
          provider: "openai",
          raw_request: payload,
          status_code: 200,
          content_type: content_type,
          content_length: total_bytes,
        )
      end

      private def build_payload(request : Request, model : String) : String
        JSON.build do |json|
          json.object do
            json.field "model", model
            json.field "voice", request.voice
            json.field "input", request.text.strip + "\n\n"
            json.field "response_format", request.response_format
            if instructions = request.instructions
              json.field "instructions", instructions
            end
            if speed = request.speed
              json.field "speed", speed
            end
          end
        end
      end

      private def post_api(payload : String) : HTTP::Client::Response
        headers = Util.bearer_headers(@api_key)
        uri = URI.parse(@endpoint)
        client = HTTP::Client.new(uri)
        client.connect_timeout = 30.seconds
        client.read_timeout = 60.seconds
        client.post(uri.request_target, headers: headers, body: payload)
      end

      private def emit_request_trace(request : Request, model : String) : Nil
        tags = request.trace_tags || {} of String => String
        emit_trace({
          phase:           "api_request_tts",
          event_type:      "api_request",
          provider:        "openai",
          endpoint:        @endpoint,
          model:           model,
          voice:           request.voice,
          response_format: request.response_format,
          tags:            tags.to_json,
        })
      end

      private def emit_response_trace(request : Request, response : HTTP::Client::Response) : Nil
        tags = request.trace_tags || {} of String => String
        emit_trace({
          phase:          "api_response_tts",
          event_type:     "api_response",
          provider:       "openai",
          endpoint:       @endpoint,
          status_code:    response.status_code,
          content_type:   response.headers["Content-Type"]? || "",
          content_length: response.headers["Content-Length"]? || "",
          tags:           tags.to_json,
        })
      end
    end
  end
end
