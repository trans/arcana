require "../spec_helper"

describe Arcana::Service do
  it "registers itself in the directory" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new

    svc = Arcana::Service.new(
      bus: bus, directory: dir,
      address: "echo",
      name: "Echo",
      description: "Echoes input back",
    ) { |data| data }

    listing = dir.lookup("echo")
    listing.should_not be_nil
    listing.not_nil!.kind.should eq(Arcana::Directory::Kind::Service)
  end

  it "handles requests and returns results" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new

    svc = Arcana::Service.new(
      bus: bus, directory: dir,
      address: "doubler",
      name: "Doubler",
      description: "Doubles a number",
    ) do |data|
      n = data["n"].as_i
      JSON::Any.new({"result" => JSON::Any.new(n * 2)})
    end
    svc.start

    payload = Arcana::Protocol.request(
      JSON::Any.new({"n" => JSON::Any.new(21)}),
    )

    result = bus.request(
      Arcana::Envelope.new(from: "client", to: "doubler", payload: payload),
      timeout: 1.second,
    )

    result.should_not be_nil
    Arcana::Protocol.result?(result.not_nil!.payload).should be_true
    Arcana::Protocol.data(result.not_nil!.payload).not_nil!["result"].as_i.should eq(42)
  end

  it "validates required fields and sends need response" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new

    schema = JSON.parse(%({"type":"object","required":["name","age"]}))

    svc = Arcana::Service.new(
      bus: bus, directory: dir,
      address: "greeter",
      name: "Greeter",
      description: "Greets by name and age",
      schema: schema,
    ) do |data|
      JSON::Any.new("Hello #{data["name"]}")
    end
    svc.start

    # Send request missing "age"
    payload = Arcana::Protocol.request(
      JSON::Any.new({"name" => JSON::Any.new("Alice")}),
    )

    result = bus.request(
      Arcana::Envelope.new(from: "client", to: "greeter", payload: payload),
      timeout: 1.second,
    )

    result.should_not be_nil
    Arcana::Protocol.need?(result.not_nil!.payload).should be_true
    Arcana::Protocol.message(result.not_nil!.payload).not_nil!.should contain("age")
  end

  it "handles raw (non-protocol) payloads" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new

    svc = Arcana::Service.new(
      bus: bus, directory: dir,
      address: "echo",
      name: "Echo",
      description: "Echoes back",
    ) { |data| data }
    svc.start

    result = bus.request(
      Arcana::Envelope.new(
        from: "client", to: "echo",
        payload: JSON::Any.new("raw message"),
      ),
      timeout: 1.second,
    )

    result.should_not be_nil
    Arcana::Protocol.result?(result.not_nil!.payload).should be_true
    Arcana::Protocol.data(result.not_nil!.payload).not_nil!.as_s.should eq("raw message")
  end

  it "returns error when handler raises" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new

    svc = Arcana::Service.new(
      bus: bus, directory: dir,
      address: "crasher",
      name: "Crasher",
      description: "Always fails",
    ) { |_| raise "boom" }
    svc.start

    result = bus.request(
      Arcana::Envelope.new(from: "client", to: "crasher", payload: JSON::Any.new(nil)),
      timeout: 1.second,
    )

    result.should_not be_nil
    Arcana::Protocol.error?(result.not_nil!.payload).should be_true
    Arcana::Protocol.message(result.not_nil!.payload).should eq("boom")
  end

  it "unregisters from directory on stop" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new

    svc = Arcana::Service.new(
      bus: bus, directory: dir,
      address: "tmp",
      name: "Tmp",
      description: "Temporary",
    ) { |d| d }
    svc.start
    svc.stop

    dir.lookup("tmp").should be_nil
  end
end
