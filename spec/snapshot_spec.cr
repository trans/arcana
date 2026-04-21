require "./spec_helper"

describe Arcana::Snapshot do
  it "saves and loads an empty bus" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new
    bus.directory = dir
    server = Arcana::Server.new(bus, dir, port: 14100)

    path = File.tempname("arcana-snap", ".json")
    begin
      Arcana::Snapshot.save(bus, dir, server, path)
      File.exists?(path).should be_true

      parsed = JSON.parse(File.read(path))
      parsed["version"].as_i.should eq(Arcana::Snapshot::VERSION)
      parsed["listings"].as_a.should be_empty
      parsed["mailboxes"].as_a.should be_empty
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "round-trips listings, messages, and frozen messages" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new
    bus.directory = dir
    server = Arcana::Server.new(bus, dir, port: 14101)

    # Register a service and create its mailbox
    dir.register(Arcana::Directory::Listing.new(
      address: "echo", name: "Echo", description: "echoes",
      kind: Arcana::Directory::Kind::Service, tags: ["test"],
    ))
    mb = bus.mailbox("echo:service")

    # Deliver three messages
    e1 = Arcana::Envelope.new(from: "alice:agent", to: "echo:service",
      subject: "first", payload: JSON::Any.new("one"))
    e2 = Arcana::Envelope.new(from: "alice:agent", to: "echo:service",
      subject: "second", payload: JSON::Any.new("two"))
    e3 = Arcana::Envelope.new(from: "alice:agent", to: "echo:service",
      subject: "third", payload: JSON::Any.new("three"))
    mb.deliver(e1)
    mb.deliver(e2)
    mb.deliver(e3)

    # Freeze the middle one
    mb.freeze(e2.correlation_id, "soapbox:agent").should be_true
    mb.pending.should eq(2)
    mb.frozen_count.should eq(1)

    path = File.tempname("arcana-snap", ".json")
    begin
      Arcana::Snapshot.save(bus, dir, server, path)

      # Restore into a fresh bus/dir
      bus2 = Arcana::Bus.new
      dir2 = Arcana::Directory.new
      bus2.directory = dir2
      server2 = Arcana::Server.new(bus2, dir2, port: 14102)

      Arcana::Snapshot.load(bus2, dir2, server2, path).should be_true

      # Listings restored
      dir2.list.size.should eq(1)
      dir2.lookup("echo:service").not_nil!.name.should eq("Echo")

      # Mailbox restored with the right messages and frozen state
      mb2 = bus2.mailbox("echo:service")
      mb2.pending.should eq(2)
      mb2.frozen_count.should eq(1)

      # Pending messages in original order (first and third)
      first = mb2.try_receive.not_nil!
      first.subject.should eq("first")
      first.payload.as_s.should eq("one")

      third = mb2.try_receive.not_nil!
      third.subject.should eq("third")

      # Thaw the frozen one and verify it
      mb2.thaw(e2.correlation_id).should_not be_nil
      thawed = mb2.try_receive.not_nil!
      thawed.subject.should eq("second")
      thawed.payload.as_s.should eq("two")
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "round-trips tokens" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new
    bus.directory = dir
    server = Arcana::Server.new(bus, dir, port: 14103)
    server.load_tokens({"alice:agent" => "secret123", "bob:agent" => "swordfish"})

    path = File.tempname("arcana-snap", ".json")
    begin
      Arcana::Snapshot.save(bus, dir, server, path)

      bus2 = Arcana::Bus.new
      dir2 = Arcana::Directory.new
      bus2.directory = dir2
      server2 = Arcana::Server.new(bus2, dir2, port: 14104)

      Arcana::Snapshot.load(bus2, dir2, server2, path).should be_true
      server2.tokens.size.should eq(2)
      server2.tokens["alice:agent"].should eq("secret123")
      server2.tokens["bob:agent"].should eq("swordfish")
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "returns false when snapshot file does not exist" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new
    bus.directory = dir
    server = Arcana::Server.new(bus, dir, port: 14105)
    Arcana::Snapshot.load(bus, dir, server, "/nonexistent/path.json").should be_false
  end

  it "atomic write — no .tmp file remains after save" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new
    bus.directory = dir
    server = Arcana::Server.new(bus, dir, port: 14106)

    path = File.tempname("arcana-snap", ".json")
    tmp = "#{path}.tmp"
    begin
      Arcana::Snapshot.save(bus, dir, server, path)
      File.exists?(path).should be_true
      File.exists?(tmp).should be_false
    ensure
      File.delete(path) if File.exists?(path)
      File.delete(tmp) if File.exists?(tmp)
    end
  end

  it "skips empty mailboxes from the snapshot" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new
    bus.directory = dir
    server = Arcana::Server.new(bus, dir, port: 14107)

    # Register but never deliver to it
    dir.register(Arcana::Directory::Listing.new(
      address: "ghost", name: "Ghost", description: "no messages",
      kind: Arcana::Directory::Kind::Agent,
    ))
    bus.mailbox("ghost:agent")

    path = File.tempname("arcana-snap", ".json")
    begin
      Arcana::Snapshot.save(bus, dir, server, path)
      parsed = JSON.parse(File.read(path))
      parsed["mailboxes"].as_a.should be_empty
      parsed["listings"].as_a.size.should eq(1)
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "restores a mailbox for every listing even if it was empty at save time" do
    # Regression: offline-agent messages were silently dropped because their
    # (empty) mailboxes weren't persisted and weren't re-created on restore.
    bus1 = Arcana::Bus.new
    dir1 = Arcana::Directory.new
    bus1.directory = dir1
    server1 = Arcana::Server.new(bus1, dir1, port: 14110)

    dir1.register(Arcana::Directory::Listing.new(
      address: "offline", name: "Offline", description: "agent that's gone home",
      kind: Arcana::Directory::Kind::Agent,
    ))
    bus1.mailbox("offline:agent") # exists but empty

    path = File.tempname("arcana-snap", ".json")
    begin
      Arcana::Snapshot.save(bus1, dir1, server1, path)

      # Fresh world — simulate restart
      bus2 = Arcana::Bus.new
      dir2 = Arcana::Directory.new
      bus2.directory = dir2
      server2 = Arcana::Server.new(bus2, dir2, port: 14111)

      Arcana::Snapshot.load(bus2, dir2, server2, path)

      # The listing is back
      dir2.lookup("offline:agent").should_not be_nil
      # And the mailbox is back too, so sends to the offline agent queue
      bus2.has_mailbox?("offline:agent").should be_true

      bus2.mailbox("sender:agent") # need a sender mailbox for the envelope
      bus2.send(Arcana::Envelope.new(from: "sender:agent", to: "offline:agent", subject: "ping"))
      bus2.pending("offline:agent").should eq(1)
    ensure
      File.delete(path) if File.exists?(path)
    end
  end
end
