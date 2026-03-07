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

      def stream(request : Request, ctx : Context? = nil, &block : StreamEvent ->) : Response
        raise CancelledError.new if ctx.try(&.cancelled?)

        model = request.model.empty? ? @model : request.model
        payload = build_payload(request, model, stream: true)
        headers = Util.bearer_headers(@api_key)
        uri = URI.parse(@endpoint)
        client = HTTP::Client.new(uri)
        client.connect_timeout = 30.seconds
        client.read_timeout = 120.seconds

        if c = ctx
          spawn do
            until c.cancelled?
              sleep 100.milliseconds
            end
            client.close rescue nil
          end
        end

        content = String::Builder.new
        tool_calls_map = {} of Int32 => {id: String, name: String, arguments: String::Builder}
        response_model = ""
        finish_reason = ""
        prompt_tokens = 0
        completion_tokens = 0

        begin
          client.post(uri.request_target, headers: headers, body: payload) do |response|
            unless response.success?
              body = response.body_io.gets_to_end
              raise APIError.new(response.status_code, body, "openai:chat:stream")
            end

            response.body_io.each_line do |line|
              raise CancelledError.new if ctx.try(&.cancelled?)

              next unless line.starts_with?("data: ")
              data = line[6..]
              next if data == "[DONE]"

              parsed = JSON.parse(data) rescue next

              if m = parsed["model"]?.try(&.as_s?)
                response_model = m
              end

              if choices = parsed["choices"]?.try(&.as_a?)
                choice = choices[0]?
                next unless choice

                if fr = choice["finish_reason"]?.try(&.as_s?)
                  finish_reason = fr
                end

                if delta = choice["delta"]?
                  # Text content
                  if text = delta["content"]?.try(&.as_s?)
                    content << text
                    block.call(StreamEvent.text_delta(text))
                  end

                  # Tool calls
                  if tcs = delta["tool_calls"]?.try(&.as_a?)
                    tcs.each do |tc|
                      idx = tc["index"]?.try(&.as_i?) || 0
                      unless tool_calls_map.has_key?(idx)
                        tool_calls_map[idx] = {
                          id:        tc["id"]?.try(&.as_s?) || "",
                          name:      tc["function"]?.try { |f| f["name"]?.try(&.as_s?) } || "",
                          arguments: String::Builder.new,
                        }
                      end
                      if args = tc["function"]?.try { |f| f["arguments"]?.try(&.as_s?) }
                        tool_calls_map[idx][:arguments] << args
                      end
                    end
                  end
                end
              end

              if usage = parsed["usage"]?
                prompt_tokens = usage["prompt_tokens"]?.try(&.as_i?) || prompt_tokens
                completion_tokens = usage["completion_tokens"]?.try(&.as_i?) || completion_tokens
              end
            end
          end
        rescue ex : CancelledError
          raise ex
        rescue ex : IO::Error
          raise CancelledError.new if ctx.try(&.cancelled?)
          raise ex
        end

        tool_calls = tool_calls_map.to_a.sort_by(&.[0]).map do |_, tc|
          call = ToolCall.new(
            id: tc[:id],
            type: "function",
            function: ToolCall::FunctionCall.new(
              name: tc[:name],
              arguments: tc[:arguments].to_s.empty? ? "{}" : tc[:arguments].to_s,
            ),
          )
          block.call(StreamEvent.tool_use(call))
          call
        end

        final = Response.new(
          content: content.to_s.empty? ? nil : content.to_s,
          tool_calls: tool_calls,
          finish_reason: finish_reason,
          model: response_model,
          provider: "openai",
          raw_request: payload,
          raw_json: "",
          prompt_tokens: prompt_tokens,
          completion_tokens: completion_tokens,
        )

        block.call(StreamEvent.done(final))
        final
      end

      def complete(request : Request, ctx : Context) : Response
        raise CancelledError.new if ctx.cancelled?

        model = request.model.empty? ? @model : request.model
        payload = build_payload(request, model)
        emit_request_trace(request, model, payload)

        response = post_api_cancellable(payload, ctx)

        emit_response_trace(request, response)

        unless response.success?
          raise APIError.new(response.status_code, response.body, "openai:chat")
        end

        result = Response.from_openai_json(response.body, provider: "openai")
        result.raw_request = payload
        result
      end

      private def build_payload(request : Request, model : String, stream : Bool = false) : String
        JSON.build do |json|
          json.object do
            json.field "model", model
            json.field "stream", true if stream
            json.field "stream_options", JSON.parse(%({"include_usage": true})) if stream
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

      private def post_api_cancellable(payload : String, ctx : Context) : HTTP::Client::Response
        headers = Util.bearer_headers(@api_key)
        uri = URI.parse(@endpoint)
        client = HTTP::Client.new(uri)
        client.connect_timeout = 30.seconds
        client.read_timeout = 120.seconds

        result = Channel(HTTP::Client::Response | Exception).new(1)

        spawn do
          begin
            resp = client.post(uri.request_target, headers: headers, body: payload)
            result.send(resp)
          rescue ex
            result.send(ex)
          end
        end

        spawn do
          until ctx.cancelled?
            sleep 100.milliseconds
          end
          client.close rescue nil
          result.send(CancelledError.new) rescue nil
        end

        outcome = result.receive
        case outcome
        when Exception
          raise outcome
        when HTTP::Client::Response
          outcome
        else
          raise CancelledError.new
        end
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
