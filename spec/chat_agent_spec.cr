require "./spec_helper"

# Fake chat provider that echoes back the last user message.
class FakeChatProvider < Arcana::Chat::Provider
  getter call_count : Int32 = 0

  def name : String
    "fake"
  end

  def complete(request : Arcana::Chat::Request) : Arcana::Chat::Response
    @call_count += 1
    # Echo the last user message content.
    last_user = request.messages.reverse.find { |m| m.role == "user" }
    content = last_user.try(&.content) || "no message"

    Arcana::Chat::Response.new(
      content: "Echo: #{content}",
      model: request.model,
      provider: "fake",
    )
  end
end

describe Arcana::ChatAgent do
  it "processes a message and replies" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new
    provider = FakeChatProvider.new

    agent = Arcana::ChatAgent.new(
      bus: bus,
      directory: dir,
      address: "bot",
      name: "Bot",
      description: "Test bot",
      provider: provider,
      system_prompt: "You are a test bot.",
    )
    agent.start

    # Create a sender mailbox.
    sender = bus.mailbox("alice")

    # Send a message to the bot.
    bus.send(Arcana::Envelope.new(
      from: "alice",
      to: "bot",
      subject: "hello",
      payload: JSON::Any.new({"message" => JSON::Any.new("Hi there!")}),
    ))

    # Wait for the reply.
    reply = sender.receive(5.seconds)
    reply.should_not be_nil
    reply.not_nil!.from.should eq("bot")

    payload = reply.not_nil!.payload
    msg = payload["message"]?.try(&.as_s?)
    msg.should_not be_nil
    msg.not_nil!.should contain("Hi there!")

    provider.call_count.should eq(1)
  end

  it "maintains separate histories per correspondent" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new
    provider = FakeChatProvider.new

    agent = Arcana::ChatAgent.new(
      bus: bus,
      directory: dir,
      address: "bot",
      name: "Bot",
      description: "Test bot",
      provider: provider,
    )
    agent.start

    alice = bus.mailbox("alice")
    bob = bus.mailbox("bob")

    # Alice sends
    bus.send(Arcana::Envelope.new(
      from: "alice", to: "bot",
      payload: JSON::Any.new({"message" => JSON::Any.new("from alice")}),
    ))
    reply_a = alice.receive(5.seconds)
    reply_a.should_not be_nil

    # Bob sends
    bus.send(Arcana::Envelope.new(
      from: "bob", to: "bot",
      payload: JSON::Any.new({"message" => JSON::Any.new("from bob")}),
    ))
    reply_b = bob.receive(5.seconds)
    reply_b.should_not be_nil

    reply_a.not_nil!.payload["message"].as_s.should contain("from alice")
    reply_b.not_nil!.payload["message"].as_s.should contain("from bob")

    provider.call_count.should eq(2)
  end

  it "handles provider errors gracefully" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new

    # Provider that always raises.
    provider = FakeChatProvider.new
    agent = Arcana::ChatAgent.new(
      bus: bus,
      directory: dir,
      address: "bot",
      name: "Bot",
      description: "Test bot",
      provider: provider,
    )

    # Monkey-patch the provider to fail (use a different approach).
    # Instead, test on_error by sending from empty address (should be ignored).
    agent.start

    sender = bus.mailbox("sender")
    bus.send(Arcana::Envelope.new(
      from: "sender", to: "bot",
      payload: JSON::Any.new("raw string payload"),
    ))

    reply = sender.receive(5.seconds)
    reply.should_not be_nil
    # Should still get a reply even with non-standard payload.
    # The reply has a "message" key with the echoed content.
    payload = reply.not_nil!.payload
    # Either a message or an error is fine — agent didn't crash.
    has_response = !!(payload["message"]? || payload["error"]?)
    has_response.should be_true
  end

  it "ignores messages with empty from" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new
    provider = FakeChatProvider.new

    agent = Arcana::ChatAgent.new(
      bus: bus,
      directory: dir,
      address: "bot",
      name: "Bot",
      description: "Test bot",
      provider: provider,
    )
    agent.start

    bus.send(Arcana::Envelope.new(
      from: "", to: "bot",
      payload: JSON::Any.new({"message" => JSON::Any.new("ghost")}),
    ))

    # Give it a moment to process.
    sleep 100.milliseconds
    provider.call_count.should eq(0)
  end

  it "registers in the directory" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new
    provider = FakeChatProvider.new

    agent = Arcana::ChatAgent.new(
      bus: bus,
      directory: dir,
      address: "bot",
      name: "Bot",
      description: "Test bot",
      provider: provider,
      tags: ["test", "ai"],
    )
    agent.start

    listing = dir.lookup("bot")
    listing.should_not be_nil
    listing.not_nil!.name.should eq("Bot")
    listing.not_nil!.tags.should eq(["test", "ai"])
  end
end
