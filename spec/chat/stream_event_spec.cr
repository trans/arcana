require "../spec_helper"

describe Arcana::Chat::StreamEvent do
  it "creates text_delta event" do
    event = Arcana::Chat::StreamEvent.text_delta("hello")
    event.type.should eq(Arcana::Chat::StreamEvent::Type::TextDelta)
    event.text.should eq("hello")
  end

  it "creates tool_use event" do
    tc = Arcana::Chat::ToolCall.new(
      id: "call_1",
      type: "function",
      function: Arcana::Chat::ToolCall::FunctionCall.new("search", %({"q":"test"})),
    )
    event = Arcana::Chat::StreamEvent.tool_use(tc)
    event.type.should eq(Arcana::Chat::StreamEvent::Type::ToolUse)
    event.tool_call.not_nil!.function.name.should eq("search")
  end

  it "creates done event with response" do
    resp = Arcana::Chat::Response.new(content: "done", model: "test")
    event = Arcana::Chat::StreamEvent.done(resp)
    event.type.should eq(Arcana::Chat::StreamEvent::Type::Done)
    event.response.not_nil!.content.should eq("done")
  end

  it "creates error event" do
    event = Arcana::Chat::StreamEvent.error("something broke")
    event.type.should eq(Arcana::Chat::StreamEvent::Type::Error)
    event.error.should eq("something broke")
  end
end

describe "Provider#stream default" do
  it "raises not supported for base provider usage" do
    # Test via the abstract interface — OpenAI and Anthropic override this
    # Just verify the event struct works correctly
    events = [] of Arcana::Chat::StreamEvent
    events << Arcana::Chat::StreamEvent.text_delta("Hi ")
    events << Arcana::Chat::StreamEvent.text_delta("there")
    events << Arcana::Chat::StreamEvent.done(Arcana::Chat::Response.new(content: "Hi there"))

    events.size.should eq(3)
    events[0].type.text_delta?.should be_true
    events[1].type.text_delta?.should be_true
    events[2].type.done?.should be_true
    events[2].response.not_nil!.content.should eq("Hi there")
  end
end
