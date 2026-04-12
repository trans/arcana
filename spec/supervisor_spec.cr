require "./spec_helper"

# Actor that crashes once then works.
class CrashOnceActor < Arcana::Actor
  class_property crash_count = 0
  class_property handle_count = 0

  def handle(envelope : Arcana::Envelope)
    @@handle_count += 1
    if @@crash_count == 0
      @@crash_count += 1
      raise "first crash"
    end
    reply(envelope, Arcana::Protocol.result(JSON::Any.new("ok")))
  end
end

describe Arcana::Supervisor do
  before_each do
    CrashOnceActor.crash_count = 0
    CrashOnceActor.handle_count = 0
  end

  it "starts and monitors actors" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new

    sup = Arcana::Supervisor.new(bus, dir)
    actor = EchoActor.new(bus, dir, "sup-echo", "Echo", "Echo")
    sup.supervise(actor)

    sup.children.should eq(["sup-echo:agent"])
    dir.lookup("sup-echo").should_not be_nil
  end

  it "restarts a crashed actor (one_for_one)" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new

    sup = Arcana::Supervisor.new(bus, dir, strategy: Arcana::Supervisor::Strategy::OneForOne)

    actor = CrashOnceActor.new(bus, dir, "crashy", "Crashy", "Crashes once")
    sup.supervise(actor)

    # Send message that triggers a crash
    bus.send(Arcana::Envelope.new(from: "tester", to: "crashy",
      payload: JSON::Any.new("trigger")))

    sleep 200.milliseconds

    # Actor should have been restarted — send another message
    result = bus.request(
      Arcana::Envelope.new(from: "tester", to: "crashy",
        payload: Arcana::Protocol.request(JSON::Any.new("after-restart"))),
      timeout: 1.second,
    )

    result.should_not be_nil
    CrashOnceActor.crash_count.should eq(1)
  end

  it "enforces max_restarts within time window" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new

    sup = Arcana::Supervisor.new(bus, dir,
      max_restarts: 2,
      within: 1.second,
    )

    actor = CrashyActor.new(bus, dir, "always-crash", "Crashy", "Always crashes")
    sup.supervise(actor)

    # Send messages that cause repeated crashes
    3.times do
      bus.send(Arcana::Envelope.new(from: "tester", to: "always-crash",
        payload: JSON::Any.new("crash")))
      sleep 50.milliseconds
    end

    sleep 100.milliseconds

    # Should have stopped restarting after max_restarts
    actor.crash_count.should be <= 3
  end

  it "stops all actors" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new

    sup = Arcana::Supervisor.new(bus, dir)
    a1 = EchoActor.new(bus, dir, "s1", "S1", "s1")
    a2 = EchoActor.new(bus, dir, "s2", "S2", "s2")
    sup.supervise(a1)
    sup.supervise(a2)

    sup.stop
    dir.lookup("s1").should be_nil
    dir.lookup("s2").should be_nil
  end
end
