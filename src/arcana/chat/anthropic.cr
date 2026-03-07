require "http/client"
require "json"

module Arcana
  module Chat
    class Anthropic < Provider
      ENDPOINT        = "https://api.anthropic.com/v1/messages"
      API_VERSION     = "2023-06-01"
      DEFAULT_MODEL   = "claude-sonnet-4-20250514"
      MAX_TOKENS_DEFAULT = 4096

      getter model : String

      def initialize(
        @api_key : String,
        @model : String = DEFAULT_MODEL,
        @max_tokens : Int32 = MAX_TOKENS_DEFAULT,
        @endpoint : String = ENDPOINT,
        trace : Proc(String, Nil)? = nil,
      )
        raise ConfigError.new("API key is required for Anthropic Chat") if @api_key.strip.empty?
        @trace = trace
      end

      def name : String
        "anthropic"
      end

      def models : Array(String)
        uri = URI.parse(@endpoint)
        models_uri = URI.new(scheme: uri.scheme, host: uri.host, port: uri.port, path: "/v1/models")
        headers = HTTP::Headers{
          "x-api-key"         => @api_key,
          "anthropic-version" => API_VERSION,
        }
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
        max_tokens = request.max_tokens > 0 ? request.max_tokens : @max_tokens
        payload = build_payload(request, model, max_tokens)

        tags = request.trace_tags || {} of String => String
        emit_trace({
          phase:      "api_request_chat",
          event_type: "api_request",
          provider:   "anthropic",
          endpoint:   @endpoint,
          model:      model,
          tags:       tags.to_json,
        })

        response = post_api(payload)

        emit_trace({
          phase:          "api_response_chat",
          event_type:     "api_response",
          provider:       "anthropic",
          endpoint:       @endpoint,
          status_code:    response.status_code,
          content_type:   response.headers["Content-Type"]? || "",
          content_length: response.headers["Content-Length"]? || "",
          tags:           tags.to_json,
        })

        unless response.success?
          raise APIError.new(response.status_code, response.body, "anthropic:chat")
        end

        parse_response(response.body, payload)
      end

      def complete(request : Request, ctx : Context) : Response
        raise CancelledError.new if ctx.cancelled?

        model = request.model.empty? ? @model : request.model
        max_tokens = request.max_tokens > 0 ? request.max_tokens : @max_tokens
        payload = build_payload(request, model, max_tokens)

        tags = request.trace_tags || {} of String => String
        emit_trace({
          phase:      "api_request_chat",
          event_type: "api_request",
          provider:   "anthropic",
          endpoint:   @endpoint,
          model:      model,
          tags:       tags.to_json,
        })

        response = post_api_cancellable(payload, ctx)

        emit_trace({
          phase:          "api_response_chat",
          event_type:     "api_response",
          provider:       "anthropic",
          endpoint:       @endpoint,
          status_code:    response.status_code,
          content_type:   response.headers["Content-Type"]? || "",
          content_length: response.headers["Content-Length"]? || "",
          tags:           tags.to_json,
        })

        unless response.success?
          raise APIError.new(response.status_code, response.body, "anthropic:chat")
        end

        parse_response(response.body, payload)
      end

      def stream(request : Request, ctx : Context? = nil, &block : StreamEvent ->) : Response
        raise CancelledError.new if ctx.try(&.cancelled?)

        model = request.model.empty? ? @model : request.model
        max_tokens = request.max_tokens > 0 ? request.max_tokens : @max_tokens
        payload = build_payload(request, model, max_tokens, stream: true)

        headers = HTTP::Headers{
          "x-api-key"         => @api_key,
          "anthropic-version" => API_VERSION,
          "Content-Type"      => "application/json",
        }
        uri = URI.parse(@endpoint)
        client = HTTP::Client.new(uri)
        client.connect_timeout = 30.seconds
        client.read_timeout = 120.seconds

        # Cancel watcher
        if c = ctx
          spawn do
            until c.cancelled?
              sleep 100.milliseconds
            end
            client.close rescue nil
          end
        end

        content = String::Builder.new
        tool_calls = [] of ToolCall
        server_tool_results = [] of JSON::Any
        current_tool_id = ""
        current_tool_name = ""
        current_tool_input = String::Builder.new
        in_tool = false
        response_model = ""
        finish_reason = ""
        prompt_tokens = 0
        completion_tokens = 0
        cache_read_tokens : Int32? = nil
        cache_creation_tokens : Int32? = nil

        begin
          client.post(uri.request_target, headers: headers, body: payload) do |response|
            unless response.success?
              body = response.body_io.gets_to_end
              raise APIError.new(response.status_code, body, "anthropic:chat:stream")
            end

            event_type = ""
            response.body_io.each_line do |line|
              raise CancelledError.new if ctx.try(&.cancelled?)

              if line.starts_with?("event: ")
                event_type = line[7..]
              elsif line.starts_with?("data: ")
                data = line[6..]
                next if data == "[DONE]"

                parsed = JSON.parse(data) rescue next

                case event_type
                when "message_start"
                  if msg = parsed["message"]?
                    response_model = msg["model"]?.try(&.as_s?) || ""
                    if usage = msg["usage"]?
                      prompt_tokens = usage["input_tokens"]?.try(&.as_i?) || 0
                      cache_read_tokens = usage["cache_read_input_tokens"]?.try(&.as_i?)
                      cache_creation_tokens = usage["cache_creation_input_tokens"]?.try(&.as_i?)
                    end
                  end

                when "content_block_start"
                  if cb = parsed["content_block"]?
                    case cb["type"]?.try(&.as_s?)
                    when "tool_use"
                      in_tool = true
                      current_tool_id = cb["id"]?.try(&.as_s?) || ""
                      current_tool_name = cb["name"]?.try(&.as_s?) || ""
                      current_tool_input = String::Builder.new
                    when "server_tool_use"
                      server_tool_results << cb
                    end
                  end

                when "content_block_delta"
                  if delta = parsed["delta"]?
                    case delta["type"]?.try(&.as_s?)
                    when "text_delta"
                      text = delta["text"]?.try(&.as_s?) || ""
                      content << text
                      block.call(StreamEvent.text_delta(text))
                    when "input_json_delta"
                      partial = delta["partial_json"]?.try(&.as_s?) || ""
                      current_tool_input << partial
                    end
                  end

                when "content_block_stop"
                  if in_tool
                    tc = ToolCall.new(
                      id: current_tool_id,
                      type: "function",
                      function: ToolCall::FunctionCall.new(
                        name: current_tool_name,
                        arguments: current_tool_input.to_s.empty? ? "{}" : current_tool_input.to_s,
                      ),
                    )
                    tool_calls << tc
                    block.call(StreamEvent.tool_use(tc))
                    in_tool = false
                  end
                  # Check if prev block was server tool result
                  if cb = parsed["content_block"]?
                    if cb["type"]?.try(&.as_s?) == "web_search_tool_result"
                      server_tool_results << cb
                    end
                  end

                when "message_delta"
                  if delta = parsed["delta"]?
                    stop_reason = delta["stop_reason"]?.try(&.as_s?)
                    finish_reason = case stop_reason
                                    when "end_turn"   then "stop"
                                    when "tool_use"   then "tool_calls"
                                    when "max_tokens" then "length"
                                    else                   stop_reason || ""
                                    end
                  end
                  if usage = parsed["usage"]?
                    completion_tokens = usage["output_tokens"]?.try(&.as_i?) || 0
                  end
                end
              end
            end
          end
        rescue ex : CancelledError
          raise ex
        rescue ex : IO::Error
          raise CancelledError.new if ctx.try(&.cancelled?)
          raise ex
        end

        content_str = content.to_s

        final = Response.new(
          content: content_str.empty? ? nil : content_str,
          tool_calls: tool_calls,
          finish_reason: finish_reason,
          model: response_model,
          provider: "anthropic",
          raw_request: payload,
          raw_json: "",
          prompt_tokens: prompt_tokens,
          completion_tokens: completion_tokens,
          cache_read_tokens: cache_read_tokens,
          cache_creation_tokens: cache_creation_tokens,
          server_tool_results: server_tool_results,
        )

        block.call(StreamEvent.done(final))
        final
      end

      private def build_payload(request : Request, model : String, max_tokens : Int32, stream : Bool = false) : String
        JSON.build do |json|
          json.object do
            json.field "model", model
            json.field "max_tokens", max_tokens
            json.field "stream", true if stream

            # Anthropic takes system as a top-level string, not in messages.
            system_msg = request.messages.find { |m| m.role == "system" }
            if system_msg && (sys_content = system_msg.content)
              json.field "system", sys_content
            end

            json.field "messages" do
              json.array do
                request.messages.each do |msg|
                  next if msg.role == "system"
                  build_message(json, msg)
                end
              end
            end

            if request.temperature != 0.7 # only send if non-default
              json.field "temperature", request.temperature
            end

            has_tools = request.tools || request.server_tools
            if has_tools
              json.field "tools" do
                json.array do
                  if tools = request.tools
                    tools.each do |tool|
                      json.object do
                        json.field "name", tool.name
                        json.field "description", tool.description
                        json.field "input_schema", JSON.parse(tool.parameters_json)
                      end
                    end
                  end
                  if server_tools = request.server_tools
                    server_tools.each do |st|
                      json.object do
                        json.field "type", st.type
                        json.field "name", st.name
                        st.config.each do |key, val|
                          json.field key, val
                        end
                      end
                    end
                  end
                end
              end

              if tc = request.tool_choice
                case tc
                when "auto"     then json.field "tool_choice", JSON.parse(%({"type":"auto"}))
                when "required" then json.field "tool_choice", JSON.parse(%({"type":"any"}))
                when "none"     then # omit — Anthropic has no "none", just don't send tools
                else
                  json.field "tool_choice", JSON.parse(%({"type":"tool","name":"#{tc}"}))
                end
              end
            end
          end
        end
      end

      private def build_message(json : JSON::Builder, msg : Message) : Nil
        json.object do
          json.field "role", msg.role == "tool" ? "user" : msg.role

          if msg.tool_call_id
            # Tool result — Anthropic uses content blocks
            json.field "content" do
              json.array do
                json.object do
                  json.field "type", "tool_result"
                  json.field "tool_use_id", msg.tool_call_id
                  json.field "content", msg.content || ""
                end
              end
            end
          elsif tc = msg.tool_calls
            # Assistant message with tool use
            json.field "content" do
              json.array do
                if c = msg.content
                  json.object do
                    json.field "type", "text"
                    json.field "text", c
                  end
                end
                tc.each do |tool_call|
                  json.object do
                    json.field "type", "tool_use"
                    json.field "id", tool_call.id
                    json.field "name", tool_call.function.name
                    json.field "input", JSON.parse(tool_call.function.arguments)
                  end
                end
              end
            end
          else
            json.field "content", msg.content || ""
          end
        end
      end

      private def post_api(payload : String) : HTTP::Client::Response
        headers = HTTP::Headers{
          "x-api-key"         => @api_key,
          "anthropic-version" => API_VERSION,
          "Content-Type"      => "application/json",
        }
        uri = URI.parse(@endpoint)
        client = HTTP::Client.new(uri)
        client.connect_timeout = 30.seconds
        client.read_timeout = 120.seconds
        client.post(uri.request_target, headers: headers, body: payload)
      end

      private def post_api_cancellable(payload : String, ctx : Context) : HTTP::Client::Response
        headers = HTTP::Headers{
          "x-api-key"         => @api_key,
          "anthropic-version" => API_VERSION,
          "Content-Type"      => "application/json",
        }
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

      private def parse_response(body : String, payload : String) : Response
        parsed = JSON.parse(body)

        content = nil
        tool_calls = [] of ToolCall
        server_tool_results = [] of JSON::Any

        if blocks = parsed["content"]?.try(&.as_a?)
          blocks.each do |block|
            case block["type"]?.try(&.as_s?)
            when "text"
              content = block["text"]?.try(&.as_s?)
            when "tool_use"
              tool_calls << ToolCall.new(
                id: block["id"]?.try(&.as_s?) || "",
                type: "function",
                function: ToolCall::FunctionCall.new(
                  name: block["name"]?.try(&.as_s?) || "",
                  arguments: (block["input"]? || JSON::Any.new({} of String => JSON::Any)).to_json,
                ),
              )
            when "server_tool_use"
              # Server-side tool invocation (e.g. web_search) — tracked but not actionable by client
              server_tool_results << block
            when "web_search_tool_result"
              server_tool_results << block
            end
          end
        end

        stop_reason = parsed["stop_reason"]?.try(&.as_s?)
        finish_reason = case stop_reason
                        when "end_turn"  then "stop"
                        when "tool_use"  then "tool_calls"
                        when "max_tokens" then "length"
                        else                  stop_reason
                        end

        model = parsed["model"]?.try(&.as_s?) || ""
        usage = parsed["usage"]?
        prompt_tokens = usage.try { |u| u["input_tokens"]?.try(&.as_i?) }
        completion_tokens = usage.try { |u| u["output_tokens"]?.try(&.as_i?) }
        cache_read_tokens = usage.try { |u| u["cache_read_input_tokens"]?.try(&.as_i?) }
        cache_creation_tokens = usage.try { |u| u["cache_creation_input_tokens"]?.try(&.as_i?) }

        Response.new(
          content: content,
          tool_calls: tool_calls,
          finish_reason: finish_reason,
          model: model,
          provider: "anthropic",
          raw_request: payload,
          raw_json: body,
          prompt_tokens: prompt_tokens,
          completion_tokens: completion_tokens,
          cache_read_tokens: cache_read_tokens,
          cache_creation_tokens: cache_creation_tokens,
          server_tool_results: server_tool_results,
        )
      end
    end
  end
end
