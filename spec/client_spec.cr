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
      kind: Arcana::Directory::Kind::Agent,
      name: "Shopperbot",
      description: "test client",
    )
    client.on_message { |env| received.send(env) }

    begin
      spawn { client.connect }
      sleep 100.milliseconds # let the join frame land

      # Server side — send an envelope directly into the client's mailbox.
      bus.send(Arcana::Envelope.new(
        from: "origin:agent",
        to: "shopperbot:agent",
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
    target = bus.mailbox("sink:agent")

    client = Arcana::Client.new(
      url: "ws://127.0.0.1:14201/bus",
      address: "sender",
      kind: Arcana::Directory::Kind::Agent,
    )

    begin
      spawn { client.connect }
      sleep 100.milliseconds

      client.send(Arcana::Envelope.new(
        from: "sender:agent",
        to: "sink:agent",
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

  it "performs a request/reply round-trip via correlation_id" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new
    bus.directory = dir

    # Echo service answers on the server side.
    svc = Arcana::Service.new(
      bus: bus, directory: dir,
      address: "echo",
      name: "Echo",
      description: "echoes",
    ) { |data| data }
    svc.start

    server = Arcana::Server.new(bus, dir, port: 14202)
    server.start_in_background

    client = Arcana::Client.new(
      url: "ws://127.0.0.1:14202/bus",
      address: "caller",
      kind: Arcana::Directory::Kind::Agent,
    )

    begin
      spawn { client.connect }
      sleep 100.milliseconds

      reply = client.request(
        Arcana::Envelope.new(
          from: "caller:agent",
          to: "echo:service",
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
