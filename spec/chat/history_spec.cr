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

    it "removes tool_use/tool_result pairs together" do
      h = Arcana::Chat::History.new
      h.add_system("sys")
      h.add_user("first user")
      h.add_assistant("first reply")

      # Add a tool_use + tool_result pair in the middle
      tc = Arcana::Chat::ToolCall.new(
        id: "call_1",
        type: "function",
        function: Arcana::Chat::ToolCall::FunctionCall.new("search", "{}"),
      )
      h.messages << Arcana::Chat::Message.user("x" * 6000)
      h.messages << Arcana::Chat::Message.new("assistant", tool_calls: [tc])
      h.messages << Arcana::Chat::Message.new("tool", content: "result data", tool_call_id: "call_1")
      h.messages << Arcana::Chat::Message.assistant("based on the search...")

      # Pad to exceed limit
      20.times do
        h.add_user("x" * 6000)
        h.add_assistant("y" * 6000)
      end

      h.trim_if_needed

      # Verify no orphaned tool_use or tool_result
      h.messages.each_with_index do |msg, i|
        if msg.role == "assistant" && msg.tool_calls.try(&.size.>(0))
          # Next message must be a tool result
          next_msg = h.messages[i + 1]?
          next_msg.should_not be_nil
          next_msg.not_nil!.role.should eq("tool")
        end
        if msg.role == "tool"
          # Previous message must be an assistant with tool_calls (or another tool)
          prev_msg = h.messages[i - 1]?
          prev_msg.should_not be_nil
          prev_role = prev_msg.not_nil!.role
          (prev_role == "assistant" || prev_role == "tool").should be_true
        end
      end
    end
  end
end
