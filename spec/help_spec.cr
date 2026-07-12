require "./spec_helper"

describe Arcana::Help do
  describe "BRIEFING" do
    it "includes all topic sections" do
      Arcana::Help::TOPICS.each_value do |section|
        Arcana::Help::BRIEFING.includes?(section.strip).should be_true
      end
    end

    it "leads with the bus elevator pitch" do
      Arcana::Help::BRIEFING.starts_with?("Arcana is a persistent agent communication bus").should be_true
    end
  end

  describe ".topic" do
    it "returns the named section" do
      Arcana::Help.topic("addressing").not_nil!.includes?("routing label").should be_true
    end

    it "returns nil for unknown topics" do
      Arcana::Help.topic("nope").should be_nil
    end
  end

  describe ".topics" do
    it "lists the four canonical topics" do
      Arcana::Help.topics.should eq(["workflow", "addressing", "discovery", "errors"])
    end
  end
end
