require "json"
require "http/client"

module Arcana
  # MCP (Model Context Protocol) bridge to a running Arcana server.
  #
  # Reads JSON-RPC 2.0 from stdin, translates to REST calls against
  # the Arcana server, writes responses to stdout.
  #
  # Implements the MCP tool server protocol so Claude Code (or any
  # MCP client) gets native tool access to the Arcana bus.
  #
  class MCP
    PROTOCOL_VERSION = "2024-11-05"

    # Registered addresses we know about (for resource listing).
    @registered = [] of String
    # Active resource subscriptions — address => true.
    @subscriptions = {} of String => Bool
    # Mutex for thread-safe subscription access.
    @sub_mutex = Mutex.new
    # Whether the mailbox watcher fiber is running.
    @watcher_running = false

    TOOLS = [
      {
        name:        "arcana_directory",
        description: "List or search the Arcana service directory. Returns agents and services registered on the bus.",
        inputSchema: {
          type:       "object",
          properties: {
            query:   {type: "string", description: "Search query (matches name, description, tags)"},
            tag:     {type: "string", description: "Filter by tag"},
            kind:    {type: "string", enum: ["agent", "service"], description: "Filter by kind"},
            address: {type: "string", description: "Look up a specific address"},
          },
        },
      },
      {
        name:        "arcana_deliver",
        description: "Send a message on the Arcana bus. By default (ordering: auto), the bus decides sync vs async based on the target: services get sync (blocks for reply), agents get async (fire and forget, check arcana_receive later). Override with ordering 'sync' or 'async'. The response tells you which mode was used and the correlation_id for tracking.",
        inputSchema: {
          type:       "object",
          properties: {
            from:       {type: "string", description: "Your address on the bus (so replies come back to you)"},
            to:         {type: "string", description: "Target address on the bus"},
            subject:    {type: "string", description: "Message subject/intent"},
            payload:    {description: "Message payload (any JSON value)"},
            ordering:   {type: "string", enum: ["auto", "sync", "async"], description: "Message ordering: auto (default, resolved by target kind), sync (block for reply), or async (fire and forget)"},
            timeout_ms: {type: "integer", description: "Timeout in milliseconds for sync ordering (default: 30000)"},
          },
          required: ["to"],
        },
      },
      {
        name:        "arcana_publish",
        description: "Publish a message to a topic on the Arcana bus. All subscribers receive a copy.",
        inputSchema: {
          type:       "object",
          properties: {
            topic:   {type: "string", description: "Topic to publish to"},
            subject: {type: "string", description: "Message subject"},
            payload: {description: "Message payload (any JSON value)"},
          },
          required: ["topic"],
        },
      },
      {
        name:        "arcana_register",
        description: "Register or unregister on the Arcana bus. Default action is 'register' which creates a mailbox and optionally adds a directory listing. Use action 'unregister' to remove your mailbox and listing. Use action 'busy' or 'idle' to update your availability status.",
        inputSchema: {
          type:       "object",
          properties: {
            address:     {type: "string", description: "Your address on the bus. Agents are plain names (e.g. 'alice'); services are 'owner:capability' (e.g. 'arcana:echo')."},
            action:      {type: "string", enum: ["register", "unregister", "busy", "idle"], description: "Action to perform (default: register)"},
            token:       {type: "string", description: "Secret token to protect your mailbox (optional, you choose it)"},
            name:        {type: "string", description: "Display name for the directory"},
            description: {type: "string", description: "What you do (for the directory)"},
            guide:       {type: "string", description: "How-to guide for interacting with you"},
            tags:        {type: "array", items: {type: "string"}, description: "Tags for discovery"},
            listed:      {type: "boolean", description: "Whether to add a directory listing. Default true. Set false for pure consumers that send/subscribe but don't accept addressed messages — they get a mailbox but stay invisible to discovery."},
          },
          required: ["address"],
        },
      },
      {
        name:        "arcana_inbox",
        description: "List messages in your mailbox WITHOUT consuming them. Returns metadata (correlation_id, from, subject, timestamp) for each message. Use this to see what's waiting, then arcana_receive with an id to selectively consume specific messages.",
        inputSchema: {
          type:       "object",
          properties: {
            address: {type: "string", description: "Your address on the bus"},
            token:   {type: "string", description: "Your mailbox token (if set during register)"},
          },
          required: ["address"],
        },
      },
      {
        name:        "arcana_receive",
        description: "Check your mailbox for incoming messages. Returns an array of envelopes. Use timeout_ms to wait for messages if the mailbox is empty. Use id to selectively receive a specific message (from arcana_inbox) without consuming the rest. Combine id + timeout_ms to block until a specific message arrives.",
        inputSchema: {
          type:       "object",
          properties: {
            address:    {type: "string", description: "Your address on the bus"},
            token:      {type: "string", description: "Your mailbox token (if set during register)"},
            timeout_ms: {type: "integer", description: "How long to wait for a message if mailbox is empty (0 = don't wait, default: 0)"},
            id:         {type: "string", description: "Correlation ID of a specific message to receive (from arcana_inbox). Only that message is consumed."},
          },
          required: ["address"],
        },
      },
      {
        name:        "arcana_expect",
        description: "Manage expected response tracking. Use 'check' to see how many outstanding expectations exist, or 'await' to block until all expected responses have arrived.",
        inputSchema: {
          type:       "object",
          properties: {
            address:    {type: "string", description: "Your address on the bus"},
            token:      {type: "string", description: "Your mailbox token (if set during register)"},
            action:     {type: "string", enum: ["check", "await"], description: "Action: check (count outstanding) or await (block until all met)"},
            timeout_ms: {type: "integer", description: "Timeout for await in milliseconds (default: 30000)"},
          },
          required: ["address", "action"],
        },
      },
      {
        name:        "arcana_freeze",
        description: "Manage frozen messages. Freeze holds a message out of the receive queue; thaw releases it back. Use 'list' to see frozen messages.",
        inputSchema: {
          type:       "object",
          properties: {
            address: {type: "string", description: "Mailbox address"},
            token:   {type: "string", description: "Mailbox token (if set during register)"},
            action:  {type: "string", enum: ["freeze", "thaw", "thaw_all", "list"], description: "Action to perform"},
            id:      {type: "string", description: "Correlation ID of the message (required for freeze/thaw)"},
            by:      {type: "string", description: "Who is freezing the message (optional, for freeze action)"},
          },
          required: ["address", "action"],
        },
      },
      {
        name:        "arcana_health",
        description: "Check the health of the Arcana server.",
        inputSchema: {
          type:       "object",
          properties: {} of String => String,
        },
      },
      {
        name:        "arcana_events",
        description: "Query the Arcana audit event log. Returns an array of events matching the filters (type, subject, since, limit). Useful for debugging message flow, tracking auth failures, and auditing who registered when.",
        inputSchema: {
          type:       "object",
          properties: {
            type:    {type: "string", description: "Filter by event type (e.g. 'message.sent', 'listing.registered', 'auth.failed')"},
            subject: {type: "string", description: "Filter by subject address (usually the primary actor of the event)"},
            since:   {type: "string", description: "RFC3339 timestamp; only events at or after this time are returned"},
            limit:   {type: "integer", description: "Max events to return (default 100, cap 1000)"},
          },
        },
      },
    ]

    def initialize(@base_url : String = "http://127.0.0.1:19118")
    end

    # Run the MCP stdio loop. Blocks.
    def run
      STDERR.puts "Arcana MCP bridge connecting to #{@base_url}"

      while (line = STDIN.gets)
        line = line.strip
        next if line.empty?

        begin
          msg = JSON.parse(line)
          response = handle_message(msg)
          if response
            STDOUT.puts response.to_json
            STDOUT.flush
          end
        rescue ex
          STDERR.puts "MCP error: #{ex.message}"
        end
      end
    end

    private def handle_message(msg : JSON::Any) : JSON::Any?
      id = msg["id"]?
      method = msg["method"]?.try(&.as_s?) || ""
      params = msg["params"]? || JSON::Any.new({} of String => JSON::Any)

      case method
      when "initialize"
        jsonrpc_result(id, {
          protocolVersion: PROTOCOL_VERSION,
          capabilities:    {
            tools:     {} of String => String,
            resources: {subscribe: true, listChanged: true},
          },
          serverInfo: {name: "arcana", version: Arcana::VERSION},
        })

      when "notifications/initialized"
        nil # no response needed

      when "tools/list"
        jsonrpc_result(id, {tools: TOOLS})

      when "tools/call"
        tool_name = params["name"]?.try(&.as_s?) || ""
        args = params["arguments"]? || JSON::Any.new({} of String => JSON::Any)
        result = call_tool(tool_name, args)
        jsonrpc_result(id, {
          content: [{type: "text", text: result}],
        })

      when "resources/list"
        jsonrpc_result(id, {resources: resource_list})

      when "resources/read"
        uri = params["uri"]?.try(&.as_s?) || ""
        jsonrpc_result(id, read_resource(uri))

      when "resources/subscribe"
        uri = params["uri"]?.try(&.as_s?) || ""
        handle_subscribe(uri)
        jsonrpc_result(id, {} of String => String)

      when "resources/unsubscribe"
        uri = params["uri"]?.try(&.as_s?) || ""
        handle_unsubscribe(uri)
        jsonrpc_result(id, {} of String => String)

      when "ping"
        jsonrpc_result(id, {} of String => String)

      else
        if id
          jsonrpc_error(id, -32601, "Method not found: #{method}")
        else
          nil
        end
      end
    end

    private def call_tool(name : String, args : JSON::Any) : String
      case name
      when "arcana_directory"
        call_directory(args)
      when "arcana_deliver"
        call_deliver(args)
      when "arcana_publish"
        call_publish(args)
      when "arcana_register"
        call_register(args)
      when "arcana_inbox"
        call_inbox(args)
      when "arcana_receive"
        call_receive(args)
      when "arcana_expect"
        call_expect(args)
      when "arcana_freeze"
        call_freeze(args)
      when "arcana_health"
        call_health
      when "arcana_events"
        call_events(args)
      else
        %({"error":"unknown tool: #{name}"})
      end
    rescue ex
      %({"error":"#{ex.message}"})
    end

    private def call_directory(args : JSON::Any) : String
      if address = args["address"]?.try(&.as_s?)
        http_get("/directory/#{address}")
      elsif query = args["query"]?.try(&.as_s?)
        http_get("/directory?q=#{URI.encode_path_segment(query)}")
      elsif tag = args["tag"]?.try(&.as_s?)
        http_get("/directory?tag=#{URI.encode_path_segment(tag)}")
      elsif kind = args["kind"]?.try(&.as_s?)
        http_get("/directory?kind=#{kind}")
      else
        http_get("/directory")
      end
    end

    private def call_deliver(args : JSON::Any) : String
      ordering = args["ordering"]?.try(&.as_s?) || "auto"
      body = {
        from:       args["from"]?.try(&.as_s?) || "mcp-bridge",
        to:         args["to"]?.try(&.as_s?) || "",
        subject:    args["subject"]?.try(&.as_s?) || "",
        payload:    args["payload"]? || JSON::Any.new(nil),
        ordering:   ordering,
        timeout_ms: args["timeout_ms"]?.try(&.as_i?) || 30_000,
      }.to_json
      http_post("/deliver", body)
    end

    private def call_publish(args : JSON::Any) : String
      body = {
        from:    args["from"]?.try(&.as_s?) || "mcp-bridge",
        topic:   args["topic"]?.try(&.as_s?) || "",
        subject: args["subject"]?.try(&.as_s?) || "",
        payload: args["payload"]? || JSON::Any.new(nil),
      }.to_json
      http_post("/publish", body)
    end

    private def call_register(args : JSON::Any) : String
      address = args["address"]?.try(&.as_s?) || ""
      action = args["action"]?.try(&.as_s?) || "register"

      case action
      when "unregister"
        body = {
          address: address,
          token:   args["token"]?.try(&.as_s?),
        }.to_json
        result = http_post("/unregister", body)

        if @registered.delete(address)
          @sub_mutex.synchronize { @subscriptions.delete(address) }
          emit_notification("notifications/resources/list_changed")
        end

        result
      when "busy"
        body = {address: address, token: args["token"]?.try(&.as_s?), busy: true}.to_json
        http_post("/busy", body)
      when "idle"
        body = {address: address, token: args["token"]?.try(&.as_s?), busy: false}.to_json
        http_post("/busy", body)
      else # "register"
        body = {
          address:     address,
          token:       args["token"]?.try(&.as_s?),
          name:        args["name"]?.try(&.as_s?),
          description: args["description"]?.try(&.as_s?),
          guide:       args["guide"]?.try(&.as_s?),
          tags:        args["tags"]?,
          listed:      args["listed"]?.try(&.as_bool?),
        }.to_json
        result = http_post("/register", body)

        # Track address for resource listing + notify client of new resource
        unless @registered.includes?(address)
          @registered << address
          emit_notification("notifications/resources/list_changed")
        end

        result
      end
    end

    private def call_inbox(args : JSON::Any) : String
      body = {
        address: args["address"]?.try(&.as_s?) || "",
        token:   args["token"]?.try(&.as_s?),
      }.to_json
      http_post("/inbox", body)
    end

    private def call_receive(args : JSON::Any) : String
      h = {} of String => JSON::Any
      h["address"] = JSON::Any.new(args["address"]?.try(&.as_s?) || "")
      if token = args["token"]?.try(&.as_s?)
        h["token"] = JSON::Any.new(token)
      end
      if id = args["id"]?.try(&.as_s?)
        h["id"] = JSON::Any.new(id)
      end
      timeout_ms = args["timeout_ms"]?.try(&.as_i64?) || 0_i64
      h["timeout_ms"] = JSON::Any.new(timeout_ms) if timeout_ms > 0 || !id
      http_post("/receive", h.to_json)
    end

    private def call_expect(args : JSON::Any) : String
      address = args["address"]?.try(&.as_s?) || ""
      action = args["action"]?.try(&.as_s?) || "check"
      case action
      when "check"
        body = {address: address, token: args["token"]?.try(&.as_s?)}.to_json
        http_post("/outstanding", body)
      when "await"
        body = {
          address:    address,
          token:      args["token"]?.try(&.as_s?),
          timeout_ms: args["timeout_ms"]?.try(&.as_i?) || 30_000,
        }.to_json
        http_post("/await", body)
      else
        %({"error":"unknown action: #{action}"})
      end
    end

    private def call_freeze(args : JSON::Any) : String
      address = args["address"]?.try(&.as_s?) || ""
      action = args["action"]?.try(&.as_s?) || "list"
      case action
      when "freeze"
        body = {
          address: address,
          token:   args["token"]?.try(&.as_s?),
          id:      args["id"]?.try(&.as_s?) || "",
          by:      args["by"]?.try(&.as_s?) || "",
        }.to_json
        http_post("/freeze", body)
      when "thaw"
        body = {
          address: address,
          token:   args["token"]?.try(&.as_s?),
          id:      args["id"]?.try(&.as_s?) || "",
        }.to_json
        http_post("/thaw", body)
      when "thaw_all"
        body = {
          address: address,
          token:   args["token"]?.try(&.as_s?),
          all:     true,
        }.to_json
        http_post("/thaw", body)
      when "list"
        body = {address: address, token: args["token"]?.try(&.as_s?)}.to_json
        http_post("/frozen", body)
      else
        %({"error":"unknown action: #{action}"})
      end
    end

    private def call_health : String
      http_get("/health")
    end

    private def call_events(args : JSON::Any) : String
      params = [] of String
      if type = args["type"]?.try(&.as_s?)
        params << "type=#{URI.encode_path_segment(type)}"
      end
      if subject = args["subject"]?.try(&.as_s?)
        params << "subject=#{URI.encode_path_segment(subject)}"
      end
      if since = args["since"]?.try(&.as_s?)
        params << "since=#{URI.encode_path_segment(since)}"
      end
      if limit = args["limit"]?.try(&.as_i?)
        params << "limit=#{limit}"
      end
      qs = params.empty? ? "" : "?#{params.join('&')}"
      http_get("/events#{qs}")
    end

    # --- Resource support ---

    private def resource_list : Array(NamedTuple(uri: String, name: String, description: String, mimeType: String))
      @registered.map do |address|
        {
          uri:         "arcana://mailbox/#{address}",
          name:        "#{address} mailbox",
          description: "Incoming messages for #{address}",
          mimeType:    "application/json",
        }
      end
    end

    private def read_resource(uri : String) : NamedTuple(contents: Array(NamedTuple(uri: String, mimeType: String, text: String)))
      # Parse arcana://mailbox/<address>
      address = uri.sub("arcana://mailbox/", "")
      body = {address: address, timeout_ms: 0}.to_json
      messages = http_post("/receive", body)

      {contents: [{uri: uri, mimeType: "application/json", text: messages}]}
    end

    private def handle_subscribe(uri : String)
      address = uri.sub("arcana://mailbox/", "")
      @sub_mutex.synchronize { @subscriptions[address] = true }
      start_watcher unless @watcher_running
    end

    private def handle_unsubscribe(uri : String)
      address = uri.sub("arcana://mailbox/", "")
      @sub_mutex.synchronize { @subscriptions.delete(address) }
    end

    # Background fiber that polls subscribed mailboxes via /peek (non-destructive)
    # and emits notifications/resources/updated when messages are waiting.
    private def start_watcher
      @watcher_running = true
      spawn do
        # Track last-seen counts to only notify on changes
        last_counts = {} of String => Int32

        loop do
          addresses = @sub_mutex.synchronize { @subscriptions.keys }
          break if addresses.empty?

          addresses.each do |address|
            begin
              body = {address: address}.to_json
              response = http_post("/peek", body)
              parsed = JSON.parse(response)
              count = parsed["pending"]?.try(&.as_i?) || 0

              last = last_counts[address]? || 0
              if count > 0 && count != last
                emit_notification("notifications/resources/updated", {uri: "arcana://mailbox/#{address}"})
              end
              last_counts[address] = count
            rescue ex
              STDERR.puts "Watcher error for #{address}: #{ex.message}"
            end
          end

          sleep 1.minute
        end
        @watcher_running = false
      end
    end

    private def emit_notification(method : String, params = nil)
      msg = if params
              {jsonrpc: "2.0", method: method, params: params}
            else
              {jsonrpc: "2.0", method: method}
            end
      STDOUT.puts msg.to_json
      STDOUT.flush
    end

    private def http_get(path : String) : String
      response = HTTP::Client.get("#{@base_url}#{path}")
      response.body
    end

    private def http_post(path : String, body : String) : String
      headers = HTTP::Headers{"Content-Type" => "application/json"}
      response = HTTP::Client.post("#{@base_url}#{path}", headers: headers, body: body)
      response.body
    end

    private def jsonrpc_result(id : JSON::Any?, result) : JSON::Any
      JSON.parse({
        jsonrpc: "2.0",
        id:      id,
        result:  result,
      }.to_json)
    end

    private def jsonrpc_error(id : JSON::Any?, code : Int32, message : String) : JSON::Any
      JSON.parse({
        jsonrpc: "2.0",
        id:      id,
        error:   {code: code, message: message},
      }.to_json)
    end
  end
end
