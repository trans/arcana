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

    # Callback invoked after every state-changing REST op (/register,
    # /unregister). The daemon wires this to `Snapshot.save` so state
    # is persisted through the same path as graceful-shutdown saves —
    # which respects the ephemeral flag and doesn't accumulate
    # code-registered zombies across restarts.
    property state_saver : Proc(Nil)? = nil

    # Optional event recorder for auth failures and server lifecycle.
    property events : Events::Backend?

    # When true, every REST request (except /health) and every WebSocket
    # upgrade must present a valid `Authorization: Bearer ak_...` header
    # that resolves via Arcana::Auth::ApiKey.verify. Requires the identity
    # store (ARCANA_DATABASE_URL).
    property auth_required : Bool = false

    # Other names for this machine, besides localhost and its loopback
    # addresses, that requests may use (see `LocalGuard`).
    property allowed_hosts : Array(String) = [] of String

    def initialize(
      @bus : Bus,
      @directory : Directory,
      @host : String = "0.0.0.0",
      @port : Int32 = 19118,
    )
    end

    # Start the server. Blocks.
    def start
      server = HTTP::Server.new([
        LocalGuard.new(@host, @allowed_hosts, @events),
        WebSocketHandler.new(@bus, @directory, auth_required: @auth_required, events: @events, state_saver: @state_saver),
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

    # Has the sender proved `address` is its own, showing the key or the
    # owner token the address is held by? An address held by neither
    # proves nothing.
    def self.proves?(directory : Directory, address : String, key : String?, token : String?) : Bool
      return false if address.empty? || (key.nil? && token.nil?) || !directory.held?(address)
      directory.check_holder!(address, owner_token: token, key: key)
      true
    rescue Directory::HeldError
      false
    end

    # Where a signed request's key goes once its signature checks. One a
    # client sends is dropped first.
    PROVEN_KEY = "Arcana-Proven-Key"

    @nonces = Signing::Nonces.new

    # Check a signed request (see `Signing`): a request signed wrongly,
    # out of time or with a nonce already used is refused (401), since
    # that is a broken client or a replay. An unsigned one passes, as
    # before keys.
    private def check_signature!(ctx : HTTP::Server::Context) : Bool
      request = ctx.request
      request.headers.delete(PROVEN_KEY)
      return true unless request.headers[Signing::SIGNATURE_HEADER]?
      body = request.body.try(&.gets_to_end) || ""
      request.body = body
      signed = Signing.signed_request(request.headers, request.method, request.headers["Host"]? || "", request.resource, body).not_nil!
      raise Arcana::Error.new("the request's nonce was used before") unless @nonces.fresh?(signed.nonce)
      request.headers[PROVEN_KEY] = signed.key
      true
    rescue ex : Arcana::Error
      @events.try &.record(Events::Event.new(
        type: "auth.failed",
        subject: ctx.request.path,
        metadata: {
          "reason" => JSON::Any.new(ex.message || "bad signature"),
          "key"    => JSON::Any.new(ctx.request.headers[Signing::KEY_HEADER]? || ""),
        } of String => JSON::Any,
      ))
      ctx.response.status = HTTP::Status::UNAUTHORIZED
      ctx.response.content_type = "application/json"
      ctx.response.print({error: "#{ex.message}: nothing was done"}.to_json)
      false
    end

    # The key a request was signed with, once checked.
    private def proven_key(ctx : HTTP::Server::Context) : String?
      ctx.request.headers[PROVEN_KEY]?
    end

    # Reading an address a key holds without that key's signature is
    # logged, not yet refused: once the log shows no reader still does,
    # reading will need the key.
    private def note_read(ctx : HTTP::Server::Context, address : String) : Nil
      key = @directory.key_for(address)
      return unless key && proven_key(ctx) != key
      @events.try &.record(Events::Event.new(
        type: "read.unproven",
        subject: address,
        metadata: {"path" => JSON::Any.new(ctx.request.path)} of String => JSON::Any,
      ))
    end

    private def save_state
      @state_saver.try &.call
    end

    private def check_token!(address : String, parsed : JSON::Any)
      expected = @tokens[address]?
      return unless expected # no token set = no auth required
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
      return unless check_signature!(ctx)
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
          k = Directory::Kind.from_name?(kind) || Directory::Kind::Service
          ctx.response.print @directory.to_json(@directory.by_kind(k))
        else
          ctx.response.print @directory.to_json
        end
      when {"GET", "/events"}
        handle_get_events(ctx)
      when {"GET", _}
        if path.starts_with?("/directory/")
          # Decoded, since a topic's `#` must be sent as `%23`.
          address = URI.decode(path.lchop("/directory/"))
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
      when {"POST", "/subscribe"}
        handle_post_subscribe(ctx, subscribe: true)
      when {"POST", "/unsubscribe"}
        handle_post_subscribe(ctx, subscribe: false)
      when {"POST", "/subscriptions"}
        handle_post_subscriptions(ctx)
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
      when {"POST", "/presence"}
        handle_post_presence(ctx)
      when {"POST", "/peek"}
        handle_post_peek(ctx)
      else
        ctx.response.status = HTTP::Status::NOT_FOUND
        ctx.response.print %({"error":"not found"})
      end
    end

    # Register an address. With `owner_token`, re-registering an address
    # you already hold succeeds (`status: "yours"`) instead of failing,
    # so an agent can tell its own registration from someone else's;
    # see `Directory#claim`. The reply carries the listing, including
    # `online`, `last_seen` and `expires_at` for agents.
    #
    # A `#topic` gets a log instead of a mailbox; `retention` (a number
    # of posts, or `{ring: N}`) says how many it keeps.
    private def handle_post_register(ctx : HTTP::Server::Context)
      parsed = JSON.parse(ctx.request.body.not_nil!)
      address = parsed.str("address")
      raise "address required" if address.empty?
      Directory.validate_address(address)
      topic = Directory.topic?(address)
      retention = retention_of(parsed)
      raise "retention is for topics" if retention && !topic

      # An existing mailbox token can only be presented, not replaced:
      # otherwise a registration that fails below would still swap the
      # owner's token for the caller's.
      token = parsed.str?("token").try(&.presence)
      check_token!(address, parsed) if token && @tokens.has_key?(address)

      # Register in directory unless caller opted out (e.g. pure consumers
      # that send/subscribe but never accept addressed messages).
      listed = parsed.bool?("listed")
      listed = true if listed.nil?
      raise "a topic is always listed: that's how readers find it" if topic && !listed
      claim = nil
      if listed
        claim = @directory.claim(Directory::Listing.new(
          address: address,
          name: parsed.str?("name") || address,
          description: parsed.str("description"),
          kind: Directory::Kind.from_name?(parsed.str?("kind")),
          schema: parsed["schema"]?,
          guide: parsed.str?("guide"),
          tags: parsed.str_arr("tags"),
          retention: retention,
        ), parsed.str?("owner_token"), key: proven_key(ctx))
      end

      if topic
        @bus.topic_log(address)
      else
        # Create mailbox (always — sender check requires has_mailbox?)
        @bus.mailbox(address)
        @tokens[address] = token if token
      end
      save_state

      ctx.response.print(JSON.build do |j|
        j.object do
          j.field "ok", true
          j.field "address", address
          if c = claim
            j.field "status", c.to_s.downcase
            if listing = @directory.lookup(address)
              j.field("listing") { j.raw(@directory.to_json(listing)) }
            end
          end
        end
      end)
    rescue ex : Directory::HeldError
      respond_held(ctx, ex)
    rescue ex
      respond_error(ctx, HTTP::Status::BAD_REQUEST, ex.message)
    end

    # Mark an agent online or offline. Offline means no session is
    # running; the mailbox keeps collecting mail. Requires the owner
    # token when the address was registered with one.
    private def handle_post_presence(ctx : HTTP::Server::Context)
      parsed = JSON.parse(ctx.request.body.not_nil!)
      address = parsed.str("address")
      raise "address required" if address.empty?
      online = parsed.bool?("online")
      raise "online (true or false) required" if online.nil?
      @directory.check_holder!(address, owner_token: parsed.str?("owner_token"), key: proven_key(ctx))
      @directory.set_online(address, online)
      save_state
      ctx.response.print({ok: true, address: address, online: online}.to_json)
    rescue ex : Directory::HeldError
      respond_held(ctx, ex)
    rescue ex
      respond_error(ctx, HTTP::Status::BAD_REQUEST, ex.message)
    end

    private def respond_error(ctx : HTTP::Server::Context, status : HTTP::Status, message : String?) : Nil
      ctx.response.status = status
      ctx.response.print({error: message || "error"}.to_json)
    end

    # 409 with the holder's public listing, so a caller that is in fact
    # the holder (but lost its owner token) can recognize itself.
    private def respond_held(ctx : HTTP::Server::Context, ex : Directory::HeldError) : Nil
      ctx.response.status = HTTP::Status::CONFLICT
      ctx.response.print(JSON.build do |j|
        j.object do
          j.field "error", ex.message
          j.field "held", true
          if listing = @directory.lookup(ex.address)
            j.field("listing") { j.raw(@directory.to_json(listing)) }
          end
        end
      end)
    end

    private def handle_post_unregister(ctx : HTTP::Server::Context)
      parsed = JSON.parse(ctx.request.body.not_nil!)
      address = parsed.str("address")
      raise "address required" if address.empty?

      check_token!(address, parsed)
      @directory.check_holder!(address, owner_token: parsed.str?("owner_token"), key: proven_key(ctx))

      @directory.unregister(address)
      if Directory.topic?(address)
        @bus.remove_topic(address)
      else
        @bus.remove_mailbox(address)
        @tokens.delete(address)
      end
      save_state

      ctx.response.print %({"ok":true,"address":"#{address}"})
    rescue ex : Directory::HeldError
      respond_held(ctx, ex)
    rescue ex
      ctx.response.status = HTTP::Status::BAD_REQUEST
      ctx.response.print %({"error":"#{ex.message}"})
    end

    private def handle_post_inbox(ctx : HTTP::Server::Context)
      parsed = JSON.parse(ctx.request.body.not_nil!)
      address = parsed.str("address")
      raise "address required" if address.empty?
      return read_topic(ctx, address, parsed) if Directory.topic?(address)
      resolved = resolve_addr(address)
      check_token!(resolved, parsed)
      note_read(ctx, resolved)

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
      if Directory.topic?(address)
        raise "#{address} is a topic, shared by everyone: read it with inbox and `after` (the last post number you saw). Receiving would take posts away from the others."
      end
      resolved = resolve_addr(address)
      check_token!(resolved, parsed)
      note_read(ctx, resolved)

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
      envelope = envelope_from_json(parsed, ctx)
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
        envelope = envelope_from_json(parsed, ctx)
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

      # Sigil-aware: `@mj` and `mj` are distinct entities on purpose,
      # so a typo of `@mj` shouldn't cross-suggest `mj` (or vice versa),
      # and a `#topic` suggests only topics. Filter candidates to the
      # same sigil group as the failed address.
      sigil = ->(a : String) { a[0]?.try { |c| c.in?('@', '#') ? c : nil } }
      failed_sigil = sigil.call(addr)
      listings = listings.select { |l| sigil.call(l.address) == failed_sigil }
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
      envelope = envelope_from_json(parsed, ctx)
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
      if Directory.topic?(address)
        ctx.response.print({address: address, last_seq: @bus.topic_log(address).head}.to_json)
        return
      end
      resolved = resolve_addr(address)
      check_token!(resolved, parsed)

      count = @bus.pending(resolved)
      ctx.response.print %|{"address":"#{resolved}","pending":#{count}}|
    rescue ex
      ctx.response.status = HTTP::Status::BAD_REQUEST
      ctx.response.print %|{"error":"#{ex.message}"}|
    end

    # Publish to a topic. For a `#topic` the reply carries the post's
    # number (`seq`) and how many subscribe.
    private def handle_post_publish(ctx : HTTP::Server::Context)
      topic = ""
      begin
        parsed = JSON.parse(ctx.request.body.not_nil!)
        topic = parsed.str("topic")
        raise "topic required" if topic.empty?
        envelope = envelope_from_json(parsed, ctx)
        check_sender!(envelope.from)
        if seq = @bus.publish(topic, envelope)
          ctx.response.print({ok: true, topic: topic, seq: seq, correlation_id: envelope.correlation_id, subscribers: @bus.subscribers(topic).size}.to_json)
        else
          ctx.response.print %({"ok":true})
        end
      rescue ex : Arcana::Error
        ctx.response.status = HTTP::Status::BAD_REQUEST
        ctx.response.print error_with_suggestion(topic, ex.message || "publish failed")
      rescue ex
        ctx.response.status = HTTP::Status::BAD_REQUEST
        ctx.response.print({error: ex.message}.to_json)
      end
    end

    # Read a `#topic`: the posts after `after` (default 0, from the
    # oldest kept), at most `limit` (default 100, at most 1000). Reading
    # consumes nothing. `first_seq` past `after + 1` means posts were
    # dropped before the reader got to them.
    private def read_topic(ctx : HTTP::Server::Context, topic : String, parsed : JSON::Any) : Nil
      log = @bus.topic_log(topic)
      after = parsed.i64?("after") || 0_i64
      limit = (parsed.int?("limit") || 100).clamp(0, 1000)
      posts = log.read(after, limit)
      ctx.response.print(JSON.build do |j|
        j.object do
          j.field "topic", topic
          j.field "first_seq", log.first
          j.field "last_seq", log.head
          j.field "posts" do
            j.array do
              posts.each do |post|
                env = post.envelope
                j.object do
                  j.field "seq", post.seq
                  j.field "from", env.from
                  j.field "subject", env.subject
                  j.field "payload", env.payload
                  j.field "correlation_id", env.correlation_id
                  j.field "reply_to", env.reply_to if env.reply_to
                  j.field "timestamp", env.timestamp.to_rfc3339
                  j.field "id", env.id if env.id
                  j.field "re", env.re if env.re
                  if sig = env.signature
                    j.field "signature" do
                      j.object do
                        j.field "key", sig.key
                        j.field "sig", sig.sig
                      end
                    end
                  end
                  j.field "verified", true if env.verified
                end
              end
            end
          end
        end
      end)
    end

    # Subscribe an address to a topic, or unsubscribe it. Needs the
    # address's token and owner token when it has them, so nobody signs
    # up someone else. `cadence` is "always" (the only one so far).
    private def handle_post_subscribe(ctx : HTTP::Server::Context, subscribe : Bool)
      parsed = JSON.parse(ctx.request.body.not_nil!)
      topic = parsed.str("topic")
      address = parsed.str("address")
      raise "topic required" if topic.empty?
      raise "address required" if address.empty?
      check_token!(address, parsed)
      @directory.check_holder!(address, owner_token: parsed.str?("owner_token"), key: proven_key(ctx))
      if subscribe
        @bus.subscribe(topic, address, parsed.str?("cadence") || "always")
      else
        @bus.unsubscribe(topic, address)
      end
      save_state if Directory.topic?(topic)
      ctx.response.print({ok: true, topic: topic, address: address, subscribed: subscribe}.to_json)
    rescue ex : Directory::HeldError
      respond_held(ctx, ex)
    rescue ex
      respond_error(ctx, HTTP::Status::BAD_REQUEST, ex.message)
    end

    # The topics an address subscribes to.
    private def handle_post_subscriptions(ctx : HTTP::Server::Context)
      parsed = JSON.parse(ctx.request.body.not_nil!)
      address = parsed.str("address")
      raise "address required" if address.empty?
      ctx.response.print({address: address, topics: @bus.subscriptions(address).sort}.to_json)
    rescue ex
      respond_error(ctx, HTTP::Status::BAD_REQUEST, ex.message)
    end

    # A topic's `retention`: a number of posts, or `{ring: N}`. Nil when
    # not given.
    private def retention_of(parsed : JSON::Any) : Int32?
      raw = parsed["retention"]?
      return if raw.nil? || raw.raw.nil?
      n = raw.as_i64? || raw.as_h?.try(&.["ring"]?).try(&.as_i64?)
      raise "retention must be a number of posts, or {ring: N}" unless n
      TopicLog.check_retention!(n)
      n.to_i32
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

    # The envelope a REST request carries, stamped `verified` when the
    # request's signature shows the key holding `from`. A signed
    # envelope's payload is left as it is, since unwrapping it would
    # void the signature.
    private def envelope_from_json(parsed : JSON::Any, ctx : HTTP::Server::Context) : Envelope
      env = parsed["envelope"]? || parsed
      ordering = case env.str?("ordering")
                 when "sync"  then Ordering::Sync
                 when "async" then Ordering::Async
                 else              Ordering::Auto
                 end
      signature = Envelope.signature_of(env["signature"]?)
      envelope = Envelope.new(
        from: env.str("from"),
        to: env.str("to"),
        subject: env.str("subject"),
        payload: signature ? (env["payload"]? || JSON::Any.new(nil)) : Server.normalize_payload(env["payload"]?),
        correlation_id: env.str?("correlation_id") || Random::Secure.hex(8),
        reply_to: env.str?("reply_to"),
        ordering: ordering,
        timestamp: Server.timestamp_of(env),
        id: env.str?("id"),
        re: env.str?("re"),
        signature: signature,
      )
      envelope.verified = Server.proves?(@directory, envelope.from, proven_key(ctx), nil)
      envelope
    end

    # The time an envelope was written with, or now when it has none
    # that reads.
    def self.timestamp_of(env : JSON::Any) : Time
      env.str?("timestamp").try { |t| Time.parse_rfc3339(t) rescue nil } || Time.utc
    end

    # Some MCP clients (and hand-rolled HTTP callers) stringify the payload
    # instead of nesting it as JSON — the tool schema advertised the field as
    # "any JSON value" with no type, so a client can rationally send
    # `payload: "{\"text\":\"hi\"}"`. Left alone, schema-validated services
    # (openai:tts, anthropic:chat, ...) look for their fields at the top
    # level of the payload, don't find them, and reply "missing required
    # fields." Auto-unwrap looks-like-JSON strings back to real objects.
    # A literal string payload like `"hello"` stays a string. The MCP
    # bridge does the same before filing its copy of a message it sends.
    def self.normalize_payload(raw : JSON::Any?) : JSON::Any
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
        @state_saver : Proc(Nil)? = nil,
      )
        @connections = {} of String => HTTP::WebSocket
        @mutex = Mutex.new
      end

      private def save_state
        @state_saver.try &.call
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

          bus_host = context.request.headers["Host"]? || ""
          ws = HTTP::WebSocketHandler.new do |socket|
            handle_connection(socket, bus_host)
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

      # A join that offered a key, waiting for the client to sign the
      # challenge it was sent.
      private record PendingJoin, address : String, key : String, challenge : String,
        listing : Directory::Listing, listed : Bool, owner_token : String?

      # `bus_host` is the `Host` the client asked for, which its join
      # proof must name (see `Signing.join_proof`).
      private def handle_connection(ws : HTTP::WebSocket, bus_host : String)
        address : String? = nil
        forwarder : Fiber? = nil
        pending : PendingJoin? = nil
        # What the connection proved at join, so its messages from an
        # address held by that key or token are stamped `verified`.
        proven_key : String? = nil
        proven_token : String? = nil

        attach = ->(raw : String) do
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
          nil
        end

        ws.on_message do |msg|
          begin
            parsed = JSON.parse(msg)
            type = parsed.str("type")

            case type
            when "join"
              raw_addr = parsed.str?("address")
              next unless raw = raw_addr
              Directory.validate_address(raw)
              raise "#{raw} is a topic, which can't join: register it with POST /register" if Directory.topic?(raw)

              # Caller can opt out of directory listing (pure consumers that
              # send/subscribe but never accept addressed messages).
              listed = parsed.bool?("listed")
              listed = true if listed.nil?

              kind_str = parsed.str?("kind")
              kind = case kind_str
                     when "service" then Directory::Kind::Service
                     when "agent"   then Directory::Kind::Agent
                     end
              listing = Directory::Listing.new(
                address: raw,
                name: parsed.str?("name") || raw,
                description: parsed.str("description"),
                kind: kind,
                guide: parsed.str?("guide"),
                schema: parsed["schema"]?,
                tags: parsed.str_arr("tags"),
              )
              owner_token = parsed.str?("owner_token").try(&.presence)

              # A join offering a key is attached only once the client
              # signs the challenge sent back ("prove" below).
              if key = parsed.str?("key").try(&.presence)
                raise "not a public key: #{key}" unless Key.valid_public_key?(key)
                challenge = Signing.challenge
                pending = PendingJoin.new(raw, key, challenge, listing, listed, owner_token)
                ws.send({type: "challenge", challenge: challenge}.to_json)
                next
              end

              # With an owner token, the join claims the address as
              # POST /register does, and a join showing another token is
              # refused (HeldError). Without one, an address held under a
              # token or a key is still joined for now, but the event log
              # records it, so the clients that would break are known
              # before joins need proof.
              if owner_token
                if listed
                  @directory.claim(listing, owner_token)
                  save_state
                else
                  @directory.check_owner!(raw, owner_token)
                end
                proven_token = owner_token
              elsif @directory.held?(raw)
                @events.try &.record(Events::Event.new(
                  type: "join.unproven",
                  subject: raw,
                  metadata: {"reason" => JSON::Any.new("joined without the owner token or key the address is held by")} of String => JSON::Any,
                ))
              elsif listed && !@directory.lookup(raw)
                # Register in directory unless already present (allows reconnection
                # after restart when state was loaded from disk).
                @directory.register(listing)
              end
              attach.call(raw)
            when "prove"
              join = pending
              raise "nothing to prove: join with your key first" unless join
              pending = nil
              signature = parsed.str("signature")
              unless Key.verify(join.key, signature, Signing.join_proof(bus_host, join.address, join.challenge))
                @events.try &.record(Events::Event.new(
                  type: "auth.failed",
                  subject: join.address,
                  metadata: {
                    "reason" => JSON::Any.new("the join's signature doesn't match its key"),
                    "key"    => JSON::Any.new(join.key),
                  } of String => JSON::Any,
                ))
                raise "the join's signature doesn't match its key (signed for bus #{bus_host}?)"
              end
              if join.listed
                @directory.claim(join.listing, join.owner_token, key: join.key)
                save_state
              else
                @directory.check_holder!(join.address, owner_token: join.owner_token, key: join.key)
              end
              proven_key = join.key
              proven_token = join.owner_token
              attach.call(join.address)
              ws.send({type: "joined", address: join.address, verified: true}.to_json)
            when "send"
              envelope = parse_envelope(parsed)
              envelope.verified = Server.proves?(@directory, envelope.from, proven_key, proven_token)
              bounce(envelope) unless @bus.send?(envelope)
            when "publish"
              topic = parsed.str("topic")
              envelope = parse_envelope(parsed)
              envelope.verified = Server.proves?(@directory, envelope.from, proven_key, proven_token)
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
            ws.send({error: ex.message}.to_json)
          end
        end

        # An address held under an owner token outlives the connection, as
        # an agent's handle outlives its session: it stays listed, and its
        # mailbox keeps collecting.
        ws.on_close do
          if addr = address
            @mutex.synchronize { @connections.delete(addr) if @connections[addr]? == ws }
            unless @directory.held?(addr)
              @directory.unregister(addr)
              @bus.remove_mailbox(addr)
            end
          end
        end

        ws.run
      end

      # A message sent over a socket that the bus couldn't take (no mailbox
      # for its address, or a full one) goes back to its sender as an
      # error reply under its correlation_id, so a request fails at once
      # instead of waiting out its timeout, as the REST deliver's error
      # does. Not a reply whose request gave up (its `_reply:` mailbox is
      # gone), nor an error itself.
      private def bounce(envelope : Envelope) : Nil
        return if envelope.from.empty? || envelope.to.starts_with?("_reply:") || Protocol.error?(envelope.payload)
        why = @bus.has_mailbox?(envelope.to) ? "#{envelope.to}'s mailbox is full" : "No mailbox for address: #{envelope.to}"
        @bus.send?(envelope.reply(from: envelope.to, payload: Protocol.error(why, "undeliverable")))
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
          timestamp: Server.timestamp_of(env),
          id: env.str?("id"),
          re: env.str?("re"),
          signature: Envelope.signature_of(env["signature"]?),
        )
      end
    end
  end
end
