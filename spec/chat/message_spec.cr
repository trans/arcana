require "../spec_helper"

describe Arcana::Chat::Message do
  describe ".system" do
    it "creates a system message" do
      msg = Arcana::Chat::Message.system("You are helpful.")
      msg.role.should eq("system")
      msg.content.should eq("You are helpful.")
    end
  end

  describe ".user" do
    it "creates a user message" do
      msg = Arcana::Chat::Message.user("Hello")
      msg.role.should eq("user")
      msg.content.should eq("Hello")
    end

    it "accepts an optional name" do
      msg = Arcana::Chat::Message.user("Hello", name: "Alice")
      msg.name.should eq("Alice")
    end
  end

  describe ".assistant" do
    it "creates an assistant message" do
      msg = Arcana::Chat::Message.assistant("Hi there")
      msg.role.should eq("assistant")
      msg.content.should eq("Hi there")
    end
  end

  describe "#to_json" do
    it "serializes role and content" do
      msg = Arcana::Chat::Message.user("test")
      json = JSON.parse(msg.to_json)
      json["role"].as_s.should eq("user")
      json["content"].as_s.should eq("test")
    end

    it "includes name when present" do
      msg = Arcana::Chat::Message.user("test", name: "Bob")
      json = JSON.parse(msg.to_json)
      json["name"].as_s.should eq("Bob")
    end

    it "omits nil fields" do
      msg = Arcana::Chat::Message.user("test")
      json = JSON.parse(msg.to_json)
      json["name"]?.should be_nil
      json["tool_calls"]?.should be_nil
      json["tool_call_id"]?.should be_nil
    end

    it "serializes tool_call_id for tool messages" do
      msg = Arcana::Chat::Message.new("tool", content: "result", tool_call_id: "call_123")
      json = JSON.parse(msg.to_json)
      json["role"].as_s.should eq("tool")
      json["tool_call_id"].as_s.should eq("call_123")
    end

    it "serializes tool_calls on assistant messages" do
      tc = Arcana::Chat::ToolCall.new(
        id: "call_1",
        type: "function",
        function: Arcana::Chat::ToolCall::FunctionCall.new("get_weather", %({"city":"Tokyo"})),
      )
      msg = Arcana::Chat::Message.new("assistant", tool_calls: [tc])
      json = JSON.parse(msg.to_json)
      calls = json["tool_calls"].as_a
      calls.size.should eq(1)
      calls[0]["function"]["name"].as_s.should eq("get_weather")
    end
  end
end
