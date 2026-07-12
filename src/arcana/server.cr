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
  #   server = Arcana::Server.new(bus, dir, port: 19118)
  #   server.start  # blocking
  #
  class Server
    getter port : Int32
    getter host : String

    # TODO: Revisit token auth — currently a simple shared secret per address.
    # Consider JWT, expiry, or key length requirements if Arcana is ever
    # exposed beyond localhost.
    getter tokens = {} of String => String

    # Bulk-replace tokens (used by snapshot restore).
    def load_tokens(tokens : Hash(String, String))
      @tokens.clear
      tokens.each { |addr, tok| @tokens[addr] = tok }
    end

    property state_file : String?

    # Optional event recorder for auth failures and server lifecycle.
    property events : Events::Backend?

    # When true, every REST request (except /health) and every WebSocket
    # upgrade must present a valid `Authorization: Bearer ak_...` header
    # that resolves via Arcana::Auth::ApiKey.verify. Requires the identity
    # store (ARCANA_DATABASE_URL).
    property auth_required : Bool = false

    def initialize(
      @bus : Bus,
      @directory : Directory,
      @host : String = "0.0.0.0",
      @port : Int32 = 19118,
      @state_file : String? = nil,
    )
    end

    # Start the server. Blocks.
    def start
      server = HTTP::Server.new([
        WebSocketHandler.new(@bus, @directory, auth_required: @auth_required, events: @events),
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

    private def check_sender!(from : String)
      return if from.empty?
      raise "sender '#{from}' is not registered" unless @bus.has_mailbox?(from)
    end

    private def save_state
      if path = @state_file
        @directory.save(path)
      end
    end

    private def check_token!(address : String, parsed : JSON::Any)
      expected = @tokens[address]?
      return unless expected  # no token set = no auth required
      given = parsed.str("token")
      unless given == expected
        @events.try &.record(Events::Event.new(
          type: "auth.failed",
          subject: address,
          metadata: {"reason" => JSON::Any.new("token mismatch")} of String => JSON::Any,
        ))
        raise "unauthorized"
      end
    end

    # Post-0.14: addresses are their own canonical form. This helper is a
    # no-op kept for call-site stability; callers could use `address` directly.
    private def resolve_addr(address : String) : String
      address
    end

    # Extract and verify a bearer token from the Authorization header.
    # Returns the matching ApiKey or nil.
    private def verify_bearer(ctx : HTTP::Server::Context) : Auth::ApiKey?
      header = ctx.request.headers["Authorization"]?
      return nil unless header
      return nil unless header.starts_with?("Bearer ")
      token = header[7..].strip
      return nil if token.empty?
      Auth::ApiKey.verify(token)
    end

    # Enforce bearer-token auth on REST requests when @auth_required is set.
    # Returns true if the request may proceed, false if a 401 has been written.
    # /health is always exempt so liveness probes work without credentials.
    private def enforce_rest_auth!(ctx : HTTP::Server::Context) : Bool
      return true unless @auth_required
      return true if ctx.request.path == "/health"
      if verify_bearer(ctx)
        true
      else
        @events.try &.record(Events::Event.new(
          type: "auth.failed",
          subject: ctx.request.path,
          metadata: {
            "reason"    => JSON::Any.new("missing or invalid bearer token"),
            "transport" => JSON::Any.new("rest"),
          } of String => JSON::Any,
        ))
        ctx.response.status = HTTP::Status::UNAUTHORIZED
        ctx.response.headers["WWW-Authenticate"] = "Bearer"
        ctx.response.content_type = "application/json"
        ctx.response.print %({"error":"unauthorized"})
        false
      end
    end

    private def handle_rest(ctx : HTTP::Server::Context)
      return unless enforce_rest_auth!(ctx)
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
        elsif capability = ctx.request.query_params["capability"]?
          ctx.response.print @directory.to_json(@directory.by_capability(capability))
        elsif kind = ctx.request.query_params["kind"]?
          k = kind == "agent" ? Directory::Kind::Agent : Directory::Kind::Service
          ctx.response.print @directory.to_json(@directory.by_kind(k))
        else
          ctx.response.print @directory.to_json
        end

      when {"GET", "/events"}
        handle_get_events(ctx)

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

      when {"POST", "/deliver"}
        handle_post_deliver(ctx)

      when {"POST", "/publish"}
        handle_post_publish(ctx)

      when {"POST", "/inbox"}
        handle_post_inbox(ctx)

      when {"POST", "/outstanding"}
        handle_post_outstanding(ctx)

      when {"POST", "/await"}
        handle_post_await(ctx)

      when {"POST", "/freeze"}
        handle_post_freeze(ctx)

      when {"POST", "/thaw"}
        handle_post_thaw(ctx)

      when {"POST", "/frozen"}
        handle_post_frozen(ctx)

      when {"POST", "/busy"}
        handle_post_busy(ctx)

      when {"POST", "/peek"}
        handle_post_peek(ctx)

      else
        ctx.response.status = HTTP::Status::NOT_FOUND
        ctx.response.print %({"error":"not found"})
      end
    end

    private def handle_post_register(ctx : HTTP::Server::Context)
      parsed = JSON.parse(ctx.request.body.not_nil!)
      address = parsed.str("address")
      raise "address required" if address.empty?
      Directory.validate_address(address)

      # Store token if provided (agent-chosen shared secret)
      if token = parsed.str?("token")
        @tokens[address] = token unless token.empty?
      end

      # Create mailbox (always — sender check requires has_mailbox?)
      @bus.mailbox(address)

      # Register in directory unless caller opted out (e.g. pure consumers
      # that send/subscribe but never accept addressed messages).
      listed = parsed.bool?("listed")
      listed = true if listed.nil?
      if listed
        kind_str = parsed.str?("kind")
        kind = case kind_str
               when "service" then Directory::Kind::Service
               when "agent"   then Directory::Kind::Agent
               end
        @directory.register(Directory::Listing.new(
          address: address,
          name: parsed.str?("name") || address,
          description: parsed.str("description"),
          kind: kind,
          capability: parsed.str?("capability"),
          schema: parsed["schema"]?,
          guide: parsed.str?("guide"),
          tags: parsed.str_arr("tags"),
        ))
      end
      save_state

      ctx.response.print %({"ok":true,"address":"#{address}"})
    rescue ex
      ctx.response.status = HTTP::Status::BAD_REQUEST
      ctx.response.print %({"error":"#{ex.message}"})
    end

    private def handle_post_unregister(ctx : HTTP::Server::Context)
      parsed = JSON.parse(ctx.request.body.not_nil!)
      address = parsed.str("address")
      raise "address required" if address.empty?

      check_token!(address, parsed)

      @directory.unregister(address)
      @bus.remove_mailbox(address)
      @tokens.delete(address)
      save_state

      ctx.response.print %({"ok":true,"address":"#{address}"})
    rescue ex
      ctx.response.status = HTTP::Status::BAD_REQUEST
      ctx.response.print %({"error":"#{ex.message}"})
    end

    private def handle_post_inbox(ctx : HTTP::Server::Context)
      parsed = JSON.parse(ctx.request.body.not_nil!)
      address = parsed.str("address")
      raise "address required" if address.empty?
      resolved = resolve_addr(address)
      check_token!(resolved, parsed)

      mb = @bus.mailbox(resolved)
      ctx.response.print mb.inbox.to_json
    rescue ex
      ctx.response.status = HTTP::Status::BAD_REQUEST
      ctx.response.print %({"error":"#{ex.message}"})
    end

    private def handle_post_receive(ctx : HTTP::Server::Context)
      parsed = JSON.parse(ctx.request.body.not_nil!)
      address = parsed.str("address")
      raise "address required" if address.empty?
      resolved = resolve_addr(address)
      check_token!(resolved, parsed)

      mb = @bus.mailbox(resolved)

      # Selective receive by id (with optional timeout)
      if id = parsed.str?("id")
        timeout_ms = parsed.int("timeout_ms")
        msg = if timeout_ms > 0
                mb.receive(id, timeout_ms.milliseconds)
              else
                mb.receive(id)
              end
        if msg
          ctx.response.print [msg].to_json
        else
          ctx.response.print "[]"
        end
        return
      end

      timeout_ms = parsed.int("timeout_ms")
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
      check_sender!(envelope.from)
      if @bus.send?(envelope)
        ctx.response.print %({"ok":true})
      else
        ctx.response.status = HTTP::Status::NOT_FOUND
        ctx.response.print error_with_suggestion(envelope.to, "no mailbox for address: #{envelope.to}")
      end
    rescue ex
      ctx.response.status = HTTP::Status::BAD_REQUEST
      ctx.response.print %({"error":"#{ex.message}"})
    end

    private def handle_post_deliver(ctx : HTTP::Server::Context)
      failed_addr = ""
      begin
        parsed = JSON.parse(ctx.request.body.not_nil!)
        envelope = envelope_from_json(parsed)
        failed_addr = envelope.to
        check_sender!(envelope.from)
        timeout_ms = parsed.int("timeout_ms", 30_000)
        timeout = timeout_ms.milliseconds

        # Use strict deliver (raises if no mailbox). Silent drops are worse
        # than an error — callers need to know when a message didn't land.
        reply, resolved = @bus.deliver(envelope, timeout: timeout)
        if reply
          ctx.response.print reply.to_json
        else
          ctx.response.print %({"ok":true,"ordering":"#{resolved.to_s.downcase}","correlation_id":"#{envelope.correlation_id}"})
        end
      rescue ex : Arcana::Error
        ctx.response.status = HTTP::Status::NOT_FOUND
        ctx.response.print error_with_suggestion(failed_addr, ex.message || "delivery failed")
      rescue ex
        ctx.response.status = HTTP::Status::BAD_REQUEST
        ctx.response.print %({"error":"#{ex.message}"})
      end
    end

    # Build a JSON error body. When the failed address resembles something
    # in the directory, attach a structured `did_you_mean` hint and mention
    # it in the human-readable error string.
    private def error_with_suggestion(failed_addr : String, msg : String) : String
      suggestion = closest_listing(failed_addr)
      if s = suggestion
        full_msg = "#{msg} Did you mean '#{s.address}' (#{s.name})?"
        {
          "error"        => full_msg,
          "did_you_mean" => {
            "address"     => s.address,
            "name"        => s.name,
            "description" => s.description,
          },
        }.to_json
      else
        {"error" => msg}.to_json
      end
    end

    # Find the directory listing whose address most closely resembles the
    # failed one. Returns nil if no candidate clears the similarity threshold
    # — better to give no suggestion than a misleading one.
    private SIMILARITY_THRESHOLD = 0.5

    private def closest_listing(addr : String) : Directory::Listing?
      return nil if addr.empty?
      listings = @directory.list
      return nil if listings.empty?

      best : Directory::Listing? = nil
      best_score = 0.0_f64
      listings.each do |listing|
        next if listing.address == addr # exact match wouldn't be a failure
        score = address_similarity(addr, listing.address)
        if score > best_score
          best_score = score
          best = listing
        end
      end
      best_score >= SIMILARITY_THRESHOLD ? best : nil
    end

    # Combined similarity score for two short addresses:
    # - exact match → 1.0
    # - one contains the other → boosted by length ratio (catches "memo" vs
    #   "memo-bot")
    # - otherwise → Levenshtein-normalized ratio (catches typos)
    private def address_similarity(a : String, b : String) : Float64
      return 1.0 if a == b
      return 0.0 if a.empty? || b.empty?
      if a.includes?(b) || b.includes?(a)
        # Substring containment is strong signal — floor at 0.5 so a
        # contained address always beats the similarity threshold, then
        # scale up with how much of the longer string is shared.
        longer, shorter = a.size > b.size ? {a, b} : {b, a}
        return shorter.size.to_f64 / longer.size.to_f64 * 0.5 + 0.5
      end
      dist = levenshtein(a, b)
      max_len = {a.size, b.size}.max
      1.0 - (dist.to_f64 / max_len.to_f64)
    end

    private def levenshtein(a : String, b : String) : Int32
      m = a.size
      n = b.size
      return n if m == 0
      return m if n == 0

      prev = Array(Int32).new(n + 1) { |i| i }
      curr = Array(Int32).new(n + 1, 0)

      m.times do |i|
        curr[0] = i + 1
        n.times do |j|
          cost = a[i] == b[j] ? 0 : 1
          curr[j + 1] = {curr[j] + 1, prev[j + 1] + 1, prev[j] + cost}.min
        end
        prev, curr = curr, prev
      end
      prev[n]
    end

    private def handle_post_request(ctx : HTTP::Server::Context)
      parsed = JSON.parse(ctx.request.body.not_nil!)
      envelope = envelope_from_json(parsed)
      timeout_ms = parsed.int("timeout_ms", 30_000)
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

    private def handle_post_outstanding(ctx : HTTP::Server::Context)
      parsed = JSON.parse(ctx.request.body.not_nil!)
      address = parsed.str("address")
      raise "address required" if address.empty?
      resolved = resolve_addr(address)
      check_token!(resolved, parsed)

      mb = @bus.mailbox(resolved)
      ctx.response.print %({"address":"#{resolved}","outstanding":#{mb.outstanding}})
    rescue ex
      ctx.response.status = HTTP::Status::BAD_REQUEST
      ctx.response.print %({"error":"#{ex.message}"})
    end

    private def handle_post_await(ctx : HTTP::Server::Context)
      parsed = JSON.parse(ctx.request.body.not_nil!)
      address = parsed.str("address")
      raise "address required" if address.empty?
      resolved = resolve_addr(address)
      check_token!(resolved, parsed)

      timeout_ms = parsed.int("timeout_ms", 30_000)
      mb = @bus.mailbox(resolved)
      all_met = mb.await_outstanding(timeout_ms.milliseconds)
      ctx.response.print %({"address":"#{resolved}","all_met":#{all_met}})
    rescue ex
      ctx.response.status = HTTP::Status::BAD_REQUEST
      ctx.response.print %({"error":"#{ex.message}"})
    end

    private def handle_post_freeze(ctx : HTTP::Server::Context)
      parsed = JSON.parse(ctx.request.body.not_nil!)
      address = parsed.str("address")
      raise "address required" if address.empty?
      resolved = resolve_addr(address)
      check_token!(resolved, parsed)

      id = parsed.str("id")
      raise "id required" if id.empty?
      by = parsed.str("by")

      mb = @bus.mailbox(resolved)
      if mb.freeze(id, by)
        ctx.response.print %({"ok":true})
      else
        ctx.response.status = HTTP::Status::NOT_FOUND
        ctx.response.print %({"error":"message not found"})
      end
    rescue ex
      ctx.response.status = HTTP::Status::BAD_REQUEST
      ctx.response.print %({"error":"#{ex.message}"})
    end

    private def handle_post_thaw(ctx : HTTP::Server::Context)
      parsed = JSON.parse(ctx.request.body.not_nil!)
      address = parsed.str("address")
      raise "address required" if address.empty?
      resolved = resolve_addr(address)
      check_token!(resolved, parsed)

      if parsed.bool?("all")
        mb = @bus.mailbox(resolved)
        count = mb.thaw_all
        ctx.response.print %({"ok":true,"thawed":#{count}})
      else
        id = parsed.str("id")
        raise "id required" if id.empty?
        mb = @bus.mailbox(resolved)
        if mb.thaw(id)
          ctx.response.print %({"ok":true})
        else
          ctx.response.status = HTTP::Status::NOT_FOUND
          ctx.response.print %({"error":"frozen message not found"})
        end
      end
    rescue ex
      ctx.response.status = HTTP::Status::BAD_REQUEST
      ctx.response.print %({"error":"#{ex.message}"})
    end

    private def handle_post_frozen(ctx : HTTP::Server::Context)
      parsed = JSON.parse(ctx.request.body.not_nil!)
      address = parsed.str("address")
      raise "address required" if address.empty?
      resolved = resolve_addr(address)
      check_token!(resolved, parsed)

      mb = @bus.mailbox(resolved)
      ctx.response.print mb.frozen.to_json
    rescue ex
      ctx.response.status = HTTP::Status::BAD_REQUEST
      ctx.response.print %({"error":"#{ex.message}"})
    end

    private def handle_post_busy(ctx : HTTP::Server::Context)
      parsed = JSON.parse(ctx.request.body.not_nil!)
      address = parsed.str("address")
      raise "address required" if address.empty?
      resolved = resolve_addr(address)
      check_token!(resolved, parsed)

      busy = parsed.bool("busy")
      @directory.set_busy(resolved, busy)
      ctx.response.print %({"ok":true,"address":"#{resolved}","busy":#{busy}})
    rescue ex
      ctx.response.status = HTTP::Status::BAD_REQUEST
      ctx.response.print %({"error":"#{ex.message}"})
    end

    private def handle_post_peek(ctx : HTTP::Server::Context)
      parsed = JSON.parse(ctx.request.body.not_nil!)
      address = parsed.str("address")
      raise "address required" if address.empty?
      resolved = resolve_addr(address)
      check_token!(resolved, parsed)

      count = @bus.pending(resolved)
      ctx.response.print %|{"address":"#{resolved}","pending":#{count}}|
    rescue ex
      ctx.response.status = HTTP::Status::BAD_REQUEST
      ctx.response.print %|{"error":"#{ex.message}"}|
    end

    private def handle_post_publish(ctx : HTTP::Server::Context)
      parsed = JSON.parse(ctx.request.body.not_nil!)
      topic = parsed.str("topic")
      envelope = envelope_from_json(parsed)
      check_sender!(envelope.from)
      @bus.publish(topic, envelope)
      ctx.response.print %({"ok":true})
    rescue ex
      ctx.response.status = HTTP::Status::BAD_REQUEST
      ctx.response.print %({"error":"#{ex.message}"})
    end

    # GET /events?type=...&subject=...&since=<rfc3339>&limit=N
    private def handle_get_events(ctx : HTTP::Server::Context)
      backend = @events
      unless backend
        ctx.response.status = HTTP::Status::NOT_FOUND
        ctx.response.print %({"error":"event log not enabled"})
        return
      end
      type = ctx.request.query_params["type"]?
      subject = ctx.request.query_params["subject"]?
      since = ctx.request.query_params["since"]?.try do |s|
        Time.parse_rfc3339(s) rescue raise "invalid 'since' timestamp — expected RFC3339"
      end
      limit = (ctx.request.query_params["limit"]? || "100").to_i
      limit = 1000 if limit > 1000

      events = backend.query(since: since, type: type, subject: subject, limit: limit)
      ctx.response.print events.to_json
    rescue ex
      ctx.response.status = HTTP::Status::BAD_REQUEST
      ctx.response.print %({"error":"#{ex.message}"})
    end

    private def envelope_from_json(parsed : JSON::Any) : Envelope
      env = parsed["envelope"]? || parsed
      ordering = case env.str?("ordering")
                 when "sync"  then Ordering::Sync
                 when "async" then Ordering::Async
                 else              Ordering::Auto
                 end
      Envelope.new(
        from: env.str("from"),
        to: env.str("to"),
        subject: env.str("subject"),
        payload: normalize_payload(env["payload"]?),
        correlation_id: env.str?("correlation_id") || Random::Secure.hex(8),
        reply_to: env.str?("reply_to"),
        ordering: ordering,
      )
    end

    # Some MCP clients (and hand-rolled HTTP callers) stringify the payload
    # instead of nesting it as JSON — the tool schema advertised the field as
    # "any JSON value" with no type, so a client can rationally send
    # `payload: "{\"text\":\"hi\"}"`. Left alone, schema-validated services
    # (openai:tts, anthropic:chat, ...) look for their fields at the top
    # level of the payload, don't find them, and reply "missing required
    # fields." Auto-unwrap looks-like-JSON strings back to real objects.
    # A literal string payload like `"hello"` stays a string.
    private def normalize_payload(raw : JSON::Any?) : JSON::Any
      return JSON::Any.new(nil) if raw.nil?
      if s = raw.as_s?
        stripped = s.lstrip
        if stripped.starts_with?('{') || stripped.starts_with?('[')
          begin
            parsed = JSON.parse(s)
            return parsed if parsed.as_h? || parsed.as_a?
          rescue JSON::ParseException
            # Fall through — payload was a string that looks like JSON but
            # isn't valid; keep it as a string so the caller sees their
            # original data.
          end
        end
      end
      raw
    end

    # WebSocket handler for /bus path.
    private class WebSocketHandler
      include HTTP::Handler

      def initialize(
        @bus : Bus,
        @directory : Directory,
        @auth_required : Bool = false,
        @events : Events::Backend? = nil,
      )
        @connections = {} of String => HTTP::WebSocket
        @mutex = Mutex.new
      end

      def call(context : HTTP::Server::Context)
        if websocket_request?(context) && context.request.path == "/bus"
          unless authorized?(context)
            @events.try &.record(Events::Event.new(
              type: "auth.failed",
              subject: "/bus",
              metadata: {
                "reason"    => JSON::Any.new("missing or invalid bearer token"),
                "transport" => JSON::Any.new("websocket"),
              } of String => JSON::Any,
            ))
            context.response.status = HTTP::Status::UNAUTHORIZED
            context.response.headers["WWW-Authenticate"] = "Bearer"
            context.response.content_type = "application/json"
            context.response.print %({"error":"unauthorized"})
            return
          end

          ws = HTTP::WebSocketHandler.new do |socket|
            handle_connection(socket)
          end
          ws.call(context)
        else
          call_next(context)
        end
      end

      private def authorized?(ctx : HTTP::Server::Context) : Bool
        return true unless @auth_required
        header = ctx.request.headers["Authorization"]?
        return false unless header
        return false unless header.starts_with?("Bearer ")
        token = header[7..].strip
        return false if token.empty?
        !Arcana::Auth::ApiKey.verify(token).nil?
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
            type = parsed.str("type")

            case type
            when "join"
              raw_addr = parsed.str?("address")
              next unless raw = raw_addr
              Directory.validate_address(raw)

              # Caller can opt out of directory listing (pure consumers that
              # send/subscribe but never accept addressed messages).
              listed = parsed.bool?("listed")
              listed = true if listed.nil?

              # Register in directory unless already present (allows reconnection
              # after restart when state was loaded from disk).
              if listed && !@directory.lookup(raw)
                kind_str = parsed.str?("kind")
                kind = case kind_str
                       when "service" then Directory::Kind::Service
                       when "agent"   then Directory::Kind::Agent
                       end
                @directory.register(Directory::Listing.new(
                  address: raw,
                  name: parsed.str?("name") || raw,
                  description: parsed.str("description"),
                  kind: kind,
                  capability: parsed.str?("capability"),
                  guide: parsed.str?("guide"),
                  schema: parsed["schema"]?,
                  tags: parsed.str_arr("tags"),
                ))
              end

              # Create mailbox on local bus
              mailbox = @bus.mailbox(raw)
              address = raw

              @mutex.synchronize { @connections[raw] = ws }

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
              topic = parsed.str("topic")
              envelope = parse_envelope(parsed)
              @bus.publish(topic, envelope)

            when "subscribe"
              topic = parsed.str("topic")
              if (addr = address) && !addr.empty? && !topic.empty?
                @bus.subscribe(topic, addr)
              end

            when "unsubscribe"
              topic = parsed.str("topic")
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
          from: env.str("from"),
          to: env.str("to"),
          subject: env.str("subject"),
          payload: env["payload"]? || JSON::Any.new(nil),
          correlation_id: env.str?("correlation_id") || Random::Secure.hex(8),
          reply_to: env.str?("reply_to"),
        )
      end
    end
  end
end
