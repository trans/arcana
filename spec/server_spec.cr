require "./spec_helper"
require "http/client"

describe Arcana::Server do
  it "serves REST directory endpoints" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new

    dir.register(Arcana::Directory::Listing.new(
      address: "test-agent",
      name: "Test Agent",
      description: "A test agent",
      kind: Arcana::Directory::Kind::Agent,
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
      listings[0]["address"].as_s.should eq("test-agent:agent")

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
      address: "echo",
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
      body = {from: "ghost", to: "echo", payload: "nope"}.to_json
      resp = HTTP::Client.post("http://127.0.0.1:14001/send", headers: headers, body: body)
      resp.status_code.should eq(400)
      JSON.parse(resp.body)["error"].as_s.should contain("not registered")

      # POST /request — should get echo reply
      body = {
        from:    "test-client",
        to:      "echo",
        subject: "ping",
        payload: {message: "hello"},
      }.to_json

      resp = HTTP::Client.post("http://127.0.0.1:14001/request", headers: headers, body: body)
      resp.status_code.should eq(200)
      result = JSON.parse(resp.body)
      result["from"].as_s.should eq("echo:service")

      # POST /send — fire and forget
      body = {from: "test", to: "echo", payload: "fire"}.to_json
      resp = HTTP::Client.post("http://127.0.0.1:14001/send", headers: headers, body: body)
      resp.status_code.should eq(200)

      # POST /send to nonexistent address
      body = {from: "test", to: "nobody", payload: "lost"}.to_json
      resp = HTTP::Client.post("http://127.0.0.1:14001/send", headers: headers, body: body)
      resp.status_code.should eq(404)

      # POST /request with timeout
      body = {from: "test", to: "echo", payload: "fast", timeout_ms: 5000}.to_json
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
end
