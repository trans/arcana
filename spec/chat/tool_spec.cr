require "../spec_helper"

describe Arcana::Chat::Tool do
  describe "#to_json" do
    it "serializes to OpenAI function-calling format" do
      tool = Arcana::Chat::Tool.new(
        name: "search",
        description: "Search the web",
        parameters_json: %({"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}),
      )

      json = JSON.parse(tool.to_json)
      json["type"].as_s.should eq("function")
      fn = json["function"]
      fn["name"].as_s.should eq("search")
      fn["description"].as_s.should eq("Search the web")
      fn["parameters"]["type"].as_s.should eq("object")
      fn["parameters"]["properties"]["query"]["type"].as_s.should eq("string")
      fn["parameters"]["required"].as_a.map(&.as_s).should eq(["query"])
    end
  end
end

describe Arcana::Chat::ServerTool do
  it "creates web_search convenience" do
    st = Arcana::Chat::ServerTool.web_search(max_uses: 3)
    st.type.should eq("web_search_20250305")
    st.name.should eq("web_search")
    st.config["max_uses"].as_i.should eq(3)
  end

  it "creates web_search without config" do
    st = Arcana::Chat::ServerTool.web_search
    st.type.should eq("web_search_20250305")
    st.config.should be_empty
  end

  it "creates code_execution convenience" do
    st = Arcana::Chat::ServerTool.code_execution
    st.type.should eq("code_execution_20250522")
    st.name.should eq("code_execution")
  end
end

describe Arcana::Chat::ToolCall do
  describe "#parsed_arguments" do
    it "parses valid JSON arguments" do
      tc = Arcana::Chat::ToolCall.new(
        id: "call_1",
        type: "function",
        function: Arcana::Chat::ToolCall::FunctionCall.new("fn", %({"a":1,"b":"two"})),
      )
      args = tc.parsed_arguments
      args["a"].as_i.should eq(1)
      args["b"].as_s.should eq("two")
    end

    it "returns empty hash for invalid JSON" do
      tc = Arcana::Chat::ToolCall.new(
        id: "call_1",
        type: "function",
        function: Arcana::Chat::ToolCall::FunctionCall.new("fn", "not json"),
      )
      tc.parsed_arguments.should be_empty
    end
  end
end
