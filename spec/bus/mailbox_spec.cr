require "../spec_helper"

describe Arcana::Mailbox do
  it "stores its address" do
    mb = Arcana::Mailbox.new("agent:writer")
    mb.address.should eq("agent:writer")
  end

  it "delivers and receives an envelope" do
    mb = Arcana::Mailbox.new("test")
    env = Arcana::Envelope.new(from: "sender", to: "test", subject: "hello")
    mb.deliver(env)

    received = mb.try_receive
    received.should_not be_nil
    received.not_nil!.subject.should eq("hello")
  end

  it "try_receive returns nil when empty" do
    mb = Arcana::Mailbox.new("test")
    mb.try_receive.should be_nil
  end

  it "receives multiple envelopes in order" do
    mb = Arcana::Mailbox.new("test")
    mb.deliver(Arcana::Envelope.new(from: "a", subject: "first"))
    mb.deliver(Arcana::Envelope.new(from: "a", subject: "second"))

    mb.try_receive.not_nil!.subject.should eq("first")
    mb.try_receive.not_nil!.subject.should eq("second")
    mb.try_receive.should be_nil
  end

  it "receive with timeout returns nil on expiry" do
    mb = Arcana::Mailbox.new("test")
    result = mb.receive(10.milliseconds)
    result.should be_nil
  end

  it "receive with timeout returns envelope if available" do
    mb = Arcana::Mailbox.new("test")
    mb.deliver(Arcana::Envelope.new(from: "a", subject: "quick"))
    result = mb.receive(1.second)
    result.should_not be_nil
    result.not_nil!.subject.should eq("quick")
  end

  describe "#inbox" do
    it "returns empty array when no messages" do
      mb = Arcana::Mailbox.new("test")
      mb.inbox.should be_empty
    end

    it "returns metadata for pending messages without consuming them" do
      mb = Arcana::Mailbox.new("test")
      mb.deliver(Arcana::Envelope.new(from: "alice", subject: "greet", correlation_id: "id-1"))
      mb.deliver(Arcana::Envelope.new(from: "bob", subject: "ask", correlation_id: "id-2"))

      listing = mb.inbox
      listing.size.should eq(2)
      listing[0][:from].should eq("alice")
      listing[0][:subject].should eq("greet")
      listing[0][:correlation_id].should eq("id-1")
      listing[1][:from].should eq("bob")
      listing[1][:correlation_id].should eq("id-2")

      # Messages should still be there
      mb.pending.should eq(2)
    end
  end

  describe "#receive(id)" do
    it "selectively receives a message by correlation_id" do
      mb = Arcana::Mailbox.new("test")
      mb.deliver(Arcana::Envelope.new(from: "a", subject: "first", correlation_id: "id-1"))
      mb.deliver(Arcana::Envelope.new(from: "b", subject: "second", correlation_id: "id-2"))
      mb.deliver(Arcana::Envelope.new(from: "c", subject: "third", correlation_id: "id-3"))

      # Receive the middle one
      msg = mb.receive("id-2")
      msg.should_not be_nil
      msg.not_nil!.subject.should eq("second")

      # Other messages still there, in order
      mb.pending.should eq(2)
      mb.try_receive.not_nil!.subject.should eq("first")
      mb.try_receive.not_nil!.subject.should eq("third")
    end

    it "returns nil when id not found" do
      mb = Arcana::Mailbox.new("test")
      mb.deliver(Arcana::Envelope.new(from: "a", correlation_id: "id-1"))

      mb.receive("nonexistent").should be_nil
      mb.pending.should eq(1)
    end
  end
end
