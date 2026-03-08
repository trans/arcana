require "http/client"
require "json"

module Arcana
  module Embed
    class Voyage < Provider
      ENDPOINT = "https://api.voyageai.com/v1/embeddings"

      getter model : String

      def initialize(
        @api_key : String,
        @model : String = "voyage-3",
        @endpoint : String = ENDPOINT,
        trace : Proc(String, Nil)? = nil,
      )
        raise ConfigError.new("API key is required for Voyage Embed") if @api_key.strip.empty?
        @trace = trace
      end

      def name : String
        "voyage"
      end

      def embed(request : Request) : Result
        model = request.model.empty? ? @model : request.model

        json_payload = build_payload(model, request)

        tags = request.trace_tags || {} of String => String
        emit_trace({
          phase:      "api_request_embed",
          event_type: "api_request",
          provider:   "voyage",
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
        response = client.post(uri.request_target, headers: headers, body: json_payload)

        emit_trace({
          phase:          "api_response_embed",
          event_type:     "api_response",
          provider:       "voyage",
          endpoint:       @endpoint,
          status_code:    response.status_code,
          content_length: response.headers["Content-Length"]? || "",
          tags:           tags.to_json,
        })

        unless response.success?
          raise APIError.new(response.status_code, extract_error(response.body), "voyage:embed")
        end

        parse_response(response.body, model, json_payload)
      end

      private def build_payload(model : String, request : Request) : String
        payload = Hash(String, JSON::Any).new
        payload["model"] = JSON::Any.new(model)
        payload["input"] = JSON::Any.new(request.texts.map { |t| JSON::Any.new(t) })

        if input_type = request.input_type
          payload["input_type"] = JSON::Any.new(input_type)
        end

        if dims = request.dimensions
          payload["output_dimension"] = JSON::Any.new(dims.to_i64)
        end

        payload.to_json
      end

      private def parse_response(body : String, model : String, payload : String) : Result
        parsed = JSON.parse(body)

        data = parsed["data"].as_a.sort_by { |d| d["index"].as_i }
        embeddings = data.map { |d| d["embedding"].as_a.map(&.as_f) }

        usage = parsed["usage"]?
        total_tokens = usage.try { |u| u["total_tokens"]?.try(&.as_i?) } || 0

        # Distribute total tokens evenly across inputs.
        count = embeddings.size
        avg = count > 0 ? total_tokens // count : 0
        token_counts = Array.new(count, avg)

        Result.new(
          embeddings: embeddings,
          token_counts: token_counts,
          total_tokens: total_tokens,
          model: model,
          provider: "voyage",
          raw_request: payload,
          raw_response: body,
        )
      end

      # Voyage returns errors as {"detail": "..."} or {"error": {"message": "..."}}.
      private def extract_error(body : String) : String
        parsed = JSON.parse(body)
        parsed["detail"]?.try(&.as_s?) ||
          parsed["error"]?.try { |e| e["message"]?.try(&.as_s?) } ||
          body
      rescue
        body
      end
    end
  end
end
