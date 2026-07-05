require "./spec_helper"
require "http/client"
require "file_utils"

describe Arcana::Server do
  it "serves REST directory endpoints" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new

    dir.register(Arcana::Directory::Listing.new(
      address: "test-agent",
      name: "Test Agent",
      description: "A test agent",
      tags: ["test"],
    ))

    server = Arcana::Server.new(bus, dir, port: 14000)
    server.start_in_background

    begin
      # GET /health
      resp = HTTP::Client.get("http://127.0.0.1:14000/health")
      resp.status_code.should eq(200)
      health = JSON.parse(resp.body)
      health["status"].as_s.should eq("ok")

      # GET /directory
      resp = HTTP::Client.get("http://127.0.0.1:14000/directory")
      resp.status_code.should eq(200)
      listings = JSON.parse(resp.body).as_a
      listings.size.should eq(1)
      listings[0]["address"].as_s.should eq("test-agent")

      # GET /directory?tag=test
      resp = HTTP::Client.get("http://127.0.0.1:14000/directory?tag=test")
      JSON.parse(resp.body).as_a.size.should eq(1)

      # GET /directory?q=test
      resp = HTTP::Client.get("http://127.0.0.1:14000/directory?q=test")
      JSON.parse(resp.body).as_a.size.should eq(1)

      # GET /directory?kind=agent
      resp = HTTP::Client.get("http://127.0.0.1:14000/directory?kind=agent")
      JSON.parse(resp.body).as_a.size.should eq(1)

      # GET /directory/test-agent
      resp = HTTP::Client.get("http://127.0.0.1:14000/directory/test-agent")
      resp.status_code.should eq(200)
      JSON.parse(resp.body)["name"].as_s.should eq("Test Agent")

      # GET /directory/nonexistent
      resp = HTTP::Client.get("http://127.0.0.1:14000/directory/nonexistent")
      resp.status_code.should eq(404)

      # GET /unknown
      resp = HTTP::Client.get("http://127.0.0.1:14000/unknown")
      resp.status_code.should eq(404)
    ensure
      server.stop
    end
  end

  it "handles POST /send and /request" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new

    # Start an echo service
    svc = Arcana::Service.new(
      bus: bus, directory: dir,
      address: "arcana:echo",
      name: "Echo",
      description: "Echoes payload back",
    ) { |data| data }
    svc.start

    # Register sender mailboxes
    bus.mailbox("test-client")
    bus.mailbox("test")

    server = Arcana::Server.new(bus, dir, port: 14001)
    server.start_in_background

    begin
      headers = HTTP::Headers{"Content-Type" => "application/json"}

      # POST /send from unregistered sender — should be rejected
      body = {from: "ghost", to: "arcana:echo", payload: "nope"}.to_json
      resp = HTTP::Client.post("http://127.0.0.1:14001/send", headers: headers, body: body)
      resp.status_code.should eq(400)
      JSON.parse(resp.body)["error"].as_s.should contain("not registered")

      # POST /request — should get echo reply
      body = {
        from:    "test-client",
        to:      "arcana:echo",
        subject: "ping",
        payload: {message: "hello"},
      }.to_json

      resp = HTTP::Client.post("http://127.0.0.1:14001/request", headers: headers, body: body)
      resp.status_code.should eq(200)
      result = JSON.parse(resp.body)
      result["from"].as_s.should eq("arcana:echo")

      # POST /send — fire and forget
      body = {from: "test", to: "arcana:echo", payload: "fire"}.to_json
      resp = HTTP::Client.post("http://127.0.0.1:14001/send", headers: headers, body: body)
      resp.status_code.should eq(200)

      # POST /send to nonexistent address
      body = {from: "test", to: "nobody", payload: "lost"}.to_json
      resp = HTTP::Client.post("http://127.0.0.1:14001/send", headers: headers, body: body)
      resp.status_code.should eq(404)

      # POST /request with timeout
      body = {from: "test", to: "arcana:echo", payload: "fast", timeout_ms: 5000}.to_json
      resp = HTTP::Client.post("http://127.0.0.1:14001/request", headers: headers, body: body)
      resp.status_code.should eq(200)
    ensure
      server.stop
    end
  end

  it "enforces token auth on receive and unregister" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new

    server = Arcana::Server.new(bus, dir, port: 14002)
    server.start_in_background

    begin
      headers = HTTP::Headers{"Content-Type" => "application/json"}

      # Register with a token
      body = {address: "secure-agent", token: "s3cret", name: "Secure"}.to_json
      resp = HTTP::Client.post("http://127.0.0.1:14002/register", headers: headers, body: body)
      resp.status_code.should eq(200)

      # Receive with correct token
      body = {address: "secure-agent", token: "s3cret"}.to_json
      resp = HTTP::Client.post("http://127.0.0.1:14002/receive", headers: headers, body: body)
      resp.status_code.should eq(200)

      # Receive with wrong token
      body = {address: "secure-agent", token: "wrong"}.to_json
      resp = HTTP::Client.post("http://127.0.0.1:14002/receive", headers: headers, body: body)
      resp.status_code.should eq(400)
      JSON.parse(resp.body)["error"].as_s.should eq("unauthorized")

      # Receive with no token
      body = {address: "secure-agent"}.to_json
      resp = HTTP::Client.post("http://127.0.0.1:14002/receive", headers: headers, body: body)
      resp.status_code.should eq(400)

      # Unregister with wrong token
      body = {address: "secure-agent", token: "wrong"}.to_json
      resp = HTTP::Client.post("http://127.0.0.1:14002/unregister", headers: headers, body: body)
      resp.status_code.should eq(400)

      # Unregister with correct token
      body = {address: "secure-agent", token: "s3cret"}.to_json
      resp = HTTP::Client.post("http://127.0.0.1:14002/unregister", headers: headers, body: body)
      resp.status_code.should eq(200)
    ensure
      server.stop
    end
  end

  it "allows receive without token when none was set" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new

    server = Arcana::Server.new(bus, dir, port: 14003)
    server.start_in_background

    begin
      headers = HTTP::Headers{"Content-Type" => "application/json"}

      # Register without a token
      body = {address: "open-agent", name: "Open"}.to_json
      resp = HTTP::Client.post("http://127.0.0.1:14003/register", headers: headers, body: body)
      resp.status_code.should eq(200)

      # Receive without token — should work
      body = {address: "open-agent"}.to_json
      resp = HTTP::Client.post("http://127.0.0.1:14003/receive", headers: headers, body: body)
      resp.status_code.should eq(200)
    ensure
      server.stop
    end
  end

  describe "POST /register listed=false" do
    it "creates a mailbox without adding a directory listing" do
      bus = Arcana::Bus.new
      dir = Arcana::Directory.new
      server = Arcana::Server.new(bus, dir, port: 14400)
      server.start_in_background

      begin
        headers = HTTP::Headers{"Content-Type" => "application/json"}

        # Hidden registration
        body = {address: "wow-io", listed: false}.to_json
        resp = HTTP::Client.post("http://127.0.0.1:14400/register", headers: headers, body: body)
        resp.status_code.should eq(200)

        # Mailbox exists (so the sender check passes)
        bus.has_mailbox?("wow-io").should be_true

        # Directory listing does NOT exist
        dir.lookup("wow-io").should be_nil

        # Default behavior (no listed flag) still creates a listing
        body = {address: "alice"}.to_json
        resp = HTTP::Client.post("http://127.0.0.1:14400/register", headers: headers, body: body)
        resp.status_code.should eq(200)
        dir.lookup("alice").should_not be_nil
      ensure
        server.stop
      end
    end
  end

  describe "GET /events" do
    it "returns events when a backend is attached" do
      dir_path = File.tempname("arcana-events-rest")
      backend = Arcana::Events::FileBackend.new(log_dir: dir_path, retain_days: 7)
      begin
        bus = Arcana::Bus.new
        dir = Arcana::Directory.new
        bus.directory = dir
        bus.events = backend
        dir.events = backend

        dir.register(Arcana::Directory::Listing.new(
          address: "test-agent", name: "Test", description: "t",
        ))
        server = Arcana::Server.new(bus, dir, port: 14300)
        server.events = backend
        server.start_in_background
        sleep 100.milliseconds

        resp = HTTP::Client.get("http://127.0.0.1:14300/events?limit=50")
        resp.status_code.should eq(200)
        events = JSON.parse(resp.body).as_a
        events.size.should be > 0
        events.any? { |e| e["type"].as_s == "listing.registered" && e["subject"].as_s == "test-agent" }.should be_true

        # Filter by type
        resp = HTTP::Client.get("http://127.0.0.1:14300/events?type=listing.registered")
        JSON.parse(resp.body).as_a.all? { |e| e["type"].as_s == "listing.registered" }.should be_true

        server.stop
      ensure
        backend.close
        FileUtils.rm_rf(dir_path)
      end
    end

    it "404s when no backend is attached" do
      bus = Arcana::Bus.new
      dir = Arcana::Directory.new
      server = Arcana::Server.new(bus, dir, port: 14301)
      server.start_in_background
      begin
        resp = HTTP::Client.get("http://127.0.0.1:14301/events")
        resp.status_code.should eq(404)
      ensure
        server.stop
      end
    end
  end

  describe "did_you_mean on delivery failure" do
    it "suggests the closest registered address on /send miss" do
      bus = Arcana::Bus.new
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "memo",
        name: "Memo",
        description: "Semantic search and vector storage",
      ))
      bus.mailbox("memo")
      bus.mailbox("client")

      server = Arcana::Server.new(bus, dir, port: 14500)
      server.start_in_background
      begin
        headers = HTTP::Headers{"Content-Type" => "application/json"}
        body = {from: "client", to: "memo-agent", payload: "lost"}.to_json
        resp = HTTP::Client.post("http://127.0.0.1:14500/send", headers: headers, body: body)
        resp.status_code.should eq(404)
        parsed = JSON.parse(resp.body)
        parsed["error"].as_s.should contain("Did you mean 'memo'")
        parsed["did_you_mean"]["address"].as_s.should eq("memo")
        parsed["did_you_mean"]["name"].as_s.should eq("Memo")
      ensure
        server.stop
      end
    end

    it "suggests on /deliver miss too" do
      bus = Arcana::Bus.new
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "openai:chat",
        name: "OpenAI Chat",
        description: "Chat completion via OpenAI.",
      ))
      bus.mailbox("openai:chat")
      bus.mailbox("client")

      server = Arcana::Server.new(bus, dir, port: 14501)
      server.start_in_background
      begin
        headers = HTTP::Headers{"Content-Type" => "application/json"}
        body = {from: "client", to: "openai:chats", payload: nil}.to_json
        resp = HTTP::Client.post("http://127.0.0.1:14501/deliver", headers: headers, body: body)
        resp.status_code.should eq(404)
        parsed = JSON.parse(resp.body)
        parsed["did_you_mean"]["address"].as_s.should eq("openai:chat")
      ensure
        server.stop
      end
    end

    it "unwraps a stringified JSON payload so validated services see fields at the top level" do
      # Regression for cattacula's bug report: MCP clients that send
      # `payload: "{\"text\":\"hi\"}"` (JSON as a string) used to make
      # openai:tts / anthropic:chat reply "missing required fields"
      # because the schema check looked for "text" at the top level of
      # a string, not inside it. The server now normalizes stringified
      # JSON objects/arrays back to real structures at the boundary.
      bus = Arcana::Bus.new
      dir = Arcana::Directory.new

      schema = JSON.parse(%({"type":"object","required":["text"]}))
      captured = ""
      svc = Arcana::Service.new(
        bus: bus, directory: dir,
        address: "test:validated",
        name: "Validated",
        description: "Requires text",
        schema: schema,
      ) do |data|
        captured = data["text"].as_s
        JSON::Any.new({"echoed" => JSON::Any.new(captured)})
      end
      svc.start
      bus.mailbox("client")

      server = Arcana::Server.new(bus, dir, port: 14503)
      server.start_in_background
      begin
        headers = HTTP::Headers{"Content-Type" => "application/json"}
        # Payload comes in as a *string* — the way a naive MCP client encodes it.
        body = {from: "client", to: "test:validated", payload: %({"text":"hi"})}.to_json
        resp = HTTP::Client.post("http://127.0.0.1:14503/deliver", headers: headers, body: body)
        resp.status_code.should eq(200)
        parsed = JSON.parse(resp.body)
        payload = parsed["payload"]
        payload["_status"].as_s.should eq("result")
        payload["data"]["echoed"].as_s.should eq("hi")
        captured.should eq("hi")
      ensure
        server.stop
      end
    end

    it "leaves a legitimately-string payload alone" do
      bus = Arcana::Bus.new
      dir = Arcana::Directory.new
      seen = ""
      svc = Arcana::Service.new(
        bus: bus, directory: dir,
        address: "test:echo-str",
        name: "Echo",
        description: "echoes",
      ) do |data|
        seen = data.as_s
        data
      end
      svc.start
      bus.mailbox("client")

      server = Arcana::Server.new(bus, dir, port: 14504)
      server.start_in_background
      begin
        headers = HTTP::Headers{"Content-Type" => "application/json"}
        body = {from: "client", to: "test:echo-str", payload: "hello world"}.to_json
        resp = HTTP::Client.post("http://127.0.0.1:14504/deliver", headers: headers, body: body)
        resp.status_code.should eq(200)
        seen.should eq("hello world")
      ensure
        server.stop
      end
    end

    it "returns no suggestion when nothing is close enough" do
      bus = Arcana::Bus.new
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "alice",
        name: "Alice",
        description: "an agent",
      ))
      bus.mailbox("alice")
      bus.mailbox("client")

      server = Arcana::Server.new(bus, dir, port: 14502)
      server.start_in_background
      begin
        headers = HTTP::Headers{"Content-Type" => "application/json"}
        body = {from: "client", to: "zzzzzz", payload: nil}.to_json
        resp = HTTP::Client.post("http://127.0.0.1:14502/send", headers: headers, body: body)
        resp.status_code.should eq(404)
        parsed = JSON.parse(resp.body)
        parsed["error"].as_s.should_not contain("Did you mean")
        parsed["did_you_mean"]?.should be_nil
      ensure
        server.stop
      end
    end
  end

  # Bearer-token auth specs require a real Postgres test database so
  # api_keys can be created. Pending without ARCANA_TEST_DATABASE_URL.
  if test_url = ENV["ARCANA_TEST_DATABASE_URL"]?
    describe "bearer-token auth (ARCANA_AUTH_REQUIRED)" do
      around_each do |example|
        ENV["ARCANA_DATABASE_URL"] = test_url
        Arcana::DB.close
        db = Arcana::DB.connection!
        db.exec "DROP TABLE IF EXISTS api_keys CASCADE"
        db.exec "DROP TABLE IF EXISTS memberships CASCADE"
        db.exec "DROP TABLE IF EXISTS users CASCADE"
        db.exec "DROP TABLE IF EXISTS orgs CASCADE"
        db.exec "DROP TABLE IF EXISTS schema_migrations CASCADE"
        Arcana::DB::Migrate.run
        example.run
      ensure
        Arcana::DB.close
      end

      it "rejects REST requests without an Authorization header" do
        bus = Arcana::Bus.new
        dir = Arcana::Directory.new
        server = Arcana::Server.new(bus, dir, port: 14400)
        server.auth_required = true
        server.start_in_background
        begin
          resp = HTTP::Client.get("http://127.0.0.1:14400/directory")
          resp.status_code.should eq(401)
          resp.headers["WWW-Authenticate"]?.should eq("Bearer")
        ensure
          server.stop
        end
      end

      it "rejects REST requests with a bad token" do
        bus = Arcana::Bus.new
        dir = Arcana::Directory.new
        server = Arcana::Server.new(bus, dir, port: 14401)
        server.auth_required = true
        server.start_in_background
        begin
          headers = HTTP::Headers{"Authorization" => "Bearer ak_definitely_not_real"}
          resp = HTTP::Client.get("http://127.0.0.1:14401/directory", headers: headers)
          resp.status_code.should eq(401)
        ensure
          server.stop
        end
      end

      it "rejects REST requests with a revoked key" do
        org = Arcana::Auth::Org.create(slug: "acme", name: "Acme")
        key, secret = Arcana::Auth::ApiKey.create(name: "ci", org_id: org.id)
        key.revoke

        bus = Arcana::Bus.new
        dir = Arcana::Directory.new
        server = Arcana::Server.new(bus, dir, port: 14402)
        server.auth_required = true
        server.start_in_background
        begin
          headers = HTTP::Headers{"Authorization" => "Bearer #{secret}"}
          resp = HTTP::Client.get("http://127.0.0.1:14402/directory", headers: headers)
          resp.status_code.should eq(401)
        ensure
          server.stop
        end
      end

      it "accepts REST requests with a valid bearer token" do
        org = Arcana::Auth::Org.create(slug: "acme", name: "Acme")
        _key, secret = Arcana::Auth::ApiKey.create(name: "ci", org_id: org.id)

        bus = Arcana::Bus.new
        dir = Arcana::Directory.new
        server = Arcana::Server.new(bus, dir, port: 14403)
        server.auth_required = true
        server.start_in_background
        begin
          headers = HTTP::Headers{"Authorization" => "Bearer #{secret}"}
          resp = HTTP::Client.get("http://127.0.0.1:14403/directory", headers: headers)
          resp.status_code.should eq(200)
        ensure
          server.stop
        end
      end

      it "always allows /health, even without a token" do
        bus = Arcana::Bus.new
        dir = Arcana::Directory.new
        server = Arcana::Server.new(bus, dir, port: 14404)
        server.auth_required = true
        server.start_in_background
        begin
          resp = HTTP::Client.get("http://127.0.0.1:14404/health")
          resp.status_code.should eq(200)
        ensure
          server.stop
        end
      end

      it "leaves anonymous access intact when auth_required is false" do
        bus = Arcana::Bus.new
        dir = Arcana::Directory.new
        server = Arcana::Server.new(bus, dir, port: 14405)
        server.start_in_background
        begin
          resp = HTTP::Client.get("http://127.0.0.1:14405/directory")
          resp.status_code.should eq(200)
        ensure
          server.stop
        end
      end

      it "rejects WebSocket upgrades without a valid token" do
        bus = Arcana::Bus.new
        dir = Arcana::Directory.new
        server = Arcana::Server.new(bus, dir, port: 14406)
        server.auth_required = true
        server.start_in_background
        begin
          # Send an upgrade-style request without auth; the handler must
          # return 401 instead of completing the upgrade.
          headers = HTTP::Headers{
            "Upgrade"               => "websocket",
            "Connection"            => "Upgrade",
            "Sec-WebSocket-Key"     => "dGhlIHNhbXBsZSBub25jZQ==",
            "Sec-WebSocket-Version" => "13",
          }
          resp = HTTP::Client.get("http://127.0.0.1:14406/bus", headers: headers)
          resp.status_code.should eq(401)
        ensure
          server.stop
        end
      end
    end
  else
    pending "bearer-token auth (set ARCANA_TEST_DATABASE_URL to run)"
  end
end
