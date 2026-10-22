require "./spec_helper"

# End-to-end tests for Arcana::Client against a live Arcana::Server.
# These verify that the WebSocket client (which lives in arcana-core)
# speaks the same protocol as the server (which lives in arcana).
describe Arcana::Client do
  it "joins and receives a pushed envelope" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new
    bus.directory = dir
    server = Arcana::Server.new(bus, dir, port: 14200)
    server.start_in_background

    received = Channel(Arcana::Envelope).new(1)
    client = Arcana::Client.new(
      url: "ws://127.0.0.1:14200/bus",
      address: "shopperbot",
      name: "Shopperbot",
      description: "test client",
    )
    client.on_message { |env| received.send(env) }

    begin
      spawn { client.connect }
      sleep 100.milliseconds # let the join frame land

      # Server side — send an envelope directly into the client's mailbox.
      bus.send(Arcana::Envelope.new(
        from: "origin",
        to: "shopperbot",
        subject: "hello",
        payload: JSON::Any.new("world"),
      ))

      env = received.receive
      env.subject.should eq("hello")
      env.payload.as_s.should eq("world")
    ensure
      client.close
      server.stop
    end
  end

  it "sends an envelope through the bus" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new
    bus.directory = dir
    server = Arcana::Server.new(bus, dir, port: 14201)
    server.start_in_background

    # Local recipient (mailbox on the server-side bus).
    target = bus.mailbox("sink")

    client = Arcana::Client.new(
      url: "ws://127.0.0.1:14201/bus",
      address: "sender",
    )

    begin
      spawn { client.connect }
      sleep 100.milliseconds

      client.send(Arcana::Envelope.new(
        from: "sender",
        to: "sink",
        subject: "ping",
        payload: JSON::Any.new("ping-data"),
      ))

      env = target.receive(1.second)
      env.should_not be_nil
      env.not_nil!.subject.should eq("ping")
      env.not_nil!.payload.as_s.should eq("ping-data")
    ensure
      client.close
      server.stop
    end
  end

  it "joins as a hidden consumer (listed: false) — mailbox without directory entry" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new
    bus.directory = dir
    server = Arcana::Server.new(bus, dir, port: 14210)
    server.start_in_background

    client = Arcana::Client.new(
      url: "ws://127.0.0.1:14210/bus",
      address: "wow-io",
      listed: false,
    )

    begin
      spawn { client.connect }
      sleep 100.milliseconds

      bus.has_mailbox?("wow-io").should be_true
      dir.lookup("wow-io").should be_nil
    ensure
      client.close
      server.stop
    end
  end

  it "performs a request/reply round-trip via correlation_id" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new
    bus.directory = dir

    # Echo service answers on the server side.
    svc = Arcana::Service.new(
      bus: bus, directory: dir,
      address: "arcana:echo",
      name: "Echo",
      description: "echoes",
    ) { |data| data }
    svc.start

    server = Arcana::Server.new(bus, dir, port: 14202)
    server.start_in_background

    client = Arcana::Client.new(
      url: "ws://127.0.0.1:14202/bus",
      address: "caller",
    )

    begin
      spawn { client.connect }
      sleep 100.milliseconds

      reply = client.request(
        Arcana::Envelope.new(
          from: "caller",
          to: "arcana:echo",
          subject: "test",
          payload: JSON::Any.new("hello echo"),
        ),
        timeout: 2.seconds,
      )

      reply.should_not be_nil
      Arcana::Protocol.data(reply.not_nil!.payload).not_nil!.as_s.should eq("hello echo")
    ensure
      client.close
      server.stop
    end
  end
end

# Joining an address held under an owner token (as an agent's handle is,
# by `arcana hook`).
describe "Arcana::Client joining a held address" do
  agent = ->(address : String) do
    Arcana::Directory::Listing.new(address: address, name: address, description: "d",
      kind: Arcana::Directory::Kind::Agent)
  end

  it "claims the address with an owner token, and keeps it, mailbox and all, after disconnecting" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new
    bus.directory = dir
    server = Arcana::Server.new(bus, dir, port: 14220)
    server.start_in_background
    client = Arcana::Client.new(url: "ws://127.0.0.1:14220/bus", address: "@proj",
      kind: Arcana::Directory::Kind::Agent, owner_token: "tok")
    begin
      spawn { client.connect }
      sleep 100.milliseconds
      dir.held?("@proj").should be_true
      client.close
      sleep 100.milliseconds

      dir.lookup("@proj").should_not be_nil
      dir.held?("@proj").should be_true
      bus.send(Arcana::Envelope.new(from: "@x", to: "@proj", subject: "later"))
      bus.mailbox("@proj").receive(1.second).not_nil!.subject.should eq("later")
    ensure
      client.close
      server.stop
    end
  end

  it "refuses a join showing another owner token, leaving the mailbox alone" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new
    bus.directory = dir
    dir.claim(agent.call("@proj"), "tok")
    mailbox = bus.mailbox("@proj")
    server = Arcana::Server.new(bus, dir, port: 14221)
    server.start_in_background
    frames = Channel(String).new(10)
    ws = HTTP::WebSocket.new(URI.parse("ws://127.0.0.1:14221/bus"))
    ws.on_message { |msg| frames.send(msg) }
    begin
      spawn { ws.run }
      ws.send({type: "join", address: "@proj", owner_token: "other"}.to_json)
      select
      when frame = frames.receive
        frame.should contain("held by another owner")
      when timeout(2.seconds)
        fail "no refusal"
      end

      bus.send(Arcana::Envelope.new(from: "@x", to: "@proj", subject: "mine"))
      mailbox.receive(1.second).not_nil!.subject.should eq("mine")
      ws.close
      sleep 100.milliseconds
      dir.held?("@proj").should be_true
    ensure
      server.stop
    end
  end

  it "still joins a held address without its token, records that, and doesn't unregister it on leaving" do
    log_dir = File.tempname("arcana-join-events")
    backend = Arcana::Events::FileBackend.new(log_dir: log_dir, retain_days: 7)
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new
    bus.directory = dir
    dir.claim(agent.call("@game"), "tok")
    server = Arcana::Server.new(bus, dir, port: 14222)
    server.events = backend
    server.start_in_background
    client = Arcana::Client.new(url: "ws://127.0.0.1:14222/bus", address: "@game",
      kind: Arcana::Directory::Kind::Agent)
    begin
      spawn { client.connect }
      sleep 100.milliseconds
      client.close
      sleep 100.milliseconds

      dir.held?("@game").should be_true
      bus.has_mailbox?("@game").should be_true
      backend.query(type: "join.unproven").map(&.subject).should eq(["@game"])
    ensure
      client.close
      server.stop
      backend.close
      FileUtils.rm_rf(log_dir)
    end
  end

  it "unregisters an address held without a token when its client leaves, as before" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new
    bus.directory = dir
    server = Arcana::Server.new(bus, dir, port: 14223)
    server.start_in_background
    client = Arcana::Client.new(url: "ws://127.0.0.1:14223/bus", address: "svc:thing",
      kind: Arcana::Directory::Kind::Service)
    begin
      spawn { client.connect }
      sleep 100.milliseconds
      dir.lookup("svc:thing").should_not be_nil
      client.close
      sleep 100.milliseconds
      dir.lookup("svc:thing").should be_nil
      bus.has_mailbox?("svc:thing").should be_false
    ensure
      client.close
      server.stop
    end
  end
end
