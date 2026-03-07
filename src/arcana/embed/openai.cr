require "http/client"
require "json"

module Arcana
  module Embed
    class OpenAI < Provider
      ENDPOINT = "https://api.openai.com/v1/embeddings"

      getter model : String

      def initialize(
        @api_key : String,
        @model : String = "text-embedding-3-small",
        @endpoint : String = ENDPOINT,
        trace : Proc(String, Nil)? = nil,
      )
        raise ConfigError.new("API key is required for OpenAI Embed") if @api_key.strip.empty?
        @trace = trace
      end

      def name : String
        "openai"
      end

      def embed(request : Request) : Result
        model = request.model.empty? ? @model : request.model

        payload = {
          model:           model,
          input:           request.texts,
          encoding_format: "float",
        }.to_json

        tags = request.trace_tags || {} of String => String
        emit_trace({
          phase:      "api_request_embed",
          event_type: "api_request",
          provider:   "openai",
          endpoint:   @endpoint,
          model:      model,
          count:      request.texts.size,
          tags:       tags.to_json,
        })

        headers = Util.bearer_headers(@api_key)
        uri = URI.parse(@endpoint)
        client = HTTP::Client.new(uri)
        client.connect_timeout = 30.seconds
        client.read_timeout = 120.seconds
        response = client.post(uri.request_target, headers: headers, body: payload)

        emit_trace({
          phase:          "api_response_embed",
          event_type:     "api_response",
          provider:       "openai",
          endpoint:       @endpoint,
          status_code:    response.status_code,
          content_length: response.headers["Content-Length"]? || "",
          tags:           tags.to_json,
        })

        unless response.success?
          raise APIError.new(response.status_code, response.body, "openai:embed")
        end

        parse_response(response.body, model, payload)
      end

      private def parse_response(body : String, model : String, payload : String) : Result
        parsed = JSON.parse(body)

        data = parsed["data"].as_a.sort_by { |d| d["index"].as_i }
        embeddings = data.map { |d| d["embedding"].as_a.map(&.as_f) }

        usage = parsed["usage"]?
        total_tokens = usage.try { |u| u["total_tokens"]?.try(&.as_i?) } || 0

        # Distribute total tokens evenly across inputs (API doesn't give per-text counts).
        count = embeddings.size
        avg = count > 0 ? total_tokens // count : 0
        token_counts = Array.new(count, avg)

        Result.new(
          embeddings: embeddings,
          token_counts: token_counts,
          total_tokens: total_tokens,
          model: model,
          provider: "openai",
          raw_request: payload,
          raw_response: body,
        )
      end
    end
  end
end
