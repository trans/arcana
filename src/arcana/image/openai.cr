require "base64"
require "http/client"
require "json"

module Arcana
  module Image
    class OpenAI < Provider
      GENERATIONS_ENDPOINT = "https://api.openai.com/v1/images/generations"
      EDITS_ENDPOINT       = "https://api.openai.com/v1/images/edits"

      getter model : String
      getter quality : String

      def initialize(
        @api_key : String,
        @model : String = "gpt-image-1",
        @quality : String = "medium",
        trace : Proc(String, Nil)? = nil,
      )
        raise ConfigError.new("API key is required for OpenAI image generation") if @api_key.strip.empty?
        @trace = trace
      end

      def name : String
        "openai"
      end

      def generate(request : Request, output_path : String) : Result
        raise ConfigError.new("Image prompt cannot be empty") if request.prompt.strip.empty?

        # OpenAI only supports seed_image identity (via edits endpoint).
        # ACE++, PuLID, ControlNet are ignored — OpenAI doesn't support them.
        use_edit = false
        if id = request.identity
          if id.method.seed_image? && File.exists?(id.reference_path)
            use_edit = true
          end
        end

        size = "#{request.width}x#{request.height}"
        tags = request.trace_tags || {} of String => String

        if use_edit
          request_image_edit(request, size, output_path, tags)
        else
          request_image(request, size, output_path, tags)
        end

        Result.new(output_path, @model, "openai")
      end

      private def request_image(request : Request, size : String, output_path : String,
                                tags : Hash(String, String)) : Nil
        payload = {
          model:   @model,
          prompt:  request.prompt,
          n:       1,
          size:    size,
          quality: @quality,
        }.to_json

        emit_trace({
          phase:      "api_request_image",
          event_type: "api_request",
          provider:   "openai",
          endpoint:   GENERATIONS_ENDPOINT,
          model:      @model,
          quality:    @quality,
          size:       size,
          tags:       tags.to_json,
        })

        headers = Util.bearer_headers(@api_key)
        response = HTTP::Client.post(GENERATIONS_ENDPOINT, headers: headers, body: payload)

        emit_trace({
          phase:          "api_response_image",
          event_type:     "api_response",
          provider:       "openai",
          endpoint:       GENERATIONS_ENDPOINT,
          status_code:    response.status_code,
          content_type:   response.headers["Content-Type"]? || "",
          content_length: response.headers["Content-Length"]? || "",
          tags:           tags.to_json,
        })

        unless response.success?
          raise APIError.new(response.status_code, response.body, "openai")
        end

        parsed = JSON.parse(response.body)
        b64_data = parsed["data"][0]["b64_json"].as_s
        File.write(output_path, Base64.decode(b64_data))
      end

      private def request_image_edit(request : Request, size : String, output_path : String,
                                     tags : Hash(String, String)) : Nil
        id = request.identity.not_nil!

        emit_trace({
          phase:      "api_request_image_edit",
          event_type: "api_request",
          provider:   "openai",
          endpoint:   EDITS_ENDPOINT,
          model:      @model,
          quality:    @quality,
          size:       size,
          tags:       tags.to_json,
        })

        ref_mime = Util.mime_for(id.reference_path)
        ref_ext = File.extname(id.reference_path).lchop('.')

        mp = Util::MultipartBuilder.new
        mp.add_file("image[]", id.reference_path, "reference.#{ref_ext}", ref_mime)
        mp.add_field("prompt", request.prompt)
        mp.add_field("model", @model)
        mp.add_field("size", size)
        mp.add_field("quality", @quality)
        mp.add_field("n", "1")

        headers = HTTP::Headers{
          "Authorization" => "Bearer #{@api_key}",
          "Content-Type"  => mp.content_type,
        }

        response = HTTP::Client.post(EDITS_ENDPOINT, headers: headers, body: mp.to_s)

        emit_trace({
          phase:          "api_response_image_edit",
          event_type:     "api_response",
          provider:       "openai",
          endpoint:       EDITS_ENDPOINT,
          status_code:    response.status_code,
          content_type:   response.headers["Content-Type"]? || "",
          content_length: response.headers["Content-Length"]? || "",
          tags:           tags.to_json,
        })

        unless response.success?
          raise APIError.new(response.status_code, response.body, "openai")
        end

        parsed = JSON.parse(response.body)
        b64_data = parsed["data"][0]["b64_json"].as_s
        File.write(output_path, Base64.decode(b64_data))
      end
    end
  end
end
