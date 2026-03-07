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
end
