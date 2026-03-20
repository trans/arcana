require "../spec_helper"

describe Arcana::Directory do
  it "registers and looks up listings" do
    dir = Arcana::Directory.new
    listing = Arcana::Directory::Listing.new(
      address: "resizer",
      name: "Image Resizer",
      description: "Resizes images",
      kind: Arcana::Directory::Kind::Service,
    )
    dir.register(listing)
    dir.lookup("resizer").should_not be_nil
    dir.lookup("resizer").not_nil!.name.should eq("Image Resizer")
  end

  it "unregisters listings" do
    dir = Arcana::Directory.new
    dir.register(Arcana::Directory::Listing.new(
      address: "tmp", name: "Tmp", description: "temp",
      kind: Arcana::Directory::Kind::Service,
    ))
    dir.unregister("tmp")
    dir.lookup("tmp").should be_nil
  end

  it "lists all listings" do
    dir = Arcana::Directory.new
    dir.register(Arcana::Directory::Listing.new(
      address: "a", name: "A", description: "a",
      kind: Arcana::Directory::Kind::Agent,
    ))
    dir.register(Arcana::Directory::Listing.new(
      address: "b", name: "B", description: "b",
      kind: Arcana::Directory::Kind::Service,
    ))
    dir.list.size.should eq(2)
  end

  describe "#by_kind" do
    it "filters by agent or service" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "agent1", name: "Agent", description: "smart",
        kind: Arcana::Directory::Kind::Agent,
      ))
      dir.register(Arcana::Directory::Listing.new(
        address: "svc1", name: "Service", description: "dumb",
        kind: Arcana::Directory::Kind::Service,
      ))

      dir.by_kind(Arcana::Directory::Kind::Agent).size.should eq(1)
      dir.by_kind(Arcana::Directory::Kind::Service).size.should eq(1)
    end
  end

  describe "#by_tag" do
    it "filters by tag" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "a", name: "A", description: "a",
        kind: Arcana::Directory::Kind::Service, tags: ["image", "resize"],
      ))
      dir.register(Arcana::Directory::Listing.new(
        address: "b", name: "B", description: "b",
        kind: Arcana::Directory::Kind::Service, tags: ["audio"],
      ))

      dir.by_tag("image").size.should eq(1)
      dir.by_tag("audio").size.should eq(1)
      dir.by_tag("video").size.should eq(0)
    end
  end

  describe "#search" do
    it "matches on name, description, and tags" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "a", name: "Image Generator", description: "Creates images from prompts",
        kind: Arcana::Directory::Kind::Agent, tags: ["ai", "creative"],
      ))
      dir.register(Arcana::Directory::Listing.new(
        address: "b", name: "File Converter", description: "Converts file formats",
        kind: Arcana::Directory::Kind::Service,
      ))

      dir.search("image").size.should eq(1)
      dir.search("image").first.address.should eq("a")
      dir.search("convert").size.should eq(1)
      dir.search("creative").size.should eq(1)
      dir.search("nonexistent").size.should eq(0)
    end

    it "is case-insensitive" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "a", name: "Image Generator", description: "...",
        kind: Arcana::Directory::Kind::Agent,
      ))
      dir.search("IMAGE").size.should eq(1)
    end
  end

  describe "#busy?" do
    it "defaults to not busy" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "a", name: "A", description: "a",
        kind: Arcana::Directory::Kind::Service,
      ))
      dir.busy?("a").should be_false
    end

    it "tracks busy state" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "a", name: "A", description: "a",
        kind: Arcana::Directory::Kind::Service,
      ))
      dir.set_busy("a", true)
      dir.busy?("a").should be_true
      dir.set_busy("a", false)
      dir.busy?("a").should be_false
    end

    it "clears busy on unregister" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "a", name: "A", description: "a",
        kind: Arcana::Directory::Kind::Service,
      ))
      dir.set_busy("a", true)
      dir.unregister("a")
      dir.busy?("a").should be_false
    end

    it "raises when setting busy on address without listing" do
      dir = Arcana::Directory.new
      expect_raises(Exception, "no directory listing for 'ghost'") do
        dir.set_busy("ghost", true)
      end
    end

    it "includes busy in JSON output" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "a", name: "A", description: "a",
        kind: Arcana::Directory::Kind::Service,
      ))
      dir.set_busy("a", true)
      parsed = JSON.parse(dir.to_json)
      parsed[0]["busy"].as_bool.should be_true
    end
  end

  describe "#to_json" do
    it "serializes all listings" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "a", name: "A", description: "does A",
        kind: Arcana::Directory::Kind::Agent, tags: ["tag1"],
      ))

      parsed = JSON.parse(dir.to_json)
      parsed.as_a.size.should eq(1)
      parsed[0]["address"].as_s.should eq("a")
      parsed[0]["kind"].as_s.should eq("agent")
      parsed[0]["tags"].as_a.map(&.as_s).should eq(["tag1"])
    end
  end
end
