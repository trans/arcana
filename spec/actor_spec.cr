require "./spec_helper"

# A simple echo actor for testing.
class EchoActor < Arcana::Actor
  getter received = [] of String

  def handle(envelope : Arcana::Envelope)
    data = extract_data(envelope.payload)
    @received << (data.as_s? || data.to_json)
    reply(envelope, Arcana::Protocol.result(data))
  end
end

# An actor that crashes on a specific message.
class CrashyActor < Arcana::Actor
  getter crash_count = 0

  def handle(envelope : Arcana::Envelope)
    data = extract_data(envelope.payload)
    if data.as_s? == "crash"
      @crash_count += 1
      raise "boom"
    end
    reply(envelope, Arcana::Protocol.result(data))
  end
end

# An actor that swallows errors instead of crashing.
class ResilientActor < Arcana::Actor
  getter errors = [] of String

  def handle(envelope : Arcana::Envelope)
    raise "oops"
  end

  def on_error(envelope : Arcana::Envelope, error : Exception)
    @errors << (error.message || "unknown")
    # Don't re-raise — stay alive
  end
end

describe Arcana::Actor do
  it "registers in directory and processes messages" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new

    actor = EchoActor.new(bus, dir, "echo", "Echo", "Echoes messages")
    actor.start

    listing = dir.lookup("echo")
    listing.should_not be_nil
    listing.not_nil!.kind.should eq(Arcana::Directory::Kind::Agent)

    result = bus.request(
      Arcana::Envelope.new(from: "tester", to: "echo",
        payload: Arcana::Protocol.request(JSON::Any.new("hello"))),
      timeout: 1.second,
    )

    result.should_not be_nil
    Arcana::Protocol.data(result.not_nil!.payload).not_nil!.as_s.should eq("hello")
  end

  it "tracks received messages" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new

    actor = EchoActor.new(bus, dir, "echo2", "Echo", "Echoes")
    actor.start

    bus.send(Arcana::Envelope.new(from: "tester", to: "echo2",
      payload: JSON::Any.new("one")))
    bus.send(Arcana::Envelope.new(from: "tester", to: "echo2",
      payload: JSON::Any.new("two")))

    sleep 50.milliseconds
    actor.received.should eq(["one", "two"])
  end

  it "stops cleanly" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new

    actor = EchoActor.new(bus, dir, "stopper", "Stopper", "Stops")
    actor.start
    sleep 10.milliseconds
    actor.running?.should be_true

    actor.stop
    dir.lookup("stopper").should be_nil
  end

  it "resilient actor swallows errors and keeps running" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new

    actor = ResilientActor.new(bus, dir, "resilient", "Resilient", "Handles errors")
    actor.start

    bus.send(Arcana::Envelope.new(from: "tester", to: "resilient",
      payload: JSON::Any.new("trigger")))
    bus.send(Arcana::Envelope.new(from: "tester", to: "resilient",
      payload: JSON::Any.new("trigger2")))

    sleep 50.milliseconds
    actor.errors.size.should eq(2)
    actor.running?.should be_true
  end
end
