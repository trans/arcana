require "http/client"
require "json"

module Arcana
  module TTS
    class ElevenLabs < Provider
      ENDPOINT = "https://api.elevenlabs.io/v1/text-to-speech"
      DEFAULT_MODEL = "eleven_multilingual_v2"
      DEFAULT_VOICE = "JBFqnCBsd6RMkjVDRZzb"  # "George" — a built-in voice

      MODELS = %w(
        eleven_monolingual_v1
        eleven_multilingual_v1
        eleven_multilingual_v2
        eleven_turbo_v2
        eleven_turbo_v2_5
        eleven_flash_v2
        eleven_flash_v2_5
      )

      getter model : String

      def initialize(
        @api_key : String,
        @model : String = DEFAULT_MODEL,
        @voice_id : String = DEFAULT_VOICE,
        @endpoint : String = ENDPOINT,
        trace : Proc(String, Nil)? = nil,
      )
        raise ConfigError.new("API key is required for ElevenLabs TTS") if @api_key.strip.empty?
        @trace = trace
      end

      def name : String
        "elevenlabs"
      end

      def synthesize(request : Request, output_path : String) : Result
        model = request.model.empty? ? @model : request.model
        voice_id = request.voice.empty? ? @voice_id : request.voice
        payload = build_payload(request, model)
        output_format = format_param(request.response_format)

        emit_request_trace(request, model, voice_id)

        response = post_api(voice_id, payload, output_format)

        emit_response_trace(request, response)

        unless response.success?
          raise APIError.new(response.status_code, response.body, "elevenlabs:tts")
        end

        File.open(output_path, "wb") do |file|
          file.write(response.body.to_slice)
        end

        Result.new(output_path, model, "elevenlabs",
          raw_request: payload,
          status_code: response.status_code,
          content_type: response.headers["Content-Type"]? || "",
          content_length: response.body.bytesize.to_i64)
      end

      def stream(request : Request, ctx : Context? = nil, &block : Bytes ->) : Result
        raise CancelledError.new if ctx.try(&.cancelled?)

        model = request.model.empty? ? @model : request.model
        voice_id = request.voice.empty? ? @voice_id : request.voice
        payload = build_payload(request, model)
        output_format = format_param(request.response_format)
        headers = api_headers

        uri = URI.parse("#{@endpoint}/#{voice_id}/stream?output_format=#{output_format}")
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
              raise APIError.new(response.status_code, body, "elevenlabs:tts:stream")
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
          provider: "elevenlabs",
          raw_request: payload,
          status_code: 200,
          content_type: content_type,
          content_length: total_bytes,
        )
      end

      private def build_payload(request : Request, model : String) : String
        JSON.build do |json|
          json.object do
            json.field "text", request.text
            json.field "model_id", model
            if previous = request.previous_text
              json.field "previous_text", previous
            end
            if nxt = request.next_text
              json.field "next_text", nxt
            end
            if instructions = request.instructions
              json.field "voice_settings" do
                json.object do
                  json.field "stability", 0.5
                  json.field "similarity_boost", 0.75
                end
              end
            end
          end
        end
      end

      private def post_api(voice_id : String, payload : String, output_format : String) : HTTP::Client::Response
        headers = api_headers
        uri = URI.parse("#{@endpoint}/#{voice_id}?output_format=#{output_format}")
        client = HTTP::Client.new(uri)
        client.connect_timeout = 30.seconds
        client.read_timeout = 60.seconds
        client.post(uri.request_target, headers: headers, body: payload)
      end

      private def api_headers : HTTP::Headers
        HTTP::Headers{
          "xi-api-key"   => @api_key,
          "Content-Type" => "application/json",
        }
      end

      # Map Arcana format names to ElevenLabs output_format param.
      private def format_param(format : String) : String
        case format.downcase
        when "mp3"  then "mp3_44100_128"
        when "wav"  then "pcm_44100"
        when "pcm"  then "pcm_44100"
        when "opus" then "mp3_44100_128" # ElevenLabs doesn't support opus, fallback to mp3
        else             "mp3_44100_128"
        end
      end

      private def emit_request_trace(request : Request, model : String, voice_id : String) : Nil
        tags = request.trace_tags || {} of String => String
        emit_trace({
          phase:      "api_request_tts",
          event_type: "api_request",
          provider:   "elevenlabs",
          endpoint:   @endpoint,
          model:      model,
          voice:      voice_id,
          tags:       tags.to_json,
        })
      end

      private def emit_response_trace(request : Request, response : HTTP::Client::Response) : Nil
        tags = request.trace_tags || {} of String => String
        emit_trace({
          phase:          "api_response_tts",
          event_type:     "api_response",
          provider:       "elevenlabs",
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
