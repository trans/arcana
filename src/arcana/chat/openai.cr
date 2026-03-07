require "http/client"
require "json"

module Arcana
  module Chat
    class OpenAI < Provider
      ENDPOINT = "https://api.openai.com/v1/chat/completions"

      getter model : String

      def initialize(
        @api_key : String,
        @model : String = "gpt-4o-mini",
        @endpoint : String = ENDPOINT,
        trace : Proc(String, Nil)? = nil,
      )
        raise ConfigError.new("API key is required for OpenAI Chat") if @api_key.strip.empty?
        @trace = trace
      end

      def name : String
        "openai"
      end

      def models : Array(String)
        uri = URI.parse(@endpoint)
        models_uri = URI.new(scheme: uri.scheme, host: uri.host, port: uri.port, path: "/v1/models")
        headers = Util.bearer_headers(@api_key)
        response = HTTP::Client.get(models_uri, headers: headers)
        return [] of String unless response.success?
        parsed = JSON.parse(response.body)
        data = parsed["data"]?.try(&.as_a?) || return [] of String
        data.compact_map { |m| m["id"]?.try(&.as_s?) }.sort
      rescue
        [] of String
      end

      def complete(request : Request) : Response
        model = request.model.empty? ? @model : request.model
        payload = build_payload(request, model)

        emit_request_trace(request, model, payload)

        response = post_api(payload)

        emit_response_trace(request, response)

        unless response.success?
          raise APIError.new(response.status_code, response.body, "openai:chat")
        end

        result = Response.from_openai_json(response.body, provider: "openai")
        result.raw_request = payload
        result
      end

      private def build_payload(request : Request, model : String) : String
        JSON.build do |json|
          json.object do
            json.field "model", model
            json.field "messages" do
              json.array do
                request.messages.each(&.to_json(json))
              end
            end
            json.field "temperature", request.temperature
            json.field "max_tokens", request.max_tokens

            if tools = request.tools
              json.field "tools" do
                json.array do
                  tools.each(&.to_json(json))
                end
              end
              json.field "tool_choice", request.tool_choice || "auto"
            end
          end
        end
      end

      private def post_api(payload : String) : HTTP::Client::Response
        headers = Util.bearer_headers(@api_key)
        uri = URI.parse(@endpoint)
        client = HTTP::Client.new(uri)
        client.connect_timeout = 30.seconds
        client.read_timeout = 120.seconds
        client.post(uri.request_target, headers: headers, body: payload)
      end

      private def emit_request_trace(request : Request, model : String, payload : String) : Nil
        tags = request.trace_tags || {} of String => String
        emit_trace({
          phase:      "api_request_chat",
          event_type: "api_request",
          provider:   "openai",
          endpoint:   @endpoint,
          model:      model,
          tags:       tags.to_json,
        })
      end

      private def emit_response_trace(request : Request, response : HTTP::Client::Response) : Nil
        tags = request.trace_tags || {} of String => String
        emit_trace({
          phase:          "api_response_chat",
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
