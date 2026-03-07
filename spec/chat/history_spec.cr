require "../spec_helper"

describe Arcana::Chat::History do
  it "starts empty" do
    h = Arcana::Chat::History.new
    h.empty?.should be_true
    h.size.should eq(0)
  end

  describe "#add_system" do
    it "inserts system message at position 0" do
      h = Arcana::Chat::History.new
      h.add_system("Be helpful.")
      h.messages[0].role.should eq("system")
      h.messages[0].content.should eq("Be helpful.")
    end

    it "replaces existing system message" do
      h = Arcana::Chat::History.new
      h.add_system("First")
      h.add_system("Second")
      h.size.should eq(1)
      h.messages[0].content.should eq("Second")
    end
  end

  describe "#add_user / #add_assistant" do
    it "appends messages in order" do
      h = Arcana::Chat::History.new
      h.add_user("Hi")
      h.add_assistant("Hello")
      h.add_user("How are you?")
      h.size.should eq(3)
      h.messages.map(&.role).should eq(["user", "assistant", "user"])
    end
  end

  describe "#update_last_assistant" do
    it "updates the most recent assistant message" do
      h = Arcana::Chat::History.new
      h.add_user("Hi")
      h.add_assistant("Draft")
      h.add_user("More")
      h.update_last_assistant("Final")
      h.messages[1].content.should eq("Final")
    end

    it "does nothing when no assistant message exists" do
      h = Arcana::Chat::History.new
      h.add_user("Hi")
      h.update_last_assistant("Nope")
      h.size.should eq(1)
    end
  end

  describe "#trim_if_needed" do
    it "does not trim when under limit" do
      h = Arcana::Chat::History.new
      h.add_system("sys")
      h.add_user("short")
      h.add_assistant("reply")
      h.trim_if_needed
      h.size.should eq(3)
    end

    it "trims middle messages when over limit" do
      h = Arcana::Chat::History.new
      h.add_system("sys")
      h.add_user("first user")
      h.add_assistant("first reply")

      # Add enough messages to exceed 100k chars
      20.times do |i|
        h.add_user("x" * 6000)
        h.add_assistant("y" * 6000)
      end

      original_size = h.size
      h.trim_if_needed
      h.size.should be < original_size

      # System message preserved
      h.messages[0].role.should eq("system")
      h.messages[0].content.should eq("sys")

      # First user/assistant preserved
      h.messages[1].content.should eq("first user")
      h.messages[2].content.should eq("first reply")
    end
  end
end
