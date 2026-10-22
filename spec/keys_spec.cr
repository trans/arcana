require "./spec_helper"
require "http/client"
require "http/web_socket"
require "file_utils"

# A live server on `port`, with an events log, for each example.
private def with_bus(port : Int32, &)
  log_dir = File.tempname("arcana-keys-events")
  events = Arcana::Events::FileBackend.new(log_dir: log_dir, retain_days: 7)
  bus = Arcana::Bus.new
  dir = Arcana::Directory.new
  bus.directory = dir
  server = Arcana::Server.new(bus, dir, host: "127.0.0.1", port: port)
  server.events = events
  server.start_in_background
  begin
    yield bus, dir, events
  ensure
    server.stop
    events.close
    FileUtils.rm_rf(log_dir)
  end
end

private def signed_post(port : Int32, key : Arcana::Key, path : String, body : String) : HTTP::Client::Response
  headers = Arcana::Signing.sign_request(key, "POST", "127.0.0.1:#{port}", path, body)
  headers["Content-Type"] = "application/json"
  HTTP::Client.post("http://127.0.0.1:#{port}#{path}", headers: headers, body: body)
end

private def joined(client : Arcana::Client) : Arcana::Client
  spawn { client.connect }
  sleep 150.milliseconds
  client
end

private def agent(address : String) : Arcana::Directory::Listing
  Arcana::Directory::Listing.new(address: address, name: address, description: "d",
    kind: Arcana::Directory::Kind::Agent)
end

describe "Keys on the bus" do
  describe "over the WebSocket" do
    it "holds the address for a client that signs the challenge, and stamps what it sends" do
      with_bus(14900) do |bus, dir, _events|
        key = Arcana::Key.generate
        inbox = bus.mailbox("@peer")
        client = joined(Arcana::Client.new(url: "ws://127.0.0.1:14900/bus", address: "@proj",
          kind: Arcana::Directory::Kind::Agent, key: key))
        begin
          client.verified?.should be_true
          dir.key_for("@proj").should eq(key.public_key)
          JSON.parse(HTTP::Client.get("http://127.0.0.1:14900/directory/@proj").body)["key"].should eq(key.public_key)

          client.send(Arcana::Envelope.new(from: "@proj", to: "@peer", payload: JSON.parse(%({"text":"hi"}))))
          got = inbox.receive(1.second).not_nil!
          got.verified.should be_true
          got.signer.should eq(key.public_key)

          client.send(Arcana::Envelope.new(from: "@someone-else", to: "@peer", subject: "forged"))
          inbox.receive(1.second).not_nil!.verified.should be_false
        ensure
          client.close
        end
      end
    end

    it "moves an address held under an owner token to the key only when the token is shown" do
      with_bus(14901) do |_bus, dir, _events|
        dir.claim(agent("@proj"), "tok")
        key = Arcana::Key.generate
        refused = joined(Arcana::Client.new(url: "ws://127.0.0.1:14901/bus", address: "@proj",
          kind: Arcana::Directory::Kind::Agent, key: key))
        begin
          refused.verified?.should be_false
          refused.last_error.not_nil!.should contain("move the address to your key")
          dir.key_for("@proj").should be_nil
        ensure
          refused.close
        end

        moved = joined(Arcana::Client.new(url: "ws://127.0.0.1:14901/bus", address: "@proj",
          kind: Arcana::Directory::Kind::Agent, key: key, owner_token: "tok"))
        begin
          moved.verified?.should be_true
          dir.key_for("@proj").should eq(key.public_key)
        ensure
          moved.close
        end
      end
    end

    it "refuses a join whose proof doesn't match its key, and attaches nothing" do
      with_bus(14902) do |bus, dir, events|
        key = Arcana::Key.generate
        frames = Channel(JSON::Any).new(10)
        ws = HTTP::WebSocket.new(URI.parse("ws://127.0.0.1:14902/bus"))
        ws.on_message { |msg| frames.send(JSON.parse(msg)) }
        spawn { ws.run }
        begin
          ws.send({type: "join", address: "@proj", kind: "agent", key: key.public_key}.to_json)
          challenge = frames.receive["challenge"].as_s
          wrong = key.sign(Arcana::Signing.join_proof("evil.example:14902", "@proj", challenge))
          ws.send({type: "prove", signature: wrong}.to_json)
          frames.receive["error"].as_s.should contain("doesn't match its key")
          dir.lookup("@proj").should be_nil
          bus.has_mailbox?("@proj").should be_false
          sleep 100.milliseconds
          events.query(type: "auth.failed").map(&.subject).should contain("@proj")
        ensure
          ws.close
        end
      end
    end

    it "clears a verified stamp a client wrote itself" do
      with_bus(14903) do |bus, dir, _events|
        dir.claim(agent("@proj"), key: Arcana::Key.generate.public_key)
        inbox = bus.mailbox("@peer")
        client = joined(Arcana::Client.new(url: "ws://127.0.0.1:14903/bus", address: "@lurker", listed: false))
        begin
          forged = Arcana::Envelope.new(from: "@proj", to: "@peer", subject: "trust me")
          forged.verified = true
          client.send(forged)
          inbox.receive(1.second).not_nil!.verified.should be_false
        ensure
          client.close
        end
      end
    end
  end

  describe "over REST" do
    it "stamps a delivery signed by the key holding `from`, and keeps the signature" do
      with_bus(14904) do |bus, dir, _events|
        key = Arcana::Key.generate
        dir.claim(agent("@proj"), key: key.public_key)
        bus.mailbox("@proj")
        inbox = bus.mailbox("@peer")
        envelope = Arcana::Envelope.new(from: "@proj", to: "@peer", payload: JSON.parse(%({"text":"hi"}))).signed(key)

        signed_post(14904, key, "/deliver", envelope.to_json).status_code.should eq(200)
        got = inbox.receive(1.second).not_nil!
        got.verified.should be_true
        got.signer.should eq(key.public_key)

        HTTP::Client.post("http://127.0.0.1:14904/deliver", body: %({"from":"@proj","to":"@peer","subject":"unsigned","verified":true}))
        inbox.receive(1.second).not_nil!.verified.should be_false

        other = Arcana::Key.generate
        signed_post(14904, other, "/deliver", %({"from":"@proj","to":"@peer","subject":"not theirs"}))
        inbox.receive(1.second).not_nil!.verified.should be_false
      end
    end

    it "refuses a request signed wrongly or replayed" do
      with_bus(14905) do |bus, _dir, events|
        key = Arcana::Key.generate
        bus.mailbox("@peer")
        body = %({"from":"","to":"@peer","subject":"x"})
        headers = Arcana::Signing.sign_request(key, "POST", "127.0.0.1:14905", "/deliver", body)
        HTTP::Client.post("http://127.0.0.1:14905/deliver", headers: headers, body: body).status_code.should eq(200)
        replay = HTTP::Client.post("http://127.0.0.1:14905/deliver", headers: headers, body: body)
        replay.status_code.should eq(401)
        JSON.parse(replay.body)["error"].as_s.should contain("nonce was used before")

        tampered = HTTP::Client.post("http://127.0.0.1:14905/deliver",
          headers: Arcana::Signing.sign_request(key, "POST", "127.0.0.1:14905", "/deliver", body), body: body + " ")
        tampered.status_code.should eq(401)
        bus.pending("@peer").should eq(1)
        sleep 100.milliseconds
        events.query(type: "auth.failed").size.should eq(2)
      end
    end

    it "claims a registration signed with a key, moving one held under the token shown" do
      with_bus(14906) do |_bus, dir, _events|
        key = Arcana::Key.generate
        dir.claim(agent("@proj"), "tok")
        resp = signed_post(14906, key, "/register", %({"address":"@proj","kind":"agent","owner_token":"tok"}))
        JSON.parse(resp.body)["status"].should eq("moved")
        JSON.parse(resp.body)["listing"]["key"].should eq(key.public_key)

        signed_post(14906, key, "/presence", %({"address":"@proj","online":false})).status_code.should eq(200)
        HTTP::Client.post("http://127.0.0.1:14906/presence", body: %({"address":"@proj","online":true})).status_code.should eq(409)
      end
    end

    it "logs reading an address a key holds without its signature" do
      with_bus(14907) do |bus, dir, events|
        key = Arcana::Key.generate
        dir.claim(agent("@proj"), key: key.public_key)
        bus.mailbox("@proj")
        signed_post(14907, key, "/inbox", %({"address":"@proj"})).status_code.should eq(200)
        HTTP::Client.post("http://127.0.0.1:14907/receive", body: %({"address":"@proj"})).status_code.should eq(200)
        sleep 100.milliseconds
        unproven = events.query(type: "read.unproven")
        unproven.size.should eq(1)
        unproven.first.metadata.not_nil!["path"].should eq("/receive")
      end
    end
  end
end
