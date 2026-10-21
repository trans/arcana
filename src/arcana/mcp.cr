require "json"
require "http/client"
require "uri"

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
        description: "List or search the Arcana service directory. Returns agents, services and topics registered on the bus. A topic's listing shows `last_seq` (its newest post's number) and `last_published_at`: compare them with the last post you read to see whether there's anything new.",
        inputSchema: {
          type:       "object",
          properties: {
            query:   {type: "string", description: "Search query (matches name, description, tags)"},
            tag:     {type: "string", description: "Filter by tag. Providers auto-tag their tool names, so `tag: \"chat\"` finds every entity that offers a chat tool."},
            kind:    {type: "string", enum: ["agent", "service", "topic"], description: "Filter by kind"},
            address: {type: "string", description: "Look up a specific address"},
          },
        },
      },
      {
        name:        "arcana_deliver",
        description: "Send a message on the Arcana bus. By default (ordering: auto), the bus decides sync vs async based on the target: services get sync (blocks for reply), agents get async (fire and forget, check arcana_receive later). Override with ordering 'sync' or 'async'. The response tells you which mode was used and the correlation_id for tracking. Each message from the project's own handle to an agent gets its dot-ai message id (the response's `id`), carried with it; in a project with `.ai/mail/sent/`, it is also filed there as the sender's copy, named in the response's `sent_file`: don't file it again. To answer a message, pass its id (its inbox file's `Id:`) as `re`.",
        inputSchema: {
          type:       "object",
          properties: {
            from:       {type: "string", description: "Your address on the bus (so replies come back to you). Defaults to this project's handle."},
            to:         {type: "string", description: "Target address on the bus"},
            subject:    {type: "string", description: "Message subject/intent"},
            payload:    {description: "The message. For mail to an agent, {\"text\":\"...\"} (its subject goes in `subject`). For a service, a JSON OBJECT with the fields it expects (e.g. {\"text\":\"hi\",\"output_path\":\"/tmp/x.opus\"} for openai:tts). Not a stringified JSON blob — pass the object directly. The server does auto-unwrap stringified JSON as a fallback, but the tool schema wants an object."},
            ordering:   {type: "string", enum: ["auto", "sync", "async"], description: "Message ordering: auto (default, resolved by target kind), sync (block for reply), or async (fire and forget)"},
            timeout_ms: {type: "integer", description: "Timeout in milliseconds for sync ordering (default: 30000)"},
            re:         {type: "string", description: "What this message answers: a message's id (the `Id:` of its inbox file), or a topic's post as `#topic:<seq>`. Carried with the message as its `Re:`."},
          },
          required: ["to"],
        },
      },
      {
        name:        "arcana_publish",
        description: "Post to a topic on the Arcana bus. A `#topic` (registered with arcana_register kind \"topic\") is a shared log: the post is stored once and numbered, anyone reads it with arcana_inbox, and subscribers get a short notification. The reply gives the post's number (`seq`). A topic name without `#` sends every subscriber a full copy instead.",
        inputSchema: {
          type:       "object",
          properties: {
            topic:   {type: "string", description: "Topic to post to, e.g. `#releases`"},
            from:    {type: "string", description: "Your address on the bus. Defaults to this project's handle."},
            subject: {type: "string", description: "What the post is about: subscribers see it in their notification"},
            payload: {description: "The post (any JSON value)"},
            re:      {type: "string", description: "What this post answers: a message's id, or another post as `#topic:<seq>`"},
          },
          required: ["topic"],
        },
      },
      {
        name:        "arcana_register",
        description: "Register or unregister on the Arcana bus. Default action is 'register' which creates a mailbox and optionally adds a directory listing. Use action 'unregister' to remove your mailbox and listing. Use action 'busy' or 'idle' to update your availability status. In a project with a session hook, you are usually registered already: registering your own handle again just refreshes your listing (status \"yours\"), and this bridge supplies the project's owner token for it. To create a topic, register its `#name` with kind \"topic\" (and optionally `retention`). Action 'subscribe' (with `topic`) puts a short notification in your mailbox for each new post; 'unsubscribe' stops them; 'subscriptions' lists your topics. You don't need to subscribe to read a topic: see arcana_inbox.",
        inputSchema: {
          type:       "object",
          properties: {
            address:     {type: "string", description: "Your routing address on the bus. Legal shapes: `foo` (bare token, typically a service), `@foo` (agent handle — leading `@` sigil, for conversational identities like a project's Claude agent), `#foo` or `#foo.bar` (a topic), or `owner:capability` (two-token colon form for services). Pick something stable; other agents will remember it. `@mj` and `mj` are distinct entities — the sigil lets Claude/Codex register alongside a same-project tool service without colliding. For subscribe, unsubscribe and subscriptions: the address that gets the notifications (yours)."},
            action:      {type: "string", enum: ["register", "unregister", "busy", "idle", "subscribe", "unsubscribe", "subscriptions"], description: "Action to perform (default: register)"},
            topic:       {type: "string", description: "The `#topic` to subscribe to or unsubscribe from"},
            cadence:     {type: "string", enum: ["always"], description: "How often to be notified when subscribing: \"always\" (each post, the default and only choice so far)"},
            retention:   {type: "integer", description: "Topics only: how many posts the topic keeps, newest first (default 10000, at most 100000)"},
            token:       {type: "string", description: "Secret token to protect your mailbox (optional, you choose it)"},
            name:        {type: "string", description: "Display name for the directory"},
            description: {type: "string", description: "What you do (for the directory)"},
            kind:        {type: "string", enum: ["agent", "service", "topic"], description: "What kind of listing this is. Default: agent. Set to 'service' if you handle requests via a fixed schema, or 'topic' for a `#topic`."},
            guide:       {type: "string", description: "How-to guide for interacting with you"},
            tags:        {type: "array", items: {type: "string"}, description: "Tags for discovery"},
            listed:      {type: "boolean", description: "Whether to add a directory listing. Default true. Set false for pure consumers that send/subscribe but don't accept addressed messages — they get a mailbox but stay invisible to discovery."},
          },
          required: ["address"],
        },
      },
      {
        name:        "arcana_inbox",
        description: "List messages in your mailbox WITHOUT consuming them. Returns metadata (correlation_id, from, subject, timestamp) for each message. Use this to see what's waiting, then arcana_receive with an id to selectively consume specific messages. With a `#topic` as the address, reads the topic instead: its posts numbered after `after`, in full, oldest first, plus `first_seq` and `last_seq`. Anyone can read a topic, and reading consumes nothing. A notification from a topic (`from` starts with `#`) gives the new post's `seq`.",
        inputSchema: {
          type:       "object",
          properties: {
            address: {type: "string", description: "Your address on the bus, or a `#topic` to read"},
            token:   {type: "string", description: "Your mailbox token (if set during register)"},
            after:   {type: "integer", description: "Topics only: return posts numbered after this (the last one you read). Default 0: from the oldest kept post."},
            limit:   {type: "integer", description: "Topics only: at most this many posts (default 100, at most 1000)"},
          },
          required: ["address"],
        },
      },
      {
        name:        "arcana_receive",
        description: "Check your mailbox for incoming messages. Returns an array of envelopes. Use timeout_ms to wait for messages if the mailbox is empty. Use id to selectively receive a specific message (from arcana_inbox) without consuming the rest. Combine id + timeout_ms to block until a specific message arrives. Not for topics: read those with arcana_inbox. In a project with `.ai/mail/inbox/` (dot-ai), each message from an agent to the project's own handle is also written there as an inbox file, named in the message's `inbox_file`.",
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

    # Each tool's argument names, from its schema.
    TOOL_ARGS = JSON.parse(TOOLS.to_json).as_a.to_h do |tool|
      {tool["name"].as_s, tool["inputSchema"]["properties"].as_h.keys}
    end

    # This project's identity, from `.ai/config.yml` in the nearest
    # directory with `.ai/` at or above where the agent started the bridge
    # (see `AgentConfig.find`). Lets the bridge
    # default `from` to the agent's handle and supply its owner token.
    getter self_config : AgentConfig?

    def initialize(@base_url : String = "http://127.0.0.1:19118", @api_key : String? = nil,
                   project_dir : String? = ENV["CLAUDE_PROJECT_DIR"]?.try(&.presence) || Dir.current)
      @self_config = project_dir.try { |d| AgentConfig.find(d) rescue nil }
      uri = URI.parse(@base_url)
      @http = HTTP::Client.new(uri)  # persistent keep-alive connection
      @http_mutex = Mutex.new         # HTTP::Client is not fiber-safe for concurrent use
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
      method = msg.str("method")
      params = msg["params"]? || JSON::Any.new({} of String => JSON::Any)

      case method
      when "initialize"
        jsonrpc_result(id, {
          protocolVersion: PROTOCOL_VERSION,
          capabilities:    {
            tools:     {} of String => String,
            resources: {subscribe: true, listChanged: true},
          },
          serverInfo:   {name: "arcana", version: Arcana::VERSION},
          instructions: Help::BRIEFING,
        })

      when "notifications/initialized"
        nil # no response needed

      when "tools/list"
        jsonrpc_result(id, {tools: TOOLS})

      when "tools/call"
        tool_name = params.str("name")
        args = params["arguments"]? || JSON::Any.new({} of String => JSON::Any)
        result = call_tool(tool_name, args)
        jsonrpc_result(id, {
          content: [{type: "text", text: result}],
        })

      when "resources/list"
        jsonrpc_result(id, {resources: resource_list})

      when "resources/read"
        uri = params.str("uri")
        jsonrpc_result(id, read_resource(uri))

      when "resources/subscribe"
        uri = params.str("uri")
        handle_subscribe(uri)
        jsonrpc_result(id, {} of String => String)

      when "resources/unsubscribe"
        uri = params.str("uri")
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
      if (known = TOOL_ARGS[name]?) && (given = args.as_h?)
        unknown = given.keys - known
        return unknown_args(name, unknown, known) unless unknown.empty?
      end
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

    # Arguments a tool doesn't take are refused, not dropped: an agent
    # that passed its message as `message` would otherwise send nothing
    # and be told it went.
    private def unknown_args(name : String, unknown : Array(String), known : Array(String)) : String
      sends = {"arcana_deliver", "arcana_publish"}.includes?(name)
      error = String.build do |e|
        e << name << " takes no " << (unknown.size == 1 ? "argument " : "arguments ")
        e << unknown.map { |a| "`#{a}`" }.join(", ") << "; it takes " << known.join(", ") << "."
        e << %( The message goes in `payload` (for mail, {"text": "..."}), and its subject in `subject`.) if sends
        e << (sends ? " Nothing was sent." : " Nothing was done.")
      end
      {error: error}.to_json
    end

    NOTHING_TO_SEND = {error: %(Nothing to send: the message goes in `payload` (for mail, {"text": "..."}), and its subject in `subject`. Nothing was sent.)}.to_json

    private def call_directory(args : JSON::Any) : String
      if address = args.str?("address")
        http_get("/directory/#{URI.encode_path_segment(address)}")
      elsif query = args.str?("query")
        http_get("/directory?q=#{URI.encode_path_segment(query)}")
      elsif tag = args.str?("tag")
        http_get("/directory?tag=#{URI.encode_path_segment(tag)}")
      elsif kind = args.str?("kind")
        http_get("/directory?kind=#{kind}")
      else
        http_get("/directory")
      end
    end

    BAD_RE = {error: "re must be a message's id (8 or more hex digits, its inbox file's Id:) or a topic's post as #topic:<seq>"}.to_json

    private def call_deliver(args : JSON::Any) : String
      ordering = args.str("ordering", "auto")
      from = args.str("from", default_from)
      to = args.str("to")
      subject = args.str("subject")
      re = args.str?("re").try(&.strip.presence)
      return BAD_RE if re && !re.matches?(Envelope::REPLY_TO)
      # As the daemon will have it, so the copy filed below says the same.
      payload = Server.normalize_payload(args["payload"]?)
      return NOTHING_TO_SEND if to.starts_with?('@') && subject.blank? && empty?(payload)
      time = Time.utc
      mail = outbound_mail(from, to, subject, payload, time)
      body = {
        from:       from,
        to:         to,
        subject:    subject,
        payload:    payload,
        ordering:   ordering,
        timeout_ms: args.int("timeout_ms", 30_000),
        id:         mail.try(&.[:id]),
        re:         re,
      }.to_json
      resp = request { @http.post("/deliver", headers: json_headers, body: body) }
      return resp.body unless resp.success?
      return resp.body unless mail
      file_sent(mail, re, time, resp.body)
    end

    # Mail is a message from the project's own handle to an agent; calls
    # to services, and messages from other senders, aren't. Mail gets its
    # dot-ai id before it goes, from the name its `sent/` copy has, or
    # would have where the project has no `mail/` (`Hook.sent_name`), and
    # the message as that copy holds it. Nil when it isn't mail.
    private def outbound_mail(from : String, to : String, subject : String, payload : JSON::Any,
                              time : Time) : NamedTuple(id: String, name: String, message: String, sent: String?)?
      cfg = @self_config
      return unless cfg && cfg.handle == from && to.starts_with?('@')
      mail_dir = File.join(cfg.project_dir, ".ai", "mail")
      sent = File.join(mail_dir, "sent")
      name = Hook.sent_name(Dir.exists?(mail_dir) ? mail_dir : nil, to, subject, time)
      message = Hook.mail_body(payload) || ""
      {id: Hook.message_id(from, name, message), name: name, message: message, sent: Dir.exists?(sent) ? sent : nil}
    end

    # Mail sent here goes onto the bus without passing through the outbox,
    # so the bridge files the sender's copy itself, as local delivery files
    # the outbox's: each message the bus took is written into
    # `.ai/mail/sent/` (dot-ai: both projects keep every message between
    # them) with its `Id:`, and the result names the file (`sent_file`).
    # Only when the project has that folder; the result carries the `id`
    # either way. The message went even if its copy can't be written; the
    # result then says why (`sent_error`), so the agent can file it itself.
    private def file_sent(mail : NamedTuple(id: String, name: String, message: String, sent: String?),
                          re : String?, time : Time, result : String) : String
      h = begin
        JSON.parse(result).as_h?
      rescue JSON::ParseException
        nil
      end
      return result unless h

      h = h.dup
      h["id"] = JSON::Any.new(mail[:id])
      if sent = mail[:sent]
        begin
          h["sent_file"] = JSON::Any.new(Hook.write_sent(sent, mail[:name], mail[:message], time, mail[:id], re))
        rescue ex
          h["sent_error"] = JSON::Any.new("couldn't write the sent copy: #{ex.message}")
        end
      end
      h.to_json
    end

    # A payload with nothing in it: none, a blank string, or an empty
    # object or array.
    private def empty?(payload : JSON::Any) : Bool
      case raw = payload.raw
      when Nil    then true
      when String then raw.blank?
      when Hash   then raw.empty?
      when Array  then raw.empty?
      else             false
      end
    end

    private def call_publish(args : JSON::Any) : String
      re = args.str?("re").try(&.strip.presence)
      return BAD_RE if re && !re.matches?(Envelope::REPLY_TO)
      body = {
        from:    args.str("from", default_from),
        topic:   args.str("topic"),
        subject: args.str("subject"),
        payload: args["payload"]? || JSON::Any.new(nil),
        re:      re,
      }.to_json
      http_post("/publish", body)
    end

    private def default_from : String
      @self_config.try(&.handle) || "mcp-bridge"
    end

    # The owner token, when `address` is this project's own handle.
    private def owner_token_for(address : String) : String?
      cfg = @self_config
      cfg.owner_token if cfg && cfg.handle == address
    end

    private def call_register(args : JSON::Any) : String
      address = args.str("address")
      action = args.str("action", "register")

      case action
      when "unregister"
        body = {
          address:     address,
          token:       args.str?("token"),
          owner_token: owner_token_for(address),
        }.to_json
        result = http_post("/unregister", body)

        if @registered.delete(address)
          @sub_mutex.synchronize { @subscriptions.delete(address) }
          emit_notification("notifications/resources/list_changed")
        end

        result
      when "subscribe", "unsubscribe"
        body = {
          address:     address,
          topic:       args.str("topic"),
          cadence:     args.str?("cadence"),
          token:       args.str?("token"),
          owner_token: owner_token_for(address),
        }.to_json
        http_post("/#{action}", body)
      when "subscriptions"
        http_post("/subscriptions", {address: address}.to_json)
      when "busy"
        body = {address: address, token: args.str?("token"), busy: true}.to_json
        http_post("/busy", body)
      when "idle"
        body = {address: address, token: args.str?("token"), busy: false}.to_json
        http_post("/busy", body)
      else # "register"
        body = {
          address:     address,
          token:       args.str?("token"),
          name:        args.str?("name"),
          description: args.str?("description"),
          kind:        args.str?("kind"),
          guide:       args.str?("guide"),
          tags:        args["tags"]?,
          listed:      args.bool?("listed"),
          retention:   args["retention"]?,
          owner_token: owner_token_for(address),
        }.to_json
        result = http_post("/register", body)

        # Track address for resource listing + notify client of new
        # resource. A topic has no mailbox to offer as one.
        unless @registered.includes?(address) || address.starts_with?('#')
          @registered << address
          emit_notification("notifications/resources/list_changed")
        end

        result
      end
    end

    private def call_inbox(args : JSON::Any) : String
      body = {
        address: args.str("address"),
        token:   args.str?("token"),
        after:   args.i64?("after"),
        limit:   args.int?("limit"),
      }.to_json
      http_post("/inbox", body)
    end

    private def call_receive(args : JSON::Any) : String
      h = {} of String => JSON::Any
      h["address"] = JSON::Any.new(args.str("address"))
      if token = args.str?("token")
        h["token"] = JSON::Any.new(token)
      end
      if id = args.str?("id")
        h["id"] = JSON::Any.new(id)
      end
      timeout_ms = args.i64?("timeout_ms") || 0_i64
      h["timeout_ms"] = JSON::Any.new(timeout_ms) if timeout_ms > 0 || !id
      write_inbox_files(args.str("address"), http_post("/receive", h.to_json))
    end

    # A message taken here is gone from the bus, so each one from an agent
    # is written into the project's `.ai/mail/inbox/` first, as the
    # session-end hook writes unread mail (dot-ai: every message between
    # projects is recorded), and the result names the file
    # (`inbox_file`). Only for the project's own handle, and only when the
    # project has that folder. Topic notices and service replies aren't
    # mail and get no file. A message whose file can't be written still
    # comes back, with `inbox_error`, so the agent can write it itself.
    private def write_inbox_files(address : String, result : String) : String
      cfg = @self_config
      return result unless cfg && cfg.handle == address
      inbox = File.join(cfg.project_dir, ".ai", "mail", "inbox")
      return result unless Dir.exists?(inbox)
      messages = begin
        JSON.parse(result).as_a?
      rescue JSON::ParseException
        nil
      end
      return result unless messages

      messages.map do |env|
        h = env.as_h?
        next env unless h && env["from"]?.try(&.as_s?).try(&.starts_with?('@'))
        h = h.dup
        begin
          h["inbox_file"] = JSON::Any.new(Hook.write_note(inbox, env))
        rescue ex
          h["inbox_error"] = JSON::Any.new("couldn't write the inbox file: #{ex.message}")
        end
        JSON::Any.new(h)
      end.to_json
    end

    private def call_expect(args : JSON::Any) : String
      address = args.str("address")
      action = args.str("action", "check")
      case action
      when "check"
        body = {address: address, token: args.str?("token")}.to_json
        http_post("/outstanding", body)
      when "await"
        body = {
          address:    address,
          token:      args.str?("token"),
          timeout_ms: args.int("timeout_ms", 30_000),
        }.to_json
        http_post("/await", body)
      else
        %({"error":"unknown action: #{action}"})
      end
    end

    private def call_freeze(args : JSON::Any) : String
      address = args.str("address")
      action = args.str("action", "list")
      case action
      when "freeze"
        body = {
          address: address,
          token:   args.str?("token"),
          id:      args.str("id"),
          by:      args.str("by"),
        }.to_json
        http_post("/freeze", body)
      when "thaw"
        body = {
          address: address,
          token:   args.str?("token"),
          id:      args.str("id"),
        }.to_json
        http_post("/thaw", body)
      when "thaw_all"
        body = {
          address: address,
          token:   args.str?("token"),
          all:     true,
        }.to_json
        http_post("/thaw", body)
      when "list"
        body = {address: address, token: args.str?("token")}.to_json
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
      if type = args.str?("type")
        params << "type=#{URI.encode_path_segment(type)}"
      end
      if subject = args.str?("subject")
        params << "subject=#{URI.encode_path_segment(subject)}"
      end
      if since = args.str?("since")
        params << "since=#{URI.encode_path_segment(since)}"
      end
      if limit = args.int?("limit")
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
              count = parsed.int("pending")

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
      request { @http.get(path, headers: auth_headers) }.body
    end

    private def http_post(path : String, body : String) : String
      request { @http.post(path, headers: json_headers, body: body) }.body
    end

    private def json_headers : HTTP::Headers
      headers = auth_headers
      headers["Content-Type"] = "application/json"
      headers
    end

    # One request on the keep-alive connection. When the daemon restarts,
    # that connection dies, and HTTP::Client doesn't always drop it: if it
    # decides not to retry, it raises and keeps the dead socket, so every
    # later call fails too. Close it, so the next try reconnects, and try
    # once more. The daemon that held the old socket is gone, so the
    # request didn't reach anything that could act on it.
    private def request(& : -> HTTP::Client::Response) : HTTP::Client::Response
      @http_mutex.synchronize do
        begin
          yield
        rescue IO::Error
          @http.close
          yield
        end
      end
    end

    private def auth_headers : HTTP::Headers
      headers = HTTP::Headers.new
      if key = @api_key
        headers["Authorization"] = "Bearer #{key}"
      end
      headers
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
