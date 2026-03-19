require "./spec_helper"

# Expose handle_message for testing.
class Arcana::MCP
  def test_handle(msg : JSON::Any) : JSON::Any?
    handle_message(msg)
  end
end

describe Arcana::MCP do
  it "has the expected tools defined" do
    tools = Arcana::MCP::TOOLS
    names = tools.map { |t| t[:name] }
    names.should contain("arcana_directory")
    names.should contain("arcana_request")
    names.should contain("arcana_send")
    names.should contain("arcana_publish")
    names.should contain("arcana_register")
    names.should contain("arcana_unregister")
    names.should contain("arcana_receive")
    names.should contain("arcana_health")
  end

  it "handles initialize message" do
    mcp = Arcana::MCP.new
    msg = JSON.parse(%({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","clientInfo":{"name":"test"}}}))
    response = mcp.test_handle(msg)
    response.should_not be_nil
    result = response.not_nil!["result"]
    result["protocolVersion"].as_s.should eq("2024-11-05")
    result["serverInfo"]["name"].as_s.should eq("arcana")
  end

  it "handles tools/list message" do
    mcp = Arcana::MCP.new
    msg = JSON.parse(%({"jsonrpc":"2.0","id":2,"method":"tools/list"}))
    response = mcp.test_handle(msg)
    response.should_not be_nil
    tools = response.not_nil!["result"]["tools"].as_a
    tools.size.should eq(12)
  end

  it "returns nil for notifications" do
    mcp = Arcana::MCP.new
    msg = JSON.parse(%({"jsonrpc":"2.0","method":"notifications/initialized"}))
    response = mcp.test_handle(msg)
    response.should be_nil
  end

  it "returns error for unknown methods" do
    mcp = Arcana::MCP.new
    msg = JSON.parse(%({"jsonrpc":"2.0","id":99,"method":"unknown/method"}))
    response = mcp.test_handle(msg)
    response.should_not be_nil
    response.not_nil!["error"]["code"].as_i.should eq(-32601)
  end
end
