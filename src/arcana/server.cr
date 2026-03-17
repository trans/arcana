require "http/server"
require "http/server/handler"

module Arcana
  # Network gateway — exposes the Bus and Directory over WebSocket + REST.
  #
  # WebSocket clients connect, join with an address, and become full
  # participants on the local Bus. Transparent bridging — local actors
  # don't know whether they're talking to a local or remote agent.
  #
  # REST endpoints expose the Directory for discovery and health checks.
  #
  #   bus = Arcana::Bus.new
  #   dir = Arcana::Directory.new
  #   server = Arcana::Server.new(bus, dir, port: 4000)
  #   server.start  # blocking
  #
  class Server
    getter port : Int32
    getter host : String

    # TODO: Revisit token auth — currently a simple shared secret per address.
    # Consider JWT, expiry, or key length requirements if Arcana is ever
    # exposed beyond localhost.
    @tokens = {} of String => String

    def initialize(
      @bus : Bus,
      @directory : Directory,
      @host : String = "0.0.0.0",
      @port : Int32 = 4000,
    )
    end

    # Start the server. Blocks.
    def start
      server = HTTP::Server.new([
        WebSocketHandler.new(@bus, @directory),
      ]) do |ctx|
        handle_rest(ctx)
      end

      @http_server = server
      server.bind_tcp(@host, @port)
      server.listen
    end

    # Stop the server.
    def stop
      @http_server.try(&.close)
    end

    @http_server : HTTP::Server?

    # Start in a background fiber.
    def start_in_background
      spawn { start }
      sleep 50.milliseconds # let the server bind
    end

    private def check_token!(address : String, parsed : JSON::Any)
      expected = @tokens[address]?
      return unless expected  # no token set = no auth required
      given = parsed["token"]?.try(&.as_s?) || ""
      raise "unauthorized" unless given == expected
    end

    private def handle_rest(ctx : HTTP::Server::Context)
      ctx.response.content_type = "application/json"
      path = ctx.request.path

      case {ctx.request.method, path}
      when {"GET", "/health"}
        ctx.response.print %({"status":"ok","addresses":#{@bus.addresses.size},"listings":#{@directory.list.size}})

      when {"GET", "/directory"}
        if query = ctx.request.query_params["q"]?
          ctx.response.print @directory.to_json(@directory.search(query))
        elsif tag = ctx.request.query_params["tag"]?
          ctx.response.print @directory.to_json(@directory.by_tag(tag))
        elsif kind = ctx.request.query_params["kind"]?
          k = kind == "agent" ? Directory::Kind::Agent : Directory::Kind::Service
          ctx.response.print @directory.to_json(@directory.by_kind(k))
        else
          ctx.response.print @directory.to_json
        end

      when {"GET", _}
        if path.starts_with?("/directory/")
          address = path.lchop("/directory/")
          if listing = @directory.lookup(address)
            ctx.response.print @directory.to_json(listing)
          else
            ctx.response.status = HTTP::Status::NOT_FOUND
            ctx.response.print %({"error":"not found"})
          end
        else
          ctx.response.status = HTTP::Status::NOT_FOUND
          ctx.response.print %({"error":"not found"})
        end

      when {"POST", "/register"}
        handle_post_register(ctx)

      when {"POST", "/unregister"}
        handle_post_unregister(ctx)

      when {"POST", "/receive"}
        handle_post_receive(ctx)

      when {"POST", "/send"}
        handle_post_send(ctx)

      when {"POST", "/request"}
        handle_post_request(ctx)

      when {"POST", "/publish"}
        handle_post_publish(ctx)

      when {"POST", "/inbox"}
        handle_post_inbox(ctx)

      when {"POST", "/peek"}
        handle_post_peek(ctx)

      else
        ctx.response.status = HTTP::Status::NOT_FOUND
        ctx.response.print %({"error":"not found"})
      end
    end

    private def handle_post_register(ctx : HTTP::Server::Context)
      parsed = JSON.parse(ctx.request.body.not_nil!)
      address = parsed["address"]?.try(&.as_s?) || ""
      raise "address required" if address.empty?

      # Store token if provided (agent-chosen shared secret)
      if token = parsed["token"]?.try(&.as_s?)
        @tokens[address] = token unless token.empty?
      end

      # Create mailbox so messages can be received
      @bus.mailbox(address)

      # Register in directory if listing info provided
      if parsed["name"]?
        @directory.register(Directory::Listing.new(
          address: address,
          name: parsed["name"]?.try(&.as_s?) || address,
          description: parsed["description"]?.try(&.as_s?) || "",
          kind: parsed["kind"]?.try(&.as_s?) == "service" ? Directory::Kind::Service : Directory::Kind::Agent,
          schema: parsed["schema"]?,
          guide: parsed["guide"]?.try(&.as_s?),
          tags: parsed["tags"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String,
        ))
      end

      ctx.response.print %({"ok":true,"address":"#{address}"})
    rescue ex
      ctx.response.status = HTTP::Status::BAD_REQUEST
      ctx.response.print %({"error":"#{ex.message}"})
    end

    private def handle_post_unregister(ctx : HTTP::Server::Context)
      parsed = JSON.parse(ctx.request.body.not_nil!)
      address = parsed["address"]?.try(&.as_s?) || ""
      raise "address required" if address.empty?
      check_token!(address, parsed)

      @directory.unregister(address)
      @bus.remove_mailbox(address)
      @tokens.delete(address)

      ctx.response.print %({"ok":true,"address":"#{address}"})
    rescue ex
      ctx.response.status = HTTP::Status::BAD_REQUEST
      ctx.response.print %({"error":"#{ex.message}"})
    end

    private def handle_post_inbox(ctx : HTTP::Server::Context)
      parsed = JSON.parse(ctx.request.body.not_nil!)
      address = parsed["address"]?.try(&.as_s?) || ""
      raise "address required" if address.empty?
      check_token!(address, parsed)

      unless @bus.has_mailbox?(address)
        @bus.mailbox(address)
      end

      mb = @bus.mailbox(address)
      ctx.response.print mb.inbox.to_json
    rescue ex
      ctx.response.status = HTTP::Status::BAD_REQUEST
      ctx.response.print %({"error":"#{ex.message}"})
    end

    private def handle_post_receive(ctx : HTTP::Server::Context)
      parsed = JSON.parse(ctx.request.body.not_nil!)
      address = parsed["address"]?.try(&.as_s?) || ""
      raise "address required" if address.empty?
      check_token!(address, parsed)

      unless @bus.has_mailbox?(address)
        @bus.mailbox(address)
      end

      mb = @bus.mailbox(address)

      # Selective receive by id
      if id = parsed["id"]?.try(&.as_s?)
        msg = mb.receive(id)
        if msg
          ctx.response.print [msg].to_json
        else
          ctx.response.print "[]"
        end
        return
      end

      timeout_ms = parsed["timeout_ms"]?.try(&.as_i?) || 0
      messages = [] of Envelope

      if timeout_ms > 0 && messages.empty?
        # Wait for first message up to timeout, then drain the rest
        if msg = mb.receive(timeout_ms.milliseconds)
          messages << msg
          # Drain any additional messages that arrived
          while (extra = mb.try_receive)
            messages << extra
          end
        end
      else
        # Non-blocking drain
        while (msg = mb.try_receive)
          messages << msg
        end
      end

      ctx.response.print messages.to_json
    rescue ex
      ctx.response.status = HTTP::Status::BAD_REQUEST
      ctx.response.print %({"error":"#{ex.message}"})
    end

    private def handle_post_send(ctx : HTTP::Server::Context)
      parsed = JSON.parse(ctx.request.body.not_nil!)
      envelope = envelope_from_json(parsed)
      if @bus.send?(envelope)
        ctx.response.print %({"ok":true})
      else
        ctx.response.status = HTTP::Status::NOT_FOUND
        ctx.response.print %({"error":"no mailbox for address: #{envelope.to}"})
      end
    rescue ex
      ctx.response.status = HTTP::Status::BAD_REQUEST
      ctx.response.print %({"error":"#{ex.message}"})
    end

    private def handle_post_request(ctx : HTTP::Server::Context)
      parsed = JSON.parse(ctx.request.body.not_nil!)
      envelope = envelope_from_json(parsed)
      timeout_ms = parsed["timeout_ms"]?.try(&.as_i?) || 30_000
      timeout = timeout_ms.milliseconds

      result = @bus.request(envelope, timeout: timeout)
      if result
        ctx.response.print result.to_json
      else
        ctx.response.status = HTTP::Status::GATEWAY_TIMEOUT
        ctx.response.print %({"error":"timeout waiting for reply"})
      end
    rescue ex
      ctx.response.status = HTTP::Status::BAD_REQUEST
      ctx.response.print %({"error":"#{ex.message}"})
    end

    private def handle_post_peek(ctx : HTTP::Server::Context)
      parsed = JSON.parse(ctx.request.body.not_nil!)
      address = parsed["address"]?.try(&.as_s?) || ""
      raise "address required" if address.empty?
      check_token!(address, parsed)

      count = @bus.pending(address)
      ctx.response.print %|{"address":"#{address}","pending":#{count}}|
    rescue ex
      ctx.response.status = HTTP::Status::BAD_REQUEST
      ctx.response.print %|{"error":"#{ex.message}"}|
    end

    private def handle_post_publish(ctx : HTTP::Server::Context)
      parsed = JSON.parse(ctx.request.body.not_nil!)
      topic = parsed["topic"]?.try(&.as_s?) || ""
      envelope = envelope_from_json(parsed)
      @bus.publish(topic, envelope)
      ctx.response.print %({"ok":true})
    rescue ex
      ctx.response.status = HTTP::Status::BAD_REQUEST
      ctx.response.print %({"error":"#{ex.message}"})
    end

    private def envelope_from_json(parsed : JSON::Any) : Envelope
      env = parsed["envelope"]? || parsed
      Envelope.new(
        from: env["from"]?.try(&.as_s?) || "",
        to: env["to"]?.try(&.as_s?) || "",
        subject: env["subject"]?.try(&.as_s?) || "",
        payload: env["payload"]? || JSON::Any.new(nil),
        correlation_id: env["correlation_id"]?.try(&.as_s?) || Random::Secure.hex(8),
        reply_to: env["reply_to"]?.try(&.as_s?),
      )
    end

    # WebSocket handler for /bus path.
    private class WebSocketHandler
      include HTTP::Handler

      def initialize(@bus : Bus, @directory : Directory)
        @connections = {} of String => HTTP::WebSocket
        @mutex = Mutex.new
      end

      def call(context : HTTP::Server::Context)
        if websocket_request?(context) && context.request.path == "/bus"
          ws = HTTP::WebSocketHandler.new do |socket|
            handle_connection(socket)
          end
          ws.call(context)
        else
          call_next(context)
        end
      end

      private def websocket_request?(ctx : HTTP::Server::Context) : Bool
        ctx.request.headers["Upgrade"]?.try(&.downcase) == "websocket"
      end

      private def handle_connection(ws : HTTP::WebSocket)
        address : String? = nil
        forwarder : Fiber? = nil

        ws.on_message do |msg|
          begin
            parsed = JSON.parse(msg)
            type = parsed["type"]?.try(&.as_s?) || ""

            case type
            when "join"
              address = parsed["address"]?.try(&.as_s?)
              next unless addr = address

              # Register remote agent on local bus
              mailbox = @bus.mailbox(addr)

              # Register in directory if listing info provided
              if parsed["name"]?
                @directory.register(Directory::Listing.new(
                  address: addr,
                  name: parsed["name"]?.try(&.as_s?) || addr,
                  description: parsed["description"]?.try(&.as_s?) || "",
                  kind: parsed["kind"]?.try(&.as_s?) == "service" ? Directory::Kind::Service : Directory::Kind::Agent,
                  tags: parsed["tags"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String,
                ))
              end

              @mutex.synchronize { @connections[addr] = ws }

              # Forward bus messages to WebSocket
              forwarder = spawn do
                loop do
                  envelope = mailbox.receive
                  ws.send(envelope.to_json)
                end
              end

            when "send"
              envelope = parse_envelope(parsed)
              @bus.send?(envelope)

            when "publish"
              topic = parsed["topic"]?.try(&.as_s?) || ""
              envelope = parse_envelope(parsed)
              @bus.publish(topic, envelope)

            when "subscribe"
              topic = parsed["topic"]?.try(&.as_s?) || ""
              if (addr = address) && !addr.empty? && !topic.empty?
                @bus.subscribe(topic, addr)
              end

            when "unsubscribe"
              topic = parsed["topic"]?.try(&.as_s?) || ""
              if (addr = address) && !addr.empty? && !topic.empty?
                @bus.unsubscribe(topic, addr)
              end
            end
          rescue ex
            ws.send(%({"error":"#{ex.message}"}))
          end
        end

        ws.on_close do
          if addr = address
            @mutex.synchronize { @connections.delete(addr) }
            @directory.unregister(addr)
            @bus.remove_mailbox(addr)
          end
        end

        ws.run
      end

      private def parse_envelope(parsed : JSON::Any) : Envelope
        env = parsed["envelope"]? || parsed
        Envelope.new(
          from: env["from"]?.try(&.as_s?) || "",
          to: env["to"]?.try(&.as_s?) || "",
          subject: env["subject"]?.try(&.as_s?) || "",
          payload: env["payload"]? || JSON::Any.new(nil),
          correlation_id: env["correlation_id"]?.try(&.as_s?) || Random::Secure.hex(8),
          reply_to: env["reply_to"]?.try(&.as_s?),
        )
      end
    end
  end
end
