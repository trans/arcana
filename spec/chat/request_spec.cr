require "../spec_helper"

describe Arcana::Chat::Request do
  describe ".from_history" do
    it "builds a request from history" do
      h = Arcana::Chat::History.new
      h.add_system("Be concise.")
      h.add_user("Hello")

      req = Arcana::Chat::Request.from_history(h,
        model: "gpt-4o",
        temperature: 0.3,
        max_tokens: 200,
      )

      req.messages.size.should eq(2)
      req.messages[0].role.should eq("system")
      req.messages[1].role.should eq("user")
      req.model.should eq("gpt-4o")
      req.temperature.should eq(0.3)
      req.max_tokens.should eq(200)
    end

    it "duplicates messages so history mutations don't affect request" do
      h = Arcana::Chat::History.new
      h.add_user("Hello")
      req = Arcana::Chat::Request.from_history(h)
      h.add_user("World")

      req.messages.size.should eq(1)
      h.size.should eq(2)
    end
  end

  describe "defaults" do
    it "uses sensible defaults" do
      req = Arcana::Chat::Request.new(messages: [] of Arcana::Chat::Message)
      req.model.should eq("gpt-4o-mini")
      req.temperature.should eq(0.7)
      req.max_tokens.should eq(150)
      req.tools.should be_nil
      req.tool_choice.should be_nil
    end
  end
end
