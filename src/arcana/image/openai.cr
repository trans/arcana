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

        raw_req, raw_resp = if use_edit
          request_image_edit(request, size, output_path, tags)
        else
          request_image(request, size, output_path, tags)
        end

        Result.new(output_path, @model, "openai",
          raw_request: raw_req, raw_response: raw_resp)
      end

      private def request_image(request : Request, size : String, output_path : String,
                                tags : Hash(String, String)) : {String, String}
        payload = {
          model:   @model,
          prompt:  request.prompt,
          n:       1,
          size:    size,
          quality: @quality,
        }.to_json

        headers = Util.bearer_headers(@api_key)
        response = HTTP::Client.post(GENERATIONS_ENDPOINT, headers: headers, body: payload)

        unless response.success?
          raise APIError.new(response.status_code, response.body, "openai")
        end

        parsed = JSON.parse(response.body)
        b64_data = parsed["data"][0]["b64_json"].as_s
        File.write(output_path, Base64.decode(b64_data))

        # Strip b64 data from response log (huge) — keep metadata only
        resp_summary = {status: response.status_code, model: @model, size: size}.to_json
        {payload, resp_summary}
      end

      private def request_image_edit(request : Request, size : String, output_path : String,
                                     tags : Hash(String, String)) : {String, String}
        id = request.identity.not_nil!

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

        unless response.success?
          raise APIError.new(response.status_code, response.body, "openai")
        end

        parsed = JSON.parse(response.body)
        b64_data = parsed["data"][0]["b64_json"].as_s
        File.write(output_path, Base64.decode(b64_data))

        # Log multipart fields (not binary data) as the request
        req_summary = {endpoint: EDITS_ENDPOINT, model: @model, prompt: request.prompt, size: size,
                       quality: @quality, reference: id.reference_path}.to_json
        resp_summary = {status: response.status_code, model: @model, size: size}.to_json
        {req_summary, resp_summary}
      end
    end
  end
end
