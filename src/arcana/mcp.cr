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
        name:        "arcana_request",
        description: "Send a message to an agent or service on the Arcana bus and wait for a reply. Use this to ask agents to do work.",
        inputSchema: {
          type:       "object",
          properties: {
            from:       {type: "string", description: "Your address on the bus (so replies come back to you)"},
            to:         {type: "string", description: "Target address on the bus"},
            subject:    {type: "string", description: "Message subject/intent"},
            payload:    {description: "Message payload (any JSON value)"},
            timeout_ms: {type: "integer", description: "Timeout in milliseconds (default: 30000)"},
          },
          required: ["to"],
        },
      },
      {
        name:        "arcana_send",
        description: "Send a fire-and-forget message to an address on the Arcana bus. No reply expected.",
        inputSchema: {
          type:       "object",
          properties: {
            from:    {type: "string", description: "Your address on the bus"},
            to:      {type: "string", description: "Target address on the bus"},
            subject: {type: "string", description: "Message subject"},
            payload: {description: "Message payload (any JSON value)"},
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
        description: "Register yourself as an agent on the Arcana bus. Creates a mailbox so you can receive messages. Optionally registers in the directory with name/description.",
        inputSchema: {
          type:       "object",
          properties: {
            address:     {type: "string", description: "Your address on the bus"},
            token:       {type: "string", description: "Secret token to protect your mailbox (optional, you choose it)"},
            name:        {type: "string", description: "Display name for the directory"},
            description: {type: "string", description: "What you do (for the directory)"},
            kind:        {type: "string", enum: ["agent", "service"], description: "Agent or service (default: agent)"},
            guide:       {type: "string", description: "How-to guide for interacting with you"},
            tags:        {type: "array", items: {type: "string"}, description: "Tags for discovery"},
          },
          required: ["address"],
        },
      },
      {
        name:        "arcana_receive",
        description: "Check your mailbox for incoming messages. Returns an array of envelopes. Use timeout_ms to wait for messages if the mailbox is empty.",
        inputSchema: {
          type:       "object",
          properties: {
            address:    {type: "string", description: "Your address on the bus"},
            token:      {type: "string", description: "Your mailbox token (if set during register)"},
            timeout_ms: {type: "integer", description: "How long to wait for a message if mailbox is empty (0 = don't wait, default: 0)"},
          },
          required: ["address"],
        },
      },
      {
        name:        "arcana_unregister",
        description: "Unregister from the Arcana bus. Removes your mailbox and directory listing. Messages in flight are lost.",
        inputSchema: {
          type:       "object",
          properties: {
            address: {type: "string", description: "The address to unregister"},
            token:   {type: "string", description: "Your mailbox token (if set during register)"},
          },
          required: ["address"],
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
    ]

    def initialize(@base_url : String = "http://127.0.0.1:4000")
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
          capabilities:    {tools: {} of String => String},
          serverInfo:      {name: "arcana", version: Arcana::VERSION},
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
      when "arcana_request"
        call_request(args)
      when "arcana_send"
        call_send(args)
      when "arcana_publish"
        call_publish(args)
      when "arcana_register"
        call_register(args)
      when "arcana_unregister"
        call_unregister(args)
      when "arcana_receive"
        call_receive(args)
      when "arcana_health"
        call_health
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

    private def call_request(args : JSON::Any) : String
      body = {
        from:       args["from"]?.try(&.as_s?) || "mcp-bridge",
        to:         args["to"]?.try(&.as_s?) || "",
        subject:    args["subject"]?.try(&.as_s?) || "",
        payload:    args["payload"]? || JSON::Any.new(nil),
        timeout_ms: args["timeout_ms"]?.try(&.as_i?) || 30_000,
      }.to_json
      http_post("/request", body)
    end

    private def call_send(args : JSON::Any) : String
      body = {
        from:    args["from"]?.try(&.as_s?) || "mcp-bridge",
        to:      args["to"]?.try(&.as_s?) || "",
        subject: args["subject"]?.try(&.as_s?) || "",
        payload: args["payload"]? || JSON::Any.new(nil),
      }.to_json
      http_post("/send", body)
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
      body = {
        address:     args["address"]?.try(&.as_s?) || "",
        token:       args["token"]?.try(&.as_s?),
        name:        args["name"]?.try(&.as_s?),
        description: args["description"]?.try(&.as_s?),
        kind:        args["kind"]?.try(&.as_s?),
        guide:       args["guide"]?.try(&.as_s?),
        tags:        args["tags"]?,
      }.to_json
      http_post("/register", body)
    end

    private def call_unregister(args : JSON::Any) : String
      body = {
        address: args["address"]?.try(&.as_s?) || "",
        token:   args["token"]?.try(&.as_s?),
      }.to_json
      http_post("/unregister", body)
    end

    private def call_receive(args : JSON::Any) : String
      body = {
        address:    args["address"]?.try(&.as_s?) || "",
        token:      args["token"]?.try(&.as_s?),
        timeout_ms: args["timeout_ms"]?.try(&.as_i?) || 0,
      }.to_json
      http_post("/receive", body)
    end

    private def call_health : String
      http_get("/health")
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
